import Foundation

struct ResultArtifactDeletionManifest: Codable {
    enum Phase: String, Codable {
        case prepared
        case staged
        case persisted
    }

    struct Entry: Codable {
        let originalPath: String
        let stagedName: String
    }

    let version: Int
    let transactionID: String
    let jobID: String
    let phase: Phase
    let entries: [Entry]
}

/// Durable file-side transaction used when deleting or replacing all artifacts
/// owned by a job. Artifacts are staged under the application stage root, not
/// `NSTemporaryDirectory`, and a versioned manifest lets startup either
/// restore them or finish deletion based on the companion SwiftData commit.
public final class ResultArtifactDeletionTransaction {
    private static let directoryPrefix = ".swiftasr-artifact-deletion-"
    private static let manifestFileName = "deletion-manifest.json"

    private let fileManager = FileManager.default
    private let transactionDirectory: URL
    private let manifestURL: URL
    private let jobID: String
    private var entries: [ResultArtifactDeletionManifest.Entry]
    private var isClosed = false
    private var persistenceSucceeded = false
    public let id: String

    public init(
        jobId: String,
        storedPath: String?,
        stageRoot: String? = nil
    ) throws {
        id = UUID().uuidString
        jobID = jobId
        let durableRoot = URL(
            fileURLWithPath: stageRoot ?? ResultStore.defaultStageRoot(),
            isDirectory: true
        )
        transactionDirectory = durableRoot.appendingPathComponent(
            Self.directoryPrefix + id,
            isDirectory: true
        )
        manifestURL = transactionDirectory.appendingPathComponent(Self.manifestFileName)

        let existingArtifacts = ResultStore.artifactPaths(
            jobId: jobId,
            storedPath: storedPath,
            stageRoot: stageRoot
        ).filter { FileManager.default.fileExists(atPath: $0.path) }
        entries = existingArtifacts.enumerated().map { index, original in
            ResultArtifactDeletionManifest.Entry(
                originalPath: original.standardizedFileURL.path,
                stagedName: "\(index)-\(original.lastPathComponent)"
            )
        }
        // R4-P0-1：删除事务目录与其中 staged 文件（含转写正文副本）收紧到
        // owner-only。
        try SecureArtifactWriter.ensureDirectory(transactionDirectory)

        do {
            try writeManifest(phase: .prepared)
            for entry in entries {
                let original = URL(fileURLWithPath: entry.originalPath)
                let staged = transactionDirectory.appendingPathComponent(entry.stagedName)
                try fileManager.moveItem(at: original, to: staged)
                // staged 文件含转写正文 / 声纹证据，收紧 0600。
                try SecureArtifactWriter.restrictFile(at: staged)
            }
            try writeManifest(phase: .staged)
        } catch {
            let stagingError = error
            // R4-P1-1：staging 失败后恢复也不可静默吞错。恢复失败必须留 log，
            // 否则部分 artifact 已经被 move 走，调用方只看到原始 error，
            // 不会知道恢复也失败，用户结果文件可能处于中间态且无任何痕迹。
            do {
                try Self.restore(
                    entries: entries,
                    transactionDirectory: transactionDirectory,
                    fileManager: fileManager
                )
            } catch {
                Logger.shared.error(
                    "ArtifactDeletionTransaction \(id) init restore failed after staging error; leaving transaction directory for retry. staging error=\(stagingError) restore error=\(error)"
                )
                // 恢复失败时保留事务目录，让下次启动 recovery 继续处理，
                // 不要删除唯一恢复证据。
                throw stagingError
            }
            // 恢复成功才清理事务目录。
            try? fileManager.removeItem(at: transactionDirectory)
            throw stagingError
        }
    }

    /// Records the already-successful SwiftData commit and permanently removes
    /// the staged artifacts. The in-memory boundary is flipped before manifest
    /// IO so a post-save marker failure can never restore deleted data.
    public func commit() throws {
        guard !isClosed else { return }
        persistenceSucceeded = true
        try writeManifest(phase: .persisted)
        try fileManager.removeItem(at: transactionDirectory)
        isClosed = true
    }

