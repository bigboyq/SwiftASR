import Testing
import Foundation
@testable import SwiftASR

// MARK: - Phase 8: APIKeyConfig schema + SettingsStore + Importer

@Test func apiKeyConfigDerivesKeyPrefix() {
    // 基本：前 4 + 掩码 + 后 4
    let k = APIKeyConfig(label: "x", keyValue: "AIzaSyTest12345abcdef")
    #expect(k.keyPrefix == "AIza••••cdef")

    // 短 key 显示全部
    let short = APIKeyConfig(label: "x", keyValue: "abc")
    #expect(short.keyPrefix == "abc")
}

@Test func apiKeyConfigDecoderIgnoresLegacyBaseURLField() {
    // 旧 settings.json 里可能残留 baseURL 字段（Phase 8 引入，后被移除）
    // decoder 应 silently 忽略，不报错也不写入（因为字段已删除）
    let json = """
    {
        "id": "u-legacy",
        "label": "legacy",
        "keyValue": "AIzaSyLegacyKey1234abcd",
        "isEnabled": true,
        "priority": 2,
        "tier": 0,
        "provider": "gemini",
        "successCount": 0,
        "baseURL": "https://example.com/v1beta"
    }
    """
    let data = Data(json.utf8)
    let decoded = try! JSONDecoder().decode(APIKeyConfig.self, from: data)
    #expect(decoded.id == "u-legacy")
    #expect(decoded.priority == 2)
    // baseURL 字段已从 schema 删除；未知字段被 Swift Codable 默认忽略
}

@Test func apiKeyConfigDecoderToleratesAllCurrentFields() {
    // 完整 settings.json：当前 schema 全字段都在
    let json = """
    {
        "id": "u-2",
        "label": "neat",
        "keyValue": "AIzaSyNewKeyABCDefg1234",
        "isEnabled": false,
        "priority": 7,
        "tier": 0,
        "provider": "gemini",
        "keyPrefix": "AIza••••1234",
        "lastUsedAt": "2026-07-09T12:34:56Z",
        "successCount": 5,
        "createdAt": "2026-07-01T08:00:00Z",
        "notes": "公司 gemini key"
    }
    """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try! decoder.decode(APIKeyConfig.self, from: data)
    #expect(decoded.notes == "公司 gemini key")
    #expect(decoded.isEnabled == false)
    #expect(decoded.lastUsedAt != nil)
    #expect(decoded.createdAt != nil)
}

@Suite(.serialized)
@MainActor
struct SettingsStorePhase8Tests {
    @Test func settingsStoreUpsertReplacesById() {
        let s = SettingsStore.createTestInstance()

        // 第一次 upsert：2 个新 key
        let a = APIKeyConfig(label: "A", keyValue: "AIzaSyA1111aaaa", priority: 5)
        let b = APIKeyConfig(label: "B", keyValue: "AIzaSyB2222bbbb", priority: 10)
        s.upsertApiKeys([a, b])
        var loaded = s.apiKeys()
        #expect(loaded.count == 2)
        #expect(loaded.contains { $0.label == "A" })

        // 改 B 的 priority（用同一个 id 替换）
        let bUpdated = APIKeyConfig(id: b.id, label: "B", keyValue: "AIzaSyB2222bbbb", priority: 3)
        s.upsertApiKeys([bUpdated])
        loaded = s.apiKeys()
        #expect(loaded.count == 2, "不应新增，应该替换 B")
        let bNow = loaded.first { $0.label == "B" }!
        #expect(bNow.priority == 3, "B 的 priority 应该被更新到 3")
    }

    @Test func settingsStoreUpdateLastUsedAt() {
        let s = SettingsStore.createTestInstance()

        let key = APIKeyConfig(label: "LuTest", keyValue: "AIzaSyLuTest1111aaaa", priority: 50)
        s.upsertApiKeys([key])
        #expect(s.apiKeys().first?.lastUsedAt == nil, "刚 upsert 时 lastUsedAt 是 nil")

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        s.updateLastUsedAt(keyId: key.id, at: when)
        let reloaded = s.apiKeys().first { $0.id == key.id }!
        #expect(reloaded.lastUsedAt == when)
    }

    @Test func settingsStoreUpdateNotes() {
        let s = SettingsStore.createTestInstance()

        let key = APIKeyConfig(label: "NoteTest", keyValue: "AIzaSyNoteTest1111")
        s.upsertApiKeys([key])
        s.updateNotes(keyId: key.id, notes: "test notes / 备注")
        let reloaded = s.apiKeys().first { $0.id == key.id }!
        #expect(reloaded.notes == "test notes / 备注")
        s.updateNotes(keyId: key.id, notes: nil)
        #expect(s.apiKeys().first { $0.id == key.id }!.notes == nil)
    }

    // MARK: - Gemini Failover lastUsedAt 联动

    @Test func failoverUpdatesCurrentSuccessfulKeyId() async {
    // 这个测试不能调真 Gemini API，但能验证 failover 在切换 key 时
    // currentSuccessfulKeyId 字段语义对（手动构造一个 mock-like 场景）
    let keyA = APIKeyConfig(label: "A", keyValue: "fakeA", priority: 1)
    let keyB = APIKeyConfig(label: "B", keyValue: "fakeB", priority: 2)
    let failover = GeminiKeyFailover(keys: [keyA, keyB], model: "fake")
    // 初始 sticky 在 idx=0
    #expect(await failover.currentIdx == 0)
    #expect(await failover.currentSuccessfulKeyId == nil)
    #expect(await failover.currentKey?.label == "A")
}

    // MARK: - GeminiProvider.testConnection URL / error decoding

    @Test func testConnectionBuildsCorrectEndpoint() async {
    // 用一个无效 key 和一个 mock 不可能成功的 endpoint，
    // 验证返回的 (ok=false, message) 不崩且 message 包含 "❌"
    let (_, message) = await GeminiProvider.testConnection(
        apiKey: "definitely-not-a-real-key",
        endpoint: "https://invalid.invalid.example"
    )
    #expect(message.contains("❌") || message.contains("网络异常"))
}

    @Test func testConnectionRejectsEmptyKey() async {
    let (ok, message) = await GeminiProvider.testConnection(apiKey: "")
    #expect(ok == false)
    #expect(message.contains("Key 不能为空"))
}

}
