import Foundation
import Testing
@testable import SwiftASR

/// Unit tests for `SubSentenceAggregator` and `SentenceDecision.rollUp`.
///
/// 2026-07-26 refactor: L1 (`SpeakerConfidenceRouter.rollUpSubSentences`)
/// and L2 (`SentenceAcceptanceRouter.rollUpSubSentences`) each had a
/// private rollup that shared ~80% of the implementation.  Centralising
/// in `SubSentenceAggregator` + `SentenceDecision.rollUp` makes the
/// "most-conservative" status rollup a single source of truth.
///
/// These tests pin the shared rollup contract so any future drift
/// between L1 / L2 is caught.
@Suite(.serialized)
struct SubSentenceAggregatorTests {

    private func makeSub(
        status: SentenceStatus,
        label: Int?,
        votes: [Int: Int] = [:],
        totalVotes: Int = 0,
        topRatio: Float = 0,
        voteWinner: Int? = nil,
        avgVoterMargin: Float = 0
    ) -> SubSentenceDecision {
        SubSentenceDecision(
            startTokenIndex: 0, endTokenIndex: 0,
            status: status, label: label,
            voteCount: votes, totalVotes: totalVotes,
            topRatio: topRatio, voteWinner: voteWinner,
            avgVoterMargin: avgVoterMargin,
            excludedLabels: []
        )
    }

    @Test func emptyInputYieldsOtherSentinel() {
        let agg = SubSentenceAggregator.rollUp([])
        #expect(agg.status == .other)
        #expect(agg.label == nil)
        #expect(agg.voteCount.isEmpty)
        #expect(agg.totalVotes == 0)
        #expect(agg.topRatio == 0)
        #expect(agg.voteWinner == nil)
    }

    @Test func anyOtherSubDemotesSentenceToOther() {
        let subs = [
            makeSub(status: .direct, label: 0, votes: [0: 5], totalVotes: 5, topRatio: 1.0, voteWinner: 0),
            makeSub(status: .other, label: nil),
        ]
        let agg = SubSentenceAggregator.rollUp(subs)
        #expect(agg.status == .other)
        #expect(agg.label == nil)
    }

    @Test func anyPendingSubDemotesSentenceToPending() {
        let subs = [
            makeSub(status: .direct, label: 0, votes: [0: 5], totalVotes: 5, topRatio: 1.0, voteWinner: 0),
            makeSub(status: .pending, label: 0, votes: [0: 3, 1: 2], totalVotes: 5, topRatio: 0.6, voteWinner: 0),
        ]
        let agg = SubSentenceAggregator.rollUp(subs)
        #expect(agg.status == .pending)
        #expect(agg.label == nil)
    }

    @Test func allDirectSameLabelYieldsDirectThatLabel() {
        let subs = [
            makeSub(status: .direct, label: 0, votes: [0: 3], totalVotes: 3, topRatio: 1.0, voteWinner: 0),
            makeSub(status: .direct, label: 0, votes: [0: 4], totalVotes: 4, topRatio: 1.0, voteWinner: 0),
        ]
        let agg = SubSentenceAggregator.rollUp(subs)
        #expect(agg.status == .direct)
        #expect(agg.label == 0)
    }

    @Test func allDirectDifferentLabelsDemotesToPending() {
        // When sub-sentences disagree on the label (a real turn break
        // got split, or the punctuation landed between two different
        // speakers), the sentence must NOT silently pick one.  This
        // is the safety property the most-conservative rollup
        // guarantees.
        let subs = [
            makeSub(status: .direct, label: 0, votes: [0: 3], totalVotes: 3, topRatio: 1.0, voteWinner: 0),
            makeSub(status: .direct, label: 1, votes: [1: 4], totalVotes: 4, topRatio: 1.0, voteWinner: 1),
        ]
        let agg = SubSentenceAggregator.rollUp(subs)
        #expect(agg.status == .pending)
        #expect(agg.label == nil)
    }

    @Test func voteCountsAreSummedAcrossSubs() {
        let subs = [
            makeSub(status: .direct, label: 0, votes: [0: 3, 1: 1], totalVotes: 4, topRatio: 0.75, voteWinner: 0),
            makeSub(status: .direct, label: 0, votes: [0: 2, 2: 1], totalVotes: 3, topRatio: 0.67, voteWinner: 0),
        ]
        let agg = SubSentenceAggregator.rollUp(subs)
        #expect(agg.voteCount[0] == 5)
        #expect(agg.voteCount[1] == 1)
        #expect(agg.voteCount[2] == 1)
        #expect(agg.totalVotes == 7)
        #expect(agg.voteWinner == 0)
        #expect(abs(agg.topRatio - (5.0 / 7.0)) < 0.001)
    }

    @Test func maxTopRatioIsMaxOfSubTopRatios() {
        let subs = [
            makeSub(status: .direct, label: 0, votes: [0: 3], totalVotes: 3, topRatio: 0.6, voteWinner: 0),
            makeSub(status: .direct, label: 0, votes: [0: 4], totalVotes: 4, topRatio: 0.95, voteWinner: 0),
            makeSub(status: .direct, label: 0, votes: [0: 2], totalVotes: 2, topRatio: 0.5, voteWinner: 0),
        ]
        let agg = SubSentenceAggregator.rollUp(subs)
        #expect(abs(agg.maxTopRatio - 0.95) < 0.001)
    }

    @Test func voteWinnerTieBreaksBySmallerLabel() {
        // Match L1's per-sub tiebreaker exactly: the comparator
        //   `left.value == right.value ? left.key > right.key : left.value < right.value`
        // makes the *smaller* label win on count ties (Swift's
        // `max(by:)` keeps the element that returns false on the
        // comparator, and `0 > 1 == false` makes label 0 the "max").
        // This is the tiebreaker L1 has shipped with since the
        // sub-sentence vote rollout, so the aggregator must keep it
        // bit-exact.
        let subs = [
            makeSub(status: .direct, label: 0, votes: [0: 2, 1: 2], totalVotes: 4, topRatio: 0.5, voteWinner: 0),
        ]
        let agg = SubSentenceAggregator.rollUp(subs)
        #expect(agg.voteWinner == 0)
    }

    @Test func sentenceDecisionRollUpBuilderProducesCorrectShape() {
        // Smoke test: the builder's output structure matches what L1
        // and L2 expect — sentenceID, status, label, the voteCount /
        // totalVotes / topRatio / voteWinner aggregated fields, the
        // maxSubTopRatio (renamed from maxPerTokenScore, R4-P2-13) from
        // maxTopRatio, and the caller-supplied avgVoterMargin.
        let subs = [
            makeSub(status: .direct, label: 0, votes: [0: 3], totalVotes: 3, topRatio: 1.0, voteWinner: 0, avgVoterMargin: 0.2),
            makeSub(status: .direct, label: 0, votes: [0: 4], totalVotes: 4, topRatio: 1.0, voteWinner: 0, avgVoterMargin: 0.3),
        ]
        let decision = SentenceDecision.rollUp(
            sentenceID: 42,
            subSentences: subs,
            avgVoterMargin: 0.25
        )
        #expect(decision.sentenceID == 42)
        #expect(decision.status == .direct)
        #expect(decision.label == 0)
        #expect(decision.voteCount[0] == 7)
        #expect(decision.totalVotes == 7)
        #expect(decision.topRatio == 1.0)
        #expect(decision.voteWinner == 0)
        #expect(decision.maxSubTopRatio == 1.0)
        #expect(decision.avgVoterMargin == 0.25)
        #expect(decision.subSentences.count == 2)
    }
}
