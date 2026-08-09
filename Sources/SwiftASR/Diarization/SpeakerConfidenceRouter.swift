import Foundation

/// The complete routing contract is persisted with a routing snapshot.  This
/// prevents a future policy change from silently changing a reversible
/// profile-split replay for an already-finished job.
public struct SpeakerTemporalPolicy: Sendable, Equatable, Codable {
    /// Score threshold for the per-utt L1 "no usable evidence" branch.
    /// Below this score a token is treated as truly silent (e.g. "啊" at
    /// 0.38) and never contributes to per-sentence voting.
    public var otherMaximumScore: Float = 0.40
    public var acceptedMinimumScore: Float = 0.45
    /// Only sufficiently separated evidence is allowed to bypass the
    /// temporal decoder.  Everything below this threshold is defer input.
    public var acceptedMinimumMargin: Float = 0.08

    // Clustering-stage controls. These are unrelated to temporal defer.
    public var enableSentinelIsolation: Bool = true
    public var enableTripleTrackMerge: Bool = true

    public var acousticDegradedThreshold: Float = 0.42
    public var sentinelInterjectionThreshold: Float = 0.40

    // MARK: - L1 per-sentence voting (2026-07-25 refactor)
    //
    // L1 is now a per-sentence router, not per-token.  For each ASR sentence
    // we count per-utt top-label votes (over tokens with usable evidence)
    // and decide the sentence status from a single two-bucket rule:
    //
    //   strong majority (voteWinner non-nil AND totalVotes >= sentenceMinimumVotes
    //                    AND avgVoterMargin >= sentenceMinimumVoterMargin
    //                    AND topRatio >= sentenceDirectRatio)  →  .direct(winnerLabel)
    //   otherwise                                                 →  .pending
    //
    // Per-token state is derived from the sentence-level decision:
    //
    //   .direct(Sx)  →  every token in the sentence is .accepted(Sx, .direct, …)
    //   .pending     →  every token is .deferred(.insufficientSentenceEvidence, …)
    //                   so L2 can still flip the per-utt winner
    //
    // L1 itself never produces a sub-sentence `.other`; that only emerges
    // from L2's zero-evidence rescue (2026-07-26 audit fix), which keeps
    // the `Other → Speaker/fp_system_speaker` contract intact.
    /// Top-label vote share required for a sentence to be marked .direct.
    /// User-picked 2026-07-25 ("balanced 60%"); the prior L2 threshold (80%)
    /// was too strict and let too many correct turns fall into .defer.
    public var sentenceDirectRatio: Float = 0.60
    /// Minimum number of tokens with usable per-utt evidence for a
    /// sentence to participate in voting.  Below this the sentence is
    /// forced to .pending.
    public var sentenceMinimumVotes: Int = 1
    /// Minimum average per-utt margin required for direct sentence
    /// acceptance. A sub-sentence below this threshold stays pending
    /// and may enter boundary exclusion unless its raw top-label share
    /// is protected by `boundaryExclusionRawTopRatioProtection`.
    public var sentenceMinimumVoterMargin: Float = 0.10
    /// A weak-margin sub-sentence with an overwhelming raw per-utt majority
    /// is still positive acoustic evidence, not a boundary contradiction.
    /// Boundary exclusion must not remove its raw winner at or above 80%.
    public static let boundaryExclusionRawTopRatioProtection: Float = 0.80

