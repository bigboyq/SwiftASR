import Foundation

/// Immutable, job-local evidence needed to replay speaker routing after the
/// initial diarization run.  This is deliberately separate from
/// `.speaker-diagnostics.json`: diagnostics are investigative and have a
/// backward-compatible, evolving schema, while this snapshot is the input
/// contract for the reversible profile-split operation layer.
///
/// Scores and labels use acoustic labels (`0`, `1`, ...).  The explicit
/// `profileMappings` plane is the bridge to result.json's display labels.
public struct SpeakerRoutingSnapshot: Codable, Sendable {
    /// v2 adds the exact routing policy used to create the evidence.  v1
    /// remains readable and is explicitly replayed with `.production`.
    public static let currentVersion = 2

    public let version: Int
    public let profileMappings: [ProfileMapping]
    public let tokens: [Token]
    /// Acoustic-pause probes for every adjacent same-sentence token boundary
    /// whose timestamp signal reached the production pause threshold.  A nil
    /// `confirmedSilenceMs` is meaningful: it records a candidate that failed
    /// the fail-closed audio confirmation, so a later replay must not split
    /// there merely from timestamps.
    public let pauseCandidates: [PauseCandidate]
    /// Nil only for legacy v1 sidecars.  This is part of the replay identity
    /// for v2 so a threshold change cannot masquerade as the same snapshot.
    public let routingPolicy: SpeakerTemporalPolicy?

    /// Deterministic content identity for binding a persisted split operation
    /// to the exact routing evidence it was calculated from. It is computed
    /// rather than stored, so copying or re-encoding a valid snapshot cannot
    /// leave behind a stale digest. The operation layer persists this value
    /// and rejects replay when the currently loaded snapshot differs.
    public var stableIdentity: String {
        var digest = FNV1a64()
        digest.append("speaker-routing-snapshot")
        digest.append(version)
        for mapping in profileMappings.sorted(by: { $0.acousticLabel < $1.acousticLabel }) {
            digest.append(mapping.acousticLabel)
            digest.append(mapping.speakerLabel)
        }
        for token in tokens.sorted(by: {
            $0.sentenceIndex == $1.sentenceIndex
                ? $0.tokenIndex < $1.tokenIndex
                : $0.sentenceIndex < $1.sentenceIndex
        }) {
            digest.append(token.sentenceIndex)
            digest.append(token.tokenIndex)
            digest.append(token.text)
            digest.append(token.startMs)
            digest.append(token.endMs)
            digest.append(token.supportFrames)
            digest.append(token.baselineAcousticLabel)
            digest.append(token.finalAcousticLabel)
            for (label, score) in token.scores.sorted(by: { $0.key < $1.key }) {
                digest.append(label)
                digest.append(score.bitPattern)
            }
        }
        for candidate in pauseCandidates.sorted(by: Self.pauseCandidatePrecedes) {
            digest.append(candidate.leftSentenceIndex)
            digest.append(candidate.leftTokenIndex)
            digest.append(candidate.rightSentenceIndex)
            digest.append(candidate.rightTokenIndex)
            digest.append(candidate.candidateGapMs)
            digest.append(candidate.confirmedSilenceMs)
        }
        // Do not alter v1's historical identity: existing operation layers
        // persist that digest and must remain attachable after an upgrade.
        if version >= 2, let routingPolicy {
            digest.append(routingPolicy.otherMaximumScore.bitPattern)
            digest.append(routingPolicy.acceptedMinimumScore.bitPattern)
            digest.append(routingPolicy.acceptedMinimumMargin.bitPattern)
            digest.append(routingPolicy.enableSentinelIsolation ? 1 : 0)
            digest.append(routingPolicy.enableTripleTrackMerge ? 1 : 0)
            digest.append(routingPolicy.acousticDegradedThreshold.bitPattern)
            digest.append(routingPolicy.sentinelInterjectionThreshold.bitPattern)
            digest.append(routingPolicy.sentenceDirectRatio.bitPattern)
            digest.append(routingPolicy.sentenceMinimumVotes)
            digest.append(routingPolicy.sentenceMinimumVoterMargin.bitPattern)
            digest.append(routingPolicy.pauseSplitMs)
            digest.append(routingPolicy.pauseSplitMinimumSilenceMs)
        }
        return String(format: "routing_%016llx", digest.value)
    }

    public init(
        version: Int = Self.currentVersion,
        profileMappings: [ProfileMapping],
        tokens: [Token],
        pauseCandidates: [PauseCandidate],
        routingPolicy: SpeakerTemporalPolicy? = .production
    ) {
        self.version = version
        self.profileMappings = profileMappings
        self.tokens = tokens
        self.pauseCandidates = pauseCandidates
        self.routingPolicy = routingPolicy
    }

