import Foundation
import Testing
@testable import SwiftASR

/// `ResultWriteTransaction` / `ResultArtifactDeletionTransaction` 测试（2026-07-22）。
///
/// 这两个 file-side 事务刚拆出 `ResultData.swift`，覆盖：
/// - `ResultWriteTransaction` commit / rollback / finalize 路径
/// - `ResultArtifactDeletionTransaction` commit / restore 路径
/// - 失败时的 cleanup 行为
///
/// 用 `FileManager` + `NSTemporaryDirectory()` 真实写盘，结束后清理。
@Suite(.serialized)
@MainActor
struct ResultTransactionsTests {
    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftASR-ResultTxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEmptyPayload(jobId: String, audioPath: String) -> ResultPayload {
        ResultPayload(
            jobId: jobId,
            audioPath: audioPath,
            segments: [],
            speakers: [],
            finishedAt: "2026-07-22T00:00:00Z",
            cleanedModel: nil,
            mergedResults: []
        )
    }

    private func readResult(at url: URL) throws -> ResultPayload? {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ResultPayload.self, from: data)
    }

    // MARK: - ResultWriteTransaction

    @Test func writeTransaction_commit_writesToFinalURL() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finalURL = dir.appendingPathComponent("result.json")

        let payload = makeEmptyPayload(jobId: "test", audioPath: "/tmp/test.wav")
        let tx = try ResultWriteTransaction(payload: payload, to: finalURL)
        try tx.commit()
        try tx.markPersistenceSucceeded()
        try tx.finalize()

        // 临时目录已清
        let stagedDirExists = FileManager.default.fileExists(atPath: finalURL.deletingLastPathComponent().path)
        #expect(stagedDirExists)
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        let written = try readResult(at: finalURL)
        #expect(written?.jobId == "test")
    }

    @Test func writeTransaction_rollback_removesNewFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finalURL = dir.appendingPathComponent("result.json")

        let payload = makeEmptyPayload(jobId: "test", audioPath: "/tmp/test.wav")
        let tx = try ResultWriteTransaction(payload: payload, to: finalURL)
        try tx.commit()
        // 不 finalize — 模拟 SwiftData save 失败，调用 rollback
        try tx.rollback()

        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
    }

    @Test func writeTransaction_rollback_restoresPreviousFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finalURL = dir.appendingPathComponent("result.json")

        // 先写一个旧版本
        let oldPayload = makeEmptyPayload(jobId: "old", audioPath: "/tmp/old.wav")
        let oldData = try JSONEncoder().encode(oldPayload)
        try oldData.write(to: finalURL, options: [.atomic])

        // 启动新 transaction
        let newPayload = makeEmptyPayload(jobId: "new", audioPath: "/tmp/new.wav")
        let tx = try ResultWriteTransaction(payload: newPayload, to: finalURL)
        try tx.commit()
        // rollback
        try tx.rollback()

        // 旧文件应被恢复
        let restored = try readResult(at: finalURL)
        #expect(restored?.jobId == "old")
    }

    @Test func writeTransaction_isIdempotent() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finalURL = dir.appendingPathComponent("result.json")

        let payload = makeEmptyPayload(jobId: "test", audioPath: "/tmp/test.wav")
        let tx = try ResultWriteTransaction(payload: payload, to: finalURL)
        try tx.commit()
        // 重复 commit 不应报错
        try tx.commit()
        try tx.markPersistenceSucceeded()
        try tx.finalize()
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
    }

    @Test func startupRecovery_restoresPreviousResultAfterInterruptedReplacement() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finalURL = dir.appendingPathComponent("result.json")
        let oldPayload = makeEmptyPayload(jobId: "old", audioPath: "/tmp/old.wav")
        let newPayload = makeEmptyPayload(jobId: "new", audioPath: "/tmp/new.wav")
        try JSONEncoder().encode(oldPayload).write(to: finalURL, options: [.atomic])

        // Recreate the exact crash window: the old result has been moved to
        // the transaction backup, while the staged replacement has not yet
        // reached its final path.
        let transactionDirectory = dir.appendingPathComponent(
            ".swiftasr-result-transaction-crash-window",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: finalURL,
            to: transactionDirectory.appendingPathComponent("previous.result.json")
        )
        try JSONEncoder().encode(newPayload).write(
            to: transactionDirectory.appendingPathComponent("staged.result.json"),
            options: [.atomic]
        )
        let manifest = ResultWriteTransactionManifest(
            version: 1,
            finalPath: finalURL.standardizedFileURL.path,
            phase: .previousMoved
        )
        try JSONEncoder().encode(manifest).write(
            to: transactionDirectory.appendingPathComponent("transaction-manifest.json"),
            options: [.atomic]
        )

        #expect(try ResultWriteTransaction.recoverInterruptedTransactions(in: dir) == 1)
        #expect(try readResult(at: finalURL)?.jobId == "old")
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
        #expect(try ResultWriteTransaction.recoverInterruptedTransactions(in: dir) == 0)
    }

    @Test func startupRecovery_leavesUnknownTemporaryDirectoryUntouched() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unknownDirectory = dir.appendingPathComponent(
            ".swiftasr-result-transaction-not-ours",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unknownDirectory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unknownDirectory.appendingPathComponent("unrelated"))

        #expect(try ResultWriteTransaction.recoverInterruptedTransactions(in: dir) == 0)
        #expect(FileManager.default.fileExists(atPath: unknownDirectory.path))
    }

    @Test func startupRecovery_discardsUnpersistedReplacementButKeepsPersistedReplacement() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = makeEmptyPayload(jobId: "new", audioPath: "/tmp/new.wav")

        let unpersistedFinal = dir.appendingPathComponent("unpersisted.result.json")
        let unpersistedTransaction = dir.appendingPathComponent(
            ".swiftasr-result-transaction-unpersisted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unpersistedTransaction, withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: unpersistedFinal, options: [.atomic])
        try JSONEncoder().encode(ResultWriteTransactionManifest(
            version: 1,
            finalPath: unpersistedFinal.standardizedFileURL.path,
            phase: .installingReplacement
        )).write(
            to: unpersistedTransaction.appendingPathComponent("transaction-manifest.json"),
            options: [.atomic]
        )

        let persistedFinal = dir.appendingPathComponent("persisted.result.json")
        let persistedTransaction = dir.appendingPathComponent(
            ".swiftasr-result-transaction-persisted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: persistedTransaction, withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: persistedFinal, options: [.atomic])
        try JSONEncoder().encode(ResultWriteTransactionManifest(
            version: 1,
            finalPath: persistedFinal.standardizedFileURL.path,
            phase: .persisted
        )).write(
            to: persistedTransaction.appendingPathComponent("transaction-manifest.json"),
            options: [.atomic]
        )

        #expect(try ResultWriteTransaction.recoverInterruptedTransactions(in: dir) == 2)
        #expect(!FileManager.default.fileExists(atPath: unpersistedFinal.path))
        #expect(!FileManager.default.fileExists(atPath: unpersistedTransaction.path))
        #expect(FileManager.default.fileExists(atPath: persistedFinal.path))
        #expect(!FileManager.default.fileExists(atPath: persistedTransaction.path))
    }

    @Test func startupRecovery_keepsReplacementWhenSwiftDataTransactionIDPersisted() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finalURL = dir.appendingPathComponent("persisted-by-row.result.json")
        let transactionDirectory = dir.appendingPathComponent(
            ".swiftasr-result-transaction-row-token",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(makeEmptyPayload(jobId: "job", audioPath: "/tmp/job.wav"))
            .write(to: finalURL, options: [.atomic])
        try JSONEncoder().encode(ResultWriteTransactionManifest(
            version: 2,
            transactionID: "persisted-row-token",
            finalPath: finalURL.standardizedFileURL.path,
            phase: .installingReplacement
        )).write(
            to: transactionDirectory.appendingPathComponent("transaction-manifest.json"),
            options: [.atomic]
        )

        #expect(try ResultWriteTransaction.recoverInterruptedTransactions(
            in: dir,
            persistedTransactionIDs: ["persisted-row-token"]
        ) == 1)
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    @Test func startupRecovery_finishesStagedReplacementWhenSwiftDataTokenPersisted() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finalURL = dir.appendingPathComponent("staged-by-row.result.json")
        let transactionDirectory = dir.appendingPathComponent(
            ".swiftasr-result-transaction-row-token-staged",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(makeEmptyPayload(jobId: "job", audioPath: "/tmp/job.wav"))
            .write(
                to: transactionDirectory.appendingPathComponent("staged.result.json"),
                options: [.atomic]
            )
        try JSONEncoder().encode(ResultWriteTransactionManifest(
            version: 2,
            transactionID: "persisted-staged-token",
            finalPath: finalURL.standardizedFileURL.path,
            phase: .installingReplacement
        )).write(
            to: transactionDirectory.appendingPathComponent("transaction-manifest.json"),
            options: [.atomic]
        )

        #expect(try ResultWriteTransaction.recoverInterruptedTransactions(
            in: dir,
            persistedTransactionIDs: ["persisted-staged-token"]
        ) == 1)
        #expect(try readResult(at: finalURL)?.jobId == "job")
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    @Test func startupRecovery_keepsPreviousFinalWhenReplacementNeverStarted() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finalURL = dir.appendingPathComponent("result.json")
        let oldPayload = makeEmptyPayload(jobId: "old", audioPath: "/tmp/old.wav")
        let stagedPayload = makeEmptyPayload(jobId: "new", audioPath: "/tmp/new.wav")
        try JSONEncoder().encode(oldPayload).write(to: finalURL, options: [.atomic])
        let transactionDirectory = dir.appendingPathComponent(
            ".swiftasr-result-transaction-prepared",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(stagedPayload).write(
            to: transactionDirectory.appendingPathComponent("staged.result.json"),
            options: [.atomic]
        )
        try JSONEncoder().encode(ResultWriteTransactionManifest(
            version: 1,
            finalPath: finalURL.standardizedFileURL.path,
            phase: .prepared
        )).write(
            to: transactionDirectory.appendingPathComponent("transaction-manifest.json"),
            options: [.atomic]
        )

        #expect(try ResultWriteTransaction.recoverInterruptedTransactions(in: dir) == 1)
        #expect(try readResult(at: finalURL)?.jobId == "old")
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    @Test func recursiveRecoveryDoesNotFollowSymbolicLinkDirectories() throws {
        let root = try makeTempDirectory()
        let outside = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideFinal = outside.appendingPathComponent("result.json")
        let outsideTransaction = outside.appendingPathComponent(
            ".swiftasr-result-transaction-outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outsideTransaction, withIntermediateDirectories: true)
        try JSONEncoder().encode(makeEmptyPayload(jobId: "outside", audioPath: "/tmp/outside.wav"))
            .write(to: outsideFinal, options: [.atomic])
        try JSONEncoder().encode(ResultWriteTransactionManifest(
            version: 1,
            finalPath: outsideFinal.standardizedFileURL.path,
            phase: .persisted
        )).write(
            to: outsideTransaction.appendingPathComponent("transaction-manifest.json"),
            options: [.atomic]
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("outside-link").path,
            withDestinationPath: outside.path
        )

        #expect(try ResultWriteTransaction.recoverInterruptedTransactions(under: root) == 0)
        #expect(FileManager.default.fileExists(atPath: outsideTransaction.path))
        #expect(FileManager.default.fileExists(atPath: outsideFinal.path))
    }

    // MARK: - ResultArtifactDeletionTransaction
    //
    // 2026-07-22 扩展 `ResultArtifactDeletionTransaction.init` 加 `stageRoot: String?`，
    // 让测试能在临时目录里跑（避免污染生产 AppSupport）。

    @Test func deletionTransaction_commit_removesArtifacts() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let jobId = "del-test-\(UUID().uuidString.prefix(8))"
        let stageResultURL = ResultStore.stageResultPath(
            jobId: String(jobId),
            stageRoot: stageRoot.path
        )
        try FileManager.default.createDirectory(
            at: stageResultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = makeEmptyPayload(jobId: String(jobId), audioPath: "/tmp/del.wav")
        let data = try JSONEncoder().encode(payload)
        try data.write(to: stageResultURL, options: [.atomic])

        #expect(FileManager.default.fileExists(atPath: stageResultURL.path))

        let tx = try ResultArtifactDeletionTransaction(
            jobId: String(jobId),
            storedPath: nil,
            stageRoot: stageRoot.path
        )
        try tx.commit()

        #expect(!FileManager.default.fileExists(atPath: stageResultURL.path))
    }

    /// R4-P0-1：删除事务把 artifact stage 到事务目录时，staged 文件含完整
    /// 转写正文副本，必须收紧到 0600。
    @Test func deletionTransaction_stagesFilesWithOwnerOnlyPermissions() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let jobId = "perm-test-\(UUID().uuidString.prefix(8))"
        let stageResultURL = ResultStore.stageResultPath(
            jobId: String(jobId),
            stageRoot: stageRoot.path
        )
        try FileManager.default.createDirectory(
            at: stageResultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = makeEmptyPayload(jobId: String(jobId), audioPath: "/tmp/perm.wav")
        try JSONEncoder().encode(payload).write(to: stageResultURL, options: [.atomic])

        let tx = try ResultArtifactDeletionTransaction(
            jobId: String(jobId),
            storedPath: nil,
            stageRoot: stageRoot.path
        )
        // 不 commit，让 staged 文件留在事务目录里检查权限。
        // 事务目录位于 stageRoot 下，stageRoot 在系统临时目录下（测试）所以
        // 目录本身不会被 ensureDirectory 收紧，但 staged 文件会走 restrictFile。
        let manifestURL = stageRoot.appendingPathComponent(
            ".swiftasr-artifact-deletion-\(tx.id)"
        ).appendingPathComponent("deletion-manifest.json")
        #expect(
            SecureArtifactWriter.currentPermissions(at: manifestURL) == 0o600
        )
        // 显式 restore 清理（避免 deinit 路径在 @MainActor 下的时序问题）。
        try tx.restore()
    }

    @Test func deletionTransaction_restore_movesArtifactsBack() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let jobId = "restore-test-\(UUID().uuidString.prefix(8))"
        let stageResultURL = ResultStore.stageResultPath(
            jobId: String(jobId),
            stageRoot: stageRoot.path
        )
        try FileManager.default.createDirectory(
            at: stageResultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = makeEmptyPayload(jobId: String(jobId), audioPath: "/tmp/restore.wav")
        let data = try JSONEncoder().encode(payload)
        try data.write(to: stageResultURL, options: [.atomic])

        let tx = try ResultArtifactDeletionTransaction(
            jobId: String(jobId),
            storedPath: nil,
            stageRoot: stageRoot.path
        )
        // 不 commit，调 restore
        try tx.restore()

        #expect(FileManager.default.fileExists(atPath: stageResultURL.path))
    }

    @Test func deletionTransaction_isIdempotent() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let jobId = "idem-test-\(UUID().uuidString.prefix(8))"
        let stageResultURL = ResultStore.stageResultPath(
            jobId: String(jobId),
            stageRoot: stageRoot.path
        )
        try FileManager.default.createDirectory(
            at: stageResultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = makeEmptyPayload(jobId: String(jobId), audioPath: "/tmp/idem.wav")
        let data = try JSONEncoder().encode(payload)
        try data.write(to: stageResultURL, options: [.atomic])

        let tx = try ResultArtifactDeletionTransaction(
            jobId: String(jobId),
            storedPath: nil,
            stageRoot: stageRoot.path
        )
        try tx.commit()
        // 重复 commit 不应崩
        try tx.commit()
    }

    @Test func deletionTransaction_noMatchingFiles_stillSucceeds() throws {
        // 启动时 stage 目录还不存在，artifactPaths 返回的 URL 都不在
        // 磁盘上。init 不应抛、commit 也不应抛。
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let tx = try ResultArtifactDeletionTransaction(
            jobId: "nonexistent-\(UUID().uuidString.prefix(8))",
            storedPath: nil,
            stageRoot: stageRoot.path
        )
        try tx.commit()
        // 不抛即成功
    }

    @Test func deletionTransaction_droppedWithoutCommitOrRestore_restoresArtifacts() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let jobId = "drop-test-\(UUID().uuidString.prefix(8))"
        let stageResultURL = ResultStore.stageResultPath(
            jobId: String(jobId),
            stageRoot: stageRoot.path
        )
        try FileManager.default.createDirectory(
            at: stageResultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = makeEmptyPayload(jobId: String(jobId), audioPath: "/tmp/drop.wav")
        let data = try JSONEncoder().encode(payload)
        try data.write(to: stageResultURL, options: [.atomic])

        do {
            _ = try ResultArtifactDeletionTransaction(
                jobId: String(jobId),
                storedPath: nil,
                stageRoot: stageRoot.path
            )
        }

        #expect(FileManager.default.fileExists(atPath: stageResultURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: stageRoot.path)
            .filter { $0.hasPrefix(".swiftasr-artifact-deletion-") }
        #expect(leftovers.isEmpty)
    }

    @Test func deletionStartupRecovery_restoresWhenJobCommitIsMissing() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }
        let jobID = "recover-delete"
        let original = ResultStore.stageResultPath(jobId: jobID, stageRoot: stageRoot.path)
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("result".utf8).write(to: original)
        let txDirectory = stageRoot.appendingPathComponent(
            ".swiftasr-artifact-deletion-crash",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: txDirectory, withIntermediateDirectories: true)
        let stagedName = "0-\(original.lastPathComponent)"
        try FileManager.default.moveItem(
            at: original,
            to: txDirectory.appendingPathComponent(stagedName)
        )
        let manifest = ResultArtifactDeletionManifest(
            version: 1,
            transactionID: "delete-token",
            jobID: jobID,
            phase: .staged,
            entries: [.init(originalPath: original.path, stagedName: stagedName)]
        )
        try JSONEncoder().encode(manifest).write(
            to: txDirectory.appendingPathComponent("deletion-manifest.json"),
            options: [.atomic]
        )

        #expect(try ResultArtifactDeletionTransaction.recoverInterruptedTransactions(
            under: stageRoot,
            allowedArtifactPathsByJobID: [
                jobID: Set(
                    ResultStore.artifactPaths(
                        jobId: jobID,
                        storedPath: original.path,
                        stageRoot: stageRoot.path
                    ).map { $0.standardizedFileURL.path }
                )
            ],
            persistedTransactionIDs: []
        ) == 1)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: txDirectory.path))
    }

    @Test func deletionStartupRecovery_finishesWhenSwiftDataTokenPersisted() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }
        let jobID = "persisted-delete"
        let original = ResultStore.stageResultPath(jobId: jobID, stageRoot: stageRoot.path)
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("result".utf8).write(to: original)
        let txDirectory = stageRoot.appendingPathComponent(
            ".swiftasr-artifact-deletion-persisted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: txDirectory, withIntermediateDirectories: true)
        let stagedName = "0-\(original.lastPathComponent)"
        try FileManager.default.moveItem(
            at: original,
            to: txDirectory.appendingPathComponent(stagedName)
        )
        let manifest = ResultArtifactDeletionManifest(
            version: 1,
            transactionID: "persisted-delete-token",
            jobID: jobID,
            phase: .staged,
            entries: [.init(originalPath: original.path, stagedName: stagedName)]
        )
        try JSONEncoder().encode(manifest).write(
            to: txDirectory.appendingPathComponent("deletion-manifest.json"),
            options: [.atomic]
        )

        #expect(try ResultArtifactDeletionTransaction.recoverInterruptedTransactions(
            under: stageRoot,
            allowedArtifactPathsByJobID: [
                jobID: Set(
                    ResultStore.artifactPaths(
                        jobId: jobID,
                        storedPath: original.path,
                        stageRoot: stageRoot.path
                    ).map { $0.standardizedFileURL.path }
                )
            ],
            persistedTransactionIDs: ["persisted-delete-token"]
        ) == 1)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: txDirectory.path))
    }

    @Test func deletionFinalization_preventsOlderTokenFromBlockingConsecutiveRetranscription() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }
        let jobID = "consecutive-retranscription"
        let original = ResultStore.stageResultPath(jobId: jobID, stageRoot: stageRoot.path)
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Transaction A crossed the SwiftData commit boundary, but its
        // `.persisted` manifest write failed. Its staged manifest and old
        // generation therefore remain while the job has already produced a
        // newer result.
        try Data("generation-1".utf8).write(to: original)
        let firstToken = "first-persisted-token"
        let firstDirectory = stageRoot.appendingPathComponent(
            ".swiftasr-artifact-deletion-\(firstToken)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstDirectory,
            withIntermediateDirectories: true
        )
        let firstStagedName = "0-\(original.lastPathComponent)"
        try FileManager.default.moveItem(
            at: original,
            to: firstDirectory.appendingPathComponent(firstStagedName)
        )
        try JSONEncoder().encode(ResultArtifactDeletionManifest(
            version: 1,
            transactionID: firstToken,
            jobID: jobID,
            phase: .staged,
            entries: [.init(originalPath: original.path, stagedName: firstStagedName)]
        )).write(
            to: firstDirectory.appendingPathComponent("deletion-manifest.json"),
            options: [.atomic]
        )
        try Data("generation-2".utf8).write(to: original)

        #expect(try ResultArtifactDeletionTransaction.finalizePersistedTransaction(
            id: firstToken,
            jobID: jobID,
            under: stageRoot
        ))
        #expect(!FileManager.default.fileExists(atPath: firstDirectory.path))
        #expect(try !ResultArtifactDeletionTransaction.finalizePersistedTransaction(
            id: firstToken,
            jobID: jobID,
            under: stageRoot
        ))

        // Transaction B can now replace the job token safely. A later startup
        // sees only B and must retain the newest generation instead of trying
        // to restore A over its occupied final path.
        let secondToken = "second-persisted-token"
        let secondDirectory = stageRoot.appendingPathComponent(
            ".swiftasr-artifact-deletion-\(secondToken)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: secondDirectory,
            withIntermediateDirectories: true
        )
        let secondStagedName = "0-\(original.lastPathComponent)"
        try FileManager.default.moveItem(
            at: original,
            to: secondDirectory.appendingPathComponent(secondStagedName)
        )
        try JSONEncoder().encode(ResultArtifactDeletionManifest(
            version: 1,
            transactionID: secondToken,
            jobID: jobID,
            phase: .staged,
            entries: [.init(originalPath: original.path, stagedName: secondStagedName)]
        )).write(
            to: secondDirectory.appendingPathComponent("deletion-manifest.json"),
            options: [.atomic]
        )
        try Data("generation-3".utf8).write(to: original)

        #expect(try ResultArtifactDeletionTransaction.recoverInterruptedTransactions(
            under: stageRoot,
            allowedArtifactPathsByJobID: [
                jobID: Set(
                    ResultStore.artifactPaths(
                        jobId: jobID,
                        storedPath: original.path,
                        stageRoot: stageRoot.path
                    ).map { $0.standardizedFileURL.path }
                )
            ],
            persistedTransactionIDs: [secondToken]
        ) == 1)
        #expect(try String(contentsOf: original, encoding: .utf8) == "generation-3")
        #expect(!FileManager.default.fileExists(atPath: secondDirectory.path))
    }

    @Test func deletionFinalization_failsClosedForMismatchedManifest() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }
        let transactionID = "expected-token"
        let transactionDirectory = stageRoot.appendingPathComponent(
            ".swiftasr-artifact-deletion-\(transactionID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ResultArtifactDeletionManifest(
            version: 1,
            transactionID: "different-token",
            jobID: "job",
            phase: .staged,
            entries: []
        )).write(
            to: transactionDirectory.appendingPathComponent("deletion-manifest.json"),
            options: [.atomic]
        )

        #expect(throws: ResultArtifactDeletionTransactionError.self) {
            try ResultArtifactDeletionTransaction.finalizePersistedTransaction(
                id: transactionID,
                jobID: "job",
                under: stageRoot
            )
        }
        #expect(FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    @Test func deletionStartupRecovery_ignoresManifestOutsideJobsArtifactSet() throws {
        let stageRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: stageRoot) }
        let jobID = "tampered-delete"
        let allowed = ResultStore.stageResultPath(jobId: jobID, stageRoot: stageRoot.path)
        let outside = stageRoot.deletingLastPathComponent()
            .appendingPathComponent("unrelated-\(UUID().uuidString).result.json")
        let txDirectory = stageRoot.appendingPathComponent(
            ".swiftasr-artifact-deletion-tampered",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: txDirectory, withIntermediateDirectories: true)
        let stagedName = "0-\(outside.lastPathComponent)"
        try Data("must-not-restore".utf8).write(
            to: txDirectory.appendingPathComponent(stagedName)
        )
        let manifest = ResultArtifactDeletionManifest(
            version: 1,
            transactionID: "tampered-token",
            jobID: jobID,
            phase: .staged,
            entries: [.init(originalPath: outside.path, stagedName: stagedName)]
        )
        try JSONEncoder().encode(manifest).write(
            to: txDirectory.appendingPathComponent("deletion-manifest.json"),
            options: [.atomic]
        )

        #expect(try ResultArtifactDeletionTransaction.recoverInterruptedTransactions(
            under: stageRoot,
            allowedArtifactPathsByJobID: [jobID: [allowed.standardizedFileURL.path]],
            persistedTransactionIDs: []
        ) == 0)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: txDirectory.path))
    }
}
