import Foundation
import CommonCrypto

// 2026-07-26 P2 F5.3: ResultStoreError + ResultStore 从 ResultData.swift
// 抽出。IO / 路径 / atomic write / SHA256 path-hashing 跟 result.json
// schema 完全无关，独立成 IO 层。ResultData.swift 只剩 result.json
// schema + validation + ResultPayload 主 type + ResultStoreError
// (后者更属于 schema-side 错误，但已经在原文件就近 catch 所以跟
// ResultStore 一起搬过来)。

public enum ResultStoreError: Error, LocalizedError {
    case resultMissing(jobID: String, storedPath: String?)
    /// JSONSerialization round-trip failed (encode → decode → re-encode
    /// with pretty options) in the write transaction's render path.
    /// The previous NSError template was thrown by
    /// `ResultWriteTransaction.init` when the post-encode round-trip
    /// couldn't be re-serialized.
    case jsonRenderFailed

    public var errorDescription: String? {
        switch self {
        case let .resultMissing(jobID, storedPath):
            if let storedPath {
                return "任务 \(jobID) 的结果文件不存在：\(storedPath)"
            }
            return "任务 \(jobID) 没有可读取的 result.json。"
        case .jsonRenderFailed:
            return "JSON render failed"
        }
    }
}

// `ResultWriteTransaction` / `ResultArtifactDeletionTransaction` 是 file-side
// 可回滚事务，跟下面 `ResultStore` 配合使用。它们不在 result.json schema 范畴，
// 已拆到 `Storage/ResultTransactions.swift`（2026-07-22）。

public enum ResultStore {
    /// 计算 job_id = SHA256(sourceAudioPath)。在大小写不敏感卷上保留历史
    /// lowercased 行为；在大小写敏感卷上必须保留路径大小写，避免两个真实文件碰撞。
    ///
    /// R4-P2-7：空路径会经 `URL(fileURLWithPath: "")` 解析成 cwd，产生基于
    /// cwd 的"合法" hash。调用方（`JobActionService.importAudioFile`）已在入口
    /// 拒绝空路径；这里对空路径加一道防御性 log + 退化 hash，避免漏网时静默
    /// 落到 cwd-based id。改 hash 为 throws 会影响 ~6 个 caller，故不在此处
    /// 强制；导入入口的拒绝是主防线。
    public static func hashAudioPath(_ path: String) -> String {
        if path.isEmpty {
            Logger.shared.warn("hashAudioPath 收到空路径，退化使用空串 hash（调用方应先拒绝空路径）")
        }
        // Existing files must resolve the *entire* symbolic-link chain.  The
        // former `destinationOfSymbolicLink` only read the final link's raw
        // target string, so a relative symlink was hashed relative to the
        // process working directory instead of its containing directory.
        // Keep the historical standardized-string fallback for paths that do
        // not exist yet: importing a future/missing path still has a stable
        // ID and does not accidentally depend on a failed resolution.
        let canonical = canonicalAudioPath(path)
        let data = Data(canonical.utf8)
        let digest = sha256Hex(data)
        return digest
    }

    static func audioPathsReferToSameLocation(_ lhs: String, _ rhs: String) -> Bool {
        canonicalAudioPath(lhs) == canonicalAudioPath(rhs)
    }

    private static func canonicalAudioPath(_ path: String) -> String {
        let inputURL = URL(fileURLWithPath: path)
        let normalized: String
        if FileManager.default.fileExists(atPath: inputURL.path) {
            normalized = inputURL.resolvingSymlinksInPath().standardizedFileURL.path
        } else {
            normalized = (path as NSString).standardizingPath
        }
        let trimmed = normalized == "/"
            ? normalized
            : normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return volumeSupportsCaseSensitiveNames(for: inputURL)
            ? trimmed
            : trimmed.lowercased()
    }

