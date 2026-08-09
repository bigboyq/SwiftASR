import Foundation

/// L2 per-sub-sentence rescue on top of L1.
///
/// L1 leaves weak per-utt majorities in `.pending`. L2 applies an
/// acoustically confirmed pause split, boundary-label exclusion, per-utt
/// majority promotion, and a finite mean-score fallback. Every pending
/// sub-sentence closes as `.direct` or `.other`; L1-direct anchors are
/// passed through unchanged.
struct SentenceAcceptanceRouter: Sendable {
    let policy: SpeakerTemporalPolicy
    let acousticPauseEvidence: AcousticPauseEvidence

    init(
        policy: SpeakerTemporalPolicy = .production,
        acousticPauseEvidence: AcousticPauseEvidence = AcousticPauseEvidence(fbank80: [])
    ) {
        self.policy = policy
        self.acousticPauseEvidence = acousticPauseEvidence
    }

    struct Result: Sendable {
        /// Per-sentence decision after L2, in sentenceID order.
        let sentenceDecisions: [SentenceDecision]
        /// Per-token decision after L2, in timeline order.
        let tokenDecisions: [TokenDecision]
        /// Diagnostic records for sub-sentences considered by L2.
        let overrides: [Override]
    }

    struct Override: Sendable, Equatable {
        let sentenceID: Int
        let l1TopRatio: Float
        /// Outcome label, or nil when the zero-evidence path stays `.other`.
        let l2Winner: Int?
        /// Boundary-promotion vote share, zero for mean fallback, or the
        /// original L1 ratio for direct passthrough semantics.
        let l2Ratio: Float
        let applied: Bool
        /// Timestamp gap that triggered an acoustic pause split.
        let splitGapMs: Int?
        /// Consecutive low-energy duration that confirmed the split.
        let confirmedSilenceMs: Int?

        init(
            sentenceID: Int,
            l1TopRatio: Float,
            l2Winner: Int?,
            l2Ratio: Float,
            applied: Bool,
            splitGapMs: Int? = nil,
            confirmedSilenceMs: Int? = nil
        ) {
            self.sentenceID = sentenceID
            self.l1TopRatio = l1TopRatio
            self.l2Winner = l2Winner
            self.l2Ratio = l2Ratio
            self.applied = applied
            self.splitGapMs = splitGapMs
            self.confirmedSilenceMs = confirmedSilenceMs
        }
    }

    func route(
        timeline: TokenTimeline,
        l1: SpeakerRoutingResult,
        evidence: SpeakerEvidenceTimeline,
        tokenIndicesBySentence: [Int: [Int]]? = nil
    ) -> Result {
        let sentenceTokenMap = tokenIndicesBySentence
            ?? timeline.tokenIndicesBySentence()
        let pauseSplitter = SentenceAcceptancePauseSplitter(
            acousticEvidence: acousticPauseEvidence
        )
        let l2Evaluator = SentenceAcceptanceL2Evaluator(policy: policy)

        var tokenDecisions = l1.decisions
        var overrides: [Override] = []
        var refinedSentences: [SentenceDecision] = []

        for (sentenceIndex, sentence) in l1.sentenceDecisions.enumerated() {
            let tokenIndices = sentenceTokenMap[sentence.sentenceID] ?? []
            let originalSubs = sentence.subSentences
            let pauseSplits = pauseSplits(
                in: originalSubs,
                tokenIndices: tokenIndices,
                timeline: timeline,
                splitter: pauseSplitter
            )

            var refinedSubs: [SubSentenceDecision] = []
            for subIndex in originalSubs.indices {
                let sub = originalSubs[subIndex]
                guard sub.status == .pending else {
                    refinedSubs.append(sub)
                    continue
                }

                // The boundary context is derived from the parent's
                // neighbours, never from newly created split siblings.
                let (leftLabel, rightLabel) = computeBoundaryLabels(
                    subIndex: subIndex,
                    sentenceIndex: sentenceIndex,
                    originalSubs: originalSubs,
                    l1: l1,
                    refinedSentences: refinedSentences
                )

                if let split = pauseSplits[subIndex] {
                    let leftShell = pauseSplitter.makeShell(
                        start: sub.startTokenIndex,
                        end: split.offset,
                        parent: sub
                    )
                    let rightShell = pauseSplitter.makeShell(
                        start: split.offset,
                        end: sub.endTokenIndex,
                        parent: sub
                    )
                    append(
                        l2Evaluator.evaluate(
                            sub: leftShell,
                            leftLabel: leftLabel,
                            rightLabel: rightLabel,
                            sentence: sentence,
                            tokenIndices: tokenIndices,
                            timeline: timeline,
                            evidence: evidence,
                            splitGapMs: split.gapMs,
                            confirmedSilenceMs: split.confirmedSilenceMs
                        ),
                        to: &refinedSubs,
                        tokenDecisions: &tokenDecisions,
                        overrides: &overrides
                    )
                    append(
                        l2Evaluator.evaluate(
                            sub: rightShell,
                            leftLabel: leftLabel,
                            rightLabel: rightLabel,
                            sentence: sentence,
                            tokenIndices: tokenIndices,
                            timeline: timeline,
                            evidence: evidence,
                            splitGapMs: split.gapMs,
                            confirmedSilenceMs: split.confirmedSilenceMs
                        ),
                        to: &refinedSubs,
                        tokenDecisions: &tokenDecisions,
                        overrides: &overrides
                    )
                } else {
                    append(
                        l2Evaluator.evaluate(
                            sub: sub,
                            leftLabel: leftLabel,
                            rightLabel: rightLabel,
                            sentence: sentence,
                            tokenIndices: tokenIndices,
                            timeline: timeline,
                            evidence: evidence,
                            splitGapMs: nil
                        ),
                        to: &refinedSubs,
                        tokenDecisions: &tokenDecisions,
                        overrides: &overrides
                    )
                }
            }

            let rollup = SentenceDecision.rollUp(
                sentenceID: sentence.sentenceID,
                subSentences: refinedSubs,
                avgVoterMargin: 0
            )
            refinedSentences.append(rollup)
        }

        return Result(
            sentenceDecisions: refinedSentences,
            tokenDecisions: tokenDecisions,
            overrides: overrides
        )
    }

