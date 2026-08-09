import Foundation

/// The production speaker path is deliberately single-purpose:
///
///   L1 (per-sub-sentence vote) → L2 (per-sub-sentence rescue: pause-split
///   + boundary rule + per-utt majority + mean-score fallback) →
///   UtteranceBuilder (contiguous same-label merge)
///
/// 2026-07-25 refactor: the router became per-sentence (split by
/// terminal punctuation), not per-token.  L1 minority-majority votes
/// decide each sub-sentence's status, leaving weak-majority subs in
/// `.pending` for L2 to resolve.
///
/// 2026-07-26 refactor (current): every `.pending` sub-sentence is
/// resolved to `.direct(speaker)` or `.other` by L2. L2 first tries an
/// **acoustic-pause split**: a large CIF timestamp interval
/// (`policy.pauseSplitMs`, default 800ms) is only a candidate. A
/// contiguous low-energy fbank run must independently confirm actual
/// silence at that boundary before the sub is split and each half is
/// voted independently. This is the rescue for "ASR/标点 model漏打
/// 标点" — a real turn break that the punctuation model collapsed.
/// Each (half-)sub then goes through the boundary-exclusion rule,
/// per-utt majority vote (≥60% threshold), and mean-score fallback —
/// every sub ends up `.direct(speaker)` or `.other`
/// (zero-evidence → `fp_system_speaker` sentinel).  UtteranceBuilder
/// simply groups contiguous same-label tokens.
///
/// 2026-07-26: Viterbi DP and DecisionTree were removed from
/// production in this commit.  The boundary-exclusion rule, per-utt
/// majority vote, and mean-score fallback chain are the only
/// speaker-routing rules left; `UtteranceBuilder` is a pure
/// projection of the L2 output.
struct SpeakerDiarizationPipeline {
    static let sentinelFingerprint = "fp_system_speaker"
    static let sentinelLabel = "Speaker"

    struct Result: Sendable {
        let utterances: [UtteranceData]
        let speakerProfiles: [SpeakerProfileData]
        let timeline: TokenTimeline
        let tokenEvidence: SpeakerEvidenceTimeline
        let routingContext: SpeakerRoutingContext
        /// L1 per-token decisions (before L2).  Useful for
        /// diff-comparing the per-sentence router against the legacy
        /// per-token router in tests.
        let baselineDecisions: [TokenDecision]
        /// L1 per-sentence decisions, in sentenceID order.  Diagnostic
        /// consumers (e.g. `SentenceAcceptanceDiagnostic`) need this
        /// to inspect the L1 distribution — by the time
        /// `sentenceDecisions` is read, L2 has already promoted every
        /// `.pending` sub to `.direct` and the L1 distribution is
        /// unrecoverable.  2026-07-26 audit fix.
        let l1SentenceDecisions: [SentenceDecision]
        /// Post-L2 per-sentence decisions, in sentenceID order.
        /// L2's rescue chain (pause-split + boundary rule + per-utt
        /// majority + mean-score fallback) may turn some L1 .pending
        /// subs into .direct or .other.
        let sentenceDecisions: [SentenceDecision]
        /// L2 per-sentence override record (only the sentences L2
        /// considered are listed; L1 .direct / .other sentences are not
        /// re-stated here).
        let l2Overrides: [SentenceAcceptanceRouter.Override]
        let decisions: [TokenDecision]
        /// Packed-window mean cosine to the final acoustic profile centroid,
        /// keyed by the display-aligned acoustic label.
        let profileCohesions: [Int: Float]
        let windowCount: Int
        let profileCount: Int
        let otherCount: Int
        let unresolvedCount: Int
    }

    let policy: SpeakerTemporalPolicy
    let clustering: SpectralClustering

    enum Error: Swift.Error, Sendable {
        case embeddingShapeMismatch(expected: Int, actual: Int)
        case clusteringInputInvalid(SpeakerOrchestratorError)
        case clusteringOutputMismatch(expectedLabels: Int, actualLabels: Int)
        case noAcousticProfiles
        case speakerEngineRequired
    }

    init(policy: SpeakerTemporalPolicy = .production, clustering: SpectralClustering = SpectralClustering()) {
        self.policy = policy
        self.clustering = clustering
    }

