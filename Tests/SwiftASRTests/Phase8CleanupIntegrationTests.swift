// Phase 8 集成测试：URLProtocol mock + ephemeral URLSession 模拟 Gemini endpoint。
// Mock state 由 lock 保护，suite 以 serial 方式执行，避免跨测试污染。

import Testing
import Foundation
@testable import SwiftASR

// MARK: - Phase 8 集成测试：URLProtocol mock Gemini server
//
// 不跨进程拉 Python server，改用 URLProtocol 在 Swift test 进程内
// 拦截 URLSession 请求，精准模拟 Gemini endpoint 行为。这样能验证：
// - testConnection 200 / 400 / 网络错误
// - LLMCleanupService.chunkResults 续跑（mock tier 0 的 5xx → tier 1 成功）
//   （原 cleanup(segments:) 集成测试在 LLMSegment 死代码清理时一起删了，逻辑被
//    LLMCleanupService.cleanupMergedChunk 测试覆盖）
// - LLMCleanupService.cleanupMergedChunk checkpoint 续跑

// MARK: - Mock URLProtocol

final class MockGeminiProtocol: URLProtocol {
    /// Per-test stub：handler 拿到 URLRequest 返回指定 (HTTP, Data) 序列
    /// Phase 8：URLSession 注入式 mock（每个测试自己 makeMockSession()）。
    nonisolated(unsafe) static var stub: ((URLRequest) -> (HTTPURLResponse, Data?, Error?))?
    private static let lock = NSLock()

    static func setStub(_ s: ((URLRequest) -> (HTTPURLResponse, Data?, Error?))?) {
        lock.lock()
        defer { lock.unlock() }
        stub = s
    }

