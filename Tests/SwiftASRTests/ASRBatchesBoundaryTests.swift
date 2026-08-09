import Foundation
import Testing
@testable import SwiftASR

@Suite struct ASRBatchesBoundaryTests {
    @Test func gapThresholdExactBoundary() {
        let totalMs = 100_000

        // gap = 1200ms: merged into single batch
        let atBoundary = AudioPipeline.asrBatches(
            from: [(0, 2_000), (3_200, 5_000)],
            totalDurationMs: totalMs,
            maxBatchMs: 60_000,
            maxMergeGapMs: 1_200,
            targetMergeDurationMs: 15_000
        )
        #expect(atBoundary.count == 1)
        #expect(atBoundary[0].startMs == 0)
        #expect(atBoundary[0].endMs == 5_000)

        // gap = 1201ms: exceeds 1200ms gap threshold, remains 2 batches
        let overBoundary = AudioPipeline.asrBatches(
            from: [(0, 2_000), (3_201, 5_000)],
            totalDurationMs: totalMs,
            maxBatchMs: 60_000,
            maxMergeGapMs: 1_200,
            targetMergeDurationMs: 15_000
        )
        #expect(overBoundary.count == 2)
        #expect(overBoundary[0] == (0, 2_000))
        #expect(overBoundary[1] == (3_201, 5_000))
    }

    @Test func targetDurationExactBoundary() {
        let totalMs = 100_000

        // Combined duration = 15,000ms: merged into single batch
        let atBoundary = AudioPipeline.asrBatches(
            from: [(0, 5_000), (6_000, 15_000)],
            totalDurationMs: totalMs,
            maxBatchMs: 60_000,
            maxMergeGapMs: 1_200,
            targetMergeDurationMs: 15_000
        )
        #expect(atBoundary.count == 1)
        #expect(atBoundary[0] == (0, 15_000))

        // Combined duration = 15,001ms: exceeds 15s limit, remains 2 batches
        let overBoundary = AudioPipeline.asrBatches(
            from: [(0, 5_000), (6_000, 15_001)],
            totalDurationMs: totalMs,
            maxBatchMs: 60_000,
            maxMergeGapMs: 1_200,
            targetMergeDurationMs: 15_000
        )
        #expect(overBoundary.count == 2)
        #expect(overBoundary[0] == (0, 5_000))
        #expect(overBoundary[1] == (6_000, 15_001))
    }

    @Test func overlongSegmentSplittingAndTailPadding() {
        let totalMs = 100_000

        // Segment longer than maxBatchMs (60s) splits into maxBatchMs chunks
        let longSeg = AudioPipeline.asrBatches(
            from: [(0, 75_000)],
            totalDurationMs: totalMs,
            maxBatchMs: 60_000
        )
        #expect(longSeg.count == 2)
        #expect(longSeg[0] == (0, 60_000))
        #expect(longSeg[1] == (60_000, 75_000))

        // Short standalone segment padded to minBatchMs (500ms)
        let shortSeg = AudioPipeline.asrBatches(
            from: [(10_000, 10_100)],
            totalDurationMs: totalMs,
            maxBatchMs: 60_000,
            minBatchMs: 500
        )
        #expect(shortSeg.count == 1)
        #expect(shortSeg[0].endMs - shortSeg[0].startMs >= 500)
    }

    @Test func shortBatchPaddingRetainsExactOwnershipForPostDecodeTrim() {
        let plans = AudioPipelineUtilities.asrBatchPlans(
            from: [(0, 14_900), (14_950, 15_050)],
            totalDurationMs: 20_000,
            maxBatchMs: 60_000,
            minBatchMs: 500,
            maxMergeGapMs: 1_200,
            targetMergeDurationMs: 15_000
        )

        #expect(plans.count == 2)
        #expect(plans[0].decodeRangeMs == 0..<14_900)
        #expect(plans[0].ownershipRangesMs == [0..<14_900])
        #expect(plans[1].decodeRangeMs == 14_950..<15_450)
        #expect(plans[1].ownershipRangesMs == [14_950..<15_050])
    }

    @Test func paddedBatchTokensAreTrimmedBackToOwnershipRange() {
        let sentences = [ASRSentence(
            text: "甲乙",
            startMs: 150,
            endMs: 480,
            tokens: [
                ASRToken(text: "甲", startMs: 150, endMs: 250),
                ASRToken(text: "乙", startMs: 390, endMs: 480)
            ]
        )]

        let trimmed = AudioPipeline.offsetAndTrimASRSentences(
            sentences,
            by: 14_550,
            ownershipRangesMs: [14_950..<15_050]
        )

        #expect(trimmed.count == 1)
        #expect(trimmed[0].text == "乙")
        #expect(trimmed[0].tokens[0].startMs == 14_950)
        #expect(trimmed[0].tokens[0].endMs == 15_030)
    }

    @Test func mergedBatchesOwnTheIntentionalGapButNotOuterPadding() {
        let plans = AudioPipelineUtilities.asrBatchPlans(
            from: [(1_000, 1_100), (1_300, 1_400)],
            totalDurationMs: 5_000,
            maxBatchMs: 60_000
        )

        #expect(plans.count == 1)
        #expect(plans[0].decodeRangeMs == 1_000..<1_800)
        #expect(plans[0].ownershipRangesMs == [1_000..<1_400])
    }
}