    func run(
        fbank80: [Float],
        sentences: [ASRSentence],
        speaker: SpeakerNativeCoreMLEngine?,
        precomputedEmbeddings: [Float]? = nil,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) throws -> Result {
        let timeline = TokenTimeline(sentences: sentences, totalFrames: fbank80.count / 80)
        let routingContext = SpeakerRoutingContext(timeline: timeline, fbank80: fbank80)
        let windows = TokenPackedWindowPlanner().makeWindows(timeline: timeline)
        guard !windows.isEmpty else {
            let decisions = timeline.tokens.map { TokenDecision(tokenID: $0.id, disposition: .unresolved(reason: .noEvidence)) }
            return Result(
                utterances: UtteranceBuilder.build(timeline: timeline, decisions: decisions),
                speakerProfiles: [], timeline: timeline, tokenEvidence: .stub([]),
                routingContext: routingContext,
                baselineDecisions: decisions, l1SentenceDecisions: [], sentenceDecisions: [],
                l2Overrides: [],
                decisions: decisions,
                profileCohesions: [:],
                windowCount: 0, profileCount: 0, otherCount: 0, unresolvedCount: decisions.count,
            )
        }

        let extractionEmbeddings: [Float]
        if let precomputed = precomputedEmbeddings {
            extractionEmbeddings = precomputed
        } else {
            onProgress("speaker", 0, "规划声纹窗口 (\(windows.count))…")
            guard let speaker else { throw Error.speakerEngineRequired }
            let extraction = try AudioPipeline.extractPackedSpeakerEmbeddings(
                fbank80: fbank80, windows: windows, speaker: speaker,
                onProgress: onProgress, shouldCancel: shouldCancel
            )
            if shouldCancel() { throw PipelineCancelled(stage: "speaker") }
            extractionEmbeddings = extraction.embeddings
        }

        return try buildResult(
            timeline: timeline,
            routingContext: routingContext,
            windows: windows,
            embeddings: extractionEmbeddings,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
    }

    private func buildResult(
        timeline: TokenTimeline,
        routingContext: SpeakerRoutingContext,
        windows: [TokenPackedWindowPlanner.Window],
        embeddings: [Float],
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) throws -> Result {
        let expectedEmbeddingCount = windows.count * 192
        guard embeddings.count == expectedEmbeddingCount else {
            throw Error.embeddingShapeMismatch(expected: expectedEmbeddingCount, actual: embeddings.count)
        }
        let chunks = windows.map(Self.sourceTimeRange)
        let clustered = SpeakerOrchestrator(clustering: clustering).cluster(
            embeddings: embeddings,
            chunks: chunks,
            policy: policy,
            onProgress: { stage, fraction in
                onProgress("speaker", 0.80 + 0.15 * fraction, stage)
            },
            shouldCancel: shouldCancel
        )
        // Check cancellation before the label-count guard: the orchestrator
        // returns empty labels when cancelled, and we must surface the
        // cancellation rather than a spurious clustering-output mismatch.
        if shouldCancel() { throw PipelineCancelled(stage: "speaker") }
        if let failure = clustered.failure { throw Error.clusteringInputInvalid(failure) }
        guard clustered.labels.count == windows.count else {
            throw Error.clusteringOutputMismatch(
                expectedLabels: windows.count,
                actualLabels: clustered.labels.count
            )
        }
        let windowLabels = AudioPipeline.relabelSpeakerLabelsByFirstOccurrence(
            labels: clustered.labels,
            chunks: chunks
        )
        var relabeledByRaw: [Int: Int] = [:]
        for index in windowLabels.indices where clustered.labels.indices.contains(index) {
            relabeledByRaw[clustered.labels[index]] = windowLabels[index]
        }
        let centroids = Dictionary(uniqueKeysWithValues: clustered.profiles.compactMap { profile -> (Int, [Float])? in
            guard let rawLabel = profile.acousticLabel, let label = relabeledByRaw[rawLabel] else { return nil }
            return (label, profile.centroidEmbedding)
        })
        guard !centroids.isEmpty else { throw Error.noAcousticProfiles }
        // Cancellation checkpoint between clustering and the evidence/routing
        // chain. For long audio this boundary can save tens of seconds.
        if shouldCancel() { throw PipelineCancelled(stage: "speaker") }
        let evidence = SpeakerEvidenceTimeline(
            timeline: timeline,
            windows: windows,
            embeddings: embeddings,
            profileCentroids: centroids
        )
        let profileCohesions = Self.profileCohesions(
            labels: windowLabels,
            embeddings: embeddings,
            centroids: centroids
        )
        let routed = SpeakerRoutingChain.route(
            timeline: timeline,
            evidence: evidence,
            policy: policy,
            context: routingContext
        )
        let decisions = routed.l2.tokenDecisions
        let utterances = UtteranceBuilder.build(timeline: timeline, decisions: decisions)
        let profiles = Self.buildAcceptedProfiles(
            windows: windows,
            embeddings: embeddings,
            chunks: chunks,
            decisions: decisions,
            policy: policy
        )
        let otherCount = decisions.filter { if case .other = $0.disposition { true } else { false } }.count
        let unresolvedCount = decisions.filter { if case .unresolved = $0.disposition { true } else { false } }.count
        onProgress("speaker", 0.97, "分段平滑 (\(utterances.count) 段)")
        onProgress("speaker", 1, "说话人识别完成 (\(utterances.count) 段, \(profiles.count) 位说话人)")
        return Result(
            utterances: utterances,
            speakerProfiles: profiles,
            timeline: timeline,
            tokenEvidence: evidence,
            routingContext: routingContext,
            baselineDecisions: routed.l1.decisions,
            l1SentenceDecisions: routed.l1.sentenceDecisions,
            sentenceDecisions: routed.l2.sentenceDecisions,
            l2Overrides: routed.l2.overrides,
            decisions: decisions,
            profileCohesions: profileCohesions,
            windowCount: windows.count,
            profileCount: centroids.count,
            otherCount: otherCount,
            unresolvedCount: unresolvedCount
        )
    }

    private static func sourceTimeRange(_ window: TokenPackedWindowPlanner.Window) -> (startMs: Int, endMs: Int) {
        let start = window.spans.map(\.sourceFrames.lowerBound).min() ?? 0
        let end = window.spans.map(\.sourceFrames.upperBound).max() ?? start
        let timebase = AudioTimebase.standard
        return (
            timebase.milliseconds(forFrameCount: start),
            timebase.milliseconds(forFrameCount: max(start + 1, end))
        )
    }

    /// The same quantity used by profile-quality repair: mean packed-window
    /// cosine to the final profile centroid. It is metadata only, persisted
    /// so the Results UI can make a low-cohesion split action visibly
    /// cautious without rerunning speaker embedding extraction.
    private static func profileCohesions(
        labels: [Int],
        embeddings: [Float],
        centroids: [Int: [Float]],
        dimension: Int = 192
    ) -> [Int: Float] {
        var sums: [Int: Float] = [:]
        var counts: [Int: Int] = [:]
        for index in labels.indices {
            let label = labels[index]
            guard let centroid = centroids[label],
                  index * dimension + dimension <= embeddings.count else { continue }
            let embedding = Array(embeddings[(index * dimension)..<((index + 1) * dimension)])
            let score = SpeakerOrchestrator.cosineSimilarity(embedding, centroid)
            guard score.isFinite else { continue }
            sums[label, default: 0] += score
            counts[label, default: 0] += 1
        }
        return Dictionary(uniqueKeysWithValues: sums.compactMap { label, sum in
            guard let count = counts[label], count > 0 else { return nil }
            return (label, sum / Float(count))
        })
    }

    private static func buildAcceptedProfiles(
        windows: [TokenPackedWindowPlanner.Window],
        embeddings: [Float],
        chunks: [(startMs: Int, endMs: Int)],
        decisions: [TokenDecision],
        policy: SpeakerTemporalPolicy
    ) -> [SpeakerProfileData] {
        let labelsByToken = Dictionary(uniqueKeysWithValues: decisions.compactMap { decision -> (TokenTimeline.TokenID, Int)? in
            guard let label = decision.knownLabel else { return nil }
            return (decision.tokenID, label)
        })
        var selectedEmbeddings: [Float] = []
        var selectedChunks: [(startMs: Int, endMs: Int)] = []
        var selectedLabels: [Int] = []
        for index in windows.indices {
            let votes = windows[index].tokenIDs.compactMap { labelsByToken[$0] }
            guard !votes.isEmpty else { continue }
            let counts = Dictionary(grouping: votes, by: { $0 }).mapValues(\.count)
            guard let label = counts.max(by: { left, right in
                left.value == right.value ? left.key > right.key : left.value < right.value
            })?.key,
                  index * 192 + 192 <= embeddings.count else { continue }
            selectedLabels.append(label)
            selectedChunks.append(chunks[index])
            selectedEmbeddings.append(contentsOf: embeddings[(index * 192)..<((index + 1) * 192)])
        }
        return SpeakerProfileAssembler.build(
            labels: selectedLabels,
            chunks: selectedChunks,
            embeddings: selectedEmbeddings,
            dimension: 192,
            policy: policy
        )
    }
}
