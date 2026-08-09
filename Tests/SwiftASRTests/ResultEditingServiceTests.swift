import Foundation
import Testing
@testable import SwiftASR

@Suite("ResultEditingService")
struct ResultEditingServiceTests {
    @Test func manualEditInitializesCompleteEditablePreviewWithoutChangingRawSegments() {
        let originalSegments = [
            ResultSegment(segmentId: 10, startMs: 0, endMs: 1_000, speakerLabel: "Speaker1", rawText: "原始第一句"),
            ResultSegment(segmentId: 11, startMs: 1_000, endMs: 2_000, speakerLabel: "Speaker2", rawText: "原始第二句")
        ]
        var payload = ResultPayload(jobId: "job", audioPath: "/tmp/audio.wav", segments: originalSegments)
        payload.buildMergedResults()

        let edited = ResultEditingService.applyingManualEdit(
            to: payload,
            mergeId: payload.mergedResults[0].mergeId,
            text: "人工修改后的第一段"
        )

        #expect(edited?.segments == originalSegments)
        #expect(edited?.mergedResults[0].cleanedContent == "人工修改后的第一段")
        #expect(edited?.mergedResults[1].cleanedContent == payload.mergedResults[1].rawContent)
        #expect(edited?.mergedResults.allSatisfy { !$0.cleanedContent.isEmpty } == true)
    }

    @Test func manualEditRejectsEmptyTextAndUnknownParagraph() {
        var payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: [ResultSegment(segmentId: 1, startMs: 0, endMs: 1, speakerLabel: "Speaker1", rawText: "原文")]
        )
        payload.buildMergedResults()

