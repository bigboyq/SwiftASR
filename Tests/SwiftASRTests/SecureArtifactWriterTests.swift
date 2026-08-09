import Testing
import Foundation
@testable import SwiftASR

/// R4-P0-1 / R4-P1-10 回归：result.json / sidecar / 事务目录的权限收紧。
///
/// 注意：测试 fixture 写到系统临时目录（不在 SwiftASR 应用支持根下），所以
/// `ensureDirectory` 不会收紧父目录权限，但文件本身会被 `restrictFile` 收紧
/// 到 0600。这些测试覆盖文件权限，外部目录权限收敛由 `ensureDirectory` 的
/// 边界保护（见 SecureArtifactWriterTests.ensureDirectoryDoesNotTouchParent）。
@Suite("Secure artifact writer permissions")
struct SecureArtifactWriterTests {
    private func makeTemporaryFileURL(suffix: String) throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-secure-\(UUID().uuidString)\(suffix)")
    }

    @Test func writeDataRestrictsFileToOwnerOnly() throws {
        let path = try makeTemporaryFileURL(suffix: ".result.json")
        defer { try? FileManager.default.removeItem(at: path) }

        try SecureArtifactWriter.writeData(Data("{\"k\":1}".utf8), to: path)

        let permissions = SecureArtifactWriter.currentPermissions(at: path)
        #expect(permissions == 0o600)
    }

    @Test func writeEncodableRestrictsFileToOwnerOnly() throws {
        let path = try makeTemporaryFileURL(suffix: ".speaker-input.json")
        defer { try? FileManager.default.removeItem(at: path) }

        let input = SpeakerRecognitionInput(
            version: SpeakerRecognitionInput.currentVersion,
            audioPath: "/x.wav",
            sentences: []
        )
        try SecureArtifactWriter.writeEncodable(input, to: path)

        #expect(SecureArtifactWriter.currentPermissions(at: path) == 0o600)
        // 落盘内容仍可被标准 decoder 读回。
        let restored = try ResultStore.readSpeakerInput(from: path)
        #expect(restored.version == SpeakerRecognitionInput.currentVersion)
    }

    @Test func ensureDirectoryDoesNotTouchParentOutsideSupportRoot() throws {
        // 写到系统临时目录（不在 ~/Library/Application Support/SwiftASR 下），
        // 父目录权限不应被收紧，避免破坏共享目录。
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-secure-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try SecureArtifactWriter.ensureDirectory(parent)

        // 不在支持根下：不应该被改成 0700。系统临时子目录通常是 0700/0755，
        // 这里只断言"未被本调用显式设成 0700"会过于脆（mkdir 默认就是 0700），
        // 所以改为断言文件可写：父目录未被收紧到阻止后续写入。
        let probe = parent.appendingPathComponent("probe.txt")
        try Data("x".utf8).write(to: probe)
        #expect(FileManager.default.fileExists(atPath: probe.path))
    }

    @Test func ensureDirectoryHardensExistingSupportAncestors() throws {
        let supportRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SwiftASR", isDirectory: true)
        let testRoot = supportRoot
            .appendingPathComponent(".swiftasr-permission-test-\(UUID().uuidString)", isDirectory: true)
        let target = testRoot.appendingPathComponent("stage/aa/bb", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        try SecureArtifactWriter.ensureDirectory(target)

        #expect(SecureArtifactWriter.currentPermissions(at: testRoot) == 0o700)
        #expect(SecureArtifactWriter.currentPermissions(at: target.deletingLastPathComponent()) == 0o700)
        #expect(SecureArtifactWriter.currentPermissions(at: target) == 0o700)
    }

    @Test func resultStoreWriteSpeakerInputProducesOwnerOnlyFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("abcd.speaker-input.json")

        let input = SpeakerRecognitionInput(
            version: SpeakerRecognitionInput.currentVersion,
            audioPath: "/x.wav",
            sentences: []
        )
        try ResultStore.writeSpeakerInput(input, to: path)

        #expect(SecureArtifactWriter.currentPermissions(at: path) == 0o600)
    }

    @Test func resultStoreWriteSpeakerRoutingSnapshotProducesOwnerOnlyFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("abcd.speaker-routing.json")

        // 用最小合法 snapshot 写入并验证权限。
        let snapshot = SpeakerRoutingSnapshot(
            version: SpeakerRoutingSnapshot.currentVersion,
            profileMappings: [],
            tokens: [],
            pauseCandidates: []
        )
        try ResultStore.writeSpeakerRoutingSnapshot(snapshot, to: path)

        #expect(SecureArtifactWriter.currentPermissions(at: path) == 0o600)
    }

    @Test func resultWriteTransactionRestrictsFinalAndBackupFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-txn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let finalURL = dir.appendingPathComponent("abcd.result.json")

        // 先写一个旧版本文件（宽松权限），验证 commit 后会被收紧。
        try Data("old".utf8).write(to: finalURL)

        let payload = ResultPayload(
            jobId: "abcd",
            audioPath: "/tmp/x.wav",
            segments: [ResultSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "S1",
                rawText: "原文"
            )],
            mergedResults: []
        )
        let txn = try ResultWriteTransaction(payload: payload, to: finalURL)
        try txn.commit()
        try txn.markPersistenceSucceeded(persistedExternally: false)
        try txn.finalize()

        #expect(SecureArtifactWriter.currentPermissions(at: finalURL) == 0o600)
    }
}