    private func pauseSplits(
        in subSentences: [SubSentenceDecision],
        tokenIndices: [Int],
        timeline: TokenTimeline,
        splitter: SentenceAcceptancePauseSplitter
    ) -> [Int: SentenceAcceptancePauseSplitter.Split] {
        var splits: [Int: SentenceAcceptancePauseSplitter.Split] = [:]
        for index in subSentences.indices
            where subSentences[index].status == .pending {
            if let split = splitter.findSplit(
                sub: subSentences[index],
                tokenIndices: tokenIndices,
                timeline: timeline,
                thresholdMs: policy.pauseSplitMs,
                minimumSilenceMs: policy.pauseSplitMinimumSilenceMs
            ) {
                splits[index] = split
            }
        }
        return splits
    }

    private func append(
        _ outcome: SentenceAcceptanceL2Evaluator.Outcome,
        to refinedSubs: inout [SubSentenceDecision],
        tokenDecisions: inout [TokenDecision],
        overrides: inout [Override]
    ) {
        refinedSubs.append(outcome.subSentence)
        for (index, decision) in outcome.tokenUpdates {
            tokenDecisions[index] = decision
        }
        overrides.append(outcome.override)
    }

    /// Returns direct anchor labels adjacent to the parent sub-sentence.
    /// Pending neighbours may carry an L1 winner but are not anchors.
    private func computeBoundaryLabels(
        subIndex: Int,
        sentenceIndex: Int,
        originalSubs: [SubSentenceDecision],
        l1: SpeakerRoutingResult,
        refinedSentences: [SentenceDecision]
    ) -> (Int?, Int?) {
        let leftLabel: Int?
        if subIndex > 0 {
            let left = originalSubs[subIndex - 1]
            leftLabel = left.status == .direct ? left.label : nil
        } else if sentenceIndex > 0,
                  let lastSub = refinedSentences.last?.subSentences.last,
                  lastSub.status == .direct {
            leftLabel = lastSub.label
        } else {
            leftLabel = nil
        }

        let rightLabel: Int?
        if subIndex + 1 < originalSubs.count {
            let right = originalSubs[subIndex + 1]
            rightLabel = right.status == .direct ? right.label : nil
        } else if sentenceIndex + 1 < l1.sentenceDecisions.count,
                  let firstSub = l1.sentenceDecisions[
                      sentenceIndex + 1
                  ].subSentences.first,
                  firstSub.status == .direct {
            rightLabel = firstSub.label
        } else {
            rightLabel = nil
        }

        return (leftLabel, rightLabel)
    }
}