        #expect(ResultEditingService.applyingManualEdit(to: payload, mergeId: 0, text: "  ") == nil)
        #expect(ResultEditingService.applyingManualEdit(to: payload, mergeId: 99, text: "修改") == nil)
    }

    @Test func manualEditTargetsSplitOperationCleanupOnly() {
        let baselineMerged = MergedResult(
            mergeId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S1", rawContent: "基线", cleanedContent: "基线润色"
        )
        let payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: [ResultSegment(segmentId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S1", rawText: "基线")],
            mergedResults: [baselineMerged],
            speakerSplitOperation: SpeakerSplitOperation(
                splitProfileLabels: ["S1"],
                routingSnapshotVersion: 1,
                routingSnapshotIdentity: "snapshot",
                derivedAt: "2026-07-26T00:00:00Z",
                derivedSegments: [
                    SpeakerSplitDerivedSegment(
                        segmentId: 1, startMs: 0, endMs: 1_000,
                        baselineSpeakerLabel: "S1", speakerLabel: "S2", rawText: "派生"
                    )
                ],
                derivedMergedResults: [
                    MergedResult(mergeId: 1, startMs: 0, endMs: 1_000, speakerLabel: "S2", rawContent: "派生")
                ]
            )
        )

        let edited = ResultEditingService.applyingManualEdit(
            to: payload,
            mergeId: 1,
            text: "派生修改",
            speakerLabel: "S1"
        )
        #expect(edited?.mergedResults == [baselineMerged])
        #expect(edited?.speakerSplitOperation?.derivedMergedResults[0].cleanedContent == "派生修改")
        #expect(edited?.speakerSplitOperation?.derivedMergedResults[0].speakerLabel == "S2")
        #expect(edited?.speakerSplitOperation?.derivedMergedResults[0].manualSpeakerLabel == "S1")
    }

    @Test func manualSpeakerAssignmentKeepsAutomaticSegmentsAndCanBeRestored() throws {
        let originalSegments = [
            ResultSegment(
                segmentId: 1, startMs: 0, endMs: 1_000,
                speakerLabel: "S1", rawText: "第一段"
            ),
            ResultSegment(
                segmentId: 2, startMs: 1_000, endMs: 2_000,
                speakerLabel: "S2", rawText: "第二段"
            ),
        ]
        var payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: originalSegments,
            speakers: [
                ResultSpeaker(speakerLabel: "S1"),
                ResultSpeaker(speakerLabel: "S2"),
            ]
        )
        payload.buildMergedResults()

        let speakerOnly = try #require(ResultEditingService.applyingManualEdit(
            to: payload,
            mergeId: 1,
            text: payload.mergedResults[0].rawContent,
            speakerLabel: "S2"
        ))
        #expect(speakerOnly.mergedResults[0].manualSpeakerLabel == "S2")
        #expect(speakerOnly.mergedResults.allSatisfy { $0.cleanedContent.isEmpty })

        let assigned = try #require(ResultEditingService.applyingManualEdit(
            to: payload,
            mergeId: 1,
            text: "第一段修订",
            speakerLabel: "S2"
        ))
        #expect(assigned.segments == originalSegments)
        #expect(assigned.mergedResults[0].speakerLabel == "S1")
        #expect(assigned.mergedResults[0].manualSpeakerLabel == "S2")
        #expect(assigned.mergedResults[0].effectiveSpeakerLabel == "S2")

        let restored = try #require(ResultEditingService.applyingManualEdit(
            to: assigned,
            mergeId: 1,
            text: "第一段修订",
            speakerLabel: "S1"
        ))
        #expect(restored.mergedResults[0].manualSpeakerLabel == nil)
        #expect(restored.mergedResults[0].effectiveSpeakerLabel == "S1")
        #expect(ResultEditingService.applyingManualEdit(
            to: payload,
            mergeId: 1,
            text: "第一段修订",
            speakerLabel: "不存在"
        ) == nil)
    }

    @Test func manualSpeakerAssignmentDrivesPreviewPromptAndSurvivesCleanupRebuild() {
        let segment = ResultSegment(
            segmentId: 1,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "S1",
            rawText: "原文。"
        )
        let assigned = MergedResult(
            mergeId: 1,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "S1",
            manualSpeakerLabel: "S2",
            rawContent: "原文。",
            cleanedContent: "旧润色"
        )

        let display = SegmentMerger().buildDisplaySegments(
            mergedResults: [assigned],
            speakerNames: ["S1": "甲", "S2": "乙"],
            showRawText: true
        )
        #expect(display.first?.displaySpeakerName == "乙")
        #expect(display.first?.speakerLabel == "S2")

        let prompt = GeminiProvider.buildPrompt(
            mergedResults: [assigned],
            speakerNames: ["S1": "甲", "S2": "乙"],
            glossary: []
        )
        #expect(prompt.contains("[0] 乙: 原文。"))
        #expect(!prompt.contains("[0] 甲: 原文。"))

        let rebuilt = SegmentMerger().buildMergedResults(
            segments: [segment],
            preservingManualAssignmentsFrom: [assigned]
        )
        #expect(rebuilt.first?.speakerLabel == "S1")
        #expect(rebuilt.first?.manualSpeakerLabel == "S2")
        #expect(rebuilt.first?.cleanedContent.isEmpty == true)
    }

    @Test func mergedRowCanRestoreAllAutomaticSpeakersWithoutChangingText() throws {
        let automaticLabels = ["S1", "S3", "S5"]
        let segments = automaticLabels.enumerated().map { offset, label in
            ResultSegment(
                segmentId: offset + 1,
                startMs: offset * 1_000,
                endMs: (offset + 1) * 1_000,
                speakerLabel: label,
                rawText: "原文\(offset + 1)"
            )
        }
        let assignedResults = automaticLabels.enumerated().map { offset, label in
            MergedResult(
                mergeId: offset + 1,
                startMs: offset * 1_000,
                endMs: (offset + 1) * 1_000,
                speakerLabel: label,
                manualSpeakerLabel: "S2",
                rawContent: "原文\(offset + 1)",
                cleanedContent: "修订\(offset + 1)"
            )
        }
        let payload = ResultPayload(
            jobId: "job",
            audioPath: "/tmp/audio.wav",
            segments: segments,
            speakers: (automaticLabels + ["S2"]).map {
                ResultSpeaker(speakerLabel: $0)
            },
            mergedResults: assignedResults
        )

        let collapsed = SegmentMerger().buildDisplaySegments(
            mergedResults: payload.mergedResults,
            showRawText: true
        )
        #expect(collapsed.count == 1)
        #expect(collapsed[0].sourceSegmentIDs == [1, 2, 3])

        let restored = try #require(
            ResultEditingService.clearingManualSpeakerAssignments(
                from: payload,
                mergeIDs: collapsed[0].sourceSegmentIDs
            )
        )
        #expect(restored.mergedResults.map(\.speakerLabel) == automaticLabels)
        #expect(restored.mergedResults.allSatisfy { $0.manualSpeakerLabel == nil })
        #expect(restored.mergedResults.map(\.cleanedContent) == ["修订1", "修订2", "修订3"])

        let expanded = SegmentMerger().buildDisplaySegments(
            mergedResults: restored.mergedResults,
            showRawText: true
        )
        #expect(expanded.count == 3)
        #expect(expanded.map(\.speakerLabel) == automaticLabels)
    }

    @Test func legacyMergedResultWithoutManualSpeakerDecodesAsAutomatic() throws {
        let data = Data("""
        {
          "merge_id": 1,
          "start_ms": 0,
          "end_ms": 1000,
          "speaker_label": "S1",
          "raw_content": "原文",
          "cleaned_content": ""
        }
        """.utf8)
        let result = try JSONDecoder().decode(MergedResult.self, from: data)
        #expect(result.manualSpeakerLabel == nil)
        #expect(result.effectiveSpeakerLabel == "S1")

        var assigned = result
        assigned.manualSpeakerLabel = "S2"
        let roundTripped = try JSONDecoder().decode(
            MergedResult.self,
            from: JSONEncoder().encode(assigned)
        )
        #expect(roundTripped.speakerLabel == "S1")
        #expect(roundTripped.manualSpeakerLabel == "S2")
        #expect(roundTripped.effectiveSpeakerLabel == "S2")
    }
}