    // MARK: - L2 acoustic-pause sub-sentence split (2026-07-26)
    //
    // Bridges the "ASR/标点模型漏打标点" gap: when a real turn break
    // exists but no terminal punctuation was inserted, the sub-sentence
    // that L1 left in `.pending` may contain a large internal pause
    // (a speaker switch the ASR/标点 模型 collapsed).  L2's pause-split
    // rescue treats a >=800ms timestamp interval as only a candidate.
    // It must also contain an independently-confirmed low-energy audio
    // run before L2 may split the sub; CIF's token duration alone can
    // absorb non-silent alignment uncertainty. Threshold 800ms matches the
    // user's 2026-07-26 calibration against the 01:40:13 ADHD2 case
    // ("你快告诉我 / 技术差吗？" — the "我" token's 1100ms duration
    // contains a real turn break the ASR/标点 模型 failed to punctuate).
    public var pauseSplitMs: Int = 800
    /// Minimum contiguous low-energy audio required to confirm a
    /// timestamp-derived pause candidate. This is intentionally lower than
    /// `pauseSplitMs`: the latter selects suspiciously stretched CIF timing;
    /// this value proves an actual silent boundary exists within it.
    public var pauseSplitMinimumSilenceMs: Int = 200

    public static let production = SpeakerTemporalPolicy()

    /// 2026-07-26 P2 F6.4: 所有 production caller 都只走 .production
    /// 单例（grep -r 'SpeakerTemporalPolicy(' 全仓只有 .production
    /// 这一处构造），11 个字段没有任何 caller override。`production`
    /// 是唯一外部可见的入口；任何自定义 policy 都得新增一个具名
    /// case / static，而不是偷偷覆盖某个 var。
    private init() {}
}

/// Per-token source label.  After the 2026-07-26 Viterbi / DecisionTree
/// removal only `.direct` is reachable: L1 commits a sub to `.direct` on a
/// strong per-utt majority, and L2's rescue chain (pause-split + boundary
/// rule + per-utt majority + mean-score fallback) commits the same way.
/// `.other` does not carry a `DecisionSource`; the token disposition is
/// `.other(reason:)` directly.
enum DecisionSource: String, Sendable {
    case direct
}

enum OtherReason: String, Sendable { case noEvidence }
enum DeferredReason: String, Sendable {
    case competingProfiles
    case insufficientEvidence
    case insufficientSentenceEvidence
}
enum UnresolvedReason: String, Sendable { case noEvidence }

/// Per-token routing status.  In the 2026-07-25 refactor the disposition
/// is **derived from the sentence-level decision**, not the other way
/// around.  `SentenceConfidenceRouter` first decides per-sentence, then
/// emits this disposition for each token inside the sentence.
enum TokenDisposition: Sendable {
    case accepted(label: Int, source: DecisionSource, confidence: Float)
    case other(reason: OtherReason, confidence: Float)
    case deferred(reason: DeferredReason, candidates: [Int])
    case unresolved(reason: UnresolvedReason)
}

/// Per-sentence classification produced by L1 (and refined by L2).
///
/// 2026-07-25 (sub-sentence phase): a SentenceDecision now carries a
/// list of `SubSentenceDecision` — one per sub-sentence split by
/// terminal punctuation (，。？！；：).  Each sub-sentence is voted
/// independently, then a "boundary exclusion" rule applies
/// (see `applyBoundaryExclusion` for details).  The sentence-level
/// `status` / `label` is the **most conservative roll-up** of its
/// sub-sentences:
///   - any sub-sentence .other → sentence .other
///   - else any sub-sentence .pending → sentence .pending
///   - else all sub-sentence .direct(Sx) → sentence .direct(Sx)
///     (all sub-sentences must agree on the same label).
/// The per-token disposition still follows the sentence-level status,
/// matching the "token 跟着 sentence 走" rule.
///
/// 2026-07-26 audit cleanup: removed the legacy `weightedScore` field
/// (the 2026-07-25 weighted-vote L2 was superseded by the
/// boundary-exclusion + per-utt majority + mean-score rescue chain).
struct SentenceDecision: Sendable {
    let sentenceID: Int
    let status: SentenceStatus
    let label: Int?
    /// Per-label count of per-utt top-label votes across all sub-sentences
    /// (tokens with usable evidence only).  Aggregate of the
    /// sub-sentence vote tallies.
    let voteCount: [Int: Int]
    let totalVotes: Int
    let topRatio: Float
    let voteWinner: Int?
    /// R4-P2-13：原命名 `maxPerTokenScore` 误导——它的值来自
    /// `agg.maxTopRatio`（0..1 区间的 ratio，不是 raw score）。L2 把它当
    /// fallback confidence 用，名字应反映语义。
    let maxSubTopRatio: Float
    let avgVoterMargin: Float
    /// Per-sub-sentence classification, in source order.  Empty for
    /// sentences that contained no terminal punctuation (and so were
    /// treated as a single sub-sentence).
    let subSentences: [SubSentenceDecision]
}

