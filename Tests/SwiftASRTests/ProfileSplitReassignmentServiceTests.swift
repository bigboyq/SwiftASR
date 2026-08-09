import Testing
@testable import SwiftASR

@Suite("Profile split reassignment")
struct ProfileSplitReassignmentServiceTests {
    private func input() -> SpeakerRecognitionInput {
        SpeakerRecognitionInput(
            audioPath: "/tmp/profile-split.wav",
            sentences: [
                ASRSentence(
                    text: "甲乙",
                    startMs: 0,
                    endMs: 200,
                    tokens: [
                        ASRToken(text: "甲", startMs: 0, endMs: 100),
                        ASRToken(text: "乙", startMs: 100, endMs: 200)
                    ]
                )
            ]
        )
    }

    private func snapshot() -> SpeakerRoutingSnapshot {
        SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1"),
                .init(acousticLabel: 1, speakerLabel: "说话人 2")
            ],
            tokens: [
                .init(
                    sentenceIndex: 0, tokenIndex: 0, text: "甲", startMs: 0, endMs: 100,
                    scores: [0: 0.9, 1: 0.7], supportFrames: 10,
                    baselineAcousticLabel: 0, finalAcousticLabel: 0
                ),
                .init(
                    sentenceIndex: 0, tokenIndex: 1, text: "乙", startMs: 100, endMs: 200,
                    scores: [0: 0.8, 1: 0.6], supportFrames: 10,
                    baselineAcousticLabel: 0, finalAcousticLabel: 0
                )
            ],
            pauseCandidates: []
        )
    }

    @Test func excludesTheEntireSplitSetAndBuildsFreshOperationMergeUnits() throws {
        let operation = try ProfileSplitReassignmentService.derive(
            input: input(),
            snapshot: snapshot(),
            splitProfileLabels: ["说话人 1"]
        )

        #expect(operation.splitProfileLabels == ["说话人 1"])
        #expect(operation.routingSnapshotIdentity == snapshot().stableIdentity)
        #expect(operation.derivedSegments.count == 1)
        #expect(operation.derivedSegments[0].baselineSpeakerLabel == "说话人 1")
        #expect(operation.derivedSegments[0].speakerLabel == "说话人 2")
        #expect(operation.derivedMergedResults.count == 1)
        #expect(operation.derivedMergedResults[0].cleanedContent.isEmpty)
    }

    @Test func legacyV1SnapshotRemainsReplayableWithTheHistoricalProductionPolicy() throws {
        let legacy = SpeakerRoutingSnapshot(
            version: 1,
            profileMappings: snapshot().profileMappings,
            tokens: snapshot().tokens,
            pauseCandidates: [],
            routingPolicy: nil
        )

        let operation = try ProfileSplitReassignmentService.derive(
            input: input(),
            snapshot: legacy,
            splitProfileLabels: ["说话人 1"]
        )

        #expect(operation.routingSnapshotVersion == 1)
        #expect(operation.derivedSegments.map(\.speakerLabel) == ["说话人 2"])
    }

    @Test func previewFlagsASingleDestinationAboveSeventyPercent() throws {
        let base = snapshot()
        let snapshotWithCohesion = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1", cohesion: 0.64),
                .init(acousticLabel: 1, speakerLabel: "说话人 2", cohesion: 0.82)
            ],
            tokens: base.tokens,
            pauseCandidates: base.pauseCandidates
        )
        let operation = try ProfileSplitReassignmentService.derive(
            input: input(),
            snapshot: snapshotWithCohesion,
            splitProfileLabels: ["说话人 1"]
        )

        let preview = ProfileSplitReassignmentService.preview(
            operation: operation,
            sourceProfileLabel: "说话人 1",
            snapshot: snapshotWithCohesion
        )
        #expect(preview.cohesion == 0.64)
        #expect(preview.totalSentenceCount == 1)
        #expect(preview.destinations == [.init(speakerLabel: "说话人 2", sentenceCount: 1)])
        #expect(preview.dominantDestination == .init(speakerLabel: "说话人 2", sentenceCount: 1))
        #expect(preview.dominantRatio == 1)
    }

    @Test func cohesionFallsBackToPersistedTokenEvidenceForOldSnapshots() {
        // `snapshot()` has no new centroid-cohesion metadata. Its two S1
        // tokens carry scores 0.9 and 0.8 with equal support, so the old-job
        // caution proxy remains available at 0.85.
        #expect(ProfileSplitReassignmentService.cohesion(
            for: "说话人 1",
            snapshot: snapshot()
        ) == 0.85)
    }

    @Test func highSourceCohesionRequiresConfirmationEvenWithoutDominantDestination() {
        let highCohesion = ProfileSplitReassignmentService.SplitPreview(
            sourceProfileLabel: "说话人 1",
            cohesion: 0.70,
            totalSentenceCount: 10,
            destinations: [
                .init(speakerLabel: "说话人 2", sentenceCount: 6),
                .init(speakerLabel: "说话人 3", sentenceCount: 4)
            ]
        )
        let lowCohesion = ProfileSplitReassignmentService.SplitPreview(
            sourceProfileLabel: "说话人 1",
            cohesion: 0.56,
            totalSentenceCount: 10,
            destinations: [
                .init(speakerLabel: "说话人 2", sentenceCount: 6),
                .init(speakerLabel: "说话人 3", sentenceCount: 4)
            ]
        )
        #expect(highCohesion.dominantDestination == nil)
        #expect(highCohesion.requiresSplitConfirmation)
        #expect(!lowCohesion.requiresSplitConfirmation)
    }

    @Test func rejectsAProfileThatDoesNotExistInTheRoutingSnapshot() {
        #expect(throws: ProfileSplitReassignmentError.unknownSplitProfile("说话人 9")) {
            try ProfileSplitReassignmentService.derive(
                input: input(),
                snapshot: snapshot(),
                splitProfileLabels: ["说话人 9"]
            )
        }
    }

    @Test func doesNotRedistributeTokensOutsideTheSelectedBaselineProfile() throws {
        let frozenInput = SpeakerRecognitionInput(
            audioPath: "/tmp/profile-split-freeze.wav",
            sentences: [ASRSentence(
                text: "甲乙", startMs: 0, endMs: 200,
                tokens: [
                    ASRToken(text: "甲", startMs: 0, endMs: 100),
                    ASRToken(text: "乙", startMs: 100, endMs: 200)
                ]
            )]
        )
        let frozenSnapshot = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1"),
                .init(acousticLabel: 1, speakerLabel: "说话人 2")
            ],
            tokens: [
                // Selected S1 token should be reassigned to S2.
                .init(
                    sentenceIndex: 0, tokenIndex: 0, text: "甲", startMs: 0, endMs: 100,
                    scores: [0: 0.90, 1: 0.80], supportFrames: 10,
                    baselineAcousticLabel: 0, finalAcousticLabel: 0
                ),
                // Its raw TOP1 is S1, but the baseline sentence routing has
                // committed it to S2. Splitting S1 must not reopen this token.
                .init(
                    sentenceIndex: 0, tokenIndex: 1, text: "乙", startMs: 100, endMs: 200,
                    scores: [0: 0.99, 1: 0.10], supportFrames: 10,
                    baselineAcousticLabel: 1, finalAcousticLabel: 1
                )
            ],
            pauseCandidates: []
        )

        let operation = try ProfileSplitReassignmentService.derive(
            input: frozenInput,
            snapshot: frozenSnapshot,
            splitProfileLabels: ["说话人 1"]
        )
        #expect(operation.derivedSegments.map(\.baselineSpeakerLabel) == ["说话人 1", "说话人 2"])
        #expect(operation.derivedSegments.map(\.speakerLabel) == ["说话人 2", "说话人 2"])
    }

    @Test func keepsFrozenOneTokenSentenceDirectBetweenReassignedNeighbours() throws {
        let input = SpeakerRecognitionInput(
            audioPath: "/tmp/profile-split-boundary.wav",
            sentences: [
                ASRSentence(text: "甲", startMs: 0, endMs: 100,
                            tokens: [ASRToken(text: "甲", startMs: 0, endMs: 100)]),
                ASRSentence(text: "乙", startMs: 100, endMs: 200,
                            tokens: [ASRToken(text: "乙", startMs: 100, endMs: 200)]),
                ASRSentence(text: "丙", startMs: 200, endMs: 300,
                            tokens: [ASRToken(text: "丙", startMs: 200, endMs: 300)])
            ]
        )
        let snapshot = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1"),
                .init(acousticLabel: 1, speakerLabel: "说话人 2"),
                .init(acousticLabel: 2, speakerLabel: "说话人 3")
            ],
            tokens: [
                // Both neighbours are selected S1 tokens. Excluding S1
                // gives them a finite-margin direct decision for S2.
                .init(sentenceIndex: 0, tokenIndex: 0, text: "甲", startMs: 0, endMs: 100,
                      scores: [0: 0.9, 1: 0.8, 2: 0.6], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                // This stable S2 token must remain a direct S2. If its
                // synthetic frozen score has no runner-up, L1 leaves it
                // pending and L2 excludes S2 between the two S2 anchors.
                .init(sentenceIndex: 1, tokenIndex: 0, text: "乙", startMs: 100, endMs: 200,
                      scores: [0: 0.3, 1: 0.8, 2: 0.2], supportFrames: 10,
                      baselineAcousticLabel: 1, finalAcousticLabel: 1),
                .init(sentenceIndex: 2, tokenIndex: 0, text: "丙", startMs: 200, endMs: 300,
                      scores: [0: 0.9, 1: 0.8, 2: 0.6], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0)
            ],
            pauseCandidates: []
        )

        let operation = try ProfileSplitReassignmentService.derive(
            input: input,
            snapshot: snapshot,
            splitProfileLabels: ["说话人 1"]
        )

        #expect(operation.derivedSegments.map(\.speakerLabel) == ["说话人 2", "说话人 2", "说话人 2"])
    }

    @Test func preservesNonSplitTokensInsideASentenceThatIsOtherwiseReassigned() throws {
        let input = SpeakerRecognitionInput(
            audioPath: "/tmp/profile-split-mixed-sentence.wav",
            sentences: [ASRSentence(
                text: "甲乙丙", startMs: 0, endMs: 300,
                tokens: [
                    ASRToken(text: "甲", startMs: 0, endMs: 100),
                    ASRToken(text: "乙", startMs: 100, endMs: 200),
                    ASRToken(text: "丙", startMs: 200, endMs: 300)
                ]
            )]
        )
        let snapshot = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1"),
                .init(acousticLabel: 1, speakerLabel: "说话人 2"),
                .init(acousticLabel: 2, speakerLabel: "说话人 3")
            ],
            tokens: [
                // Two selected S1 tokens make the sentence-level replay
                // choose S3 once S1 is excluded.
                .init(sentenceIndex: 0, tokenIndex: 0, text: "甲", startMs: 0, endMs: 100,
                      scores: [0: 0.9, 1: 0.1, 2: 0.8], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                .init(sentenceIndex: 0, tokenIndex: 1, text: "乙", startMs: 100, endMs: 200,
                      scores: [0: 0.9, 1: 0.1, 2: 0.8], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                // This S2 token shares the original ASR sentence, but it is
                // not in Split Set and therefore must remain exactly S2.
                .init(sentenceIndex: 0, tokenIndex: 2, text: "丙", startMs: 200, endMs: 300,
                      scores: [0: 0.2, 1: 0.8, 2: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 1, finalAcousticLabel: 1)
            ],
            pauseCandidates: []
        )

        let operation = try ProfileSplitReassignmentService.derive(
            input: input,
            snapshot: snapshot,
            splitProfileLabels: ["说话人 1"]
        )

        #expect(operation.derivedSegments.map(\.baselineSpeakerLabel) == ["说话人 1", "说话人 2"])
        #expect(operation.derivedSegments.map(\.speakerLabel) == ["说话人 3", "说话人 2"])
        #expect(operation.derivedSegments.map(\.rawText) == ["甲乙", "丙"])
    }

    @Test func clampsOverlappingInputSentenceBoundariesAndPassesPayloadValidation() throws {
        let input = SpeakerRecognitionInput(
            audioPath: "/tmp/profile-split-overlapping-sentences.wav",
            sentences: [
                ASRSentence(
                    text: "甲乙", startMs: 0, endMs: 200,
                    tokens: [
                        ASRToken(text: "甲", startMs: 0, endMs: 100),
                        ASRToken(text: "乙", startMs: 100, endMs: 200)
                    ]
                ),
                ASRSentence(
                    text: "丙丁", startMs: 150, endMs: 350,
                    tokens: [
                        ASRToken(text: "丙", startMs: 150, endMs: 250),
                        ASRToken(text: "丁", startMs: 250, endMs: 350)
                    ]
                )
            ]
        )
        let snapshot = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1"),
                .init(acousticLabel: 1, speakerLabel: "说话人 2")
            ],
            tokens: [
                .init(sentenceIndex: 0, tokenIndex: 0, text: "甲", startMs: 0, endMs: 100,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                .init(sentenceIndex: 0, tokenIndex: 1, text: "乙", startMs: 100, endMs: 200,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                .init(sentenceIndex: 1, tokenIndex: 0, text: "丙", startMs: 150, endMs: 250,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                .init(sentenceIndex: 1, tokenIndex: 1, text: "丁", startMs: 250, endMs: 350,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0)
            ],
            pauseCandidates: []
        )

        let operation = try ProfileSplitReassignmentService.derive(
            input: input,
            snapshot: snapshot,
            splitProfileLabels: ["说话人 1"]
        )

        #expect(operation.derivedSegments.count == 2)
        #expect(operation.derivedSegments[0].startMs == 0)
        #expect(operation.derivedSegments[0].endMs == 200)
        // Segment 1 startMs must be clamped from 150 to 200 to eliminate the overlap with Segment 0
        #expect(operation.derivedSegments[1].startMs == 200)
        #expect(operation.derivedSegments[1].endMs == 350)

        // The production baseline groups globally time-ordered, same-label
        // tokens across ASR sentence boundaries into one utterance.
        let timeline = TokenTimeline(sentences: input.sentences, totalFrames: 35)
        let decisions = timeline.tokens.map {
            TokenDecision(
                tokenID: $0.id,
                disposition: .accepted(label: 0, source: .direct, confidence: 0.9)
            )
        }
        let utterances = UtteranceBuilder.build(timeline: timeline, decisions: decisions)
        var payload = ResultPayload.from(
            utterances: utterances,
            audioPath: input.audioPath,
            jobId: "overlap-clamp-job"
        )
        payload.speakerSplitOperation = operation
        #expect(throws: Never.self) {
            try payload.validate()
        }
    }

    @Test func followsBaselineTimeOrderWhenCrossBatchTokensInvertSentenceOrder() throws {
        let input = SpeakerRecognitionInput(
            audioPath: "/tmp/profile-split-inverted-sentences.wav",
            sentences: [
                ASRSentence(
                    text: "甲乙", startMs: 0, endMs: 300,
                    tokens: [
                        ASRToken(text: "甲", startMs: 0, endMs: 100),
                        ASRToken(text: "乙", startMs: 200, endMs: 300)
                    ]
                ),
                ASRSentence(
                    text: "丙丁", startMs: 150, endMs: 400,
                    tokens: [
                        ASRToken(text: "丙", startMs: 150, endMs: 250),
                        ASRToken(text: "丁", startMs: 300, endMs: 400)
                    ]
                )
            ]
        )
        let snapshot = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1"),
                .init(acousticLabel: 1, speakerLabel: "说话人 2")
            ],
            tokens: [
                .init(sentenceIndex: 0, tokenIndex: 0, text: "甲", startMs: 0, endMs: 100,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                .init(sentenceIndex: 0, tokenIndex: 1, text: "乙", startMs: 200, endMs: 300,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                .init(sentenceIndex: 1, tokenIndex: 0, text: "丙", startMs: 150, endMs: 250,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                .init(sentenceIndex: 1, tokenIndex: 1, text: "丁", startMs: 300, endMs: 400,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0)
            ],
            pauseCandidates: []
        )

        let operation = try ProfileSplitReassignmentService.derive(
            input: input,
            snapshot: snapshot,
            splitProfileLabels: ["说话人 1"]
        )
        #expect(operation.derivedSegments.map(\.rawText).joined() == "甲丙乙丁")
        for pair in zip(operation.derivedSegments, operation.derivedSegments.dropFirst()) {
            #expect(pair.0.endMs <= pair.1.startMs)
        }

        let timeline = TokenTimeline(sentences: input.sentences, totalFrames: 40)
        let decisions = timeline.tokens.map {
            TokenDecision(
                tokenID: $0.id,
                disposition: .accepted(label: 0, source: .direct, confidence: 0.9)
            )
        }
        var payload = ResultPayload.from(
            utterances: UtteranceBuilder.build(timeline: timeline, decisions: decisions),
            audioPath: input.audioPath,
            jobId: "inverted-overlap-job"
        )
        payload.speakerSplitOperation = operation
        #expect(throws: Never.self) {
            try payload.validate()
        }
    }

    @Test func nestedTokenRangeUsesTheRunMaximumEndLikeBaselineBuilder() throws {
        let input = SpeakerRecognitionInput(
            audioPath: "/tmp/profile-split-nested-token.wav",
            sentences: [ASRSentence(
                text: "甲乙",
                startMs: 0,
                endMs: 300,
                tokens: [
                    ASRToken(text: "甲", startMs: 0, endMs: 300),
                    ASRToken(text: "乙", startMs: 100, endMs: 200)
                ]
            )]
        )
        let snapshot = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1"),
                .init(acousticLabel: 1, speakerLabel: "说话人 2")
            ],
            tokens: [
                .init(sentenceIndex: 0, tokenIndex: 0, text: "甲", startMs: 0, endMs: 300,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0),
                .init(sentenceIndex: 0, tokenIndex: 1, text: "乙", startMs: 100, endMs: 200,
                      scores: [0: 0.9, 1: 0.1], supportFrames: 10,
                      baselineAcousticLabel: 0, finalAcousticLabel: 0)
            ],
            pauseCandidates: []
        )

        let operation = try ProfileSplitReassignmentService.derive(
            input: input,
            snapshot: snapshot,
            splitProfileLabels: ["说话人 1"]
        )

        #expect(operation.derivedSegments.count == 1)
        #expect(operation.derivedSegments[0].startMs == 0)
        #expect(operation.derivedSegments[0].endMs == 300)
    }

}
