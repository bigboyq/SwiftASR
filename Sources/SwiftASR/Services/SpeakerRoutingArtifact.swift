import Foundation

/// Pure helpers for versioned speaker-routing artifacts. The pipeline actor
/// supplies immutable run output and owns the actual write/diagnostic policy.
enum SpeakerRoutingArtifact {
    static func snapshotPath(diagnosticsURL: URL?, audioPath: String) -> URL {
        guard let diagnosticsURL else {
            return ResultStore.speakerRoutingSnapshotPath(jobId: ResultStore.hashAudioPath(audioPath))
        }
        let name = diagnosticsURL.lastPathComponent
        let routingName: String
        if let range = name.range(of: ".speaker-diagnostics") {
            routingName = String(name[..<range.lowerBound]) + ".speaker-routing.json"
        } else if name.hasSuffix(".json") {
            routingName = String(name.dropLast(".json".count)) + ".speaker-routing.json"
        } else {
            routingName = name + ".speaker-routing.json"
        }
        return diagnosticsURL.deletingLastPathComponent().appendingPathComponent(routingName)
    }

    static func pauseCandidates(
        timeline: TokenTimeline,
        tokenIndicesBySentence: [Int: [Int]],
        evidence: AcousticPauseEvidence,
        policy: SpeakerTemporalPolicy
    ) -> [SpeakerRoutingSnapshot.PauseCandidate] {
        var output: [SpeakerRoutingSnapshot.PauseCandidate] = []
        for sentenceID in tokenIndicesBySentence.keys.sorted() {
            guard let indices = tokenIndicesBySentence[sentenceID], indices.count >= 2 else { continue }
            for offset in indices.indices.dropLast() {
                let left = timeline.tokens[indices[offset]]
                let right = timeline.tokens[indices[offset + 1]]
                let leftDuration = max(0, left.rawRangeMs.upperBound - left.rawRangeMs.lowerBound)
                let interTokenGap = max(0, right.rawRangeMs.lowerBound - left.rawRangeMs.upperBound)
                let candidateGap = max(leftDuration, interTokenGap)
                guard candidateGap >= policy.pauseSplitMs else { continue }
                let confirmation = evidence.confirmPause(
                    leftTokenStartMs: left.rawRangeMs.lowerBound,
                    rightTokenStartMs: right.rawRangeMs.lowerBound,
                    candidatePauseMs: candidateGap,
                    minimumSilenceMs: policy.pauseSplitMinimumSilenceMs
                )
                output.append(SpeakerRoutingSnapshot.PauseCandidate(
                    leftSentenceIndex: left.id.sentenceIndex,
                    leftTokenIndex: left.id.tokenIndex,
                    rightSentenceIndex: right.id.sentenceIndex,
                    rightTokenIndex: right.id.tokenIndex,
                    candidateGapMs: candidateGap,
                    confirmedSilenceMs: confirmation?.silenceMs
                ))
            }
        }
        return output
    }
}
