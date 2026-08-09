import Foundation

/// Durable marker for a result-file replacement that may need startup
/// recovery.  The marker deliberately records only a final path in the same
/// directory as the transaction: recovery never follows a manifest to a
/// different directory, so a malformed or unrelated temporary directory
/// cannot make startup move or delete arbitrary files.
struct ResultWriteTransactionManifest: Codable {
    enum Phase: String, Codable {
        case prepared
        case movingPrevious
        case previousMoved
        case installingReplacement
        /// SwiftData (or the file-only ResultStore write) has saved the row
        /// that points at the replacement. Version-2 recovery can reach the
        /// same conclusion from the transaction ID persisted in SwiftData
        /// even if the process dies before this convenience phase is written.
        case persisted
    }

    let version: Int
    /// Version 2 persists this identifier in the companion SwiftData row.
    /// Startup recovery can therefore determine which side of a
    /// cross-medium commit became durable without relying on timing.
    let transactionID: String?
    let finalPath: String
    let phase: Phase

    init(
        version: Int,
        transactionID: String? = nil,
        finalPath: String,
        phase: Phase
    ) {
        self.version = version
        self.transactionID = transactionID
        self.finalPath = finalPath
        self.phase = phase
    }
}

/// Reversible replacement for a result artifact. It keeps the previous file
/// in a private sibling directory until the corresponding SwiftData save has
/// succeeded, so a failed cross-medium commit can restore the old result (or
/// remove a newly-created one).
public final class ResultWriteTransaction {
    private static let directoryPrefix = ".swiftasr-result-transaction-"
    private static let manifestFileName = "transaction-manifest.json"
    private static let stagedFileName = "staged.result.json"
    private static let backupFileName = "previous.result.json"

    private let fileManager = FileManager.default
    private let finalURL: URL
    private let temporaryDirectory: URL
    private let stagedURL: URL
    private let backupURL: URL
    private let manifestURL: URL
    private var hadPreviousFile = false
    private var previousFileStaged = false
    private var replacementInstalled = false
    private var committed = false
    private var persistenceMarked = false
    private var closed = false
    public let id: String

    public init(payload: ResultPayload, to finalURL: URL) throws {
        try payload.validate(
            expectedJobID: ResultStore.canonicalJobIDEncoded(in: finalURL)
        )
        self.id = UUID().uuidString
        self.finalURL = finalURL
        self.temporaryDirectory = finalURL.deletingLastPathComponent()
            .appendingPathComponent(Self.directoryPrefix + id, isDirectory: true)
        self.stagedURL = temporaryDirectory.appendingPathComponent(Self.stagedFileName)
        self.backupURL = temporaryDirectory.appendingPathComponent(Self.backupFileName)
        self.manifestURL = temporaryDirectory.appendingPathComponent(Self.manifestFileName)

        // R4-P0-1：事务临时目录与其中所有文件（staged/backup/manifest）都
        // 收紧到 owner-only。临时目录包含完整转写正文与 manifest 路径，
        // 不能比 result.json 本身更宽松。
        try SecureArtifactWriter.ensureDirectory(temporaryDirectory)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)
            try SecureArtifactWriter.writeData(data, to: stagedURL)
            try writeManifest(phase: .prepared)
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    public func commit() throws {
        guard !closed, !committed else { return }
        try SecureArtifactWriter.ensureDirectory(finalURL.deletingLastPathComponent())
        hadPreviousFile = fileManager.fileExists(atPath: finalURL.path)
        do {
            if hadPreviousFile {
                try writeManifest(phase: .movingPrevious)
                try fileManager.moveItem(at: finalURL, to: backupURL)
                previousFileStaged = true
                // 备份文件在临时目录里，但它也含完整转写正文，收紧到 0600。
                try SecureArtifactWriter.restrictFile(at: backupURL)
                try writeManifest(phase: .previousMoved)
            }
            try writeManifest(phase: .installingReplacement)
            try fileManager.moveItem(at: stagedURL, to: finalURL)
            replacementInstalled = true
            // 最终 result.json 落盘后收紧权限。这是 R4-P0-1 的核心写入点。
            try SecureArtifactWriter.restrictFile(at: finalURL)
            committed = true
        } catch {
            let commitError = error
            do {
                try restorePreviousFile()
            } catch {
                // R4-P1-1：结果替换事务的恢复失败也不能被静默吞掉。保留
                // transaction directory，让 startup recovery 继续处理，并把
                // 两个错误写入日志；调用方收到稳定 typed error。
                Logger.shared.error(
                    "ResultWriteTransaction \(id) commit failed and restore failed; leaving transaction directory for recovery. commit=\(commitError) restore=\(error)"
                )
                throw ResultWriteTransactionError.commitRecoveryFailed
            }
            throw commitError
        }
    }