/// Per-sub-sentence classification produced by L1.
struct SubSentenceDecision: Sendable {
    /// Inclusive token index in `timeline.tokens` (or equivalently,
    /// the offset into the parent `SentenceDecision`'s tokenIndices).
    let startTokenIndex: Int
    /// Exclusive token index (so `tokens[start..<end]` covers the
    /// sub-sentence).
    let endTokenIndex: Int
    let status: SentenceStatus
    let label: Int?
    let voteCount: [Int: Int]
    let totalVotes: Int
    let topRatio: Float
    let voteWinner: Int?
    /// Average per-utt margin across voting tokens.  Used by the
    /// roll-up aggregation; not surfaced to DT / L2 individually.
    let avgVoterMargin: Float
    /// Labels excluded from the candidate set by the boundary-exclusion
    /// rule (e.g. because the left / right sub-sentences are committed
    /// to that label and this sub-sentence's punctuation breaks the
    /// turn).  Empty when no boundary rule fired.
    let excludedLabels: [Int]
}

enum SentenceStatus: String, Sendable, CustomStringConvertible {
    /// L1 / L2 commit the sentence to `label`; all tokens in the sentence
    /// are .accepted(label, …) and become a hard speaker anchor.
    case direct
    /// No per-sentence majority; per-token disposition is .deferred and
    /// L2 (or DT) may still promote the sentence to .direct.
    case pending
    /// The sub-sentence has no usable evidence at all (e.g. L2's
    /// zero-evidence rescue path kept the sub as `.other` because the
    /// mean-score fallback had no finite candidate).  All tokens
    /// become .other and `UtteranceBuilder` renders the span as a
    /// `Speaker` sentinel with `fingerprintId = fp_system_speaker`.
    case other

    var description: String {
        switch self {
        case .direct: return "direct"
        case .pending: return "pending"
        case .other: return "other"
        }
    }
}

struct SpeakerRoutingResult: Sendable {
    let decisions: [TokenDecision]
    let sentenceDecisions: [SentenceDecision]
}

struct TokenDecision: Sendable {
    let tokenID: TokenTimeline.TokenID
    let disposition: TokenDisposition

    var knownLabel: Int? {
        if case let .accepted(label, _, _) = disposition { return label }
        return nil
    }

}

/// L1 in the 2026-07-25 refactor: per-sentence classification.
///
/// For each ASR sentence we count per-utt top-label votes among the
/// tokens that have usable per-utt evidence.  The strong-majority
/// rule decides the sentence's `SentenceStatus`:
///
/// * voteWinner non-nil AND totalVotes >= sentenceMinimumVotes
///   AND avgVoterMargin >= sentenceMinimumVoterMargin
///   AND topRatio >= sentenceDirectRatio  →  `.direct(winnerLabel)`
/// * otherwise  →  `.pending` (L2 owns the rescue chain)
///
/// Once a sentence is classified, every token inside it is stamped with
/// a `TokenDisposition` that **follows the sentence** (label and source
/// are uniform across the sentence).  Per-utt scores are still per-token
/// — they live in `evidence` and are visible to L2 — but
/// the routing decision is sentence-level.  This matches the user
/// direction "token 的 direct/defer S0/S1 是跟着 sentence 走的,
/// score 是自己的".  L1 never emits `.other` at the sub-sentence
/// level; `.other` only emerges from L2's zero-evidence rescue.
///
/// L1 deliberately produces **no** `run support` / `minimumDirectSupportWindows`
/// style hard-anchor set.  Sentence-level `.direct` already implies "every
/// token in this sentence is a hard anchor".
struct SpeakerConfidenceRouter: Sendable {
    let policy: SpeakerTemporalPolicy

