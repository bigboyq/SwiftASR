import Foundation

/// Errors are deliberately explicit: profile split is a reversible operation,
/// but it must never be replayed from an incomplete or mismatched artifact.
enum ProfileSplitReassignmentError: Error, LocalizedError, Equatable {
    case emptySplitSet
    case unsupportedSnapshotVersion(Int)
    case duplicateProfileMapping(Int)
    case unknownSplitProfile(String)
    case duplicateSnapshotToken(sentenceIndex: Int, tokenIndex: Int)
    case snapshotTokenMismatch(sentenceIndex: Int, tokenIndex: Int)
    case missingSnapshotToken(sentenceIndex: Int, tokenIndex: Int)
    case invalidPauseCandidate

    var errorDescription: String? {
        switch self {
        case .emptySplitSet:
            return "当前没有需要分拆的说话人。"
        case let .unsupportedSnapshotVersion(version):
            return "该结果的说话人重算数据版本不受支持（v\(version)）。请重新执行说话人识别。"
        case let .duplicateProfileMapping(label):
            return "说话人重算数据包含重复 Profile 映射（\(label)）。"
        case let .unknownSplitProfile(label):
            return "说话人 \(label) 不存在于当前可重算 Profile 中。"
        case let .duplicateSnapshotToken(sentence, token):
            return "说话人重算数据包含重复 token（\(sentence), \(token)）。"
        case let .snapshotTokenMismatch(sentence, token):
            return "说话人重算数据与原始转写不一致（token \(sentence), \(token)）。请重新执行说话人识别。"
        case let .missingSnapshotToken(sentence, token):
            return "说话人重算数据缺少 token（\(sentence), \(token)）。请重新执行说话人识别。"
        case .invalidPauseCandidate:
            return "说话人重算数据的停顿证据不完整。请重新执行说话人识别。"
        }
    }
}

/// Replays the current L1/L2 sentence-routing chain from the immutable
/// routing snapshot. Only tokens whose *baseline final* profile belongs to
/// the Split Set have their candidate profiles filtered. Every other token is
/// replayed as its baseline final label rather than re-opened to a global
/// TOP1 redistribution. Every invocation starts from the snapshot, never a
/// previous derived result.
struct ProfileSplitReassignmentService {
    /// User-facing preflight summary for one newly added Split Set member.
    /// Counts use the same derived sentence units that Results displays,
    /// exports and submits to cleanup.
    struct SplitPreview: Equatable {
        struct Destination: Equatable {
            let speakerLabel: String
            let sentenceCount: Int
        }

        let sourceProfileLabel: String
        let cohesion: Float?
        let totalSentenceCount: Int
        let destinations: [Destination]

        var dominantDestination: Destination? {
            guard let first = destinations.first, totalSentenceCount > 0,
                  Float(first.sentenceCount) / Float(totalSentenceCount) > 0.70
            else { return nil }
            return first
        }

        var dominantRatio: Float? {
            guard let destination = dominantDestination, totalSentenceCount > 0 else { return nil }
            return Float(destination.sentenceCount) / Float(totalSentenceCount)
        }

        /// A stable profile, or a split result overwhelmingly concentrated in
        /// one destination, both require an explicit split confirmation.
        var requiresSplitConfirmation: Bool {
            (cohesion ?? 0) >= 0.65 || dominantDestination != nil
        }
    }

    static func derive(
        input: SpeakerRecognitionInput,
        snapshot: SpeakerRoutingSnapshot,
        splitProfileLabels: Set<String>
    ) throws -> SpeakerSplitOperation {
        try input.validate()
        guard !splitProfileLabels.isEmpty else {
            throw ProfileSplitReassignmentError.emptySplitSet
        }
        guard (1...SpeakerRoutingSnapshot.currentVersion).contains(snapshot.version) else {
            throw ProfileSplitReassignmentError.unsupportedSnapshotVersion(snapshot.version)
        }

        let labelByAcoustic = try profileLabelMap(snapshot.profileMappings)
        for label in splitProfileLabels where !labelByAcoustic.values.contains(label) {
            throw ProfileSplitReassignmentError.unknownSplitProfile(label)
        }

        let replay = try makeReplayContext(
            input: input,
            snapshot: snapshot,
            labelByAcoustic: labelByAcoustic,
            splitProfileLabels: splitProfileLabels
        )
        let l2 = replay.routed.l2
        let derivedSegments: [SpeakerSplitDerivedSegment] = buildDerivedSentenceSegments(
            timeline: replay.timeline,
            tokenDecisions: l2.tokenDecisions,
            snapshotByID: replay.snapshotByID,
            labelByAcoustic: labelByAcoustic,
            splitProfileLabels: splitProfileLabels
        )
        let derivedMergedResults = SegmentMerger().buildMergedResults(
            segments: derivedSegments.map(\.effectiveSegment)
        )
        return SpeakerSplitOperation(
            splitProfileLabels: Array(splitProfileLabels),
            routingSnapshotVersion: snapshot.version,
            routingSnapshotIdentity: snapshot.stableIdentity,
            derivedAt: ResultStore.nowIso(),
            derivedSegments: derivedSegments,
            // Freshly built merge units intentionally invalidate all previous
            // operation-layer cleanup.  Baseline cleanup remains untouched.
            derivedMergedResults: derivedMergedResults
        )
    }