    /// Restores artifacts to their original paths. This is used when the
    /// corresponding SwiftData transaction cannot be saved.
    public func restore() throws {
        guard !isClosed else { return }
        guard !persistenceSucceeded else {
            throw ResultArtifactDeletionTransactionError.persistenceAlreadySucceeded
        }
        try Self.restore(
            entries: entries,
            transactionDirectory: transactionDirectory,
            fileManager: fileManager
        )
        // 恢复成功才删除事务目录；删除失败不致命（下次启动 recovery 兜底），
        // 但走 log 让运维能定位残留目录。
        do {
            try fileManager.removeItem(at: transactionDirectory)
        } catch {
            Logger.shared.warn(
                "ArtifactDeletionTransaction \(id) restored artifacts but failed to remove transaction directory; startup will finalize it: \(error)"
            )
        }
        isClosed = true
    }

    deinit {
        guard !isClosed else { return }
        if persistenceSucceeded {
            Logger.shared.warn(
                "Artifact deletion committed but transaction cleanup remains pending; startup will finalize it."
            )
        } else {
            // A normal scope exit is not a crash. Restore defensively so a
            // forgotten caller close cannot turn into user-visible data loss.
            // R4-P1-1：对齐 ResultWriteTransaction.deinit，恢复失败必须留 log，
            // 不能用 `try?` 静默吞错。
            do {
                try restore()
            } catch {
                Logger.shared.error(
                    "ArtifactDeletionTransaction \(id) restore failed in deinit; leaving transaction directory for startup recovery: \(error)"
                )
            }
        }
    }