    init(policy: SpeakerTemporalPolicy = .production) {
        self.policy = policy
    }

    /// Single-token helper retained for diagnostic tests that want to
    /// inspect the per-utt classification rule in isolation.  Not used
    /// by the production pipeline; the production path always goes
    /// through the per-sentence `route(timeline:evidence:)` method.
    func route(_ evidence: SpeakerEvidenceTimeline.TokenEvidence) -> TokenDisposition {
        guard evidence.supportFrames > 0, let topLabel = evidence.topLabel else {
            return .deferred(reason: .insufficientEvidence, candidates: [])
        }
        let topScore = evidence.topScore
        if topScore < policy.otherMaximumScore {
            let candidates = Array(evidence.ranked.prefix(3).map(\.label))
            return .deferred(reason: .insufficientEvidence, candidates: candidates)
        }
        if topScore >= policy.acceptedMinimumScore,
           evidence.margin >= policy.acceptedMinimumMargin {
            return .accepted(label: topLabel, source: .direct, confidence: topScore)
        }
        let candidates = Array(evidence.ranked.prefix(3).map(\.label))
        return .deferred(
            reason: candidates.count >= 2 ? .competingProfiles : .insufficientEvidence,
            candidates: candidates
        )
    }

    func route(
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        tokenIndicesBySentence: [Int: [Int]]? = nil
    ) -> SpeakerRoutingResult {
        // 1. Group token indices by sentenceID.  The caller can pass a
        // precomputed map to share with downstream stages (L2) — when
        // nil we build it once here, which is the only call site for
        // tests / one-off users.
        let sentenceTokenMap: [Int: [Int]] = tokenIndicesBySentence
            ?? timeline.tokenIndicesBySentence()

        // 2. Per-sentence vote + per-token disposition.  The per-token
        //    decision is *derived* from the sentence-level outcome, so
        //    every token in a .direct sentence carries the same label
        //    and source — matching the "token follows sentence" rule.
        var decisions = Array(
            repeating: TokenDecision(
                tokenID: timeline.tokens.first?.id ?? TokenTimeline.TokenID(sentenceIndex: 0, tokenIndex: 0),
                disposition: .unresolved(reason: .noEvidence)
            ),
            count: timeline.tokens.count
        )
        var sentenceDecisions: [SentenceDecision] = []

        let sortedSentenceIDs = sentenceTokenMap.keys.sorted()
        for sentenceID in sortedSentenceIDs {
            guard let tokenIndices = sentenceTokenMap[sentenceID] else { continue }
            let sentenceDecision = processSentence(
                sentenceID: sentenceID,
                tokenIndices: tokenIndices,
                timeline: timeline,
                evidence: evidence,
                prevSentence: sentenceDecisions.last
            )
            sentenceDecisions.append(sentenceDecision)

            // Project the **sub-sentence** decision onto every token in
            // the sub-sentence.  The sub-sentence is the authoritative
            // unit of routing now: per 2026-07-25 user direction, a
            // terminal-punctuation boundary inside an ASR sentence
            // may flip the label mid-sentence, and the L1 / L2 layers
            // see sub-sentences, not whole ASR sentences.  per-utt
            // confidence is preserved per token.
            for sub in sentenceDecision.subSentences {
                for offset in sub.startTokenIndex..<sub.endTokenIndex {
                    let idx = tokenIndices[offset]
                    let token = timeline.tokens[idx]
                    let confidence = evidence.tokenEvidence[token.id]?.topScore ?? sentenceDecision.maxSubTopRatio
                    let disposition = tokenDisposition(for: sub, perTokenTopScore: confidence)
                    decisions[idx] = TokenDecision(tokenID: token.id, disposition: disposition)
                }
            }
        }

        return SpeakerRoutingResult(
            decisions: decisions,
            sentenceDecisions: sentenceDecisions
        )
    }

