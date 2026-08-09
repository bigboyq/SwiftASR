import Testing
import Foundation
@testable import SwiftASR

@Test func apiKeyConfigRoundTrip() throws {
    let key = APIKeyConfig(label: "primary", keyValue: "AIza-test", isEnabled: true)
    let data = try JSONEncoder().encode(key)
    let restored = try JSONDecoder().decode(APIKeyConfig.self, from: data)
    #expect(restored.label == "primary")
    #expect(restored.keyValue == "AIza-test")
    #expect(restored.isEnabled == true)
}

@MainActor
struct SettingsStoreRoundTripTests {
    @Test func roundTrip() {
        let s = SettingsStore.createTestInstance()
        let label = "test_\(UUID().uuidString)"
        s.setApiKeys([APIKeyConfig(label: label, keyValue: "AIza-x", isEnabled: true)])
        s.setGlossary(["术语A", "术语B"])

        let keys = s.apiKeys()
        #expect(keys.first?.label == label)
        let terms = s.glossary()
        #expect(terms.contains("术语A"))
        #expect(terms.contains("术语B"))
        // 干净源码检出不附带模型；开发环境有模型时路径应指向 Models。
        #expect(SettingsStore.modelsRoot.isEmpty || SettingsStore.modelsRoot.contains("Models"))

        // 清理
        s.setApiKeys([])
        s.setGlossary([])
    }
}
