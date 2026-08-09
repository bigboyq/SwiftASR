import Foundation
import Combine

/// 全局设置存储：API Key 池 + 术语表 + 模型路径 + 润色设置。
/// 用 JSON 存到 ``~/Library/Application Support/SwiftASR/settings.json``。
///
/// **响应式通知**：实现 `ObservableObject` 协议，view 端用
/// `@ObservedObject` / `@StateObject` 订阅，任何 set 都会触发 view
/// 重新计算对应的 computed property。`Sidebar.needsApiKeyBadge` 等
/// "每次都查"的属性变成"store 变 → view 重渲染 → 重新查"，避免
/// 之前手 `load()` 的脆弱模式。
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    /// Latest persistence failure shown by SettingsTab. A nil value means the
    /// most recent settings write completed successfully.
    @Published public private(set) var lastPersistenceError: String?

    /// 兼容旧调用点。模型目录与文件契约由 ``ModelCatalog`` 统一维护。
    public static let modelsRoot = ModelCatalog.defaultModelsRoot


    private var fileURL: URL
    private let queue = DispatchQueue(label: "SwiftASR.SettingsStore", qos: .userInitiated)
    private let permissionSetter: (URL, Int) throws -> Void
    private var cachedBlob: SettingsBlob? = nil
    /// A syntactically unreadable file must never be replaced by a default
    /// blob during an unrelated settings write. Only the explicit
    /// `resetAllSettings()` action may replace the preserved original bytes.
    private var loadFailureBlocksWrites = false

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Application Support/SwiftASR")
        self.fileURL = dir.appendingPathComponent("settings.json")
        self.permissionSetter = Self.setPOSIXPermissions
    }

    #if DEBUG
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.permissionSetter = Self.setPOSIXPermissions
    }

    init(
        fileURL: URL,
        permissionSetter: @escaping (URL, Int) throws -> Void
    ) {
        self.fileURL = fileURL
        self.permissionSetter = permissionSetter
    }

    public static func createTestInstance() -> SettingsStore {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("settings.json")
        return SettingsStore(fileURL: fileURL)
    }
    #endif

    private static func setPOSIXPermissions(_ url: URL, _ permissions: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private func protectSettingsDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try permissionSetter(directoryURL, 0o700)
    }

    private func protectExistingSettingsFile() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try permissionSetter(fileURL, 0o600)
    }

    private func loadBlob() -> SettingsBlob {
        if let cached = cachedBlob { return cached }
        do {
            try protectSettingsDirectory()
        } catch {
            reportPersistenceError("无法保护设置目录：\(error.localizedDescription)")
            loadFailureBlocksWrites = true
            return SettingsBlob()
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = SettingsBlob()
            loadFailureBlocksWrites = false
            cachedBlob = empty
            return empty
        }
        do {
            try protectExistingSettingsFile()
            let data = try Data(contentsOf: fileURL)
            let blob = try JSONDecoder().decode(SettingsBlob.self, from: data)
            loadFailureBlocksWrites = false
            cachedBlob = blob
            return blob
        } catch {
            reportPersistenceError("无法读取设置文件：\(error.localizedDescription)")
            loadFailureBlocksWrites = true
            let empty = SettingsBlob()
            cachedBlob = empty
            return empty
        }
    }

    @discardableResult
    private func saveBlob(_ blob: SettingsBlob) -> Bool {
        guard !loadFailureBlocksWrites else {
            reportPersistenceError("设置文件无法解析；为保护原数据，本次修改未写入磁盘")
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(blob)
            try protectSettingsDirectory()
            try data.write(to: fileURL, options: [.atomic])
            try protectExistingSettingsFile()
        } catch {
            reportPersistenceError("无法保存设置：\(error.localizedDescription)")
            return false
        }
        // Do not advance the cache until the atomic disk write succeeds.
        cachedBlob = blob
        reportPersistenceError(nil)
        // 不能在 queue.sync 持锁时同步 send：SwiftUI 收到变更后可能立即读取
        // apiKeys()/glossary()，再次 queue.sync 会和当前写入形成重入死锁。
        // 投递到主队列保证通知发生在锁释放后，也让 @Published 观察者在 UI
        // 所在线程重绘。
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        return true
    }

    private func reportPersistenceError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.lastPersistenceError = message
        }
    }

    private static func normalizedCleanupSettings(_ input: CleanupSettings) -> CleanupSettings {
        var output = input
        // Gemini cleanup uses one fixed production model. Migrate legacy or
        // hand-written settings instead of letting the UI and runtime diverge.
        output.model = CleanupDefaults.model
        output.chunkChars = max(2_000, min(12_000, output.chunkChars))
        output.temperature = max(0, min(1, output.temperature.isFinite ? output.temperature : CleanupDefaults.temperature))
        if output.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output.prompt = CleanupDefaults.prompt
        }
        return output
    }

    // MARK: - API Keys
    public func apiKeys() -> [APIKeyConfig] {
        queue.sync { loadBlob().apiKeys }
    }

    public func hasUsableGeminiKey() -> Bool {
        queue.sync { loadBlob().apiKeys.contains(where: \.isUsableGeminiKey) }
    }

    public func setApiKeys(_ keys: [APIKeyConfig]) {
        queue.sync {
            var blob = loadBlob()
            blob.apiKeys = keys
            saveBlob(blob)
        }
    }

    /// Phase 8：批量 upsert keys（按 id 匹配；新 key 追加、已有 key 就更新字段）
    /// 避免 cleared settings.json 后 setApiKeys 全覆盖导致其他字段丢失。
    public func upsertApiKeys(_ keys: [APIKeyConfig]) {
        queue.sync {
            var blob = loadBlob()
            var current = blob.apiKeys
            for new in keys {
                if let idx = current.firstIndex(where: { $0.id == new.id }) {
                    current[idx] = new
                } else {
                    current.append(new)
                }
            }
            // Tier 升级：按 (tier ASC, priority ASC) 排序。
            // 跟 GeminiKeyFailover 的 keys 排序 + FunASR-Mac 的
            // `get_key_pool_for_cleanup` 完全一致。
            current.sort { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return lhs.priority < rhs.priority
            }
            blob.apiKeys = current
            saveBlob(blob)
        }
    }

    /// Phase 8：更新 key 的 lastUsedAt 时间。GeminiKeyFailover 成功 chunk 后自动调。
    ///
    /// **只刷时间，不增计数**。testConnection 路径调这个，避免把"测试连接"
    /// 算成"业务成功调用"。业务成功（cleanup chunk 成功）走 `recordSuccess`。
    public func updateLastUsedAt(keyId: String, at: Date = Date()) {
        queue.sync {
            var blob = loadBlob()
            if let idx = blob.apiKeys.firstIndex(where: { $0.id == keyId }) {
                blob.apiKeys[idx].lastUsedAt = at
                saveBlob(blob)
            }
        }
    }

    /// 业务成功一次：刷新 lastUsedAt + successCount += 1。LLMCleanupService
    /// 的每个 chunk 成功都会调一次。失败 / 4xx / 5xx / 取消都不调。
    ///
    /// 跟 `updateLastUsedAt` 分开：testConnection 只刷时间不算业务成功。
    public func recordSuccess(keyId: String, at: Date = Date()) {
        queue.sync {
            var blob = loadBlob()
            if let idx = blob.apiKeys.firstIndex(where: { $0.id == keyId }) {
                blob.apiKeys[idx].lastUsedAt = at
                blob.apiKeys[idx].successCount += 1
                saveBlob(blob)
            }
        }
    }

    /// Phase 8：更新 key 的 notes
    public func updateNotes(keyId: String, notes: String?) {
        queue.sync {
            var blob = loadBlob()
            if let idx = blob.apiKeys.firstIndex(where: { $0.id == keyId }) {
                blob.apiKeys[idx].notes = notes
                saveBlob(blob)
            }
        }
    }

    // MARK: - Glossary
    public func glossary() -> [String] {
        queue.sync { Self.normalizeGlossary(loadBlob().glossary) }
    }

    public func setGlossary(_ glossary: [String]) {
        queue.sync {
            var blob = loadBlob()
            blob.glossary = Self.normalizeGlossary(glossary)
            saveBlob(blob)
        }
    }

    /// 术语表规范化 helper：去除空白符、空行，对仅大小写不同的重复项去重（保留首次出现的原始写法），并忽略大小写按字母顺序排序。
    public static func normalizeGlossary(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerKey = term.lowercased()
            guard !term.isEmpty, !seen.contains(lowerKey) else { continue }
            seen.insert(lowerKey)
            out.append(term)
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Cleanup Settings (Phase 4 / A4)
    public func cleanupSettings() -> CleanupSettings {
        queue.sync {
            Self.normalizedCleanupSettings(loadBlob().cleanup ?? CleanupSettings())
        }
    }

    public func setCleanupSettings(_ settings: CleanupSettings) {
        queue.sync {
            var blob = loadBlob()
            blob.cleanup = Self.normalizedCleanupSettings(settings)
            saveBlob(blob)
        }
    }

    /// 重置 cleanup 设置到默认值
    public func resetCleanupSettings() {
        queue.sync {
            var blob = loadBlob()
            blob.cleanup = nil  // 读时 fallback 到 default
            saveBlob(blob)
        }
    }

    /// 重置全部设置到默认值（apiKeys / glossary / cleanup 全清空）。
    /// 模型路径跟数据位置属于文件系统层，不动。
    /// 调用方需在重置后主动刷新 UI（store 已发 objectWillChange，订阅方会重渲染）。
    public func resetAllSettings() {
        queue.sync {
            var blob = loadBlob()
            blob.apiKeys = []
            blob.glossary = []
            blob.cleanup = nil
            blob.queue = nil
            // Reset-all is the one explicit destructive recovery action. All
            // ordinary setters remain blocked after a fatal load failure.
            loadFailureBlocksWrites = false
            saveBlob(blob)
        }
    }

    // MARK: - Queue Settings

    public func queueSettings() -> QueueSettings {
        queue.sync { loadBlob().queue ?? QueueSettings() }
    }

    public func setQueueSettings(_ settings: QueueSettings) {
        queue.sync {
            var blob = loadBlob()
            blob.queue = settings
            saveBlob(blob)
        }
    }

    #if DEBUG
    /// 供单元测试重置内存缓存，以避免跨测试交叉污染
    public func resetCacheForTesting() {
        queue.sync {
            cachedBlob = nil
            loadFailureBlocksWrites = false
        }
    }

    public var settingsFileURL: URL {
        queue.sync { fileURL }
    }
    #endif
}
