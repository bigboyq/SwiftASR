import Foundation

/// Resolves timestamp pause candidates against acoustic evidence and builds
/// the two pending shells consumed by the sentence L2 evaluator.
///
/// Keeping this concern separate from `SentenceAcceptanceRouter` makes the
/// routing loop describe orchestration only: discover a split, derive the
/// parent boundary context, and evaluate each resulting sub-sentence.
struct SentenceAcceptancePauseSplitter: Sendable {
    let acousticEvidence: AcousticPauseEvidence

    struct Split: Sendable {
        /// Split happens before this offset in the parent sub-sentence.
        let offset: Int
        /// Timestamp-derived pause-like signal recorded for diagnostics.
        let gapMs: Int
        /// Consecutive low-energy evidence that confirmed the candidate.
        let confirmedSilenceMs: Int
    }

    /// Finds the largest acoustically confirmed internal pause.
    ///
    /// Each adjacent token pair contributes
    /// `max(leftToken.duration, interTokenGap)` as a timestamp candidate.
    /// A candidate is accepted only when the matching fbank span contains
    /// the required consecutive low-energy evidence. Equal gaps retain the
    /// earliest boundary, matching the router's historical deterministic
    /// tie-breaking behavior.
    func findSplit(
        sub: SubSentenceDecision,
        tokenIndices: [Int],
        timeline: TokenTimeline,
        thresholdMs: Int,
        minimumSilenceMs: Int
    ) -> Split? {
        guard sub.endTokenIndex - sub.startTokenIndex >= 2 else { return nil }

        var bestGap = 0
        var bestOffset = -1
        var bestConfirmation: AcousticPauseEvidence.Confirmation?

        for offset in sub.startTokenIndex..<(sub.endTokenIndex - 1) {
            guard offset >= 0, offset + 1 < tokenIndices.count else { continue }
            let leftIndex = tokenIndices[offset]
            let rightIndex = tokenIndices[offset + 1]
            guard timeline.tokens.indices.contains(leftIndex),
                  timeline.tokens.indices.contains(rightIndex) else { continue }

            let leftToken = timeline.tokens[leftIndex]
            let rightToken = timeline.tokens[rightIndex]
            let leftDuration = max(
                0,
                leftToken.rawRangeMs.upperBound - leftToken.rawRangeMs.lowerBound
            )
            let interTokenGap = max(
                0,
                rightToken.rawRangeMs.lowerBound - leftToken.rawRangeMs.upperBound
            )
            let candidateGap = max(leftDuration, interTokenGap)

            guard candidateGap >= thresholdMs,
                  let confirmation = acousticEvidence.confirmPause(
                    leftTokenStartMs: leftToken.rawRangeMs.lowerBound,
                    rightTokenStartMs: rightToken.rawRangeMs.lowerBound,
                    candidatePauseMs: candidateGap,
                    minimumSilenceMs: minimumSilenceMs
                  ) else { continue }

            if candidateGap > bestGap {
                bestGap = candidateGap
                bestOffset = offset + 1
                bestConfirmation = confirmation
            }
        }

        guard bestGap >= thresholdMs,
              bestOffset > sub.startTokenIndex,
              bestOffset < sub.endTokenIndex,
              let bestConfirmation else { return nil }

        return Split(
            offset: bestOffset,
            gapMs: bestGap,
            confirmedSilenceMs: bestConfirmation.silenceMs
        )
    }

    /// Builds a pending half that preserves the parent's L1 diagnostic
    /// values while narrowing the token range for a fresh L2 vote.
    func makeShell(
        start: Int,
        end: Int,
        parent: SubSentenceDecision
    ) -> SubSentenceDecision {
        SubSentenceDecision(
            startTokenIndex: start,
            endTokenIndex: end,
            status: .pending,
            label: parent.voteWinner,
            voteCount: [:],
            totalVotes: 0,
            topRatio: parent.topRatio,
            voteWinner: parent.voteWinner,
            avgVoterMargin: 0,
            excludedLabels: []
        )
    }
}