    private static func volumeSupportsCaseSensitiveNames(for inputURL: URL) -> Bool {
        var candidate = inputURL.standardizedFileURL
        let manager = FileManager.default
        while !manager.fileExists(atPath: candidate.path),
              candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return (try? candidate.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? false
    }

    /// 计算 stage 目录里的 result.json 路径：``stage/<hash[:2]>/<hash[2:4]>/<hash>.result.json``
    /// stageRoot 默认是 ``~/Library/Application Support/SwiftASR/stage``（不要重复 append "stage"）
    public static func stageResultPath(jobId: String, stageRoot: String? = nil) -> URL {
        let root = stageRoot ?? defaultStageRoot()
        let prefix1 = jobId.prefix(2)
        let prefix2 = jobId.dropFirst(2).prefix(2)
        let dir = URL(fileURLWithPath: root)
            .appendingPathComponent(String(prefix1))
            .appendingPathComponent(String(prefix2))
        return dir.appendingPathComponent("\(jobId).result.json")
    }

    /// Sidecar holding the pre-diarization ASR timeline for speaker-only runs.
    public static func speakerInputPath(jobId: String, stageRoot: String? = nil) -> URL {
        stageResultPath(jobId: jobId, stageRoot: stageRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("\(jobId).speaker-input.json")
    }

    /// Sidecar with chunk-level speaker diagnostics for quality investigation.
    public static func speakerDiagnosticsPath(jobId: String, stageRoot: String? = nil) -> URL {
        stageResultPath(jobId: jobId, stageRoot: stageRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("\(jobId).speaker-diagnostics.json")
    }

    /// Authoritative token-level routing evidence for the reversible
    /// profile-split operation layer. Unlike diagnostics, this file is a
    /// versioned replay contract and is never embedded in result.json.
    public static func speakerRoutingSnapshotPath(jobId: String, stageRoot: String? = nil) -> URL {
        stageResultPath(jobId: jobId, stageRoot: stageRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("\(jobId).speaker-routing.json")
    }

    /// Locate the speaker input beside the result currently owned by a job.
    /// Historical result paths must win over the canonical fallback so a
    /// migrated job never silently reads a different artifact set.
    public static func locateSpeakerInputPath(
        jobId: String,
        storedPath: String? = nil,
        stageRoot: String? = nil
    ) -> URL? {
        var candidates: [URL] = []
        if let storedPath {
            let storedURL = URL(fileURLWithPath: storedPath)
            if storedURL.lastPathComponent == "\(jobId).result.json" {
                candidates.append(
                    storedURL.deletingLastPathComponent()
                        .appendingPathComponent("\(jobId).speaker-input.json")
                )
            }
        }
        if let resultPath = resolveStoredPath(storedPath) {
            candidates.append(
                resultPath.deletingLastPathComponent()
                    .appendingPathComponent("\(jobId).speaker-input.json")
            )
        }
        candidates.append(speakerInputPath(jobId: jobId, stageRoot: stageRoot))

        var seen = Set<String>()
        return candidates.first {
            seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Locate the routing snapshot adjacent to a historical or canonical
    /// result. Historical artifact directories win for the same reason as
    /// speaker-input: migrated jobs must not accidentally mix artifact sets.
    public static func locateSpeakerRoutingSnapshotPath(
        jobId: String,
        storedPath: String? = nil,
        stageRoot: String? = nil
    ) -> URL? {
        var candidates: [URL] = []
        if let storedPath {
            let storedURL = URL(fileURLWithPath: storedPath)
            if storedURL.lastPathComponent == "\(jobId).result.json" {
                candidates.append(
                    storedURL.deletingLastPathComponent()
                        .appendingPathComponent("\(jobId).speaker-routing.json")
                )
            }
        }
        if let resultPath = resolveStoredPath(storedPath) {
            candidates.append(
                resultPath.deletingLastPathComponent()
                    .appendingPathComponent("\(jobId).speaker-routing.json")
            )
        }
        candidates.append(speakerRoutingSnapshotPath(jobId: jobId, stageRoot: stageRoot))

        var seen = Set<String>()
        return candidates.first {
            seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// All files owned by one job, including legacy result locations and
    /// speaker sidecars. The list is de-duplicated so cleanup is safe across
    /// canonical and historical paths.
    ///
    /// `stageRoot` 让测试和自定义 root 部署能复用路径计算（2026-07-22 扩展）。
    /// 留 `nil` 时走默认 `defaultStageRoot()`，跟旧行为完全一致。
    public static func artifactPaths(
        jobId: String,
        storedPath: String?,
        stageRoot: String? = nil
    ) -> [URL] {
        var paths: [URL] = [
            stageResultPath(jobId: jobId, stageRoot: stageRoot),
            speakerInputPath(jobId: jobId, stageRoot: stageRoot),
            speakerDiagnosticsPath(jobId: jobId, stageRoot: stageRoot),
            speakerRoutingSnapshotPath(jobId: jobId, stageRoot: stageRoot)
        ]
        if let resolved = resolveStoredPath(storedPath) {
            paths.append(resolved)
            let directory = resolved.deletingLastPathComponent()
            paths.append(directory.appendingPathComponent("\(jobId).speaker-input.json"))
            paths.append(directory.appendingPathComponent("\(jobId).speaker-diagnostics.json"))
            paths.append(directory.appendingPathComponent("\(jobId).speaker-routing.json"))
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0.path).inserted }
    }

    /// 从 SwiftData 存的 transcriptPath 字符串恢复成可读 URL。
    public static func resolveStoredPath(_ stored: String?) -> URL? {
        guard let stored = stored else { return nil }
        let u = URL(fileURLWithPath: stored)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        // 老路径里有 "stage/stage/<xx>/<xx>/<hash>.result.json"，反推 jobId
        let name = u.lastPathComponent
        guard name.hasSuffix(".result.json") else { return nil }
        let jobId = String(name.dropLast(".result.json".count))

        // 老路径：去掉 /stage/，还原 canonical，再 locate 一次
        // u.path = .../stage/stage/<xx>/<xx>/<jobId>.result.json
        // canonical stage root = .../stage
        // 删除 "stage" + 1 层 <xx> + 1 层 <xx> + 文件名 = .../stage
        var dir = u.deletingLastPathComponent()  // .../stage/stage/<xx>/<xx>
        dir.deleteLastPathComponent()  // .../stage/stage/<xx>
        dir.deleteLastPathComponent()  // .../stage/stage
        let stageRoot = dir.deletingLastPathComponent().path  // .../stage
        return stageResultPath(jobId: jobId, stageRoot: stageRoot)
    }

    /// Resolve the persisted path for reading. Historical stage paths are
    /// preferred when they still exist; the canonical path is only used as a
    /// fallback. Missing files are reported instead of becoming an empty UI.
    public static func readPath(jobId: String, storedPath: String?) throws -> URL {
        if let resolved = resolveStoredPath(storedPath),
           FileManager.default.fileExists(atPath: resolved.path) {
            return resolved
        }
        let canonical = stageResultPath(jobId: jobId)
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            throw ResultStoreError.resultMissing(jobID: jobId, storedPath: storedPath)
        }
        return canonical
    }

    /// Resolve the persisted path for writing. Keep an existing historical
    /// location stable; new jobs use the canonical stage path.
    public static func writePath(jobId: String, storedPath: String?) -> URL {
        if let resolved = resolveStoredPath(storedPath),
           FileManager.default.fileExists(atPath: resolved.path) {
            return resolved
        }
        return stageResultPath(jobId: jobId)
    }

    /// Canonical stage artifacts encode the 64-character SHA-256 job ID in
    /// their filename. Custom/legacy test filenames do not, so only return an
    /// expected ID when the filename itself is an unambiguous contract.
    static func canonicalJobIDEncoded(in resultURL: URL) -> String? {
        let suffix = ".result.json"
        let name = resultURL.lastPathComponent
        guard name.hasSuffix(suffix) else { return nil }
        let candidate = String(name.dropLast(suffix.count))
        guard candidate.count == 64,
              candidate.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              })
        else { return nil }
        return candidate
    }

    /// 原子写：写 .tmp 然后 rename。失败时清理 .tmp。
    public static func write(_ payload: ResultPayload, to path: URL) throws {
        try payload.validate()
        let transaction = try ResultWriteTransaction(payload: payload, to: path)
        try transaction.commit()
        // This path has no SwiftData companion write. The replacement itself
        // is therefore the durable commit boundary.
        try transaction.markPersistenceSucceeded(persistedExternally: false)
        try transaction.finalize()
    }

    public static func writeSpeakerInput(_ input: SpeakerRecognitionInput, to path: URL) throws {
        try input.validate()
        // R4-P0-1 / R4-P1-10：sidecar 经统一安全写入器，落盘后收紧 0600，
        // 父目录 0700。
        try SecureArtifactWriter.writeEncodable(input, to: path)
    }

    public static func writeSpeakerDiagnostics(
        _ diagnostics: SpeakerDiarizationDiagnostics,
        to path: URL
    ) throws {
        try SecureArtifactWriter.writeEncodable(diagnostics, to: path)
    }

    public static func readSpeakerDiagnostics(from path: URL) throws -> SpeakerDiarizationDiagnostics {
        try JSONDecoder().decode(SpeakerDiarizationDiagnostics.self, from: Data(contentsOf: path))
    }

    public static func writeSpeakerRoutingSnapshot(
        _ snapshot: SpeakerRoutingSnapshot,
        to path: URL
    ) throws {
        try SecureArtifactWriter.writeEncodable(snapshot, to: path)
    }

    public static func readSpeakerRoutingSnapshot(from path: URL) throws -> SpeakerRoutingSnapshot {
        try JSONDecoder().decode(SpeakerRoutingSnapshot.self, from: Data(contentsOf: path))
    }

    public static func readSpeakerInput(from path: URL) throws -> SpeakerRecognitionInput {
        let input = try JSONDecoder().decode(
            SpeakerRecognitionInput.self,
            from: Data(contentsOf: path)
        )
        try input.validate()
        return input
    }

    public static func read(from path: URL) throws -> ResultPayload {
        let data = try Data(contentsOf: path)
        let payload = try JSONDecoder().decode(ResultPayload.self, from: data)
        try payload.validate()
        return payload
    }

    public static func nowIso() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // 默认 stage 根：``~/Library/Application Support/SwiftASR/stage``
    public static func defaultStageRoot() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support/SwiftASR/stage")
        return appSupport.path
    }

    // MARK: - SHA-256 hex

    private static func sha256Hex(_ data: Data) -> String {
        // 用 CommonCrypto（Security framework）
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