    private struct ReplayContext {
        let timeline: TokenTimeline
        let snapshotByID: [TokenKey: SpeakerRoutingSnapshot.Token]
        let routed: SpeakerRoutingChain.Result
    }

    private static func makeReplayContext(
        input: SpeakerRecognitionInput,
        snapshot: SpeakerRoutingSnapshot,
        labelByAcoustic: [Int: String],
        splitProfileLabels: Set<String>
    ) throws -> ReplayContext {
        let snapshotByID = try snapshotTokenMap(snapshot.tokens)
        let maximumEndMs = snapshot.tokens.map(\.endMs).max() ?? 0
        let timeline = TokenTimeline(
            sentences: input.sentences,
            totalFrames: max(1, (maximumEndMs + 9) / 10)
        )
        let replayCandidates = try pauseCandidates(snapshot.pauseCandidates, tokenByID: snapshotByID)
        var evidenceItems: [SpeakerEvidenceTimeline.TokenEvidence] = []
        evidenceItems.reserveCapacity(timeline.tokens.count)

        for token in timeline.tokens {
            let key = TokenKey(token.id)
            guard let stored = snapshotByID[key] else {
                throw ProfileSplitReassignmentError.missingSnapshotToken(
                    sentenceIndex: token.id.sentenceIndex,
                    tokenIndex: token.id.tokenIndex
                )
            }
            guard stored.text == token.text,
                  stored.startMs == token.rawRangeMs.lowerBound,
                  stored.endMs == token.rawRangeMs.upperBound else {
                throw ProfileSplitReassignmentError.snapshotTokenMismatch(
                    sentenceIndex: token.id.sentenceIndex,
                    tokenIndex: token.id.tokenIndex
                )
            }

            let baselineLabel = stored.finalAcousticLabel.flatMap { labelByAcoustic[$0] }
            let scores: [Int: Float]
            if let baselineLabel, splitProfileLabels.contains(baselineLabel) {
                scores = stored.scores.filter { acoustic, _ in
                    guard let candidateLabel = labelByAcoustic[acoustic] else { return false }
                    return !splitProfileLabels.contains(candidateLabel)
                }
            } else if let finalAcousticLabel = stored.finalAcousticLabel {
                var fixedScores = [finalAcousticLabel: Float(1)]
                if let runnerUp = labelByAcoustic.keys
                    .filter({ $0 != finalAcousticLabel })
                    .sorted()
                    .first {
                    fixedScores[runnerUp] = 0
                }
                scores = fixedScores
            } else {
                scores = [:]
            }
            evidenceItems.append(.init(
                tokenID: token.id,
                scores: scores,
                supportFrames: stored.supportFrames
            ))
        }

        let routed = SpeakerRoutingChain.route(
            timeline: timeline,
            evidence: .stub(evidenceItems),
            policy: snapshot.routingPolicy ?? .production,
            context: SpeakerRoutingContext(
                tokenIndicesBySentence: timeline.tokenIndicesBySentence(),
                acousticPauseEvidence: AcousticPauseEvidence(replayCandidates: replayCandidates)
            )
        )
        return ReplayContext(timeline: timeline, snapshotByID: snapshotByID, routed: routed)
    }