    // MARK: - Sentence-level classification

    private func processSentence(
        sentenceID: Int,
        tokenIndices: [Int],
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        prevSentence: SentenceDecision?
    ) -> SentenceDecision {
        var subSentences = classifySubSentences(
            tokenIndices: tokenIndices,
            timeline: timeline,
            evidence: evidence
        )
        applyBoundaryExclusion(
            to: &subSentences,
            tokenIndices: tokenIndices,
            timeline: timeline,
            evidence: evidence,
            prevSentence: prevSentence
        )
        let aggregated = rollUpSubSentences(subSentences: subSentences)
        return SentenceDecision(
            sentenceID: sentenceID,
            status: aggregated.status,
            label: aggregated.label,
            voteCount: aggregated.voteCount,
            totalVotes: aggregated.totalVotes,
            topRatio: aggregated.topRatio,
            voteWinner: aggregated.voteWinner,
            maxSubTopRatio: aggregated.maxSubTopRatio,
            avgVoterMargin: aggregated.avgVoterMargin,
            subSentences: subSentences
        )
    }

    private func classifySubSentences(
        tokenIndices: [Int],
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline
    ) -> [SubSentenceDecision] {
        splitSubSentences(tokenIndices: tokenIndices, timeline: timeline).map { split in
            voteSubSentence(
                startTokenIndex: split.lowerBound,
                endTokenIndex: split.upperBound,
                tokenIndices: tokenIndices,
                timeline: timeline,
                evidence: evidence,
                excludedLabels: []
            )
        }
    }

    private func applyBoundaryExclusion(
        to subSentences: inout [SubSentenceDecision],
        tokenIndices: [Int],
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        prevSentence: SentenceDecision?
    ) {
        for n in subSentences.indices {
            let sub = subSentences[n]
            guard sub.avgVoterMargin < policy.sentenceMinimumVoterMargin,
                  sub.topRatio < SpeakerTemporalPolicy.boundaryExclusionRawTopRatioProtection
            else { continue }

            let leftLabel: Int?
            if n > 0 {
                let left = subSentences[n - 1]
                leftLabel = left.status == .direct ? left.label : nil
            } else if let previous = prevSentence?.subSentences.last,
                      previous.status == .direct {
                leftLabel = previous.label
            } else {
                leftLabel = nil
            }
            let rightLabel: Int? = {
                guard n + 1 < subSentences.count else { return nil }
                let right = subSentences[n + 1]
                return right.status == .direct ? right.label : nil
            }()
            let excluded = diarizationBoundaryExcludedLabels(leftLabel: leftLabel, rightLabel: rightLabel)
            guard !excluded.isEmpty else { continue }
            subSentences[n] = voteSubSentence(
                startTokenIndex: sub.startTokenIndex,
                endTokenIndex: sub.endTokenIndex,
                tokenIndices: tokenIndices,
                timeline: timeline,
                evidence: evidence,
                excludedLabels: excluded
            )
        }
    }

