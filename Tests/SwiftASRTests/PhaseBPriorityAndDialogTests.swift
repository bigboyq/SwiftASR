import Testing
import Foundation
@testable import SwiftASR

// MARK: - APIKeyConfig.priority

@Test func apiKeyConfig_PriorityDefaultIsZero() {
    let k = APIKeyConfig(label: "test", keyValue: "AIza-x")
    #expect(k.priority == 0, "默认 priority 应该是 0")
}

@Test func apiKeyConfig_PriorityClampedToValidRange() {
    // priority < 0 → 0
    let k1 = APIKeyConfig(label: "a", keyValue: "x", priority: -5)
    #expect(k1.priority == 0, "负数 priority 应该是 0")
    // priority > 99 → 99
    let k2 = APIKeyConfig(label: "b", keyValue: "x", priority: 150)
    #expect(k2.priority == 99, ">99 的 priority 应该是 99")
}

@Test func apiKeyConfig_PriorityPreservedInValidRange() {
    let k = APIKeyConfig(label: "a", keyValue: "x", priority: 42)
    #expect(k.priority == 42)
}

@Test func apiKeyConfig_PriorityRoundTripJSON() throws {
    let k = APIKeyConfig(label: "primary", keyValue: "AIza-x", priority: 7)
    let data = try JSONEncoder().encode(k)
    let restored = try JSONDecoder().decode(APIKeyConfig.self, from: data)
    #expect(restored.priority == 7)
}

// MARK: - GeminiKeyFailover 按 priority 排序

@Test func failover_SortsKeysByPriorityAscending() {
    let k1 = APIKeyConfig(label: "low", keyValue: "AIza-1", priority: 10)
    let k2 = APIKeyConfig(label: "high", keyValue: "AIza-2", priority: 1)
    let k3 = APIKeyConfig(label: "mid", keyValue: "AIza-3", priority: 5)
    let failover = GeminiKeyFailover(keys: [k1, k2, k3])
    #expect(failover.keys.count == 3)
    #expect(failover.keys[0].label == "high", "priority=1 应排第一")
    #expect(failover.keys[1].label == "mid", "priority=5 应排第二")
    #expect(failover.keys[2].label == "low", "priority=10 应排第三")
}

@Test func failover_FiltersDisabledAndEmptyKeys() {
    let k1 = APIKeyConfig(label: "enabled-1", keyValue: "AIza-1", isEnabled: true, priority: 1)
    let k2 = APIKeyConfig(label: "disabled", keyValue: "AIza-2", isEnabled: false, priority: 2)
    let k3 = APIKeyConfig(label: "empty", keyValue: "", isEnabled: true, priority: 3)
    let failover = GeminiKeyFailover(keys: [k1, k2, k3])
    #expect(failover.keys.count == 1, "只保留 enabled + 非空")
    #expect(failover.keys[0].label == "enabled-1")
}

@Test func failover_InitialCurrentIdx_BelowKeysCount() async {
    let k1 = APIKeyConfig(label: "a", keyValue: "AIza-1", priority: 1)
    let k2 = APIKeyConfig(label: "b", keyValue: "AIza-2", priority: 2)
    let failover = GeminiKeyFailover(keys: [k1, k2])
    #expect(await failover.currentIdx == 0, "init 时 currentIdx = 0")
    #expect(await failover.currentIdx < failover.keys.count)
}

@Test func failover_EmptyKeys_DoesNotCrash() async {
    let failover = GeminiKeyFailover(keys: [])
    #expect(failover.keys.isEmpty)
    #expect(await failover.currentIdx == 0)
}