    static func preview(
        operation: SpeakerSplitOperation,
        sourceProfileLabel: String,
        snapshot: SpeakerRoutingSnapshot
    ) -> SplitPreview {
        var counts: [String: Int] = [:]
        for segment in operation.derivedSegments
        where segment.baselineSpeakerLabel == sourceProfileLabel {
            counts[segment.speakerLabel, default: 0] += 1
        }
        var destinations: [SplitPreview.Destination] = []
        for (label, count) in counts {
            destinations.append(
                SplitPreview.Destination(speakerLabel: label, sentenceCount: count)
            )
        }
        destinations.sort {
            $0.sentenceCount == $1.sentenceCount
                ? $0.speakerLabel < $1.speakerLabel
                : $0.sentenceCount > $1.sentenceCount
        }
        return SplitPreview(
            sourceProfileLabel: sourceProfileLabel,
            cohesion: cohesion(for: sourceProfileLabel, snapshot: snapshot),
            totalSentenceCount: counts.values.reduce(0, +),
            destinations: destinations
        )
    }

    /// New snapshots carry true packed-window centroid cohesion. For older
    /// snapshots, use the persisted token-to-profile evidence as a compatible
    /// caution proxy instead of hiding the guard entirely.
    static func cohesion(
        for speakerLabel: String,
        snapshot: SpeakerRoutingSnapshot
    ) -> Float? {
        guard let mapping = snapshot.profileMappings.first(where: {
            $0.speakerLabel == speakerLabel
        }) else { return nil }
        if let cohesion = mapping.cohesion { return cohesion }

        var weightedSum: Float = 0
        var totalWeight = 0
        for token in snapshot.tokens where token.finalAcousticLabel == mapping.acousticLabel {
            guard let score = token.scores[mapping.acousticLabel], score.isFinite else { continue }
            let weight = max(1, token.supportFrames)
            weightedSum += score * Float(weight)
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        return weightedSum / Float(totalWeight)
    }

    private struct TokenKey: Hashable {
        let sentenceIndex: Int
        let tokenIndex: Int

        init(_ id: TokenTimeline.TokenID) {
            sentenceIndex = id.sentenceIndex
            tokenIndex = id.tokenIndex
        }

        init(sentenceIndex: Int, tokenIndex: Int) {
            self.sentenceIndex = sentenceIndex
            self.tokenIndex = tokenIndex
        }
    }

    private static func profileLabelMap(
        _ mappings: [SpeakerRoutingSnapshot.ProfileMapping]
    ) throws -> [Int: String] {
        var output: [Int: String] = [:]
        for mapping in mappings {
            guard output[mapping.acousticLabel] == nil else {
                throw ProfileSplitReassignmentError.duplicateProfileMapping(mapping.acousticLabel)
            }
            output[mapping.acousticLabel] = mapping.speakerLabel
        }
        return output
    }

    private static func snapshotTokenMap(
        _ tokens: [SpeakerRoutingSnapshot.Token]
    ) throws -> [TokenKey: SpeakerRoutingSnapshot.Token] {
        var output: [TokenKey: SpeakerRoutingSnapshot.Token] = [:]
        for token in tokens {
            let key = TokenKey(sentenceIndex: token.sentenceIndex, tokenIndex: token.tokenIndex)
            guard output[key] == nil else {
                throw ProfileSplitReassignmentError.duplicateSnapshotToken(
                    sentenceIndex: token.sentenceIndex,
                    tokenIndex: token.tokenIndex
                )
            }
            output[key] = token
        }
        return output
    }

    private static func pauseCandidates(
        _ candidates: [SpeakerRoutingSnapshot.PauseCandidate],
        tokenByID: [TokenKey: SpeakerRoutingSnapshot.Token]
    ) throws -> [AcousticPauseEvidence.ReplayCandidate] {
        try candidates.map { candidate in
            let leftKey = TokenKey(
                sentenceIndex: candidate.leftSentenceIndex,
                tokenIndex: candidate.leftTokenIndex
            )
            let rightKey = TokenKey(
                sentenceIndex: candidate.rightSentenceIndex,
                tokenIndex: candidate.rightTokenIndex
            )
            guard let left = tokenByID[leftKey], let right = tokenByID[rightKey] else {
                throw ProfileSplitReassignmentError.invalidPauseCandidate
            }
            return AcousticPauseEvidence.ReplayCandidate(
                leftTokenStartMs: left.startMs,
                rightTokenStartMs: right.startMs,
                candidatePauseMs: candidate.candidateGapMs,
                confirmedSilenceMs: candidate.confirmedSilenceMs
            )
        }
    }

    private static func buildDerivedSentenceSegments(
        timeline: TokenTimeline,
        tokenDecisions: [TokenDecision],
        snapshotByID: [TokenKey: SpeakerRoutingSnapshot.Token],
        labelByAcoustic: [Int: String],
        splitProfileLabels: Set<String>
    ) -> [SpeakerSplitDerivedSegment] {
        // Keep only the accepted acoustic label here instead of retaining the
        // full TokenDecision enum in the lookup table. Swift 6.3.3's release
        // optimizer currently crashes in CopyPropagation when it consumes a
        // TokenDecision from a dictionary and immediately pattern-matches its
        // associated-value enum (see ProfileSplitReassignmentService's old
        // implementation). The accepted-label map is also the only piece of
        // the decision needed to render the derived segments.
        var acceptedLabelByTokenID: [TokenTimeline.TokenID: Int] = [:]
        acceptedLabelByTokenID.reserveCapacity(tokenDecisions.count)
        for decision in tokenDecisions {
            if let knownLabel = decision.knownLabel {
                acceptedLabelByTokenID[decision.tokenID] = knownLabel
            }
        }

        var output: [SpeakerSplitDerivedSegment] = []
        var nextID = 1
        var runTokens: [TokenTimeline.Token] = []
        var runSentenceID: Int?
        var runBaseline: String?
        var runEffective: String?

        // Baseline UtteranceBuilder consumes `timeline.tokens` in this exact
        // global time order. Split replay must use the same order or a
        // cross-batch timestamp inversion can make baseline and derived text
        // disagree even though they contain the same token identities.
        for token in timeline.tokens {
            let stored = snapshotByID[TokenKey(token.id)]
            let baseline = stored?.finalAcousticLabel.flatMap { labelByAcoustic[$0] }
                ?? SpeakerDiarizationPipeline.sentinelLabel
            // This is the operation's central invariant: a token whose
            // baseline profile is outside Split Set is copied verbatim.
            // It may act as a stable routing anchor, but its displayed
            // label can never be changed by the replay's sentence/L2
            // context. Only Split Set tokens consume an L2 decision.
            let effective: String
            if splitProfileLabels.contains(baseline) {
                effective = acceptedLabelByTokenID[token.id]
                    .flatMap { labelByAcoustic[$0] }
                    ?? SpeakerDiarizationPipeline.sentinelLabel
            } else {
                effective = baseline
            }

            if runSentenceID == token.sentenceID,
               runBaseline == baseline,
               runEffective == effective {
                runTokens.append(token)
            } else {
                if let runBaseline, let runEffective,
                   let segment = makeDerivedSegment(
                       runTokens: runTokens,
                       baselineSpeakerLabel: runBaseline,
                       speakerLabel: runEffective,
                       segmentId: nextID,
                       previousEndMs: output.last?.endMs
                   ) {
                    output.append(segment)
                    nextID += 1
                }
                runTokens = [token]
                runSentenceID = token.sentenceID
                runBaseline = baseline
                runEffective = effective
            }
        }
        if let runBaseline, let runEffective,
           let segment = makeDerivedSegment(
               runTokens: runTokens,
               baselineSpeakerLabel: runBaseline,
               speakerLabel: runEffective,
               segmentId: nextID,
               previousEndMs: output.last?.endMs
           ) {
            output.append(segment)
        }
        return output
    }

    private static func makeDerivedSegment(
        runTokens: [TokenTimeline.Token],
        baselineSpeakerLabel: String,
        speakerLabel: String,
        segmentId: Int,
        previousEndMs: Int? = nil
    ) -> SpeakerSplitDerivedSegment? {
        guard !runTokens.isEmpty else { return nil }
        let text = runTokens
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var startMs = runTokens.map(\.rawRangeMs.lowerBound).min() ?? 0
        if let previousEndMs {
            startMs = max(startMs, previousEndMs)
        }
        let rawEndMs = runTokens.map(\.rawRangeMs.upperBound).max() ?? startMs
        let endMs = max(startMs, rawEndMs)
        return SpeakerSplitDerivedSegment(
            segmentId: segmentId,
            startMs: startMs,
            endMs: endMs,
            baselineSpeakerLabel: baselineSpeakerLabel,
            speakerLabel: speakerLabel,
            rawText: text
        )
    }
}