    public struct ProfileMapping: Codable, Sendable, Equatable {
        public let acousticLabel: Int
        public let speakerLabel: String
        /// Mean cosine similarity between this acoustic profile's packed
        /// windows and its centroid at diarization time. This is profile
        /// quality metadata for UI caution only; it never affects replay,
        /// so it is intentionally excluded from `stableIdentity`.
        public let cohesion: Float?

        public init(acousticLabel: Int, speakerLabel: String, cohesion: Float? = nil) {
            self.acousticLabel = acousticLabel
            self.speakerLabel = speakerLabel
            self.cohesion = cohesion
        }
    }

    /// Stable token identity is `(sentenceIndex, tokenIndex)`, backed by the
    /// original token timing/text for integrity checks against speaker-input.
    public struct Token: Codable, Sendable, Equatable {
        public let sentenceIndex: Int
        public let tokenIndex: Int
        public let text: String
        public let startMs: Int
        public let endMs: Int
        public let scores: [Int: Float]
        public let supportFrames: Int
        /// L1 sentence/sub-sentence projection before L2 rescue.
        public let baselineAcousticLabel: Int?
        /// Authoritative post-L2 label. nil means the system Speaker sentinel.
        public let finalAcousticLabel: Int?

        public init(
            sentenceIndex: Int,
            tokenIndex: Int,
            text: String,
            startMs: Int,
            endMs: Int,
            scores: [Int: Float],
            supportFrames: Int,
            baselineAcousticLabel: Int?,
            finalAcousticLabel: Int?
        ) {
            self.sentenceIndex = sentenceIndex
            self.tokenIndex = tokenIndex
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
            self.scores = scores
            self.supportFrames = supportFrames
            self.baselineAcousticLabel = baselineAcousticLabel
            self.finalAcousticLabel = finalAcousticLabel
        }
    }

    public struct PauseCandidate: Codable, Sendable, Equatable {
        public let leftSentenceIndex: Int
        public let leftTokenIndex: Int
        public let rightSentenceIndex: Int
        public let rightTokenIndex: Int
        public let candidateGapMs: Int
        public let confirmedSilenceMs: Int?

        public init(
            leftSentenceIndex: Int,
            leftTokenIndex: Int,
            rightSentenceIndex: Int,
            rightTokenIndex: Int,
            candidateGapMs: Int,
            confirmedSilenceMs: Int?
        ) {
            self.leftSentenceIndex = leftSentenceIndex
            self.leftTokenIndex = leftTokenIndex
            self.rightSentenceIndex = rightSentenceIndex
            self.rightTokenIndex = rightTokenIndex
            self.candidateGapMs = candidateGapMs
            self.confirmedSilenceMs = confirmedSilenceMs
        }
    }

    private static func pauseCandidatePrecedes(_ lhs: PauseCandidate, _ rhs: PauseCandidate) -> Bool {
        let left = (
            lhs.leftSentenceIndex, lhs.leftTokenIndex,
            lhs.rightSentenceIndex, lhs.rightTokenIndex,
            lhs.candidateGapMs, lhs.confirmedSilenceMs ?? -1
        )
        let right = (
            rhs.leftSentenceIndex, rhs.leftTokenIndex,
            rhs.rightSentenceIndex, rhs.rightTokenIndex,
            rhs.candidateGapMs, rhs.confirmedSilenceMs ?? -1
        )
        return left < right
    }
}

/// Small self-contained FNV-1a implementation. Its purpose is deterministic
/// identity binding, not cryptographic tamper resistance; this remains valid
/// on all supported macOS versions without changing the result-store hash API.
private struct FNV1a64 {
    private static let offsetBasis: UInt64 = 0xcbf29ce484222325
    private static let prime: UInt64 = 0x00000100000001B3
    private(set) var value = offsetBasis

    mutating func append(_ value: String) {
        append(Data(value.utf8))
        append(UInt8(0))
    }

    mutating func append(_ value: Int) {
        append(String(value))
        append(UInt8(0))
    }

    mutating func append(_ value: Int?) {
        append(value.map(String.init) ?? "nil")
        append(UInt8(0))
    }

    mutating func append(_ value: UInt32) {
        append(String(value))
        append(UInt8(0))
    }

    private mutating func append(_ data: Data) {
        for byte in data {
            value ^= UInt64(byte)
            value &*= Self.prime
        }
    }

    private mutating func append(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= Self.prime
    }
}
