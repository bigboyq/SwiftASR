import Testing
@testable import SwiftASR

@Suite("Results export presentation")
struct ResultsExportPresentationTests {
    @Test func excludedSpeakersProduceNoExportableSegments() {
        let payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: [ResultSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 1",
                rawText: "内容"
            )]
        )

        let display = ResultsPresentation.segmentList(
            payload: payload,
            includedLabels: [],
            showMerged: false,
            showRawText: true,
            hasCompleteCleanedResults: false,
            speakerNames: [:]
        )

        #expect(display.isEmpty)
    }

    @Test func incompleteCleanedPreviewProducesNoExportableMergedSegments() {
        let payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: [ResultSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 1",
                rawText: "原文"
            )],
            mergedResults: [MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 1",
                rawContent: "原文",
                cleanedContent: "",
                wasLLMFailure: false
            )]
        )

        let display = ResultsPresentation.segmentList(
            payload: payload,
            includedLabels: ["说话人 1"],
            showMerged: true,
            showRawText: false,
            hasCompleteCleanedResults: false,
            speakerNames: [:]
        )

        #expect(display.isEmpty)
    }

    @Test func mergedDisplayRetainsSourceIDsForNavigation() {
        let payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: [
                ResultSegment(segmentId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S1", rawText: "甲"),
                ResultSegment(segmentId: 2, startMs: 1_000, endMs: 2_000, speakerLabel: "S2", rawText: "乙")
            ],
            speakers: [],
            mergedResults: [
                MergedResult(mergeId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S1", rawContent: "甲"),
                MergedResult(mergeId: 2, startMs: 1_000, endMs: 2_000, speakerLabel: "S2", rawContent: "乙")
            ]
        )

        let display = ResultsPresentation.segmentList(
            payload: payload,
            includedLabels: ["S1", "S2"],
            showMerged: true,
            showRawText: true,
            hasCompleteCleanedResults: false,
            speakerNames: ["S1": "同一人", "S2": "同一人"]
        )

        #expect(display.count == 1)
        #expect(display[0].sourceSegmentIDs == [1, 2])
        #expect(!display[0].hasSingleSource,
                "多来源展示行必须先还原说话人，不能只编辑第一个 MergedResult")
    }

    @Test func projectionKeepsHeaderPanelAndRowsOnSameSnapshot() {
        let payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: [
                ResultSegment(segmentId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S1", rawText: "甲"),
                ResultSegment(segmentId: 2, startMs: 1_000, endMs: 3_000, speakerLabel: "S2", rawText: "乙")
            ],
            speakers: [
                ResultSpeaker(speakerLabel: "S1"),
                ResultSpeaker(speakerLabel: "S2")
            ]
        )

        let projection = ResultsPresentation.projection(
            payload: payload,
            includedLabels: ["S1"],
            showMerged: false,
            showRawText: true,
            speakerNames: ["S1": "同一人", "S2": "同一人"]
        )

        #expect(projection.activeSegments.count == 2)
        #expect(projection.speakerPanelLabels == ["S1", "S2"])
        #expect(projection.speakerDurations == ["S1": 1_000, "S2": 2_000])
        #expect(projection.uniqueNamedSpeakerCount == 1)
        #expect(projection.displaySegments.count == 1)
        #expect(projection.displaySegments[0].speakerLabel == "S1")
    }

    @Test func splitOperationUsesDerivedSentenceAndRetainsBaselineTransition() {
        let payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: [
                ResultSegment(segmentId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S1", rawText: "基线")
            ],
            mergedResults: [
                MergedResult(mergeId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S1", rawContent: "基线")
            ],
            speakerSplitOperation: SpeakerSplitOperation(
                splitProfileLabels: ["S1"],
                routingSnapshotVersion: 1,
                routingSnapshotIdentity: "snapshot",
                derivedAt: "2026-07-26T00:00:00Z",
                derivedSegments: [
                    SpeakerSplitDerivedSegment(
                        segmentId: 1,
                        startMs: 0,
                        endMs: 1_000,
                        baselineSpeakerLabel: "S1",
                        speakerLabel: "S2",
                        rawText: "派生"
                    )
                ],
                derivedMergedResults: [
                    MergedResult(mergeId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S2", rawContent: "派生")
                ]
            )
        )

        let sentences = ResultsPresentation.segmentList(
            payload: payload,
            includedLabels: ["S2"],
            showMerged: false,
            showRawText: true,
            hasCompleteCleanedResults: false,
            speakerNames: [:]
        )
        #expect(sentences.count == 1)
        #expect(sentences[0].speakerLabel == "S2")
        #expect(sentences[0].baselineSpeakerLabel == "S1")
        #expect(sentences[0].text == "派生")

        let merged = ResultsPresentation.segmentList(
            payload: payload,
            includedLabels: ["S2"],
            showMerged: true,
            showRawText: true,
            hasCompleteCleanedResults: false,
            speakerNames: [:]
        )
        #expect(merged.count == 1)
        #expect(merged[0].speakerLabel == "S2")
        #expect(merged[0].text == "派生。")

        // 即使 S1 的所有句子都被重归属，左侧面板仍必须保留它，
        // 否则用户无法取消该 Split Set 成员。
        #expect(ResultsPresentation.speakerPanelLabels(in: payload) == ["S1", "S2"])
    }
}
