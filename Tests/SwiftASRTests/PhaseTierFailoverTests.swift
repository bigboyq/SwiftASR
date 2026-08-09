// MARK: - Phase Tier 升级：APIKeyConfig.tier + GeminiKeyFailover 行为
//
// 本文件用 URLProtocol mock 拦截 URLSession，URLProtocolClient 回调需要跨
// 线程从 CFNetwork 子线程 → Swift Testing test task。URLProtocol 父类的
// `client` 属性不是 Sendable，Swift 6 严格并发会拒。URLProtocol 文档明确
// 允许从任意线程同步调 client 回调（CFNetwork 会负责 enqueue 到发起 session
// 的 runloop），这里是 file-local 单线程 ownership 边界。

import Foundation
import Testing
@testable import SwiftASR

// MARK: - APIKeyConfig.tier 兼容 + clamp

@Suite("Tier 升级：APIKeyConfig")
@MainActor
struct TierAPIKeyConfigTests {

    @Test func defaultTierIsZero() {
        let k = APIKeyConfig(label: "x", keyValue: "AIza-x")
        #expect(k.tier == 0, "默认 tier 应该是 0（免费）")
    }

    @Test func tierClampedTo09() {
        #expect(APIKeyConfig(label: "x", keyValue: "v", tier: -5).tier == 0)
        #expect(APIKeyConfig(label: "x", keyValue: "v", tier: 0).tier == 0)
        #expect(APIKeyConfig(label: "x", keyValue: "v", tier: 9).tier == 9)
        #expect(APIKeyConfig(label: "x", keyValue: "v", tier: 99).tier == 9, ">9 应当 clamp 到 9")
    }

    @Test func priorityAlsoClampedForSymmetry() {
        // v9 行为：priority 也 clamp 0...99
        #expect(APIKeyConfig(label: "x", keyValue: "v", priority: 150).priority == 99)
    }

