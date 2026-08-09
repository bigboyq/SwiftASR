import Foundation

/// Pure projection of the authoritative temporal token path. This layer never
/// votes, smooths, or changes speaker decisions.
///
/// Speaker turns, not ASR sentences, are the unit of grouping here.  Per
/// 2026-07-25 user direction the pipeline treats ASR / Punc as a
/// display-layer hint (it does not know about speakers) and Speaker as
/// an independently-identified per-token signal; the alignment step
/// just groups contiguous same-label tokens into one utterance, ignoring
/// the ASR sentence boundary.  This is why "我没见到他呀，我" (s=N) and
/// "周一没见到他呀，" (s=N+1) — both same speaker, both 精修-line 16 —
/// collapse into one utterance instead of being split at the
/// ASR-sentence boundary.
enum UtteranceBuilder {
    static func build(
        timeline: TokenTimeline,
        decisions: [TokenDecision]
    ) -> [UtteranceData] {
        let decisionByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.tokenID, $0) })
        var result: [UtteranceData] = []
        var currentTokens: [TokenTimeline.Token] = []
        var currentLabel: String?

        func label(for decision: TokenDecision?) -> String {
            guard let known = decision?.knownLabel else {
                return SpeakerDiarizationPipeline.sentinelLabel
            }
            return "说话人 \(known + 1)"
        }

        func flush() {
            guard let label = currentLabel, !currentTokens.isEmpty else { return }
            let text = currentTokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let startMs = currentTokens.map(\.rawRangeMs.lowerBound).min() ?? 0
                let endMs = currentTokens.map(\.rawRangeMs.upperBound).max() ?? startMs
                result.append(UtteranceData(
                    startMs: startMs,
                    endMs: max(startMs, endMs),
                    rawText: text,
                    speakerLabel: label
                ))
            }
            currentTokens = []
        }

        // Group contiguous same-label tokens into one utterance.  The
        // ASR / Punc sentence boundary is intentionally NOT used here:
        // the punctuation layer has no speaker signal and is only a
        // presentation hint, so we let the speaker's own decision drive
        // the split.  Two adjacent same-label tokens across an ASR
        // sentence boundary are still one utterance.
        //
        // 2026-07-26: iterate `timeline.tokens` directly (already
        // sorted by (rawStartMs, rawEndMs, id) in TokenTimeline.init).
        // The previous `sorted(by: { $0.id < $1.id })` was re-sorting
        // by (sentenceIndex, tokenIndex) — an order that does NOT
        // match the timeline's time order when the ASR gives intra-
        // sentence tokens out of rawStartMs order, which silently split
        // time-adjacent same-label tokens across two utterances.
        for token in timeline.tokens {
            let nextLabel = label(for: decisionByID[token.id])
            if currentLabel == nextLabel {
                currentTokens.append(token)
            } else {
                flush()
                currentTokens = [token]
                currentLabel = nextLabel
            }
        }
        flush()
        return result
    }
}