    /// Per-sub-sentence vote.  Tokens without usable per-utt evidence
    /// (supportFrames == 0 or topScore < otherMaximumScore) are
    /// excluded from the denominator — the same rule used at the
    /// sentence level.
    private func voteSubSentence(
        startTokenIndex: Int,
        endTokenIndex: Int,
        tokenIndices: [Int],
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        excludedLabels: [Int]
    ) -> SubSentenceDecision {
        var voteCount: [Int: Int] = [:]
        var totalVotes = 0
        var voterMarginSum: Float = 0
        for offset in startTokenIndex..<endTokenIndex {
            let idx = tokenIndices[offset]
            let token = timeline.tokens[idx]
            // 2026-07-25 (third revision): every token with usable
            // per-utt evidence (topScore >= otherMaximumScore) counts
            // as a voter, regardless of margin strength.  The earlier
            // "margin >= 0.10" filter was wrong: it made a 4-token
            // weak-margin sub-utterance ("我也不喜" per-utt margin
            // 0.03) drop to 0 voters → .pending → L2-only override.
            // But the correct behavior is for all 4 tokens to vote
            // S1 (per-utt topLabel=S1), giving the sub-sentence
            // 80% S1 majority → direct S1, which the boundary rule
            // then defends against a same-label neighbour by
            // excluding S0 (the surrounding speakers' label) and
            // re-voting to keep S1.  Removing the filter restores
            // the user's original "per-utt majority" intent.
            guard let item = evidence.tokenEvidence[token.id],
                  item.supportFrames > 0,
                  item.topScore.isFinite,
                  item.topScore >= policy.otherMaximumScore,
                  let topLabel = item.topLabel,
                  !excludedLabels.contains(topLabel) else { continue }
            voteCount[topLabel, default: 0] += 1
            totalVotes += 1
            if item.margin.isFinite {
                voterMarginSum += item.margin
            }
        }
        let voteWinner = voteCount.max(by: { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        })?.key
        let topRatio: Float = (totalVotes > 0 && voteWinner != nil)
            ? Float(voteCount[voteWinner!] ?? 0) / Float(totalVotes)
            : 0
        let avgVoterMargin: Float = totalVotes > 0 ? voterMarginSum / Float(totalVotes) : 0
        // 2026-07-25 (fourth revision): L1 commits to .direct when
        // the per-utt majority is **strong** (avgVoterMargin >=
        // sentenceMinimumVoterMargin AND topRatio >=
        // sentenceDirectRatio).  Otherwise the sub-sentence is
        // .pending and L2 owns the decision: weak-majority sub-
        // sentences get the boundary-exclusion rule; the per-utt
        // tally is recorded as L2 metadata (voteWinner, voteCount,
        // topRatio, avgVoterMargin).
        let status: SentenceStatus
        let label: Int?
        if let winner = voteWinner,
           totalVotes >= policy.sentenceMinimumVotes,
           avgVoterMargin >= policy.sentenceMinimumVoterMargin,
           topRatio >= policy.sentenceDirectRatio {
            status = .direct
            label = winner
        } else {
            status = .pending
            label = voteWinner
        }
        return SubSentenceDecision(
            startTokenIndex: startTokenIndex,
            endTokenIndex: endTokenIndex,
            status: status,
            label: label,
            voteCount: voteCount,
            totalVotes: totalVotes,
            topRatio: topRatio,
            voteWinner: voteWinner,
            avgVoterMargin: avgVoterMargin,
            excludedLabels: excludedLabels
        )
    }

    // 2026-08-05 (R4-P1-2): boundary 排除规则（原 `boundaryExcludedLabels`
    // 实例方法）已合并到模块级 free function `diarizationBoundaryExcludedLabels`
    // 与 L2 (`SentenceAcceptanceL2Evaluator`) 共享，规则见该函数 doc。

    /// Sentence-level roll-up of sub-sentence decisions.
    ///
    /// 2026-07-26: this method is now a thin wrapper over
    /// `SubSentenceAggregator.rollUp` plus a per-sub
    /// avgVoterMargin aggregation.  The status rollup + voteCount
    /// aggregation logic now lives in one place (L2 uses the same
    /// helper).  The L1-specific piece is the avgVoterMargin
    /// weighting by per-sub `totalVotes`, which is preserved here.
    private struct AggregatedSentence {
        let status: SentenceStatus
        let label: Int?
        let voteCount: [Int: Int]
        let totalVotes: Int
        let topRatio: Float
        let voteWinner: Int?
        let maxSubTopRatio: Float
        let avgVoterMargin: Float
    }

