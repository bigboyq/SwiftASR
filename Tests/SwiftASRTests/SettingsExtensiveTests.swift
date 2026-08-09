import Testing
import Foundation
@testable import SwiftASR

// MARK: - SettingsStore 全面测试
// 临时 instance 各自使用独立目录；singleton 测试仍串行，避免与进程级 shared 状态竞争。

@Suite(.serialized)
@MainActor
struct SettingsStoreExtensiveTests {
    @Test func singletonSame() {
        let a = SettingsStore.shared
        let b = SettingsStore.shared
        #expect(a === b)
    }

    @Test func apiKeysEmpty() {
        let s = SettingsStore.createTestInstance()
        s.setApiKeys([])
        #expect(s.apiKeys().isEmpty)
    }

    @Test func glossaryPersistenceAndNormalization() {
        let s = SettingsStore.createTestInstance()
        let marker = "TEST_MARKER_\(UUID().uuidString)"
        s.setGlossary([marker, " OpenAI ", "openai", "OpenAI", "B", "", " C "])
        let loaded = s.glossary()
        #expect(loaded.contains(marker))
        #expect(loaded.contains("OpenAI"))
        #expect(!loaded.contains("openai"))
        #expect(!loaded.contains(" OpenAI "))
        #expect(loaded.contains("B"))
        #expect(loaded.contains("C"))

        // 测试 normalizeGlossary 纯静态方法行为
        let normalized = SettingsStore.normalizeGlossary([" OpenAI ", "openai", "FunASR", "funasr"])
        #expect(normalized == ["FunASR", "OpenAI"])

        s.setGlossary([])
        #expect(s.glossary().isEmpty)
    }

    @Test func modelsRootIsFixed() {
        // 公开源码不分发权重，因此无模型环境返回空路径是合法状态。
        #expect(SettingsStore.modelsRoot.isEmpty || SettingsStore.modelsRoot.hasSuffix("/Models"))
    }

    @Test func preservesKeysAcrossGlossaryChanges() {
        let s = SettingsStore.createTestInstance()
        let keys = [APIKeyConfig(label: "primary", keyValue: "k1", isEnabled: true)]
        s.setApiKeys(keys)
        s.setGlossary(["abc"])
        s.setGlossary([])  // 改 glossary 不应影响 keys
        #expect(s.apiKeys().count == 1)
        s.setApiKeys([])
    }

    @Test func queueSettingsPersistIndependently() {
        let s = SettingsStore.createTestInstance()
        s.setQueueSettings(.init(isPaused: true, automaticallyStartNext: false))
        #expect(s.queueSettings() == .init(isPaused: true, automaticallyStartNext: false))
        s.setGlossary(["术语"])
        #expect(s.queueSettings().isPaused)
    }

    @Test func cleanupSettingsNormalizeCorruptValues() {
        let s = SettingsStore.createTestInstance()
        s.setCleanupSettings(.init(
            model: " ",
            chunkChars: -1,
            temperature: .infinity,
            prompt: "\n"
        ))
        let normalized = s.cleanupSettings()
        #expect(normalized.model == SettingsStore.CleanupDefaults.model)
        #expect(normalized.chunkChars == 2_000)
        #expect(normalized.temperature == SettingsStore.CleanupDefaults.temperature)
        #expect(normalized.prompt == SettingsStore.CleanupDefaults.prompt)
    }

    @Test func cleanupSettingsMigratesLegacyModelToFixedProductionModel() {
        let s = SettingsStore.createTestInstance()
        s.setCleanupSettings(.init(model: "legacy-model"))
        #expect(s.cleanupSettings().model == SettingsStore.CleanupDefaults.model)
    }

