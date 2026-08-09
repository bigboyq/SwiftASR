import Testing
import Foundation
@testable import SwiftASR

// MARK: - Bug fix 2026-07-13 整体重构: 跑润色按段扫描, 失败 throw
//
// 之前 Step 1/2 (commit 87117d7/2a2d67a/acab39a) 多步 fallback/refill 流程
// 太复杂. 改统一为:
//   1. 扫空段 → 切 chunk → 跑循环
//   2. Gemini 调用成功 + 单段空 → ⚠️原文 + wasLLMFailure=true
//   3. Gemini 调用成功 + 连续空 (>=2 段连续) → throw consecutiveEmptyParagraphs
//      (LLM 输出质量差, 用户重跑)
//   4. 进度: "已润色 para/总 para" 不是 "5/6 chunks"

@Suite("Cleanup alignment + verification (Bug fix 2026-07-12 + 2026-07-13)")
struct CleanupAlignmentTests {

    // MARK: - Bug fix 2026-07-13: 连续空 (consecutiveEmptyParagraphs) error

    @Test func consecutiveEmptyParagraphs_errorDescriptionMentionsConsecutive() {
        let error = GeminiParagraphAlignmentError.consecutiveEmptyParagraphs(indexes: [3, 4, 5])
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("连续"), "description 应包含 '连续'")
        #expect(desc.contains("3"), "description 应包含段数 3")
    }

    // MARK: - Bug fix 2026-07-13: LLMCleanupService.hasConsecutiveEmpty 静态辅助

    @Test func hasConsecutiveEmpty_noEmptyIndexes_returnsFalse() {
        let result = LLMCleanupService.hasConsecutiveEmpty(indexes: [], minimumConsecutive: 2)
        #expect(result == false)
    }

    @Test func hasConsecutiveEmpty_singleEmpty_returnsFalse() {
        // 单段空不算连续, 应该被 caller 当作"单段空 → ⚠️原文"处理
        let result = LLMCleanupService.hasConsecutiveEmpty(indexes: [3], minimumConsecutive: 2)
        #expect(result == false)
    }

    @Test func hasConsecutiveEmpty_twoConsecutive_returnsTrue() {
        let result = LLMCleanupService.hasConsecutiveEmpty(indexes: [3, 4], minimumConsecutive: 2)
        #expect(result == true, "2 段连续应该当失败")
    }

    @Test func hasConsecutiveEmpty_threeConsecutive_returnsTrue() {
        let result = LLMCleanupService.hasConsecutiveEmpty(indexes: [3, 4, 5], minimumConsecutive: 2)
        #expect(result == true)
    }

    @Test func hasConsecutiveEmpty_twoNonConsecutive_returnsFalse() {
        // [3, 5] 中间跳过 4, 不算连续
        let result = LLMCleanupService.hasConsecutiveEmpty(indexes: [3, 5], minimumConsecutive: 2)
        #expect(result == false)
    }

    @Test func hasConsecutiveEmpty_threeWithGap_returnsTrue() {
        // [3, 4, 10] 前 2 段连续, 算连续
        let result = LLMCleanupService.hasConsecutiveEmpty(indexes: [3, 4, 10], minimumConsecutive: 2)
        #expect(result == true, "前 2 段连续, 算连续")
    }

    @Test func hasConsecutiveEmpty_customMinimumConsecutive() {
        // 4 段连续 (3,4,5,6) + minimumConsecutive=4 → 应该返回 true (刚好 4 段)
        let result = LLMCleanupService.hasConsecutiveEmpty(indexes: [3, 4, 5, 6], minimumConsecutive: 4)
        #expect(result == true, "4 段连续刚好等于 minimumConsecutive=4, 算连续")
    }

    // MARK: - 段级 cleanupCheckpoint (Bug fix 2026-07-13)

    @Test func cleanupCheckpoint_emptyPayload_returnsZeroZero() {
        // mergedResults 为空时, completed=0, total=0 (isComplete 依赖 total>0)
        let payload = ResultPayload(
            jobId: "test", audioPath: "/tmp/test.m4a",
            segments: [], speakers: [],
            mergedResults: []
        )
        let total = payload.mergedResults.count
        let completed = payload.mergedResults.filter {
            !$0.cleanedContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        }.count
        #expect(total == 0)
        #expect(completed == 0)
    }

    @Test func cleanupCheckpoint_partialCleanup_completedLessThanTotal() {
        // 段级算法: 1h 音频 266 段, 已润色 200 段, 66 段待润色
        // completed=200, total=266, isPartial=true (修复前是 "5/6 chunk" 不直观)
        var segments: [MergedResult] = []
        for i in 0..<266 {
            let isCleaned = i < 200
            segments.append(MergedResult(
                mergeId: i, startMs: i * 1000, endMs: (i + 1) * 1000,
                speakerLabel: "S1", rawContent: "raw \(i)",
                cleanedContent: isCleaned ? "cleaned \(i)" : ""
            ))
        }
        let total = segments.count
        let completed = segments.filter {
            !$0.cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        #expect(total == 266)
        #expect(completed == 200, "已润色段数 200")
    }

    // MARK: - MergedResult.wasLLMFailure 序列化 (Codable 兼容)

    @Test func mergedResult_wasLLMFailure_codableRoundTrip() throws {
        // 旧 result.json 没有 was_llm_failure 字段, 解码应默认 false (向后兼容)
        let jsonWithoutField = """
        {
          "merge_id": 1, "start_ms": 0, "end_ms": 1000,
          "speaker_label": "S1", "raw_content": "raw", "cleaned_content": "cleaned"
        }
        """.data(using: .utf8)!
        let original = try JSONDecoder().decode(MergedResult.self, from: jsonWithoutField)
        #expect(original.wasLLMFailure == false, "旧 json 没有 was_llm_failure 字段, 解码默认 false")

        // 新 json 有 was_llm_failure: 正确序列化 + 反序列化
        let mr = MergedResult(
            mergeId: 1, startMs: 0, endMs: 1000,
            speakerLabel: "S1", rawContent: "raw",
            cleanedContent: "⚠️原文填空", wasLLMFailure: true
        )
        let data = try JSONEncoder().encode(mr)
        let decoded = try JSONDecoder().decode(MergedResult.self, from: data)
        #expect(decoded.wasLLMFailure == true)
        #expect(decoded.cleanedContent == "⚠️原文填空")
    }

}