    @discardableResult
    public static func recoverInterruptedTransactions(
        under root: URL,
        allowedArtifactPathsByJobID: [String: Set<String>],
        persistedTransactionIDs: Set<String>
    ) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        )
        var recovered = 0
        for directory in directories
            where directory.lastPathComponent.hasPrefix(directoryPrefix) {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let manifestURL = directory.appendingPathComponent(manifestFileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(
                      ResultArtifactDeletionManifest.self,
                      from: data
                  ),
                  manifest.version == 1,
                  validate(
                      manifest: manifest,
                      in: directory,
                      allowedArtifactPaths: allowedArtifactPathsByJobID[manifest.jobID]
                  )
            else { continue }

            let deletionPersisted = manifest.phase == .persisted
                || persistedTransactionIDs.contains(manifest.transactionID)
                || allowedArtifactPathsByJobID[manifest.jobID] == nil
            if deletionPersisted {
                try fileManager.removeItem(at: directory)
            } else {
                try restore(
                    entries: manifest.entries,
                    transactionDirectory: directory,
                    fileManager: fileManager
                )
                try fileManager.removeItem(at: directory)
            }
            recovered += 1
        }
        return recovered
    }

    /// Finishes cleanup for the previous deletion transaction recorded on a
    /// surviving job before that job starts another destructive operation.
    ///
    /// A SwiftData save is the durable commit boundary, so the matching
    /// transaction directory must be deleted regardless of the manifest
    /// phase. This closes the crash window where writing `.persisted` failed
    /// and a later retranscription would otherwise overwrite the job's sole
    /// transaction token. A missing directory is already finalized. If a
    /// directory exists but cannot be authenticated, fail closed and leave it
    /// untouched for startup recovery or manual diagnosis.
    @discardableResult
    public static func finalizePersistedTransaction(
        id transactionID: String,
        jobID: String,
        under root: URL? = nil
    ) throws -> Bool {
        guard isSafePathComponent(transactionID), !jobID.isEmpty else {
            throw ResultArtifactDeletionTransactionError.invalidPersistedTransaction
        }

        let fileManager = FileManager.default
        let durableRoot = (
            root ?? URL(
                fileURLWithPath: ResultStore.defaultStageRoot(),
                isDirectory: true
            )
        ).standardizedFileURL
        let directory = durableRoot
            .appendingPathComponent(directoryPrefix + transactionID, isDirectory: true)
            .standardizedFileURL
        guard directory.deletingLastPathComponent() == durableRoot else {
            throw ResultArtifactDeletionTransactionError.invalidPersistedTransaction
        }
        guard fileManager.fileExists(atPath: directory.path) else { return false }

        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ResultArtifactDeletionTransactionError.invalidPersistedTransaction
        }

        let manifestURL = directory.appendingPathComponent(manifestFileName)
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ResultArtifactDeletionTransactionError.invalidPersistedTransaction
        }
        guard let manifest = try? JSONDecoder().decode(
            ResultArtifactDeletionManifest.self,
            from: data
        ),
              manifest.version == 1,
              manifest.transactionID == transactionID,
              manifest.jobID == jobID,
              validate(
                  manifest: manifest,
                  in: directory,
                  allowedArtifactPaths: nil
              )
        else {
            throw ResultArtifactDeletionTransactionError.invalidPersistedTransaction
        }

        try fileManager.removeItem(at: directory)
        return true
    }

    private func writeManifest(phase: ResultArtifactDeletionManifest.Phase) throws {
        let manifest = ResultArtifactDeletionManifest(
            version: 1,
            transactionID: id,
            jobID: jobID,
            phase: phase,
            entries: entries
        )
        // R4-P0-1：manifest 记录 artifact 路径，与 staged 文件一起收紧到 0600。
        try SecureArtifactWriter.writeEncodable(manifest, to: manifestURL)
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }

    private static func validate(
        manifest: ResultArtifactDeletionManifest,
        in transactionDirectory: URL,
        allowedArtifactPaths: Set<String>?
    ) -> Bool {
        guard !manifest.transactionID.isEmpty, !manifest.jobID.isEmpty else { return false }
        var stagedNames = Set<String>()
        for entry in manifest.entries {
            guard entry.originalPath.hasPrefix("/"),
                  !entry.stagedName.isEmpty,
                  !entry.stagedName.contains("/"),
                  stagedNames.insert(entry.stagedName).inserted,
                  transactionDirectory.appendingPathComponent(entry.stagedName)
                    .deletingLastPathComponent().standardizedFileURL
                    == transactionDirectory.standardizedFileURL
            else { return false }
            // A surviving job row supplies the exact canonical/historical
            // artifact set that may be restored. A deleted row needs no
            // original-path trust because recovery only finalizes deletion.
            if let allowedArtifactPaths,
               !allowedArtifactPaths.contains(
                   URL(fileURLWithPath: entry.originalPath).standardizedFileURL.path
               ) {
                return false
            }
        }
        return true
    }

    private static func restore(
        entries: [ResultArtifactDeletionManifest.Entry],
        transactionDirectory: URL,
        fileManager: FileManager
    ) throws {
        for entry in entries.reversed() {
            let original = URL(fileURLWithPath: entry.originalPath)
            let staged = transactionDirectory.appendingPathComponent(entry.stagedName)
            guard fileManager.fileExists(atPath: staged.path) else { continue }
            if fileManager.fileExists(atPath: original.path) {
                throw NSError(
                    domain: "ResultStore",
                    code: -20,
                    userInfo: [NSLocalizedDescriptionKey: "无法恢复结果文件，原路径已被占用：\(original.path)"]
                )
            }
            try SecureArtifactWriter.ensureDirectory(
                original.deletingLastPathComponent()
            )
            try fileManager.moveItem(at: staged, to: original)
            // 兼容旧事务或外部 stageRoot：移动后再次收紧恢复出的 artifact。
            try SecureArtifactWriter.restrictFile(at: original)
        }
    }
}

public enum ResultArtifactDeletionTransactionError: Error, LocalizedError {
    case persistenceAlreadySucceeded
    case invalidPersistedTransaction

    public var errorDescription: String? {
        switch self {
        case .persistenceAlreadySucceeded:
            return "Artifact deletion cannot be restored after its SwiftData commit succeeded."
        case .invalidPersistedTransaction:
            return "The persisted artifact deletion transaction cannot be safely finalized."
        }
    }
}
