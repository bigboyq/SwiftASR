import Foundation
import Testing
@testable import SwiftASR

/// Smoke tests for the static helpers that moved out of `AudioPipeline`
/// into `AudioPipelineUtilities` (audit F5.5 file split, 2026-07-26).
///
/// The 7 helpers here are pure-functional (no actor isolation, no
/// state) so the new file is a plain enum namespace.  These tests
/// don't replace the original behaviour tests in
/// `ASRBatchesBoundaryTests` / `Phase9CollapseDetectionTests`; they
/// just pin that the new `AudioPipelineUtilities.X` entry points
/// exist and return values equivalent to the re-exports on
/// `AudioPipeline`.
@Suite struct AudioPipelineUtilitiesTests {

    @Test func asrBatches_matchesActorReExport() {
        let segments: [(startMs: Int, endMs: Int)] = [(0, 1000), (2000, 3000)]
        let utility = AudioPipelineUtilities.asrBatches(
            from: segments, totalDurationMs: 3000, maxBatchMs: 60_000
        )
        let actor = AudioPipeline.asrBatches(
            from: segments, totalDurationMs: 3000, maxBatchMs: 60_000
        )
        #expect(utility.count == actor.count)
        for (lhs, rhs) in zip(utility, actor) {
            #expect(lhs.0 == rhs.0)
            #expect(lhs.1 == rhs.1)
        }
    }

    @Test func relabelSpeakerLabels_matchesActorReExport() {
        let labels = [2, 0, 2, 1]
        let chunks: [(startMs: Int, endMs: Int)] = [
            (0, 100), (100, 200), (200, 300), (300, 400)
        ]
        let utility = AudioPipelineUtilities.relabelSpeakerLabelsByFirstOccurrence(
            labels: labels, chunks: chunks
        )
        let actor = AudioPipeline.relabelSpeakerLabelsByFirstOccurrence(
            labels: labels, chunks: chunks
        )
        #expect(utility == actor)
        // First-occurrence order: 2 (at 0ms), 0 (at 100ms), 1 (at 300ms)
        // → 2→0, 0→1, 1→2
        #expect(utility == [0, 1, 0, 2])
    }

    @Test func audioSampleRange_matchesActorReExport() {
        let utility = AudioPipelineUtilities.audioSampleRange(
            startMs: 1000, endMs: 2000, sampleRate: 16000, totalSamples: 160_000
        )
        let actor = AudioPipeline.audioSampleRange(
            startMs: 1000, endMs: 2000, sampleRate: 16000, totalSamples: 160_000
        )
        #expect(utility == actor)
        #expect(utility == 16000..<32000)
    }

    @Test func svChunk_totalFrames_emitAtLeast100msChunks() {
        // 5-second segment with 1.5s window / 0.75s shift should emit
        // multiple chunks.  We don't pin the exact count (FunASR's
        // `sv_chunk` doesn't either) but the per-chunk duration must
        // exceed 100ms (the filter inside the helper).
        let segments: [(startMs: Int, endMs: Int)] = [(0, 5_000)]
        let chunks = AudioPipelineUtilities.svChunk(
            totalFrames: 5_000, segments: segments,
            windowSec: 1.5, shiftSec: 0.75
        )
        #expect(!chunks.isEmpty)
        for (start, end) in chunks {
            #expect(end - start > 100)
        }
    }

    @Test func svChunk_pcmRejectsNonStandardSampleRate() {
        let chunks = AudioPipelineUtilities.svChunk(
            pcm: Array(repeating: Float(0), count: 16_000),
            segments: [(startMs: 0, endMs: 1_000)],
            windowSec: 1.5,
            shiftSec: 0.75,
            sampleRate: 8_000
        )
        #expect(chunks.isEmpty)
    }
}
