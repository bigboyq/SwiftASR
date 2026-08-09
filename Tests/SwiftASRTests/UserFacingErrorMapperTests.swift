import Testing
import Foundation
@testable import SwiftASR

/// R4-P1-6 回归：用户可见文案不直接暴露底层 localizedDescription / HTTP
/// response body / Foundation._GenericObjCError。
@Suite("User facing error mapper")
struct UserFacingErrorMapperTests {
    @Test func mapsGeminiAuthErrorsToStableChinese() {
        let unauthorized = GeminiProviderError.httpError(
            statusCode: 401, retryable: false,
            retryDelaySecs: nil, isRPD: false
        )
        let forbidden = GeminiProviderError.httpError(
            statusCode: 403, retryable: false,
            retryDelaySecs: nil, isRPD: false
        )
        let msg401 = UserFacingErrorMapper.message(for: unauthorized)
        let msg403 = UserFacingErrorMapper.message(for: forbidden)
        #expect(msg401.contains("鉴权失败"))
        #expect(msg403.contains("鉴权失败"))
        // Body 不应出现在用户文案里。
        #expect(!msg401.contains("sensitive prompt echo"))
    }

    @Test func mapsGeminiQuotaToStableChinese() {
        let rateLimit = GeminiProviderError.httpError(
            statusCode: 429, retryable: true,
            retryDelaySecs: 30.0, isRPD: true
        )
        let msg = UserFacingErrorMapper.message(for: rateLimit)
        #expect(msg.contains("限流"))
        #expect(!msg.contains("{ quota detail }"))
    }

    @Test func mapsGeminiServerOverload() {
        let overload = GeminiProviderError.httpError(
            statusCode: 503, retryable: true,
            retryDelaySecs: nil, isRPD: false
        )
        let msg = UserFacingErrorMapper.message(for: overload)
        #expect(msg.contains("暂时不可用"))
        #expect(msg.contains("503"))
        #expect(!msg.contains("internal error trace"))
    }

    @Test func mapsFailoverAllTiersExhausted() {
        let exhausted = GeminiKeyFailoverError.allTiersExhausted(
            lastFailureDescription: "Gemini 403: ..."
        )
        let msg = UserFacingErrorMapper.message(for: exhausted)
        #expect(msg.contains("均已失败"))
        // lastFailureDescription 是 debug payload，不应进用户文案。
        #expect(!msg.contains("Gemini 403"))
    }

    @Test func mapsFailoverNoEnabledKeys() {
        let msg = UserFacingErrorMapper.message(for: GeminiKeyFailoverError.noEnabledKeys)
        #expect(msg.contains("设置"))
    }

    @Test func mapsResultMissingError() {
        let missing = ResultStoreError.resultMissing(jobID: "abc", storedPath: "/secret/path.json")
        let msg = UserFacingErrorMapper.message(for: missing)
        #expect(msg.contains("不存在"))
        // 路径不应泄露到用户文案。
        #expect(!msg.contains("/secret/path.json"))
    }

    @Test func mapsGenericObjCErrorToStableMessageWithoutRawDescription() {
        // SwiftData/CoreData 保存失败常冒出 Foundation._GenericObjCError code 0。
        let generic = NSError(domain: "Foundation._GenericObjCError", code: 0)
        let msg = UserFacingErrorMapper.message(for: generic, context: .cleanupPersistence)
        #expect(msg.contains("无法保存"))
        // 原始 "The operation couldn't be completed..." 不应出现。
        #expect(!msg.contains("couldn't be completed"))
    }

    @Test func mapsCocoaNoSuchFileError() {
        let missing = CocoaError(.fileReadNoSuchFile)
        let msg = UserFacingErrorMapper.message(for: missing)
        #expect(msg.contains("不存在"))
    }

    @Test func mapsCocoaPermissionError() {
        let denied = CocoaError(.fileWriteNoPermission)
        let msg = UserFacingErrorMapper.message(for: denied)
        #expect(msg.contains("权限"))
    }

    @Test func unknownErrorReturnsStableMessageWithoutLocalizedDescription() {
        struct CustomError: Error, LocalizedError {
            var errorDescription: String? { "internal stack trace detail" }
        }
        let msg = UserFacingErrorMapper.message(for: CustomError())
        #expect(!msg.contains("internal stack trace detail"))
        #expect(!msg.isEmpty)
    }
}
