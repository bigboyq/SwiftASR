import Foundation

// MARK: - Cancel 错误

/// 用户中途取消润色时抛
public struct CleanupCancelled: Error, LocalizedError {
    public var errorDescription: String? { "润色已取消" }
}

// MARK: - LLMCleanupService（chunked + cancel + sticky key）

/// Phase 4 / A4 主入口：按 chunkChars 切段 → 逐 chunk 调 GeminiKeyFailover → 拼回
/// `shouldCancel` callback 在每个 chunk 之前检查（用户点取消时抛 CleanupCancelled）
@MainActor
public final class LLMCleanupService {
    public let settings: SettingsStore.CleanupSettings
    public let failover: GeminiKeyFailover
    private let settingsStore: SettingsStore

    public init(settings: SettingsStore.CleanupSettings, keys: [APIKeyConfig],
                session: URLSession? = nil, settingsStore: SettingsStore = .shared) {
        var normalizedSettings = settings
        normalizedSettings.model = SettingsStore.CleanupDefaults.model
        self.settings = normalizedSettings
        self.settingsStore = settingsStore
        self.failover = GeminiKeyFailover(
            keys: keys,
            model: normalizedSettings.model,
            temperature: normalizedSettings.temperature,
            session: session  // nil → GeminiKeyFailover.makeSession() 内部处理
        )
    }

    /// 润色一个已切好的 paragraph chunk。调用者可以在返回后立即把结果原子写盘，
    /// 因此续跑逻辑不必等到整批完成。沿用同一个 service，故 key failover 的 sticky
    /// cursor、429/5xx 计数和成功计数语义与整批调用完全一致。
    ///
    /// Bug fix 2026-07-13 整体重构: 跑润色入口改为按段切 chunk 跑循环.
    /// 这个方法只负责单次 Gemini 调用 + 单段空 / 连续空判断:
    ///   - countMismatch: throw, 让 caller 走 cleanup 失败路径
    ///   - 单段空: 写入 ⚠️原文 + wasLLMFailure=true (caller 看到 ⚠️ 标记)
    ///   - 连续空 (>=2 段连续): throw consecutiveEmptyParagraphs, 让 caller
    ///     走 cleanup 失败路径 (LLM 输出质量差, 用户重跑更靠谱)
    public func cleanupMergedChunk(
        mergedResults: [MergedResult],
        speakerNames: [String: String],
        glossary: [String] = [],
        chunkIndex: Int = 1,
        shouldCancel: @Sendable @escaping () -> Bool = { false }
    ) async throws -> [MergedResult] {
        if shouldCancel() { throw CleanupCancelled() }
        let prompt = GeminiProvider.buildPrompt(
            mergedResults: mergedResults,
            speakerNames: speakerNames,
            glossary: glossary,
            promptText: settings.prompt
        )
        let raw = try await failover.callOnceParagraphs(prompt: prompt, chunkIndex: chunkIndex)
        if shouldCancel() { throw CleanupCancelled() }


        // 1. count mismatch: 严格 throw
        guard raw.count == mergedResults.count else {
            throw GeminiParagraphAlignmentError.countMismatch(
                original: mergedResults.count, returned: raw.count
            )
        }

        // 2. 检测空段 + 连续空
        var result = mergedResults
        var emptyIndexes: [Int] = []
        for (i, text) in raw.enumerated() {
            let label = result[i].effectiveSpeakerLabel
            let displayName = speakerNames[label] ?? label
            let trimmed = GeminiProvider.stripSpeakerPrefixPublic(
                text, displayName: displayName, speakerLabel: label
            )
            if trimmed.isEmpty {
                emptyIndexes.append(i)
            }
        }
        // 3. 连续空 (>=2 段连续) 当失败 throw
        if Self.hasConsecutiveEmpty(indexes: emptyIndexes, minimumConsecutive: 2) {
            Logger.shared.warn(
                "cleanupMergedChunk: 检测到连续空段 \(emptyIndexes), 当失败处理"
            )
            throw GeminiParagraphAlignmentError.consecutiveEmptyParagraphs(indexes: emptyIndexes)
        }

        // 4. 写回: 成功段写 cleanedContent, 单段空段写 rawContent + wasLLMFailure
        for (i, text) in raw.enumerated() {
            let label = result[i].effectiveSpeakerLabel
            let displayName = speakerNames[label] ?? label
            let trimmed = GeminiProvider.stripSpeakerPrefixPublic(
                text, displayName: displayName, speakerLabel: label
            )
            if trimmed.isEmpty {
                result[i].cleanedContent = MergedResult.llmFailureFallbackContent(
                    rawContent: result[i].rawContent
                )
                result[i].wasLLMFailure = true
            } else {
                result[i].cleanedContent = trimmed
                result[i].wasLLMFailure = false
            }
        }
        if !emptyIndexes.isEmpty {
            Logger.shared.warn(
                "cleanupMergedChunk: \(emptyIndexes.count) 段单段空, 写入 ⚠️原文 + wasLLMFailure=true"
            )
        }
        // Only count a call after its output has been accepted. A malformed
        // count or consecutive-empty response must not advance usage metrics.
        if let keyId = await failover.currentSuccessfulKeyId {
            settingsStore.recordSuccess(keyId: keyId)
        }
        return result
    }

    /// 静态辅助: 检测 indexes 中是否包含 >= minimumConsecutive 个连续 index.
    /// 例: hasConsecutiveEmpty([1, 2, 4], min: 2) = true (1,2 连续)
    ///     hasConsecutiveEmpty([1, 3], min: 2) = false (1, 3 不连续)
    ///     hasConsecutiveEmpty([1], min: 2) = false (只有 1 段, 不算连续)
    nonisolated static func hasConsecutiveEmpty(indexes: [Int], minimumConsecutive: Int) -> Bool {
        guard indexes.count >= minimumConsecutive else { return false }
        var consecutiveCount = 1
        for i in 1..<indexes.count {
            if indexes[i] == indexes[i - 1] + 1 {
                consecutiveCount += 1
                if consecutiveCount >= minimumConsecutive {
                    return true
                }
            } else {
                consecutiveCount = 1
            }
        }
        return consecutiveCount >= minimumConsecutive
    }

    /// 贪心切 chunk（MergedResult 版）：按 rawContent 长度累加。
    public static func chunkResults(_ mergedResults: [MergedResult], chunkChars: Int) -> [[MergedResult]] {
        if mergedResults.isEmpty { return [] }
        guard chunkChars > 0 else { return [mergedResults] }
        var chunks: [[MergedResult]] = []
        var cur: [MergedResult] = []
        var curLen = 0
        for mr in mergedResults {
            let mrLen = mr.effectiveSpeakerLabel.count + mr.rawContent.count + 4
            if !cur.isEmpty && curLen + mrLen > chunkChars {
                chunks.append(cur)
                cur = [mr]; curLen = mrLen
            } else {
                cur.append(mr); curLen += mrLen
            }
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }
}
