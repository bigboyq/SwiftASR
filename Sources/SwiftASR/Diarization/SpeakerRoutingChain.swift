import Foundation

/// Immutable routing inputs that are expensive enough to build once and are
/// also needed when the routing snapshot is written.
struct SpeakerRoutingContext: Sendable {
    let tokenIndicesBySentence: [Int: [Int]]
    let acousticPauseEvidence: AcousticPauseEvidence

    init(timeline: TokenTimeline, fbank80: [Float]) {
        tokenIndicesBySentence = timeline.tokenIndicesBySentence()
        acousticPauseEvidence = AcousticPauseEvidence(fbank80: fbank80)
    }

    init(
        tokenIndicesBySentence: [Int: [Int]],
        acousticPauseEvidence: AcousticPauseEvidence
    ) {
        self.tokenIndicesBySentence = tokenIndicesBySentence
        self.acousticPauseEvidence = acousticPauseEvidence
    }
}

/// The one authoritative L1 → L2 routing composition.
///
/// Full diarization and profile-split replay intentionally share this small
/// boundary.  They differ only in how evidence and pause confirmation are
/// materialised; neither path may independently choose a routing policy or
/// accidentally omit a stage.
struct SpeakerRoutingChain: Sendable {
    struct Result: Sendable {
        let l1: SpeakerRoutingResult
        let l2: SentenceAcceptanceRouter.Result
    }

    static func route(
        timeline: TokenTimeline,
        evidence: SpeakerEvidenceTimeline,
        policy: SpeakerTemporalPolicy,
        context: SpeakerRoutingContext
    ) -> Result {
        let l1 = SpeakerConfidenceRouter(policy: policy).route(
            timeline: timeline,
            evidence: evidence,
            tokenIndicesBySentence: context.tokenIndicesBySentence
        )
        let l2 = SentenceAcceptanceRouter(
            policy: policy,
            acousticPauseEvidence: context.acousticPauseEvidence
        ).route(
            timeline: timeline,
            l1: l1,
            evidence: evidence,
            tokenIndicesBySentence: context.tokenIndicesBySentence
        )
        return Result(l1: l1, l2: l2)
    }
}