    public func finalize() throws {
        guard !closed else { return }
        guard persistenceMarked else {
            throw ResultWriteTransactionError.persistenceNotMarked
        }
        try fileManager.removeItem(at: temporaryDirectory)
        closed = true
    }

    public func rollback() throws {
        guard !closed else { return }
        // Once the corresponding SwiftData row has been saved, rolling the
        // file back would create the inverse inconsistency. At that point
        // rollback means best-effort private-directory cleanup only.
        if persistenceMarked {
            try finalize()
            return
        }
        if (committed || replacementInstalled), fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try restorePreviousFile()
        if fileManager.fileExists(atPath: temporaryDirectory.path) {
            try fileManager.removeItem(at: temporaryDirectory)
        }
        closed = true
    }

    /// Records the durable boundary after the corresponding SwiftData save.
    /// Startup recovery treats only this phase as permission to retain the
    /// replacement file. ResultStore.write calls it immediately after the
    /// file-only commit because no cross-medium save is involved there.
    public func markPersistenceSucceeded(persistedExternally: Bool = true) throws {
        guard !closed else { return }
        guard committed else {
            throw ResultWriteTransactionError.commitRequiredBeforePersistenceMark
        }
        guard !persistenceMarked else { return }
        if persistedExternally {
            // The companion SwiftData save has already returned successfully.
            // From this point the replacement is authoritative even if writing
            // the convenience phase marker fails. The durable transaction ID
            // in SwiftData lets startup reach the same decision after a crash.
            persistenceMarked = true
            try writeManifest(phase: .persisted)
        } else {
            // File-only writes have no independent durable token. Keep them
            // rollback-capable until the persisted marker itself is durable.
            try writeManifest(phase: .persisted)
            persistenceMarked = true
        }
    }