    @Test func failedSettingsWriteDoesNotAdvanceCache() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings_directory_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let s = SettingsStore(fileURL: directory)
        s.setGlossary(["should-not-persist"])
        #expect(s.glossary().isEmpty)
    }

    @Test func settingsDirectoryAndFileUseOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings_permissions_\(UUID().uuidString)")
        let directory = root.appendingPathComponent("nested")
        let fileURL = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path
        )
        try Data(#"{"glossary":[]}"#.utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path
        )

        let s = SettingsStore(fileURL: fileURL)
        _ = s.glossary()

        #expect(try posixPermissions(at: directory) == 0o700)
        #expect(try posixPermissions(at: fileURL) == 0o600)

        // Atomic replacement must not restore the process umask's broader mode.
        s.setGlossary(["受保护"])
        #expect(try posixPermissions(at: directory) == 0o700)
        #expect(try posixPermissions(at: fileURL) == 0o600)
    }

    @Test func permissionFailureDoesNotAdvanceCacheOrReportSuccess() async {
        struct PermissionFailure: Error {}

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings_permission_failure_\(UUID().uuidString)")
        let fileURL = root.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let s = SettingsStore(fileURL: fileURL) { url, permissions in
            if permissions == 0o600 {
                throw PermissionFailure()
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        }

        s.setGlossary(["must-not-enter-cache"])
        #expect(s.glossary().isEmpty)

        await Task.yield()
        #expect(s.lastPersistenceError != nil)
    }

    @Test func legacySettingsMissingNewFieldsAreMigratedIndependently() throws {
        let s = SettingsStore.createTestInstance()
        let legacy = """
        {
          "apiKeys": [{
            "label": "legacy",
            "keyValue": "AIza-legacy"
          }],
          "glossary": ["保留术语"],
          "cleanup": {"prompt": "保留提示词"},
          "queue": {"isPaused": true}
        }
        """
        try Data(legacy.utf8).write(to: s.settingsFileURL)
        s.resetCacheForTesting()

        let key = try #require(s.apiKeys().first)
        #expect(key.label == "legacy")
        #expect(key.tier == 0)
        #expect(key.successCount == 0)
        #expect(key.isEnabled)
        #expect(key.provider == "gemini")
        #expect(s.glossary() == ["保留术语"])
        #expect(s.cleanupSettings().prompt == "保留提示词")
        #expect(s.cleanupSettings().chunkChars == SettingsStore.CleanupDefaults.chunkChars)
        #expect(s.queueSettings().isPaused)
        #expect(s.queueSettings().automaticallyStartNext)
    }

    @Test func corruptOptionalFieldsDoNotDiscardOtherSettings() throws {
        let s = SettingsStore.createTestInstance()
        let partiallyCorrupt = """
        {
          "apiKeys": [{
            "id": "key-1",
            "label": "kept",
            "keyValue": "AIza-kept",
            "tier": "not-an-integer",
            "successCount": false
          }],
          "glossary": ["仍然保留"],
          "cleanup": {"temperature": "bad", "prompt": "有效提示词"}
        }
        """
        try Data(partiallyCorrupt.utf8).write(to: s.settingsFileURL)
        s.resetCacheForTesting()

        let key = try #require(s.apiKeys().first)
        #expect(key.id == "key-1")
        #expect(key.tier == 0)
        #expect(key.successCount == 0)
        #expect(s.glossary() == ["仍然保留"])
        #expect(s.cleanupSettings().prompt == "有效提示词")
        #expect(s.cleanupSettings().temperature == SettingsStore.CleanupDefaults.temperature)
    }

    @Test func corruptCollectionMembersDoNotDiscardValidSiblings() throws {
        let s = SettingsStore.createTestInstance()
        let partiallyCorrupt = """
        {
          "apiKeys": [
            {"label": "valid", "keyValue": "AIza-valid"},
            {"label": "missing-key-value"}
          ],
          "glossary": ["有效术语", 42]
        }
        """
        try Data(partiallyCorrupt.utf8).write(to: s.settingsFileURL)
        s.resetCacheForTesting()

        #expect(s.apiKeys().map(\.label) == ["valid"])
        #expect(s.glossary() == ["有效术语"])
    }

    @Test func syntacticallyInvalidSettingsAreNotOverwrittenByLaterWrite() throws {
        let s = SettingsStore.createTestInstance()
        let original = Data(#"{"apiKeys":["#.utf8)
        try original.write(to: s.settingsFileURL)
        s.resetCacheForTesting()

        #expect(s.apiKeys().isEmpty)
        s.setGlossary(["不得覆盖原文件"])

        #expect(try Data(contentsOf: s.settingsFileURL) == original)
        #expect(s.glossary().isEmpty)
    }

    @Test func explicitResetCanReplaceSyntacticallyInvalidSettings() throws {
        let s = SettingsStore.createTestInstance()
        let original = Data(#"{"apiKeys":["#.utf8)
        try original.write(to: s.settingsFileURL)
        s.resetCacheForTesting()

        _ = s.apiKeys()
        s.resetAllSettings()

        #expect(try Data(contentsOf: s.settingsFileURL) != original)
        #expect(s.apiKeys().isEmpty)
        #expect(s.glossary().isEmpty)
    }

    @Test func usableGeminiKeyRequiresEnabledNonWhitespaceGeminiEntry() {
        let s = SettingsStore.createTestInstance()
        s.setApiKeys([
            APIKeyConfig(label: "disabled", keyValue: "valid", isEnabled: false),
            APIKeyConfig(label: "blank", keyValue: " \n "),
            APIKeyConfig(label: "other", keyValue: "valid", provider: "other")
        ])
        #expect(!s.hasUsableGeminiKey())

        s.setApiKeys([APIKeyConfig(label: "usable", keyValue: "  secret  ")])
        #expect(s.hasUsableGeminiKey())
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }
}
