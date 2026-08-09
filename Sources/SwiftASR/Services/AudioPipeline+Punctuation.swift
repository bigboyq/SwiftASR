import Foundation

/// 标点恢复 stage（4.5 阶段）从 `runPipelineWithProfiles` 抽出（2026-07-22）。
///
/// 逻辑跟原文件保持一致：收集 ASR tokens → 调 `PunctuationRestorationPipeline`
/// 恢复标点 → `PunctuationAlignment` 映射回 token 序列 → `SentenceProjection`
/// 切分。如果 `puncRestorer` 是 nil 或 ASR 没产生句子，直接返回原 `asrResult`。
///
/// 标点错误（模型 / 对齐失败）必须 throw `PipelineStageFailure` 让
/// `PipelineRunner` 把任务标失败 / partial，绝不能静默返回原文本（让"降级
/// 结果"看起来跟"正常结果"一样）。
extension AudioPipeline {
    /// 跑 punc stage。Instance method 以读取 `self.puncRestorer`。
    /// - Parameters:
    ///   - asrResult: 上一阶段 VAD+ASR 的输出
    ///   - onProgress: stage 进度回调
    /// - Returns: punc 跑过 → 切分后的 `ASRResult`；punc 没跑 / 跳过 → 原 `asrResult`
    /// - Throws: `PipelineStageFailure(stage: "punc")` 当模型或对齐失败
    func applyPunctuationStage(
        asrResult: ASRResult,
        onProgress: @Sendable @escaping (String, Double, String) -> Void
    ) throws -> ASRResult {
        guard let punc = puncRestorer, !asrResult.sentences.isEmpty else {
            return asrResult
        }
        onProgress("punc", 0.0, "标点恢复…")

        // 1. 收集所有 raw 状态下的 ASRTokens
        var allTokens: [ASRToken] = []
        for s in asrResult.sentences {
            allTokens.append(contentsOf: s.tokens)
        }

        let rawText = allTokens.map(\.text).joined()
        let puncText: String
        do {
            puncText = try punc.restorePunctuation(text: rawText)
        } catch is PipelineCancelled {
            throw PipelineCancelled(stage: "punc")
        } catch {
            throw PipelineStageFailure(stage: "punc", underlying: error)
        }

        // 2. 将带标点的文本映射回 ASRToken 序列
        let alignment = PunctuationAlignment.align(puncText: puncText, into: allTokens)
        let punctuatedTokens: [ASRToken]
        do {
            punctuatedTokens = try PunctuationAlignment.requireAligned(alignment)
        } catch {
            throw PipelineStageFailure(stage: "punc", underlying: error)
        }

        // 3. 按照标点和最大字数切分成 ASRSentence
        let sentenceSplit = SentenceProjection.split(punctuatedTokens)

        onProgress("punc", 1.0, "标点完成")
        return ASRResult(
            sentences: sentenceSplit,
            rawText: sentenceSplit.map { $0.text }.joined(separator: "")
        )
    }
}
