import Foundation

/// Re-votes one original or pause-split sub-sentence through the L2 rescue
/// chain while preserving the router's deterministic diagnostics.
struct SentenceAcceptanceL2Evaluator: Sendable {
    let policy: SpeakerTemporalPolicy

    struct Outcome {
        let subSentence: SubSentenceDecision
        let tokenUpdates: [(Int, TokenDecision)]
        let override: SentenceAcceptanceRouter.Override
    }

    /// Statistics collected over one sub-sentence token range.
    private struct VotingStats {
        var voteCountAll: [Int: Int] = [:]
        var voteCountExcludingBoundary: [Int: Int] = [:]
        var totalVotesAll = 0
        var totalVotesExcludingBoundary = 0
        var scoreSum: [Int: Float] = [:]
        var marginSum: Float = 0
        var validTokenCount = 0

        var averageMargin: Float {
            totalVotesAll > 0 ? marginSum / Float(totalVotesAll) : 0
        }

        var rawTopRatio: Float {
            guard totalVotesAll > 0,
                  let winner = winner(from: voteCountAll) else { return 0 }
            return Float(voteCountAll[winner] ?? 0) / Float(totalVotesAll)
        }

        func winner(from counts: [Int: Int]) -> Int? {
            counts.max(by: { left, right in
                left.value == right.value
                    ? left.key > right.key
                    : left.value < right.value
            })?.key
        }
    }

    func evaluate(
        sub: SubSentenceDecision,
        leftLabel: Int?,
        rightLabel: Int?,
        sentence: SentenceDecision,
        tokenIndices: [Int],
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        splitGapMs: Int?,
        confirmedSilenceMs: Int? = nil
    ) -> Outcome {
        let unfilteredStats = collectVotingStats(
            sub: sub,
            tokenIndices: tokenIndices,
            timeline: timeline,
            evidence: evidence,
            excludedLabels: []
        )
        let isStrong = unfilteredStats.averageMargin
            >= policy.sentenceMinimumVoterMargin
        let rawMajorityProtected = unfilteredStats.rawTopRatio
            >= SpeakerTemporalPolicy.boundaryExclusionRawTopRatioProtection
        let excludedLabels = isStrong || rawMajorityProtected
            ? []
            : diarizationBoundaryExcludedLabels(leftLabel: leftLabel, rightLabel: rightLabel)

        let finalStats: VotingStats
        var promotedRatio: Float = 0
        var promotedWinner: Int?

        if !isStrong && !excludedLabels.isEmpty {
            let boundaryStats = collectVotingStats(
                sub: sub,
                tokenIndices: tokenIndices,
                timeline: timeline,
                evidence: evidence,
                excludedLabels: excludedLabels
            )
            finalStats = boundaryStats
            if boundaryStats.totalVotesExcludingBoundary > 0,
               let winner = boundaryStats.winner(
                   from: boundaryStats.voteCountExcludingBoundary
               ) {
                let ratio = Float(
                    boundaryStats.voteCountExcludingBoundary[winner]!
                ) / Float(boundaryStats.totalVotesExcludingBoundary)
                if ratio >= policy.sentenceDirectRatio {
                    promotedWinner = winner
                    promotedRatio = ratio
                }
            }
        } else {
            finalStats = unfilteredStats
        }

        let winnerAndEvidence = resolveWinner(
            promotedWinner: promotedWinner,
            stats: finalStats,
            excludedLabels: excludedLabels
        )

        let subSentence = makeSubSentence(
            from: sub,
            stats: finalStats,
            excludedLabels: excludedLabels,
            winner: winnerAndEvidence.winner,
            hasUsableEvidence: winnerAndEvidence.hasUsableEvidence
        )
        let diagnostic = makeOverride(
            sentenceID: sentence.sentenceID,
            sub: sub,
            winner: winnerAndEvidence.winner,
            hasUsableEvidence: winnerAndEvidence.hasUsableEvidence,
            wasPromoted: promotedWinner != nil,
            promotedRatio: promotedRatio,
            splitGapMs: splitGapMs,
            confirmedSilenceMs: confirmedSilenceMs
        )
        let tokenUpdates = makeTokenUpdates(
            sub: sub,
            tokenIndices: tokenIndices,
            timeline: timeline,
            evidence: evidence,
            fallbackConfidence: sentence.maxSubTopRatio,
            winner: winnerAndEvidence.winner,
            hasUsableEvidence: winnerAndEvidence.hasUsableEvidence
        )

        return Outcome(
            subSentence: subSentence,
            tokenUpdates: tokenUpdates,
            override: diagnostic
        )
    }

