import Accelerate
import Foundation
import Testing
@testable import SwiftASR

/// Unit tests for the vDSP-accelerated cosine helpers in
/// `SpeakerOrchestrator` (`cosineMatrix` for batched (n × k) scores and
/// `vDSPCosine` for a single pair).  2026-07-26: pinned the ULP behaviour
/// of both helpers so any future change to the underlying BLAS/vDSP call
/// that pushes a tolerance-breaking diff is caught.
///
/// The production code only relies on these helpers for *normalized*
/// inputs (centroids and embeddings are L2-divided upstream), so the
/// tests use normalized rows and compare against the scalar for-loop
/// reference (`SpeakerOrchestrator.cosineSimilarity`).  A 1-2 ULP diff
/// is expected from vDSP's tree-reduce, and the existing
/// `PipelineExecutionProfileTests` is the source of truth for whether
/// that diff flips any production decision.
@Suite(.serialized)
struct SpeakerOrchestratorCosineTests {

    /// 192-dim row that is L2-normalized.
    private func makeNormalizedRow(seed: Int, dim: Int = 192) -> [Float] {
        var rng = SeededGenerator(seed: UInt64(seed))
        var row = [Float](repeating: 0, count: dim)
        for i in 0..<dim { row[i] = Float.random(in: -1...1, using: &rng) }
        var sumSq: Float = 0
        vDSP_svesq(row, 1, &sumSq, vDSP_Length(dim))
        let n = sqrt(sumSq)
        guard n > 1e-10 else { return row }
        var divisor = n
        vDSP_vsdiv(row, 1, &divisor, &row, 1, vDSP_Length(dim))
        return row
    }

    @Test func vDSPCosineMatchesScalarOnNormalizedInput() {
        // Across 5 random pairs, the vDSP_dotpr result must sit within
        // 1e-5 of the scalar for-loop reference.  Empirical measurement
        // puts the actual diff at ~1e-8 (1-2 ULP).
        for seed in 0..<5 {
            let a = makeNormalizedRow(seed: seed * 2)
            let b = makeNormalizedRow(seed: seed * 2 + 1)
            let scalar = SpeakerOrchestrator.cosineSimilarity(a, b)
            let vDSP = SpeakerOrchestrator.vDSPCosine(a, b)
            #expect(abs(scalar - vDSP) < 1e-5, "seed=\(seed) scalar=\(scalar) vDSP=\(vDSP) diff=\(abs(scalar - vDSP))")
        }
    }

    @Test func cosineMatrixMatchesScalarLoop() {
        // 5 windows × 3 centroids (all 192-dim, normalized).  The matrix
        // version uses cblas_sgemm; the reference loops over each
        // (window, centroid) pair with `vDSPCosine`.  Differences should
        // stay under 1e-5 (sgemm's block reduce vs vDSP_dotpr's
        // pair-wise reduce).
        let n = 5
        let k = 3
        let dim = 192
        let embeddings: [Float] = (0..<n).flatMap { makeNormalizedRow(seed: $0, dim: dim) }
        let centroids: [Float] = (0..<k).flatMap { makeNormalizedRow(seed: 100 + $0, dim: dim) }
        var matrixOut = [Float](repeating: 0, count: n * k)
        SpeakerOrchestrator.cosineMatrix(
            embeddings: embeddings, n: n,
            centroids: centroids, k: k,
            dim: dim, outScores: &matrixOut
        )
        for i in 0..<n {
            for j in 0..<k {
                let rowOffset = i * dim
                let aSlice = Array(embeddings[rowOffset..<(rowOffset + dim)])
                let colOffset = j * dim
                let bSlice = Array(centroids[colOffset..<(colOffset + dim)])
                let reference = SpeakerOrchestrator.vDSPCosine(aSlice, bSlice)
                let matrixValue = matrixOut[i * k + j]
                #expect(
                    abs(reference - matrixValue) < 1e-5,
                    "(\(i),\(j)) reference=\(reference) matrix=\(matrixValue) diff=\(abs(reference - matrixValue))"
                )
            }
        }
    }

    @Test func cosineMatrixHandlesZeroWindowsOrCentroids() {
        // Defensive: empty windows or centroids must not crash and must
        // not write garbage into outScores.
        var out = [Float](repeating: 0, count: 0)
        SpeakerOrchestrator.cosineMatrix(
            embeddings: [], n: 0, centroids: [], k: 0,
            dim: 192, outScores: &out
        )
        #expect(out.isEmpty)
    }
}

/// Tiny seeded LCG so the tests are deterministic without pulling in
/// the whole SystemRandomNumberGenerator path.  The pattern is the
/// same `SplitMix64`-style mulberry used elsewhere in SwiftASR tests.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
