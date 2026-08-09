import Foundation
import Testing
@testable import SwiftASR

/// `SpeakerOrchestrator.repairProfileQuality` / 内部 `pruneGarbageProfiles` 测试
/// （2026-07-22 audit 发现 `SpeakerProfileQualityRepair.swift` 836 行扩展 0 覆盖）。
///
/// 难点：`pruneGarbageProfiles` 是 private，只能通过 `repairProfileQuality` 间接覆盖。
/// 重点覆盖 fast path（< 3 profile）和 happy path（3+ 全 valid）。
/// garbage 自愈 / fallback 路径需要复杂 fixture 构造 profile duration / cohesion，
/// 留到后续。
@MainActor
struct SpeakerProfileQualityRepairTests {
    // MARK: - Fixtures

    private func makeOrchestrator() -> SpeakerOrchestrator {
        SpeakerOrchestrator()
    }

    private func makeChunks(count: Int, ms: Int = 1_000) -> [(startMs: Int, endMs: Int)] {
        (0..<count).map { ($0 * ms, ($0 + 1) * ms) }
    }

    private func makeEmbeddings(count: Int, dim: Int = 192) -> [Float] {
        var result = [Float](repeating: 0, count: count * dim)
        for i in 0..<count {
            // 每个 chunk 给个不同方向的 unit vector（dim=192 时循环）
            result[i * dim + (i % dim)] = 1.0
        }
        return result
    }

    private func makeProfile(
        label: String,
        acousticLabel: Int,
        durationMs: Int,
        chunkCount: Int,
        centroid: [Float]
    ) -> SpeakerProfileData {
        let centroidData = centroid.withUnsafeBufferPointer { Data(buffer: $0) }
        return SpeakerProfileData(
            speakerLabel: label,
            fingerprintId: "fp-\(label)",
            totalDurationMs: durationMs,
            chunkCount: chunkCount,
            centroidEmbedding: centroid,
            embeddingData: centroidData
        )
    }

    private func makeTwoDimensionalProfile(
        label: String,
        durationMs: Int,
        chunkCount: Int,
        centroid: [Float]
    ) -> SpeakerProfileData {
        makeProfile(
            label: label,
            acousticLabel: 0,
            durationMs: durationMs,
            chunkCount: chunkCount,
            centroid: centroid
        )
    }

    // MARK: - fast path: profiles.count < 3

    @Test func repairProfileQuality_zeroProfiles_returnsImmediately() {
        let orch = makeOrchestrator()
        let chunks = makeChunks(count: 5)
        let result = orch.repairProfileQuality(
            labels: [],
            profiles: [],
            chunks: chunks,
            embeddings: makeEmbeddings(count: 5),
            dim: 192,
            policy: .production
        )
        // fast path: 0 profile → 不进入 garbage 循环，labels 保持空
        #expect(result.profiles.isEmpty)
        #expect(result.labels.isEmpty)
    }

    @Test func repairProfileQuality_singleProfile_doesNotCrash() {
        let orch = makeOrchestrator()
        // 1 profile：fast path，不进入 pruning 循环
        let profile = makeProfile(
            label: "说话人 1",
            acousticLabel: 0,
            durationMs: 5000,
            chunkCount: 5,
            centroid: [Float](repeating: 0.1, count: 192)
        )
        let chunks = makeChunks(count: 5)
        let result = orch.repairProfileQuality(
            labels: [0, 0, 0, 0, 0],
            profiles: [profile],
            chunks: chunks,
            embeddings: makeEmbeddings(count: 5),
            dim: 192,
            policy: .production
        )
        // chunks=5 < 30 → 走 "below_min_chunks" fallback，但 profile 数保持 1
        #expect(result.profiles.count == 1)
    }

    @Test func repairProfileQuality_twoProfiles_doesNotCrash() {
        let orch = makeOrchestrator()
        // 2 profile：fast path 进入 adaptivelyMergeFragmentShadows 但不触发 garbage
        let p1 = makeProfile(
            label: "说话人 1", acousticLabel: 0,
            durationMs: 3000, chunkCount: 3,
            centroid: [Float](repeating: 0.1, count: 192)
        )
        let p2 = makeProfile(
            label: "说话人 2", acousticLabel: 1,
            durationMs: 2000, chunkCount: 2,
            centroid: [Float](repeating: 0.2, count: 192)
        )
        let chunks = makeChunks(count: 5)
        let result = orch.repairProfileQuality(
            labels: [0, 0, 0, 1, 1],
            profiles: [p1, p2],
            chunks: chunks,
            embeddings: makeEmbeddings(count: 5),
            dim: 192,
            policy: .production
        )
        // 2 profile 走 adaptivelyMergeFragmentShadows（可能合可能不合），profile 数 1-2 之间
        #expect(result.profiles.count >= 1)
        #expect(result.profiles.count <= 2)
    }

    @Test func repairProfileQuality_invalidEmbeddings_doesNotCrash() {
        let orch = makeOrchestrator()
        // dim 不匹配（embeddings 长度 != count * dim）→ SpectralClustering 会 fail-closed
        let profile = makeProfile(
            label: "说话人 1", acousticLabel: 0,
            durationMs: 1000, chunkCount: 1,
            centroid: [Float](repeating: 0, count: 192)
        )
        let chunks = makeChunks(count: 3)
        // 故意提供错配的 embeddings（声称 3 * 192，实际 100）
        let result = orch.repairProfileQuality(
            labels: [0, 0, 0],
            profiles: [profile],
            chunks: chunks,
            embeddings: [Float](repeating: 0, count: 100),
            dim: 192,
            policy: .production
        )
        // 不崩，profile 数保持
        #expect(result.profiles.count == 1)
    }

    // MARK: - SpeakerFragmentShadowMerger

    @Test func fragmentShadowMerger_duplicateProfiles_mergeDeterministically() {
        let profiles = [
            makeTwoDimensionalProfile(
                label: "说话人 1",
                durationMs: 2_000,
                chunkCount: 2,
                centroid: [1, 0]
            ),
            makeTwoDimensionalProfile(
                label: "说话人 2",
                durationMs: 2_000,
                chunkCount: 2,
                centroid: [1, 0]
            ),
        ]
        let result = SpeakerFragmentShadowMerger.merge(
            labels: [0, 0, 1, 1],
            profiles: profiles,
            chunks: makeChunks(count: 4),
            embeddings: [
                1, 0,
                1, 0,
                1, 0,
                1, 0,
            ],
            dim: 2,
            policy: .production
        )

        #expect(result.labels == [0, 0, 0, 0])
        #expect(result.profiles.count == 1)
    }

    @Test func fragmentShadowMerger_dissimilarProfiles_preservesPartition() {
        let profiles = [
            makeTwoDimensionalProfile(
                label: "说话人 1",
                durationMs: 2_000,
                chunkCount: 2,
                centroid: [1, 0]
            ),
            makeTwoDimensionalProfile(
                label: "说话人 2",
                durationMs: 2_000,
                chunkCount: 2,
                centroid: [0, 1]
            ),
        ]
        let result = SpeakerFragmentShadowMerger.merge(
            labels: [0, 0, 1, 1],
            profiles: profiles,
            chunks: makeChunks(count: 4),
            embeddings: [
                1, 0,
                1, 0,
                0, 1,
                0, 1,
            ],
            dim: 2,
            policy: .production
        )

        #expect(result.labels == [0, 0, 1, 1])
        #expect(result.profiles.map(\.speakerLabel) == profiles.map(\.speakerLabel))
    }
}