    private func rollUpSubSentences(
        subSentences: [SubSentenceDecision]
    ) -> AggregatedSentence {
        // Per-sub avgVoterMargin weighted by per-sub totalVotes.  This
        // is the L1-specific bit that L2 doesn't need (L2 always
        // emits .direct after its rescue, so the metric is no longer
        // meaningful there).
        var voterMarginSum: Float = 0
        var voterCount: Int = 0
        for sub in subSentences where sub.topRatio > 0 {
            voterMarginSum += sub.avgVoterMargin * Float(sub.totalVotes)
            voterCount += sub.totalVotes
        }
        let avgVoterMargin: Float = voterCount > 0 ? voterMarginSum / Float(voterCount) : 0

        let agg = SubSentenceAggregator.rollUp(subSentences)
        return AggregatedSentence(
            status: agg.status,
            label: agg.label,
            voteCount: agg.voteCount,
            totalVotes: agg.totalVotes,
            topRatio: agg.topRatio,
            voteWinner: agg.voteWinner,
            maxSubTopRatio: agg.maxTopRatio,
            avgVoterMargin: avgVoterMargin
        )
    }

    /// Split a sentence's `[Int]` token-index list into sub-sentence
    /// spans by terminal punctuation on the source token text.
    /// Per 2026-07-25 user direction, the **punctuation token itself
    /// belongs to the *next* sub-sentence**, not the previous one.
    /// This matches the actual conversational turn boundary: a
    /// sub-sentence ends with spoken content, the punctuation
    /// punctuation attaches to whatever the speaker says **next**,
    /// and the boundary-exclusion rule can then correctly
    /// distinguish "我也不喜" (S1) from "欢，太吓人了。" (S0) in the
    /// 5min case 2 sentence "我也不喜欢，太吓人了。".
    private func splitSubSentences(
        tokenIndices: [Int],
        timeline: TokenTimeline
    ) -> [Range<Int>] {
        guard !tokenIndices.isEmpty else { return [] }
        var splits: [Range<Int>] = []
        var start = 0
        for offset in 0..<tokenIndices.count {
            let idx = tokenIndices[offset]
            let token = timeline.tokens[idx]
            // Punctuation belongs at the END of the current
            // sub-sentence, not the START of the next.  Per
            // 2026-07-25 user direction: "欢，" should be grouped
            // with "我也不喜" as "我不喜欢，" — the 5-token
            // ADHD sub-utterance — so the punctuation-attached
            // token counts toward the speaker who just spoke, not
            // the speaker who is about to speak.  This is the
            // opposite of the earlier "punctuation-with-next" split
            // which was wrong for Case 2.
            if hasTerminalPunctuation(token.text), offset > start, offset + 1 < tokenIndices.count {
                splits.append(start..<(offset + 1))
                start = offset + 1
            }
        }
        if start < tokenIndices.count {
            splits.append(start..<tokenIndices.count)
        }
        return splits
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        text.last.map { "，。？！、；：,.?!;:".contains($0) } ?? false
    }

    /// Map a `SubSentenceDecision` onto a per-token `TokenDisposition`.
    /// All tokens in the sub-sentence share the same status + label,
    /// but each keeps its own per-utt confidence so downstream stages
    /// can still see how strong the per-token evidence is.  This is
    /// the **authoritative** projection: every other layer (L2)
    /// sees the per-token dispositions derived from sub-sentences,
    /// not from the parent ASR sentence.
    private func tokenDisposition(
        for sub: SubSentenceDecision,
        perTokenTopScore: Float
    ) -> TokenDisposition {
        switch sub.status {
        case .direct:
            let label = sub.label ?? 0
            let confidence = perTokenTopScore.isFinite
                ? perTokenTopScore
                : sub.topRatio
            return .accepted(label: label, source: .direct, confidence: confidence)
        case .pending:
            let candidates = Array(sub.voteCount.keys.sorted {
                (sub.voteCount[$0] ?? 0) > (sub.voteCount[$1] ?? 0)
            }.prefix(3))
            return .deferred(
                reason: .insufficientSentenceEvidence,
                candidates: candidates.isEmpty ? (sub.voteWinner.map { [$0] } ?? []) : candidates
            )
        case .other:
            return .other(reason: .noEvidence, confidence: perTokenTopScore)
        }
    }
}