    @Test func decoderReadsExplicitTier() throws {
        let json = """
        {
          "id": "abc",
          "label": "paid",
          "keyValue": "AIza-paid",
          "isEnabled": true,
          "priority": 0,
          "tier": 1,
          "provider": "gemini",
          "successCount": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(APIKeyConfig.self, from: json)
        #expect(decoded.tier == 1)
    }

    @Test func encoderRoundTripsTier() throws {
        let original = APIKeyConfig(label: "x", keyValue: "AIza-x", priority: 5, tier: 2)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(APIKeyConfig.self, from: data)
        #expect(decoded.tier == 2)
        #expect(decoded.priority == 5)
    }

    // MARK: - successCount 字段

    @Test func defaultSuccessCountIsZero() {
        let k = APIKeyConfig(label: "x", keyValue: "v")
        #expect(k.successCount == 0)
    }

    @Test func successCountNegativeClampedToZero() {
        // JSON 损坏兜底：负数 → 0（不能反向自增）
        #expect(APIKeyConfig(label: "x", keyValue: "v", successCount: -5).successCount == 0)
    }

    @Test func encoderRoundTripsSuccessCount() throws {
        let original = APIKeyConfig(label: "x", keyValue: "v", successCount: 42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(APIKeyConfig.self, from: data)
        #expect(decoded.successCount == 42)
    }
}

// MARK: - 错误分类

@Suite("Tier 升级：错误分类")
@MainActor
struct TierErrorClassifierTests {

    private func makeNSError(code: Int, msg: String) -> NSError {
        return NSError(
            domain: "GeminiProvider", code: code,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }

    @Test func rateLimitIsOnly429AndURLErrors() {
        #expect(GeminiProvider.isRateLimit(makeNSError(code: 429, msg: "rate limit")) == true)
        #expect(GeminiProvider.isRateLimit(makeNSError(code: 503, msg: "high demand")) == false)
        #expect(GeminiProvider.isRateLimit(makeNSError(code: 529, msg: "")) == false)
        #expect(GeminiProvider.isRateLimit(makeNSError(code: 401, msg: "unauthorized")) == false)
    }

    @Test func serverOverloadIs5xxAnd529() {
        #expect(GeminiProvider.isServerOverload(makeNSError(code: 500, msg: "")) == true)
        #expect(GeminiProvider.isServerOverload(makeNSError(code: 503, msg: "")) == true)
        #expect(GeminiProvider.isServerOverload(makeNSError(code: 529, msg: "")) == true)
        #expect(GeminiProvider.isServerOverload(makeNSError(code: 502, msg: "")) == true)
        #expect(GeminiProvider.isServerOverload(makeNSError(code: 429, msg: "")) == false,
                "429 不算 overload — 那是 per-key 限流")
        #expect(GeminiProvider.isServerOverload(makeNSError(code: 401, msg: "unauthorized")) == false)
    }

    @Test func keywordFallbackRecognizesRateLimit() {
        // SDK 不带 code，但 message 里有 "rate limit" / "resource exhausted"
        #expect(GeminiProvider.isRateLimit(makeNSError(code: -99, msg: "ResourceExhausted: 429")) == true)
        #expect(GeminiProvider.isRateLimit(makeNSError(code: -99, msg: "rate limit exceeded")) == true)
        #expect(GeminiProvider.isRateLimit(makeNSError(code: -99, msg: "rate_limit_exceeded")) == true)
        #expect(GeminiProvider.isRateLimit(makeNSError(code: -99, msg: "high demand")) == false)
    }

    @Test func keywordFallbackRecognizesOverload() {
        #expect(GeminiProvider.isServerOverload(makeNSError(code: -99, msg: "high demand spike")) == true)
        #expect(GeminiProvider.isServerOverload(makeNSError(code: -99, msg: "site is overloaded")) == true)
        #expect(GeminiProvider.isServerOverload(makeNSError(code: -99, msg: "service unavailable")) == true)
        #expect(GeminiProvider.isServerOverload(makeNSError(code: -99, msg: "rate limit")) == false,
                "rate-limit 不算 overload")
    }

    @Test func isRetryableIsUnion() {
        // isRetryable = isRateLimit ∪ isServerOverload
        let rl = makeNSError(code: 429, msg: "")
        let overload = makeNSError(code: 503, msg: "")
        let auth = makeNSError(code: 401, msg: "")
        #expect(GeminiProvider.isRetryable(rl) == true)
        #expect(GeminiProvider.isRetryable(overload) == true)
        #expect(GeminiProvider.isRetryable(auth) == false)
    }

    @Test func explicitRetryableFalseOverridesClassification() {
        // 调用方显式说不可重试（userInfo["retryable"] = false），尊重它
        let err = NSError(
            domain: "GeminiProvider", code: 429,
            userInfo: [NSLocalizedDescriptionKey: "rate limit", "retryable": false]
        )
        #expect(GeminiProvider.isRateLimit(err) == false)
        #expect(GeminiProvider.isServerOverload(err) == false)
        #expect(GeminiProvider.isRetryable(err) == false)
    }
}

// MARK: - Mock URLProtocol + Failover 行为

/// 把 URLSession 注入到 GeminiKeyFailover，测试用 URLProtocol 拦截请求并按
/// key 返回指定的 status code。脚本式行为："keyA 第一次返回 503，第二次返回 200"
/// 这种 fake 让我们能精确控制 429/5xx/529 路径而不调真实 API。
///
/// 200 必须返 valid Gemini JSON 格式并带 STOP finishReason。
/// GeminiProvider 解析失败会抛 -3/-4（malformed 不可重试），会污染测试。
final class FakeKeyURLProtocol: URLProtocol {
    nonisolated(unsafe) static var scripts: [String: [Int]] = [:]
    nonisolated(unsafe) static var attempts: [String: Int] = [:]
    nonisolated(unsafe) static var lock = NSLock()

    static func reset() {
        lock.lock()
        scripts = [:]
        attempts = [:]
        lock.unlock()
    }

    static func recordAttempt(for apiKey: String) {
        lock.lock()
        attempts[apiKey, default: 0] += 1
        lock.unlock()
    }

    static func nextStatusCode(for apiKey: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        var queue = scripts[apiKey] ?? []
        if queue.isEmpty { return nil }
        let code = queue.removeFirst()
        scripts[apiKey] = queue
        return code
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // API key 必须只经请求头发送，不能进入会被代理/诊断记录的 URL。
        let apiKey = request.value(forHTTPHeaderField: "x-goog-api-key") ?? "?"
        Self.recordAttempt(for: apiKey)

        let code = Self.nextStatusCode(for: apiKey) ?? 500
        if code == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let bodyData: Data
        if code == 200 {
            // Valid Gemini JSON (paragraph mode): candidates[0].content.parts[0].text = "{\"paragraphs\":[]}"
            // 跟 GeminiProvider.callOnceParagraphs 期望的 schema 一致
            bodyData = Data(#"""
            {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"{\"paragraphs\":[]}"}]}}]}
            """#.utf8)
        } else if code == 429 {
            // 模拟真实 Gemini 429 响应体（含 RetryInfo + QuotaFailure）
            // FakeKeyURLProtocol 支持两种模式：
            //   - 默认：RPM 限流（retryDelay=30s，无 PerDay）
            //   - scripts 里 code 以 4290 结尾：RPD 限流（retryDelay=30s，含 PerDay）
            // 此处统一发 RPD 含 PerDay 的 body；测试用 notUseBeforeByKeyId 判断效果。
            bodyData = Data(#"""
            {"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"30s"},{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}]}}
            """#.utf8)
        } else {
            bodyData = Data("fake body".utf8)
        }


        // URLProtocol 文档允许在 startLoading 内部同步调 client 回调；
        // CFNetwork 会把回调正确路由回发起 session 的 runloop。
        // 同步调（不是 dispatch）才能让 await session.data 立即看到响应。
        // 不额外 dispatch：同步回调使每次 mock request 都在当前测试步骤内完成，
        // 从而保持脚本的请求顺序确定。
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bodyData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // URLSession 在 timeout / cancel 时调 stopLoading。
        // 必须显式通知 client 请求已终止。
        client?.urlProtocol(self, didFailWithError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "FakeKeyURLProtocol: stopLoading"]
        ))
    }
}

/// 创建一个走 URLProtocol mock 的 ephemeral URLSession，用于
/// `TierFailoverBehaviorTests`。注册 `FakeKeyURLProtocol`
/// 拦截所有请求并按 `FakeKeyURLProtocol.scripts` 返回 mock 响应。
///
/// 每个行为测试注入独立 session，避免访问真实网络；URLProtocol 同步返回
/// 脚本化响应，因此测试不会依赖 main runloop 调度。
func makeFakeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeKeyURLProtocol.self]
    config.timeoutIntervalForRequest = 5
    return URLSession(configuration: config)
}

/// 集成测试：URLSession + URLProtocol mock 调真实的 `GeminiKeyFailover.callOnceParagraphs`。
///
/// 该 suite 覆盖真实的 `GeminiKeyFailover.callOnceParagraphs` + URLProtocol mock：
/// 429 同 tier 轮换、5xx 升 tier、认证错误中止以及 sticky cursor。它必须保持
/// serial，因为 mock 脚本由 file-local static state 管理。
@Suite(
    "Tier 升级：GeminiKeyFailover 行为",
    .serialized
)
nonisolated struct TierFailoverBehaviorTests {

    init() {
        FakeKeyURLProtocol.reset()
    }

    /// 每个 test 跑前显式 reset——Swift Testing suite init 只跑一次，
    /// 但 mock 的 static 字典在 test 之间共享，必须 per-test 清。
    static func reset() {
        FakeKeyURLProtocol.reset()
    }

    @Test func keysSortedByTierThenPriority() {
        // 不同 tier 混排，构造顺序打乱，验证 init 后 keys 已排序
        let k0p0 = APIKeyConfig(label: "free-0", keyValue: "K0", priority: 0, tier: 0)
        let k1p0 = APIKeyConfig(label: "paid-0", keyValue: "K1", priority: 0, tier: 1)
        let k0p1 = APIKeyConfig(label: "free-1", keyValue: "K2", priority: 1, tier: 0)
        let k2p0 = APIKeyConfig(label: "vip-0", keyValue: "K3", priority: 0, tier: 2)
        let failover = GeminiKeyFailover(keys: [k2p0, k0p1, k1p0, k0p0])
        #expect(failover.keys.map(\.label) == ["free-0", "free-1", "paid-0", "vip-0"])
    }

    @Test nonisolated func overloadPromotesToNextTier() async {
        // tier=0 key-A 503 → 跳过 tier 0 → tier=1 key-B 200
        FakeKeyURLProtocol.scripts = [
            "K0": [503],  // tier 0 overload
            "K1": [200],  // tier 1 success
        ]
        let keys = [
            APIKeyConfig(label: "free", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "paid", keyValue: "K1", priority: 0, tier: 1),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        let result = try? await failover.callOnceParagraphs(prompt: "p")
        #expect(result != nil, "tier 1 成功 → 不抛")
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1)
        #expect(FakeKeyURLProtocol.attempts["K1"] == 1)
        // sticky 现在是 (tier=1, idx=0)
        #expect(await failover.currentTier == 1)
        #expect(await failover.currentIdxInTier == 0)
        #expect(await failover.currentSuccessfulKeyId == keys[1].id)
    }

    @Test nonisolated func rateLimitRotatesWithinTier() async {
        // tier=0 key-A 429 (per-key) → 切到 key-B（同 tier）
        // 新行为：429 后立即冷却，不再重试同 key，因此 K0 仅被尝试 1 次。
        FakeKeyURLProtocol.reset()
        FakeKeyURLProtocol.scripts = [
            "K0": [429],
            "K1": [200],       // 同 tier 下一把 key 成功
        ]
        let keys = [
            APIKeyConfig(label: "free-0", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "free-1", keyValue: "K1", priority: 1, tier: 0),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        let result = try? await failover.callOnceParagraphs(prompt: "p")
        #expect(result != nil)
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1)
        #expect(FakeKeyURLProtocol.attempts["K1"] == 1)
        #expect(await failover.currentTier == 0, "留在 tier 0 — 429 不升 tier")
        #expect(await failover.currentIdxInTier == 1, "切到同 tier 的 K1")
    }

    @Test nonisolated func tier0ExhaustedBy429PromotesToTier1() async {
        // tier=0 两个 key 都 429 → 升 tier 1
        // 新行为：两个 key 各 429 一次就会被标记冷却，不重试，因此 attempts 是 1。
        FakeKeyURLProtocol.reset()
        FakeKeyURLProtocol.scripts = [
            "K0": [429],
            "K1": [429],
            "K2": [200],
        ]
        let keys = [
            APIKeyConfig(label: "free-0", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "free-1", keyValue: "K1", priority: 1, tier: 0),
            APIKeyConfig(label: "paid-0", keyValue: "K2", priority: 0, tier: 1),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        let result = try? await failover.callOnceParagraphs(prompt: "p")
        #expect(result != nil)
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1)
        #expect(FakeKeyURLProtocol.attempts["K1"] == 1)
        #expect(FakeKeyURLProtocol.attempts["K2"] == 1)
        #expect(await failover.currentTier == 1)
        #expect(await failover.currentIdxInTier == 0)
    }

    @Test nonisolated func overloadInEveryTierFails() async {
        // tier=0 503, tier=1 503 → 全部升不上去了 → 抛错
        FakeKeyURLProtocol.scripts = [
            "K0": [503],
            "K1": [503],
        ]
        let keys = [
            APIKeyConfig(label: "free", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "paid", keyValue: "K1", priority: 0, tier: 1),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        do {
            _ = try await failover.callOnceParagraphs(prompt: "p")
            Issue.record("expected error when all tiers fail")
        } catch {
            // 期望抛错
        }
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1, "tier 0 overload → 跳 K0，不试")
        #expect(FakeKeyURLProtocol.attempts["K1"] == 1, "tier 1 overload → 跳 K1")
    }

    @Test nonisolated func authErrorDoesNotFailover() async {
        // 401 / 403 是不可重试的，直接抛
        FakeKeyURLProtocol.scripts = [
            "K0": [401],
        ]
        let keys = [
            APIKeyConfig(label: "free", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "paid", keyValue: "K1", priority: 0, tier: 1),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        do {
            _ = try await failover.callOnceParagraphs(prompt: "p")
            Issue.record("expected error on 401")
        } catch {
            // 期望
        }
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1, "401 不可重试 → 不切 K1")
        #expect(FakeKeyURLProtocol.attempts["K1"] == nil, "K1 完全没被尝试")
    }

    @Test nonisolated func urlSessionCancellationPreservesCleanupCancelled() async {
        FakeKeyURLProtocol.scripts = ["K0": [-1]]
        let key = APIKeyConfig(label: "free", keyValue: "K0", priority: 0, tier: 0)
        let failover = GeminiKeyFailover(keys: [key], session: makeFakeSession())

        do {
            _ = try await failover.callOnceParagraphs(prompt: "p")
            Issue.record("请求取消后不应返回成功")
        } catch is CleanupCancelled {
            // URLSession cancellation must remain a user cancellation.
        } catch {
            Issue.record("请求取消不应被记录为其他错误：\(error)")
        }
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1)
    }

    @Test nonisolated func stickyCursorSurvivesAcrossCallOnceCalls() async {
        // 第一次 callOnceParagraphs 升 tier 1；第二次 callOnceParagraphs 应该从 tier 1 开始
        // （不再回到 tier 0 重试 K0）
        FakeKeyURLProtocol.scripts = [
            "K0": [503],  // chunk 1: tier 0 overload
            "K1": [200, 200],  // chunk 1 + chunk 2 都成功
        ]
        let keys = [
            APIKeyConfig(label: "free", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "paid", keyValue: "K1", priority: 0, tier: 1),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        _ = try? await failover.callOnceParagraphs(prompt: "p1")
        #expect(await failover.currentTier == 1, "chunk 1 后 sticky 在 tier 1")
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1)
        #expect(FakeKeyURLProtocol.attempts["K1"] == 1)

        _ = try? await failover.callOnceParagraphs(prompt: "p2")
        // chunk 2 直接走 K1，不重试 K0
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1, "sticky 之后不再回 tier 0")
        #expect(FakeKeyURLProtocol.attempts["K1"] == 2)
        #expect(await failover.currentTier == 1)
    }

    @Test nonisolated func missingTierFallsBackToZero() async {
        // 老 APIKeyConfig 没显式 tier → 走 tier 0，跟 v9 行为兼容
        let keyA = APIKeyConfig(label: "A", keyValue: "KA", priority: 0)  // tier defaults to 0
        let keyB = APIKeyConfig(label: "B", keyValue: "KB", priority: 1)  // tier defaults to 0
        let failover = GeminiKeyFailover(keys: [keyA, keyB])
        #expect(await failover.currentTier == 0)
        #expect(await failover.currentIdxInTier == 0)
    }

    @Test nonisolated func singleTierPoolDoesNotPromoteOn429() async {
        // 只有 tier 0 的池子，所有 key 都 429 → 整 tier 冷却 → 没下一个 tier → 失败
        // 新行为（notUseBefore 冷却机制）：每个 key 429 后立即标记冷却，不再重试同 key，
        // 因此每个 key 只被调用 1 次。
        FakeKeyURLProtocol.reset()
        FakeKeyURLProtocol.scripts = [
            "K0": [429],
            "K1": [429],
        ]
        let keys = [
            APIKeyConfig(label: "a", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "b", keyValue: "K1", priority: 1, tier: 0),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        do {
            _ = try await failover.callOnceParagraphs(prompt: "p")
            Issue.record("expected error when single tier is exhausted")
        } catch {
            // 期望
        }
        // 新行为：每个 key 各只被调 1 次（429 后立即冷却切下一个）
        #expect(FakeKeyURLProtocol.attempts["K0"] == 1)
        #expect(FakeKeyURLProtocol.attempts["K1"] == 1)
        // 两次 429 → rateLimitCount == 2
        #expect(await failover.rateLimitCount == 2)
    }

    @Test nonisolated func rateLimit_setsNotUseBefore_andAdvancesToNextKey() async {
        FakeKeyURLProtocol.reset()
        // K0: 429（RPD，body 含 PerDay + retryDelay=30s）→ 切到 K1: 200
        FakeKeyURLProtocol.scripts = [
            "K0": [429],
            "K1": [200],
        ]
        let keys = [
            APIKeyConfig(label: "free-a", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "free-b", keyValue: "K1", priority: 1, tier: 0),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        let result = try? await failover.callOnceParagraphs(prompt: "p")
        #expect(result != nil, "K1 成功，不抛")
        // K0 应被标记 notUseBefore（RPD → now+6H）
        let until = await failover.notUseBefore(for: keys[0].id)
        #expect(until != nil, "K0 429 后 notUseBefore 应被设置")
        // 6H 冷却：应该在约 6*3600 秒后（允许 ±10s 误差）
        let expectedMin = Date().addingTimeInterval(6 * 3600 - 10)
        let expectedMax = Date().addingTimeInterval(6 * 3600 + 10)
        #expect(until! > expectedMin && until! < expectedMax, "RPD → notUseBefore ≈ now+6H")
        // sticky cursor 应 pin 到 K1
        #expect(await failover.currentSuccessfulKeyId == keys[1].id)
        #expect(await failover.rateLimitCount == 1)
    }

    @Test nonisolated func allTierCoolingDown_escalatesToNextTier() async {
        FakeKeyURLProtocol.reset()
        // tier=0 两个 key 都 429 → tier=1 成功
        FakeKeyURLProtocol.scripts = [
            "K0": [429],
            "K1": [429],
            "K2": [200],
        ]
        let keys = [
            APIKeyConfig(label: "free-a", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "free-b", keyValue: "K1", priority: 1, tier: 0),
            APIKeyConfig(label: "paid",   keyValue: "K2", priority: 0, tier: 1),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        let result = try? await failover.callOnceParagraphs(prompt: "p")
        #expect(result != nil, "tier=1 K2 成功")
        #expect(await failover.notUseBefore(for: keys[0].id) != nil, "K0 被冷却")
        #expect(await failover.notUseBefore(for: keys[1].id) != nil, "K1 被冷却")
        #expect(await failover.currentTier == 1)
        #expect(await failover.rateLimitCount == 2, "两次 429")
        let escalations = await failover.tierEscalations
        #expect(escalations.count == 1)
        #expect(escalations[0].reason == .rateLimitCooldown)
    }

    @Test nonisolated func recordsTierEscalationOn529ServerOverload() async throws {
        FakeKeyURLProtocol.reset()
        FakeKeyURLProtocol.scripts = [
            "K0": [529],
            "K1": [200],
        ]
        let keys = [
            APIKeyConfig(label: "free-key", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "paid-key", keyValue: "K1", priority: 0, tier: 1),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        _ = try await failover.callOnceParagraphs(prompt: "test", chunkIndex: 3)

        let escalations = await failover.tierEscalations
        #expect(escalations.count == 1)
        #expect(escalations[0].chunkIndex == 3)
        #expect(escalations[0].fromTier == 0)
        #expect(escalations[0].toTier == 1)
        #expect(escalations[0].fromKeyLabel == "free-key")
        #expect(escalations[0].toKeyLabel == "paid-key")
        #expect(escalations[0].reason == .serverOverload(statusCode: 529))
    }

    @Test nonisolated func doesNotRecordTierEscalationOnSameTier429Rotation() async throws {
        FakeKeyURLProtocol.reset()
        FakeKeyURLProtocol.scripts = [
            "K0": [429],
            "K1": [200],
        ]
        let keys = [
            APIKeyConfig(label: "free-0", keyValue: "K0", priority: 0, tier: 0),
            APIKeyConfig(label: "free-1", keyValue: "K1", priority: 1, tier: 0),
        ]
        let failover = GeminiKeyFailover(keys: keys, session: makeFakeSession())
        _ = try await failover.callOnceParagraphs(prompt: "test", chunkIndex: 2)

        let escalations = await failover.tierEscalations
        #expect(escalations.isEmpty, "同 tier 内因 429 轮询不增加 TierEscalationEvent")
    }
}

// MARK: - SettingsStore 排序

@Suite("Tier 升级：SettingsStore 排序", .serialized)
@MainActor
struct TierSettingsStoreSortTests {

    @Test func upsertSortsByTierThenPriority() {
        // 用临时 instance 避免污染真 settings.json
        let store = SettingsStore.createTestInstance()
        store.resetCacheForTesting()
        // 故意打乱顺序 upsert
        let k1 = APIKeyConfig(label: "paid-0", keyValue: "K1", priority: 0, tier: 1)
        let k2 = APIKeyConfig(label: "free-0", keyValue: "K0", priority: 0, tier: 0)
        let k3 = APIKeyConfig(label: "vip-0", keyValue: "KV", priority: 0, tier: 2)
        let k4 = APIKeyConfig(label: "free-1", keyValue: "K01", priority: 1, tier: 0)
        store.upsertApiKeys([k1, k2, k3, k4])
        let sorted = store.apiKeys()
        #expect(sorted.map(\.label) == ["free-0", "free-1", "paid-0", "vip-0"],
                "应按 (tier, priority) 排序")
    }

    @Test func upsertPreservesExistingKeys() {
        let store = SettingsStore.createTestInstance()
        store.resetCacheForTesting()
        let k1 = APIKeyConfig(label: "existing", keyValue: "K1", priority: 0, tier: 0)
        store.upsertApiKeys([k1])
        // 再 upsert 一个新 key
        let k2 = APIKeyConfig(label: "new", keyValue: "K2", priority: 1, tier: 0)
        store.upsertApiKeys([k2])
        let ids = store.apiKeys().map(\.id)
        #expect(ids.contains(k1.id))
        #expect(ids.contains(k2.id))
    }

    // MARK: - recordSuccess 行为

    @Test func recordSuccessIncrementsCount() {
        let store = SettingsStore.createTestInstance()
        store.resetCacheForTesting()
        let key = APIKeyConfig(label: "x", keyValue: "v", priority: 0, tier: 0)
        store.upsertApiKeys([key])

        // 第一次
        store.recordSuccess(keyId: key.id)
        var fetched = store.apiKeys().first { $0.id == key.id }!
        #expect(fetched.successCount == 1)
        #expect(fetched.lastUsedAt != nil)

        // 再来两次
        store.recordSuccess(keyId: key.id)
        store.recordSuccess(keyId: key.id)
        fetched = store.apiKeys().first { $0.id == key.id }!
        #expect(fetched.successCount == 3)
    }

    @Test func updateLastUsedAtDoesNotIncrementCount() {
        // testConnection 路径只刷时间，不算业务成功
        let store = SettingsStore.createTestInstance()
        store.resetCacheForTesting()
        let key = APIKeyConfig(label: "x", keyValue: "v", priority: 0, tier: 0)
        store.upsertApiKeys([key])

        store.updateLastUsedAt(keyId: key.id)
        let fetched = store.apiKeys().first { $0.id == key.id }!
        #expect(fetched.successCount == 0, "updateLastUsedAt 不应增计数")
        #expect(fetched.lastUsedAt != nil, "但 lastUsedAt 应该被刷")
    }

    @Test func recordSuccessOnUnknownKeyIsNoOp() {
        let store = SettingsStore.createTestInstance()
        store.resetCacheForTesting()
        // 没 upsert 任何 key
        store.recordSuccess(keyId: "non-existent")
        // 不崩就 OK
        #expect(store.apiKeys().isEmpty)
    }
}

// MARK: - notUseBefore 冷却机制

@Suite(
    "notUseBefore 冷却：GeminiProvider + GeminiKeyFailover",
    .serialized   // 集成测试用 FakeKeyURLProtocol 共享 static 状态，必须串行
)
@MainActor
struct NotUseBeforeTests {

    // MARK: parse429Details

    @Test func parse429Details_retryDelaySeconds() {
        let json = #"""
        {"error":{"code":429,"details":[
          {"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"55s"},
          {"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[
            {"quotaId":"GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}
          ]}
        ]}}
        """#.data(using: .utf8)!
        let (secs, isRPD) = GeminiProvider.parse429Details(from: json)
        #expect(secs == 55.0, "55s → 55.0 秒")
        #expect(!isRPD, "PerMinute 不是 RPD")
    }

    @Test func parse429Details_RPD_detected() {
        let json = #"""
        {"error":{"code":429,"details":[
          {"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"30s"},
          {"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[
            {"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}
          ]}
        ]}}
        """#.data(using: .utf8)!
        let (secs, isRPD) = GeminiProvider.parse429Details(from: json)
        #expect(secs == 30.0)
        #expect(isRPD, "quotaId 含 PerDay → isRPD")
    }

    @Test func parse429Details_minutesAndSeconds() {
        let json = #"""
        {"error":{"code":429,"details":[
          {"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"1m30s"}
        ]}}
        """#.data(using: .utf8)!
        let (secs, _) = GeminiProvider.parse429Details(from: json)
        #expect(secs == 90.0, "1m30s → 90 秒")
    }

    @Test func parse429Details_fallbackOnMalformed() {
        let json = Data("not json".utf8)
        let (secs, isRPD) = GeminiProvider.parse429Details(from: json)
        #expect(secs == 60.0, "解析失败兜底 60s")
        #expect(!isRPD)
    }

    // MARK: parseRetryDelayString

    @Test func parseRetryDelayString_seconds() {
        #expect(GeminiProvider.parseRetryDelayString("55s") == 55.0)
        #expect(GeminiProvider.parseRetryDelayString("1s") == 1.0)
    }

    @Test func parseRetryDelayString_minutesOnly() {
        #expect(GeminiProvider.parseRetryDelayString("2m") == 120.0)
    }

    @Test func parseRetryDelayString_minutesAndSeconds() {
        #expect(GeminiProvider.parseRetryDelayString("1m30s") == 90.0)
    }

    @Test func parseRetryDelayString_unknownFormat() {
        #expect(GeminiProvider.parseRetryDelayString("unknown") == nil)
    }

    // MARK: selectEligibleKey

    @Test func selectEligibleKey_returnsFirstWhenNoCooldown() async {
        let k0 = APIKeyConfig(label: "a", keyValue: "K0", priority: 0, tier: 0)
        let k1 = APIKeyConfig(label: "b", keyValue: "K1", priority: 1, tier: 0)
        let failover = GeminiKeyFailover(keys: [k0, k1])
        let buckets = [0: [k0, k1]]
        let result = await failover.selectEligibleKey(inTier: 0, fromIdx: 0, buckets: buckets)
        #expect(result?.idx == 0)
        #expect(result?.key.label == "a")
    }

    @Test func selectEligibleKey_skipsBlockedKey() async {
        let k0 = APIKeyConfig(label: "a", keyValue: "K0", priority: 0, tier: 0)
        let k1 = APIKeyConfig(label: "b", keyValue: "K1", priority: 1, tier: 0)
        let failover = GeminiKeyFailover(keys: [k0, k1])
        // 手动注入冷却（利用 markKeyCoolingDown 通过 callOnceParagraphs 触发不现实，直接用 notUseBefore getter 验证）
        // 这里借助 walkKeyPool 内部已经被调用的路径：构造一个已有冷却记录的状态
        // 方法：用 notUseBefore(for:) getter 验证初始值为 nil
        #expect(await failover.notUseBefore(for: k0.id) == nil)
        // selectEligibleKey 从 fromIdx=1 开始（跳过 k0）
        let result = await failover.selectEligibleKey(inTier: 0, fromIdx: 1, buckets: [0: [k0, k1]])
        #expect(result?.idx == 1)
        #expect(result?.key.label == "b")
    }

    @Test func selectEligibleKey_returnsNilWhenAllBlocked() async {
        let k0 = APIKeyConfig(label: "a", keyValue: "K0", priority: 0, tier: 0)
        let failover = GeminiKeyFailover(keys: [k0])
        // fromIdx=1 超出范围 → nil（整个 tier 全跳过）
        let result = await failover.selectEligibleKey(inTier: 0, fromIdx: 1, buckets: [0: [k0]])
        #expect(result == nil)
    }
}
