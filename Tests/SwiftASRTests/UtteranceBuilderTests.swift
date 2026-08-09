import Foundation
import Testing
@testable import SwiftASR

/// Unit tests for `UtteranceBuilder` — focused on the 2026-07-26
/// time-order fix where the previous `sorted(by: { $0.id < $1.id })`
/// was re-sorting by (sentenceIndex, tokenIndex), an order that does
/// NOT match the timeline's time order when ASR gives intra-sentence
/// tokens out of rawStartMs order.  The fix: iterate `timeline.tokens`
/// directly, which is already sorted by (rawStartMs, rawEndMs, id).
///
/// These tests build a `TokenTimeline` from a hand-rolled ASRSentence
/// with deliberately out-of-order token start times, so they exercise
/// the timeline's reorder + utterance grouping together.  If the
/// builder is ever re-broken, these tests will start producing two
/// utterances for what is a single contiguous same-label span.
@Suite(.serialized)
struct UtteranceBuilderTests {

    @Test func timeOrderGroupingBeatsIdOrderForOutOfTimeOrderASRTokens() {
        // 3 tokens within ONE ASR sentence.  Intentionally give the
        // source tokens a non-monotonic time order so the timeline's
        // init has to reorder by rawStartMs:
        //
        //   index 0 (tokenIndex=0) "甲"  startMs=0   endMs=100
        //   index 1 (tokenIndex=1) "乙"  startMs=200 endMs=300
        //   index 2 (tokenIndex=2) "丙"  startMs=100 endMs=200
        //
        // rawStartMs order is: 甲 (0) → 丙 (100) → 乙 (200)
        // tokenIndex / id order is: 甲 (0) → 乙 (1) → 丙 (2)
        // These differ.  The timeline's init must put the tokens in
        // time order so the utterance builder can group them as one
        // contiguous same-label span.
        let sentence = ASRSentence(
            text: "甲乙丙",
            startMs: 0,
            endMs: 300,
            tokens: [
                ASRToken(text: "甲", startMs: 0, endMs: 100),
                ASRToken(text: "乙", startMs: 200, endMs: 300),
                ASRToken(text: "丙", startMs: 100, endMs: 200),
            ]
        )
        let timeline = TokenTimeline(sentences: [sentence], totalFrames: 30)
        // The timeline should have re-ordered by rawStartMs: 甲 / 丙 / 乙.
        let textOrder = timeline.tokens.map(\.text).joined()
        #expect(textOrder == "甲丙乙", "timeline must order tokens by rawStartMs; got \(textOrder)")

        // All three tokens get the same label S0.  The utterance builder
        // must produce ONE utterance — not two, which is what the
        // pre-2026-07-26 ID-sort would do (甲 / 乙 / 丙 → label change
        // at "乙" would still group, but in the broken scenario the
        // iteration order can split time-adjacent spans).
        let decisions: [TokenDecision] = timeline.tokens.map { token in
            TokenDecision(
                tokenID: token.id,
                disposition: .accepted(label: 0, source: .direct, confidence: 0.7)
            )
        }
        let utterances = UtteranceBuilder.build(timeline: timeline, decisions: decisions)
        #expect(utterances.count == 1, "all-same-label contiguous tokens must collapse to one utterance; got \(utterances.count)")
        #expect(utterances[0].speakerLabel == "说话人 1")
        #expect(utterances[0].rawText == "甲丙乙")
        #expect(utterances[0].startMs == 0)
        #expect(utterances[0].endMs == 300)
    }

    @Test func interSentenceSameLabelStillCollapsesAcrossBoundary() {
        // Regression for the 2026-07-25 spec: two adjacent sentences
        // with the same speaker should collapse into one utterance,
        // ignoring the ASR sentence boundary.  This was the original
        // reason `UtteranceBuilder` is "speaker turns, not ASR
        // sentences" — the boundary is a display hint, not a turn
        // boundary.
        let s1 = ASRSentence(
            text: "我没见到他呀，",
            startMs: 0,
            endMs: 200,
            tokens: [
                ASRToken(text: "我", startMs: 0, endMs: 50),
                ASRToken(text: "没", startMs: 50, endMs: 100),
                ASRToken(text: "见", startMs: 100, endMs: 150),
                ASRToken(text: "到", startMs: 150, endMs: 175),
                ASRToken(text: "他", startMs: 175, endMs: 195),
                ASRToken(text: "呀，", startMs: 195, endMs: 200),
            ]
        )
        let s2 = ASRSentence(
            text: "周一没见到他呀，",
            startMs: 200,
            endMs: 400,
            tokens: [
                ASRToken(text: "周", startMs: 200, endMs: 230),
                ASRToken(text: "一", startMs: 230, endMs: 260),
                ASRToken(text: "没", startMs: 260, endMs: 310),
                ASRToken(text: "见", startMs: 310, endMs: 340),
                ASRToken(text: "到", startMs: 340, endMs: 365),
                ASRToken(text: "他", startMs: 365, endMs: 385),
                ASRToken(text: "呀，", startMs: 385, endMs: 400),
            ]
        )
        let timeline = TokenTimeline(sentences: [s1, s2], totalFrames: 40)
        let decisions: [TokenDecision] = timeline.tokens.map { token in
            TokenDecision(
                tokenID: token.id,
                disposition: .accepted(label: 0, source: .direct, confidence: 0.7)
            )
        }
        let utterances = UtteranceBuilder.build(timeline: timeline, decisions: decisions)
        #expect(utterances.count == 1, "two same-label sentences should collapse into one utterance; got \(utterances.count)")
        #expect(utterances[0].rawText == "我没见到他呀，周一没见到他呀，")
    }

    @Test func timeOrderSplitAtLabelChangeIsNotFragmented() {
        // 3 tokens in time order, but the MIDDLE token has a different
        // label.  Pre-fix the ID-sort (which would re-order if the
        // source ASR was out of time order) could put the middle token
        // adjacent to the wrong neighbour, splitting the wrong way.
        let sentence = ASRSentence(
            text: "甲乙丙",
            startMs: 0,
            endMs: 300,
            tokens: [
                // Source order: 甲(0-100, S0) → 乙(200-300, S0) → 丙(100-200, S1)
                // Time order: 甲 → 丙 → 乙
                ASRToken(text: "甲", startMs: 0, endMs: 100),
                ASRToken(text: "乙", startMs: 200, endMs: 300),
                ASRToken(text: "丙", startMs: 100, endMs: 200),
            ]
        )
        let timeline = TokenTimeline(sentences: [sentence], totalFrames: 30)
        // 甲 → 丙(S1) → 乙(S0): expect 3 utterances in time order.
        let decisionFor: (TokenTimeline.Token) -> TokenDecision = { token in
            let label = (token.text == "丙") ? 1 : 0
            return TokenDecision(
                tokenID: token.id,
                disposition: .accepted(label: label, source: .direct, confidence: 0.7)
            )
        }
        let decisions: [TokenDecision] = timeline.tokens.map(decisionFor)
        let utterances = UtteranceBuilder.build(timeline: timeline, decisions: decisions)
        #expect(utterances.count == 3)
        #expect(utterances[0].rawText == "甲")
        #expect(utterances[0].speakerLabel == "说话人 1")
        #expect(utterances[1].rawText == "丙")
        #expect(utterances[1].speakerLabel == "说话人 2")
        #expect(utterances[2].rawText == "乙")
        #expect(utterances[2].speakerLabel == "说话人 1")
    }
}
