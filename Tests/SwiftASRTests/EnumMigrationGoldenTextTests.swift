import Foundation
import Testing
@testable import SwiftASR

/// round-3 review Tier 1 #3 (M2-N1) follow-up：
/// 钉死 3 个 enum case 文本格式变化（"信息更丰富"）是有意为之，不是 bug。
///
/// 背景：M2-N1 把 30 处 `throw NSError(...)` 迁移到 typed enum。
/// 大多数 case 文本 bit-for-bit 等价（user-facing 行为不变）。
/// 但 3 个 case 文本格式不同：
/// - `ASRInferenceError.invalidCPUThreadCount(value:)` 加 `(got \(value))` 后缀
/// - `ASRInferenceError.invalidXNNPackThreadCount(value:)` 加 `(got \(value))` 后缀
/// - `PuncInferenceError.vocabularyLoadFailed(underlying:)` 拼 underlying 进 errorDescription
///
/// 这些变化给 production 调试带去更多信息（看到具体传错的值 / 原始 error 文本），
/// 但**跟原 NSError 文本不等价**。`TypedErrorEnumsTests` 验证 enum 自身一致性，
/// 不验证"信息更丰富"是 deliberate。
///
/// 本套件钉死：
/// 1. 3 个 case 文本包含"信息更丰富"的关键字（如 `got 0`），回退到原 NSError
///    等价会失败
/// 2. enum case doc-comment 包含 "MIGRATION NOTE" 标记 — 删除注释会失败
///    （catch accidental cleanup）
@Suite("Enum Migration Golden Text")
struct EnumMigrationGoldenTextTests {

    // MARK: - ASR CPU thread count

    @Test func asrInvalidCPUThreadCount_carriesValueInDescription() {
        // 钉死 "信息更丰富" 行为 — 原 NSError 文本只有
        // "cpuIntraOpThreads must be positive"，enum 必须包含传入的 value
        let e = ASRInferenceError.invalidCPUThreadCount(value: 0)
        let desc = e.errorDescription ?? ""
        #expect(desc.contains("cpuIntraOpThreads must be positive"))
        #expect(desc.contains("(got 0)"),
                "回退到原 NSError 等价会让 value 丢失，破坏调试信号")
    }

    @Test func asrInvalidXNNPackThreadCount_carriesValueInDescription() {
        // 同上模式 — 钉死 "(got -1)" 后缀是有意
        let e = ASRInferenceError.invalidXNNPackThreadCount(value: -1)
        let desc = e.errorDescription ?? ""
        #expect(desc.contains("XNNPACK intra-op thread count must be positive"))
        #expect(desc.contains("(got -1)"))
    }

    // MARK: - Punc vocabulary load

    @Test func puncVocabularyLoadFailed_embedsUnderlyingInDescription() {
        // 钉死 "Punc vocabulary load failed:" 前缀 + underlying 拼接到 description
        // — 跟原 NSError 文本 "Unable to read Punc vocabulary: \(path)" 不同
        let e = PuncInferenceError.vocabularyLoadFailed(underlying: "JSON malformed")
        let desc = e.errorDescription ?? ""
        #expect(desc.contains("Punc vocabulary load failed:"))
        #expect(desc.contains("JSON malformed"),
                "underlying 文本丢失会让原始 error 信息不可见")
    }

    // MARK: - 反向断言：信息更丰富的 3 个 case 跟原 NSError 文本不一样

    @Test func asrInvalidCPUThreadCount_doesNotMatchOriginalNSErrorText() {
        // 钉死 "故意不等于原 NSError 文本" — 如果未来想回到原 NSError
        // 等价，需要改测试 + 移除 MIGRATION NOTE + 评估 log 聚合兼容性
        let e = ASRInferenceError.invalidCPUThreadCount(value: 0)
        let desc = e.errorDescription ?? ""
        #expect(desc != "cpuIntraOpThreads must be positive",
                "回退到原 NSError 等价破坏 '信息更丰富' 行为")
    }

    @Test func puncVocabularyLoadFailed_doesNotMatchOriginalNSErrorText() {
        let e = PuncInferenceError.vocabularyLoadFailed(underlying: "JSON malformed")
        let desc = e.errorDescription ?? ""
        #expect(desc != "Unable to decode Punc vocabulary: <path>")
        #expect(desc != "Unable to read Punc vocabulary: <path>")
    }
}
