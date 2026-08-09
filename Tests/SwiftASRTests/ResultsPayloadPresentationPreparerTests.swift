import Testing
@testable import SwiftASR

@Suite("Results payload presentation preparation")
struct ResultsPayloadPresentationPreparerTests {
    @Test("normalizes prefixes in baseline merged results")
    @MainActor
    func normalizesBaselinePrefixes() {
        var payload = ResultPayload(
            jobId: "baseline",
            audioPath: "/tmp/baseline.wav",
            segments: [],
            mergedResults: [
                MergedResult(
                    mergeId: 1,
                    startMs: 0,
                    endMs: 1_000,
                    speakerLabel: "Speaker0",
                    rawContent: "原文",
                    cleanedContent: "张三：润色结果"
                ),
                MergedResult(
                    mergeId: 2,
                    startMs: 1_000,
                    endMs: 2_000,
                    speakerLabel: "Speaker1",
                    rawContent: "原文",
                    cleanedContent: ""
                )
            ]
        )

        let changed = ResultsPayloadPresentationPreparer
            .normalizeCleanedSpeakerPrefixes(
                &payload,
                speakerNames: ["Speaker0": "张三"]
            )

        #expect(changed)
        #expect(payload.mergedResults[0].cleanedContent == "润色结果")
        #expect(payload.mergedResults[1].cleanedContent.isEmpty)
    }

    @Test("normalizes prefixes using the manual speaker assignment")
    @MainActor
    func normalizesManualSpeakerPrefix() {
        var payload = ResultPayload(
            jobId: "manual-speaker",
            audioPath: "/tmp/manual.wav",
            segments: [],
            mergedResults: [
                MergedResult(
                    mergeId: 1,
                    startMs: 0,
                    endMs: 1_000,
                    speakerLabel: "Speaker0",
                    manualSpeakerLabel: "Speaker1",
                    rawContent: "原文",
                    cleanedContent: "李四：润色结果"
                )
            ]
        )

        let changed = ResultsPayloadPresentationPreparer
            .normalizeCleanedSpeakerPrefixes(
                &payload,
                speakerNames: ["Speaker0": "张三", "Speaker1": "李四"]
            )

        #expect(changed)
        #expect(payload.mergedResults[0].cleanedContent == "润色结果")
        #expect(payload.mergedResults[0].manualSpeakerLabel == "Speaker1")
    }

    @Test("normalizes only the active split operation")
    @MainActor
    func normalizesSplitOperationPrefixes() {
        var payload = ResultPayload(
            jobId: "split",
            audioPath: "/tmp/split.wav",
            segments: [],
            mergedResults: [
                MergedResult(
                    mergeId: 1,
                    startMs: 0,
                    endMs: 1_000,
                    speakerLabel: "Speaker0",
                    rawContent: "基线",
                    cleanedContent: "Speaker0：保留基线"
                )
            ],
            speakerSplitOperation: SpeakerSplitOperation(
                splitProfileLabels: ["Speaker0"],
                routingSnapshotVersion: 1,
                routingSnapshotIdentity: "snapshot",
                derivedAt: "2026-07-29T00:00:00Z",
                derivedSegments: [],
                derivedMergedResults: [
                    MergedResult(
                        mergeId: 1,
                        startMs: 0,
                        endMs: 1_000,
                        speakerLabel: "Speaker2",
                        rawContent: "派生",
                        cleanedContent: "Speaker2：派生润色"
                    )
                ]
            )
        )

        let changed = ResultsPayloadPresentationPreparer
            .normalizeCleanedSpeakerPrefixes(&payload, speakerNames: [:])

        #expect(changed)
        #expect(payload.mergedResults[0].cleanedContent == "Speaker0：保留基线")
        #expect(
            payload.speakerSplitOperation?.derivedMergedResults[0].cleanedContent
                == "派生润色"
        )
    }

    @Test("restores the warning prefix for legacy LLM fallback rows")
    @MainActor
    func normalizesLegacyLLMFailureFallbacks() {
        var payload = ResultPayload(
            jobId: "legacy-fallback",
            audioPath: "/tmp/fallback.wav",
            segments: [],
            mergedResults: [
                MergedResult(
                    mergeId: 1,
                    startMs: 0,
                    endMs: 1_000,
                    speakerLabel: "Speaker0",
                    rawContent: "嗯。",
                    cleanedContent: "嗯。",
                    wasLLMFailure: true
                )
            ]
        )

        let changed = ResultsPayloadPresentationPreparer
            .normalizeLLMFailureFallbacks(&payload)

        #expect(changed)
        #expect(payload.mergedResults[0].cleanedContent == "⚠️嗯。")
        #expect(payload.mergedResults[0].wasLLMFailure)
        #expect(!ResultsPayloadPresentationPreparer.normalizeLLMFailureFallbacks(&payload))
    }
}