    private func restorePreviousFile() throws {
        if !hadPreviousFile {
            if replacementInstalled, fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            return
        }
        guard previousFileStaged else { return }
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: backupURL.path
            ])
        }
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: backupURL, to: finalURL)
        try SecureArtifactWriter.restrictFile(at: finalURL)
    }

    private func writeManifest(phase: ResultWriteTransactionManifest.Phase) throws {
        let manifest = ResultWriteTransactionManifest(
            version: 2,
            transactionID: id,
            finalPath: finalURL.standardizedFileURL.path,
            phase: phase
        )
        // R4-P0-1：manifest 在临时事务目录里，记录 finalPath；与 staged /
        // backup 文件一起收紧到 0600。
        try SecureArtifactWriter.writeEncodable(manifest, to: manifestURL)
    }

    /// Repairs transactions left by a process crash in one result directory.
    ///
    /// A replacement is retained after its manifest reaches `.persisted` or
    /// its version-2 transaction ID is present in SwiftData. Before either
    /// durable boundary, recovery restores `previous.result.json` or removes
    /// a newly-created final file. The operation is idempotent: a second
    /// startup sees neither a marker nor an incomplete transaction.
    ///
    /// Directories without our prefix *and* a valid versioned manifest are
    /// ignored.  A valid manifest must also point back to a final path in this
    /// exact parent directory, so startup never deletes an unknown temporary
    /// directory or follows an arbitrary path from disk.
    @discardableResult
    public static func recoverInterruptedTransactions(
        in directory: URL,
        persistedTransactionIDs: Set<String> = []
    ) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }

        var recovered = 0
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        )
        for transactionDirectory in entries
            where transactionDirectory.lastPathComponent.hasPrefix(directoryPrefix) {
            let values = try transactionDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            guard try recoverInterruptedTransaction(
                at: transactionDirectory,
                in: directory,
                fileManager: fileManager,
                persistedTransactionIDs: persistedTransactionIDs
            ) else { continue }
            recovered += 1
        }
        return recovered
    }

    /// Recursively finds private transaction directories below a stage root.
    /// This is intentionally limited to directories carrying the versioned
    /// manifest validated by `recoverInterruptedTransactions(in:)`; it does
    /// not descend into symbolic-link directories outside the stage root.
    @discardableResult
    public static func recoverInterruptedTransactions(
        under root: URL,
        persistedTransactionIDs: Set<String> = []
    ) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return 0 }

        var directories = [root]
        var recovered = 0
        while let directory = directories.popLast() {
            recovered += try recoverInterruptedTransactions(
                in: directory,
                persistedTransactionIDs: persistedTransactionIDs
            )
            let entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants]
            )
            for entry in entries {
                guard entry.lastPathComponent.hasPrefix(directoryPrefix) == false else { continue }
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    directories.append(entry)
                }
            }
        }
        return recovered
    }

    private static func recoverInterruptedTransaction(
        at temporaryDirectory: URL,
        in expectedParentDirectory: URL,
        fileManager: FileManager,
        persistedTransactionIDs: Set<String>
    ) throws -> Bool {
        let manifestURL = temporaryDirectory.appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ResultWriteTransactionManifest.self, from: data),
              [1, 2].contains(manifest.version)
        else { return false }

        guard manifest.finalPath.hasPrefix("/") else { return false }
        let finalURL = URL(fileURLWithPath: manifest.finalPath).standardizedFileURL
        guard finalURL.deletingLastPathComponent().standardizedFileURL == expectedParentDirectory.standardizedFileURL,
              !finalURL.lastPathComponent.isEmpty
        else { return false }

        let stagedURL = temporaryDirectory.appendingPathComponent(stagedFileName)
        let backupURL = temporaryDirectory.appendingPathComponent(backupFileName)
        let finalExists = fileManager.fileExists(atPath: finalURL.path)
        let stagedExists = fileManager.fileExists(atPath: stagedURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        let persistedBySwiftData = manifest.transactionID.map {
            persistedTransactionIDs.contains($0)
        } ?? false
        let replacementIsAuthoritative = manifest.phase == .persisted
            || persistedBySwiftData
        if replacementIsAuthoritative {
            if !finalExists, stagedExists {
                // The database proves the replacement commit. Finish an
                // interrupted final rename instead of rolling back to a file
                // that no longer matches the persisted row.
                try fileManager.moveItem(at: stagedURL, to: finalURL)
                // R4-P0-1：崩溃恢复落盘的 result.json 也要收紧 0600；
                // 它的来源可能是旧版本写出的未收紧文件。
                try SecureArtifactWriter.restrictFile(at: finalURL)
            }
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: temporaryDirectory)
                return true
            }
        }
        if manifest.phase == .prepared || manifest.phase == .movingPrevious {
            // No replacement is known to have started. In particular, a
            // pre-existing final file is still the old durable result and
            // must never be removed merely because its transaction marker
            // was created before the process crashed.
            if !backupExists {
                try fileManager.removeItem(at: temporaryDirectory)
                return true
            }
            // If the old file did reach the backup despite the earlier marker
            // phase, fall through and restore it conservatively.
        }
        if manifest.phase != .persisted, backupExists {
            if finalExists {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: backupURL, to: finalURL)
            try fileManager.removeItem(at: temporaryDirectory)
            return true
        }
        if manifest.phase == .installingReplacement, !backupExists {
            // No previous result existed. The replacement is still
            // unpersisted, so remove either a staged or already-moved final
            // file rather than publishing a result whose SwiftData update may
            // never have been saved.
            if finalExists {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.removeItem(at: temporaryDirectory)
            return true
        }
        return false
    }

    deinit {
        guard !closed else { return }
        if persistenceMarked {
            do {
                try finalize()
            } catch {
                // 已经 markPersistenceSucceeded 但 finalize 失败：.swiftasr-result-transaction-*
                // 目录会残留，由启动恢复介入。跟 ResultArtifactDeletionTransaction.deinit
                // 对齐：显式 log 而不是静默吞错，让用户/调试能从 log 看出"为什 cleanup 没结束"。
                Logger.shared.warn(
                    "ResultWriteTransaction \(id) committed but finalize failed in deinit; startup will recover: \(error)"
                )
            }
        } else {
            do {
                try rollback()
            } catch {
                Logger.shared.warn(
                    "ResultWriteTransaction \(id) rollback failed in deinit; startup will recover: \(error)"
                )
            }
        }
    }
}

public enum ResultWriteTransactionError: Error, LocalizedError {
    case persistenceNotMarked
    case commitRequiredBeforePersistenceMark
    case commitRecoveryFailed

    public var errorDescription: String? {
        switch self {
        case .persistenceNotMarked:
            return "Result transaction cannot finalize before its persistence mark."
        case .commitRequiredBeforePersistenceMark:
            return "Result transaction cannot mark persistence before commit."
        case .commitRecoveryFailed:
            return "结果替换失败且恢复未完成，事务将由启动恢复继续处理。"
        }
    }
}