    private static func currentStub() -> ((URLRequest) -> (HTTPURLResponse, Data?, Error?))? {
        lock.lock()
        defer { lock.unlock() }
        return stub
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // 全局接管：只用来 mock Gemini endpoint
        request.url?.host?.contains("generativelanguage.googleapis.com") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.currentStub() else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockGeminiProtocol", code: -1))
            return
        }
        let (response, data, error) = stub(request)
        if let error = error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 每测 setup/install stub。suite serialized，因此不会和其他 test 交叉读写。
private func setMockStub(_ s: ((URLRequest) -> (HTTPURLResponse, Data?, Error?))?) {
    MockGeminiProtocol.setStub(s)
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockGeminiProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Helpers

private func makeHttpResponse(_ status: Int, host: String = "generativelanguage.googleapis.com",
                              path: String = "/v1beta/models/gemini-flash-latest") -> HTTPURLResponse {
    let url = URL(string: "https://\(host)\(path)")!
    return HTTPURLResponse(url: url, statusCode: status,
                           httpVersion: "HTTP/1.1", headerFields: nil)!
}

private func geminiModelsSuccessBody(modelName: String = "gemini-flash-latest") -> Data {
    let json: [String: Any] = [
        "name": "models/\(modelName)",
        "displayName": modelName,
        "supportedGenerationMethods": ["generateContent"]
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func geminiParagraphBody(
    _ paragraphs: [String],
    finishReason: String = "STOP",
    splitTextIntoParts: Bool = false
) -> Data {
    let inner: [String: Any] = ["paragraphs": paragraphs]
    let innerData = try! JSONSerialization.data(withJSONObject: inner)
    let innerText = String(data: innerData, encoding: .utf8) ?? "{}"
    let textParts: [String]
    if splitTextIntoParts, innerText.count > 1 {
        let split = innerText.index(innerText.startIndex, offsetBy: innerText.count / 2)
        textParts = [String(innerText[..<split]), String(innerText[split...])]
    } else {
        textParts = [innerText]
    }
    let partsJSON = textParts
        .map { "{\"text\":\(quotedJson($0))}" }
        .joined(separator: ",")
    return Data("""
    {"candidates":[{"finishReason":"\(finishReason)","content":{"parts":[\(partsJSON)]}}]}
    """.utf8)
}

private func quotedJson(_ s: String) -> String {
    // 把 string 编码成 JSON-safe 形式（包含引号）
    let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
    return String(data: data, encoding: .utf8) ?? "\"\""
}

// MARK: - Tests

@Suite("Phase 8：Gemini HTTP 集成", .serialized)
@MainActor
struct Phase8CleanupIntegrationTests {

@Test func testConnectionReturnsOkOn200() async {
    let session = makeMockSession()

    setMockStub { req in
        #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "fake")
        #expect(req.url?.query == nil)
        return (makeHttpResponse(200), geminiModelsSuccessBody(), nil)
    }

    let (ok, message) = await GeminiProvider.testConnection(
        apiKey: "fake",
        endpoint: "https://generativelanguage.googleapis.com/v1beta",
        session: session
    )
    #expect(ok == true)
    #expect(message.contains("✅"))
    #expect(message.contains("gemini-flash-latest"))
}

@Test func testConnectionReturnsFailOn4xx() async {
    let session = makeMockSession()

    setMockStub { _ in
        (makeHttpResponse(400), Data("bad key fake-secret".utf8), nil)
    }
    let (ok, message) = await GeminiProvider.testConnection(apiKey: "fake-secret", session: session)
    #expect(ok == false)
    #expect(message.contains("❌"))
    #expect(message.contains("400"))
    #expect(!message.contains("fake-secret"))
    #expect(message.contains("<redacted>"))
}

@Test func testConnectionHandlesNetworkError() async {
    let session = makeMockSession()

    setMockStub { _ in
        (HTTPURLResponse(), nil,
         NSError(domain: "NSURLErrorDomain", code: -1001, userInfo: nil))
    }
    let (ok, message) = await GeminiProvider.testConnection(apiKey: "fake", session: session)
    #expect(ok == false)
    #expect(message.contains("网络异常"))
}

@Test func cleanupMergedChunkReturnsPersistableCheckpoint() async throws {
    let session = makeMockSession()
    let store = SettingsStore.createTestInstance()
    let key = APIKeyConfig(label: "checkpoint", keyValue: "AIzaSyCheckpoint1111", priority: 1)
    store.upsertApiKeys([key])
    let settings = SettingsStore.CleanupSettings(chunkChars: 4000, temperature: 0.0)
    let service = LLMCleanupService(settings: settings, keys: [key], session: session, settingsStore: store)

    setMockStub { _ in
        (makeHttpResponse(200), geminiParagraphBody(["已润色段落。"]), nil)
    }

    let original = [MergedResult(
        mergeId: 1, startMs: 0, endMs: 1000,
        speakerLabel: "Speaker0", rawContent: "原始段落。"
    )]
    let updated = try await service.cleanupMergedChunk(
        mergedResults: original,
        speakerNames: [:]
    )

    #expect(updated.map(\.cleanedContent) == ["已润色段落。"])
    #expect(store.apiKeys().first?.successCount == 1)
}

@Test func cleanupEmptyParagraphPersistsWarningPrefixedRawContent() async throws {
    let session = makeMockSession()
    let store = SettingsStore.createTestInstance()
    let key = APIKeyConfig(label: "fallback", keyValue: "AIzaSyFallback1111")
    let service = LLMCleanupService(
        settings: .init(temperature: 0.0),
        keys: [key],
        session: session,
        settingsStore: store
    )
    setMockStub { _ in
        (makeHttpResponse(200), geminiParagraphBody([""]), nil)
    }

    let updated = try await service.cleanupMergedChunk(
        mergedResults: [
            MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "S1",
                rawContent: "原始段落。"
            )
        ],
        speakerNames: [:]
    )

    #expect(updated.first?.cleanedContent == "⚠️原始段落。")
    #expect(updated.first?.wasLLMFailure == true)
}

@Test func cleanupUsesFixedProductionModelAndJoinsMultipleTextParts() async throws {
    let session = makeMockSession()
    let store = SettingsStore.createTestInstance()
    let key = APIKeyConfig(label: "fixed-model", keyValue: "AIzaSyFixedModel1111")
    let service = LLMCleanupService(
        settings: .init(model: "legacy-model", temperature: 0.0),
        keys: [key], session: session, settingsStore: store
    )

    setMockStub { request in
        #expect(request.url?.absoluteString.contains("/models/gemini-flash-latest:") == true)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaSyFixedModel1111")
        #expect(request.url?.query == nil)
        return (makeHttpResponse(200), geminiParagraphBody(["多段结果。"], splitTextIntoParts: true), nil)
    }

    let updated = try await service.cleanupMergedChunk(
        mergedResults: [MergedResult(mergeId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawContent: "原文。")],
        speakerNames: [:]
    )
    #expect(updated.first?.cleanedContent == "多段结果。")
    #expect(service.settings.model == SettingsStore.CleanupDefaults.model)
}

@Test func cleanupRejectsNonTerminalResponseWithoutCountingSuccess() async throws {
    let session = makeMockSession()
    let store = SettingsStore.createTestInstance()
    let key = APIKeyConfig(label: "truncated", keyValue: "AIzaSyTruncated1111")
    store.upsertApiKeys([key])
    let service = LLMCleanupService(settings: .init(temperature: 0.0), keys: [key], session: session, settingsStore: store)

    setMockStub { _ in
        (makeHttpResponse(200), geminiParagraphBody(["不完整结果"], finishReason: "MAX_TOKENS"), nil)
    }

    await #expect(throws: Error.self) {
        try await service.cleanupMergedChunk(
            mergedResults: [MergedResult(mergeId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawContent: "原文。")],
            speakerNames: [:]
        )
    }
    #expect(store.apiKeys().first?.successCount == 0)
}

@Test func cleanupRejectsCountMismatchWithoutCountingSuccess() async throws {
    let session = makeMockSession()
    let store = SettingsStore.createTestInstance()
    let key = APIKeyConfig(label: "mismatch", keyValue: "AIzaSyMismatch1111")
    store.upsertApiKeys([key])
    let service = LLMCleanupService(settings: .init(temperature: 0.0), keys: [key], session: session, settingsStore: store)

    setMockStub { _ in
        (makeHttpResponse(200), geminiParagraphBody([]), nil)
    }

    await #expect(throws: Error.self) {
        try await service.cleanupMergedChunk(
            mergedResults: [MergedResult(mergeId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawContent: "原文。")],
            speakerNames: [:]
        )
    }
    #expect(store.apiKeys().first?.successCount == 0)
}

}
