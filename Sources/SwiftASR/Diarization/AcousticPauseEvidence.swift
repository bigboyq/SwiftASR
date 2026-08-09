import Foundation

/// Fail-closed acoustic confirmation for L2's timestamp-derived pause
/// candidates. CIF timestamps locate a possible boundary but express the
/// interval until the next fire as the preceding token's duration; that
/// duration is not, by itself, evidence of silence.
///
/// The confirmation uses the pre-CMVN 80-bin log-mel fbank already owned by
/// the speaker pipeline. A candidate is accepted only when a contiguous low
/// energy run reaches the required duration and ends near the proposed token
/// boundary. This prevents a stretched CIF token (for example "什") from
/// becoming a false speaker turn.
struct AcousticPauseEvidence: Sendable {
    struct Confirmation: Sendable, Equatable {
        let silenceMs: Int
    }

    /// Persisted equivalent of one audio probe.  Routing replay stores both
    /// positive and negative probes, so the absence of a confirmation can
    /// remain fail-closed without decoding the audio again.
    struct ReplayCandidate: Sendable, Equatable {
        let leftTokenStartMs: Int
        let rightTokenStartMs: Int
        let candidatePauseMs: Int
        let confirmedSilenceMs: Int?

        init(
            leftTokenStartMs: Int,
            rightTokenStartMs: Int,
            candidatePauseMs: Int,
            confirmedSilenceMs: Int?
        ) {
            self.leftTokenStartMs = leftTokenStartMs
            self.rightTokenStartMs = rightTokenStartMs
            self.candidatePauseMs = candidatePauseMs
            self.confirmedSilenceMs = confirmedSilenceMs
        }
    }

    private struct ReplayKey: Hashable, Sendable {
        let leftTokenStartMs: Int
        let rightTokenStartMs: Int
        let candidatePauseMs: Int
    }

    private let frameEnergies: [Float]
    private let frameMs: Int
    private let globalSpeechReference: Float?
    private let replayConfirmations: [ReplayKey: Int?]?

    init(fbank80: [Float], featureDimension: Int = 80, frameMs: Int = 10) {
        guard featureDimension > 0, frameMs > 0,
              fbank80.count >= featureDimension else {
            self.frameEnergies = []
            self.frameMs = max(1, frameMs)
            self.globalSpeechReference = nil
            self.replayConfirmations = nil
            return
        }

        let frameCount = fbank80.count / featureDimension
        self.frameEnergies = (0..<frameCount).map { frame in
            let start = frame * featureDimension
            var sum: Float = 0
            var count = 0
            for index in start..<(start + featureDimension) {
                let value = fbank80[index]
                guard value.isFinite else { continue }
                sum += value
                count += 1
            }
            return count > 0 ? sum / Float(count) : -.infinity
        }
        self.frameMs = frameMs
        self.globalSpeechReference = Self.percentile(self.frameEnergies, fraction: 0.75)
        self.replayConfirmations = nil
    }

    /// Replays the production audio probes captured in SpeakerRoutingSnapshot.
    /// A candidate omitted from the snapshot cannot be confirmed: this is
    /// intentionally fail-closed rather than falling back to timestamps.
    init(replayCandidates: [ReplayCandidate]) {
        self.frameEnergies = []
        self.frameMs = 10
        self.globalSpeechReference = nil
        var confirmations: [ReplayKey: Int?] = [:]
        for candidate in replayCandidates {
            confirmations[ReplayKey(
                leftTokenStartMs: candidate.leftTokenStartMs,
                rightTokenStartMs: candidate.rightTokenStartMs,
                candidatePauseMs: candidate.candidatePauseMs
            )] = candidate.confirmedSilenceMs
        }
        self.replayConfirmations = confirmations
    }

    /// Confirms that the final portion of the CIF-derived candidate interval
    /// contains real low-energy audio. A split stays fail-closed when the
    /// fbank is unavailable or no such silent run exists.
    func confirmPause(
        leftTokenStartMs: Int,
        rightTokenStartMs: Int,
        candidatePauseMs: Int,
        minimumSilenceMs: Int
    ) -> Confirmation? {
        if let replayConfirmations {
            let key = ReplayKey(
                leftTokenStartMs: leftTokenStartMs,
                rightTokenStartMs: rightTokenStartMs,
                candidatePauseMs: candidatePauseMs
            )
            guard let stored = replayConfirmations[key] ?? nil,
                  stored >= minimumSilenceMs else { return nil }
            return Confirmation(silenceMs: stored)
        }
        guard candidatePauseMs > 0, minimumSilenceMs > 0,
              let globalSpeechReference,
              !frameEnergies.isEmpty else { return nil }

        // For a literal inter-token gap this starts at the preceding token's
        // end. For a CIF-stretched token, inspect its timestamp interval. In
        // both cases silence must finish within 120ms of the proposed split;
        // a quiet patch earlier inside a spoken token is not a turn boundary.
        let windowStartMs = max(leftTokenStartMs, rightTokenStartMs - candidatePauseMs)
        let startFrame = max(0, windowStartMs / frameMs)
        let endFrame = min(frameEnergies.count, (rightTokenStartMs + frameMs - 1) / frameMs)
        guard startFrame < endFrame else { return nil }

        let contextStart = max(0, startFrame - 100) // 1s of local speech context
        let contextEnd = min(frameEnergies.count, endFrame + 100)
        let localSpeechReference = Self.percentile(
            Array(frameEnergies[contextStart..<contextEnd]), fraction: 0.75
        ) ?? globalSpeechReference
        // Fbank values are natural-log mel energies. Requiring a 3-unit drop
        // below both local and recording-level speech references is purposely
        // conservative: no confidence means no speaker split.
        let quietThreshold = min(globalSpeechReference, localSpeechReference) - 3.0
        let requiredFrames = max(1, (minimumSilenceMs + frameMs - 1) / frameMs)
        let boundaryToleranceFrames = max(1, 120 / frameMs)

        var runStart: Int?
        var best: (end: Int, length: Int)?
        for frame in startFrame..<endFrame {
            if frameEnergies[frame].isFinite && frameEnergies[frame] <= quietThreshold {
                if runStart == nil { runStart = frame }
            } else if let start = runStart {
                let candidate = (end: frame, length: frame - start)
                if best == nil || candidate.length > best!.length { best = candidate }
                runStart = nil
            }
        }
        if let runStart {
            let candidate = (end: endFrame, length: endFrame - runStart)
            if best == nil || candidate.length > best!.length { best = candidate }
        }

        guard let best,
              best.length >= requiredFrames,
              best.end >= endFrame - boundaryToleranceFrames else { return nil }
        return Confirmation(silenceMs: best.length * frameMs)
    }

    private static func percentile(_ values: [Float], fraction: Float) -> Float? {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return nil }
        let index = min(finite.count - 1, max(0, Int((Float(finite.count - 1) * fraction).rounded())))
        return finite[index]
    }
}