    /// Collects the per-utt vote, fallback-score, and margin views in one
    /// pass. When a boundary label is excluded, a token contributes its
    /// highest-scoring remaining label instead of disappearing.
    private func collectVotingStats(
        sub: SubSentenceDecision,
        tokenIndices: [Int],
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        excludedLabels: [Int]
    ) -> VotingStats {
        var stats = VotingStats()
        for offset in sub.startTokenIndex..<sub.endTokenIndex {
            guard offset < tokenIndices.count else { continue }
            let tokenIndex = tokenIndices[offset]
            let token = timeline.tokens[tokenIndex]
            guard let item = evidence.tokenEvidence[token.id] else { continue }

            stats.validTokenCount += 1
            for (label, score) in item.scores {
                stats.scoreSum[label, default: 0] += score
            }

            guard item.supportFrames > 0,
                  item.topScore.isFinite,
                  item.topScore >= policy.otherMaximumScore,
                  let topLabel = item.topLabel else { continue }

            stats.voteCountAll[topLabel, default: 0] += 1
            stats.totalVotesAll += 1
            if item.margin.isFinite {
                stats.marginSum += item.margin
            }

            let boundaryEligibleLabel: Int?
            if excludedLabels.contains(topLabel) {
                boundaryEligibleLabel = item.scores
                    .filter { !excludedLabels.contains($0.key) }
                    .max(by: { left, right in
                        left.value == right.value
                            ? left.key > right.key
                            : left.value < right.value
                    })?.key
            } else {
                boundaryEligibleLabel = topLabel
            }
            if let boundaryEligibleLabel {
                stats.voteCountExcludingBoundary[
                    boundaryEligibleLabel,
                    default: 0
                ] += 1
                stats.totalVotesExcludingBoundary += 1
            }
        }
        return stats
    }

    // 2026-08-05 (R4-P1-2): boundary 排除规则（原 `boundaryExcludedLabels`
    // 实例方法）已合并到模块级 free function `diarizationBoundaryExcludedLabels`，
    // 与 L1 (`SpeakerConfidenceRouter`) 共享，避免规则分叉。

    private func resolveWinner(
        promotedWinner: Int?,
        stats: VotingStats,
        excludedLabels: [Int]
    ) -> (winner: Int?, hasUsableEvidence: Bool) {
        if let promotedWinner {
            return (promotedWinner, true)
        }

        let candidates = stats.scoreSum.filter {
            !excludedLabels.contains($0.key) && $0.value.isFinite
        }
        guard stats.validTokenCount > 0,
              let winner = candidates.max(by: { left, right in
                  left.value == right.value
                      ? left.key > right.key
                      : left.value < right.value
              })?.key else {
            return (nil, false)
        }
        return (winner, true)
    }

    private func makeSubSentence(
        from sub: SubSentenceDecision,
        stats: VotingStats,
        excludedLabels: [Int],
        winner: Int?,
        hasUsableEvidence: Bool
    ) -> SubSentenceDecision {
        SubSentenceDecision(
            startTokenIndex: sub.startTokenIndex,
            endTokenIndex: sub.endTokenIndex,
            status: hasUsableEvidence ? .direct : .other,
            label: hasUsableEvidence ? winner : nil,
            voteCount: stats.voteCountAll,
            totalVotes: stats.totalVotesAll,
            topRatio: sub.topRatio,
            voteWinner: sub.voteWinner,
            avgVoterMargin: stats.averageMargin,
            excludedLabels: excludedLabels
        )
    }

    private func makeOverride(
        sentenceID: Int,
        sub: SubSentenceDecision,
        winner: Int?,
        hasUsableEvidence: Bool,
        wasPromoted: Bool,
        promotedRatio: Float,
        splitGapMs: Int?,
        confirmedSilenceMs: Int?
    ) -> SentenceAcceptanceRouter.Override {
        SentenceAcceptanceRouter.Override(
            sentenceID: sentenceID,
            l1TopRatio: sub.topRatio,
            l2Winner: hasUsableEvidence ? winner : nil,
            l2Ratio: hasUsableEvidence
                ? (wasPromoted ? promotedRatio : sub.topRatio)
                : 0,
            applied: hasUsableEvidence,
            splitGapMs: splitGapMs,
            confirmedSilenceMs: confirmedSilenceMs
        )
    }

    private func makeTokenUpdates(
        sub: SubSentenceDecision,
        tokenIndices: [Int],
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        fallbackConfidence: Float,
        winner: Int?,
        hasUsableEvidence: Bool
    ) -> [(Int, TokenDecision)] {
        var updates: [(Int, TokenDecision)] = []
        updates.reserveCapacity(sub.endTokenIndex - sub.startTokenIndex)

        for offset in sub.startTokenIndex..<sub.endTokenIndex {
            guard offset < tokenIndices.count else { continue }
            let tokenIndex = tokenIndices[offset]
            let token = timeline.tokens[tokenIndex]
            let evidenceScore = evidence.tokenEvidence[token.id]?.topScore
                ?? fallbackConfidence
            let confidence = evidenceScore.isFinite
                ? evidenceScore
                : fallbackConfidence
            let disposition: TokenDisposition
            if hasUsableEvidence, let winner {
                disposition = .accepted(
                    label: winner,
                    source: .direct,
                    confidence: confidence
                )
            } else {
                disposition = .other(
                    reason: .noEvidence,
                    confidence: confidence
                )
            }
            updates.append((
                tokenIndex,
                TokenDecision(tokenID: token.id, disposition: disposition)
            ))
        }
        return updates
    }
}
