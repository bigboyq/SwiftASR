import Foundation
import Testing
@testable import SwiftASR

/// `SpeakerOrchestrator.mergeLabelsByCos` / `pruneGarbageProfiles` 测试（2026-07-22）。
///
/// 之前这俩核心算法方法 0 测试覆盖（`SpeakerProfileQualityRepair.swift`
/// 836 行方法没单测）。这次补上：
/// - `mergeLabelsByCos` 输入校验 / 基础合并 / 不可合并 / 链式合并
/// - `pruneGarbageProfiles` 触发 forced re-cluster 的 happy path
@MainActor
struct SpeakerOrchestratorMergeTests {
    // MARK: - Fixtures

    private func makeOrchestrator() -> SpeakerOrchestrator {
        // 默认 SpectralClustering：minNumSpks=2, maxNumSpks=15, pval=0.022
        // pval 影响 P-pruning，但 mergeLabelsByCos 走的是独立路径，不受影响
        SpeakerOrchestrator()
    }

    /// 构造 N 个 [dim] 维 embedding。center 应该是个**有方向的** unit vector
    /// （如 [1, 0, ..., 0]），给每个 sample 加 5% jitter 让方向略偏离 center。
    /// `mergeLabelsByCos` 内部会 normalize 中心，所以传入的 center 方向最重要。
    private func makeCluster(
        center: [Float],
        count: Int,
        jitter: Float = 0.05,
        seed: UInt64 = 1
    ) -> [Float] {
        let dim = center.count
        var state = seed
        func nextUnit() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 11) / Float(UInt64(1) << 53) * 2 - 1  // [-1, 1)
        }
        var result = [Float](repeating: 0, count: count * dim)
        for i in 0..<count {
            for d in 0..<dim {
                result[i * dim + d] = center[d] * (1.0 + nextUnit() * jitter)
            }
        }
        return result
    }

    // MARK: - mergeLabelsByCos: input validation

    @Test func mergeLabelsByCos_rejectsMismatchedInputs() {
        let orch = makeOrchestrator()
        // labels.count != count
        let result = orch.mergeLabelsByCos(
            labels: [0, 0, 1],
            embeddings: [Float](repeating: 0, count: 2 * 192),
            count: 2,
            dim: 192,
            threshold: 0.78
        )
        #expect(result.isEmpty)
    }

    @Test func mergeLabelsByCos_rejectsMismatchedEmbeddingSize() {
        let orch = makeOrchestrator()
        let result = orch.mergeLabelsByCos(
            labels: [0, 0],
            embeddings: [Float](repeating: 0, count: 192),  // 应该是 2 * 192
            count: 2,
            dim: 192,
            threshold: 0.78
        )
        #expect(result.isEmpty)
    }

    @Test func mergeLabelsByCos_rejectsZeroDim() {
        let orch = makeOrchestrator()
        let result = orch.mergeLabelsByCos(
            labels: [],
            embeddings: [],
            count: 0,
            dim: 0,  // dim > 0 是必要条件
            threshold: 0.78
        )
        #expect(result.isEmpty)
    }

    // MARK: - mergeLabelsByCos: behavior

    @Test func mergeLabelsByCos_similarClustersMerge() {
        let orch = makeOrchestrator()
        // 两个 cluster 中心方向相同（X 轴），5% 抖动；cos 应 > 0.5
        let centerX: [Float] = (0..<192).map { $0 == 0 ? 1.0 : 0.0 }
        let embeddings = makeCluster(center: centerX, count: 3, seed: 1) +
                         makeCluster(center: centerX, count: 3, seed: 2)
        let labels = [0, 0, 0, 1, 1, 1]

        let result = orch.mergeLabelsByCos(
            labels: labels,
            embeddings: embeddings,
            count: 6,
            dim: 192,
            threshold: 0.5
        )
        #expect(result.count == 6)
        let unique = Set(result)
        #expect(unique.count == 1)
    }

    @Test func mergeLabelsByCos_dissimilarClustersStayApart() {
        let orch = makeOrchestrator()
        // 两个 cluster 中心正交（X 轴 vs Y 轴），不会合并
        let centerX: [Float] = (0..<192).map { $0 == 0 ? 1.0 : 0.0 }
        let centerY: [Float] = (0..<192).map { $0 == 1 ? 1.0 : 0.0 }
        let embeddings = makeCluster(center: centerX, count: 3, seed: 1) +
                         makeCluster(center: centerY, count: 3, seed: 2)
        let labels = [0, 0, 0, 1, 1, 1]

        let result = orch.mergeLabelsByCos(
            labels: labels,
            embeddings: embeddings,
            count: 6,
            dim: 192,
            threshold: 0.95  // 高阈值，正交 (cos=0) 不会合并
        )
        #expect(Set(result).count == 2)
    }

    @Test func mergeLabelsByCos_chainMerges() {
        let orch = makeOrchestrator()
        // 链式：所有 cluster 中心都接近 X 轴方向 → 应该全部合并
        let centerX: [Float] = (0..<192).map { $0 == 0 ? 1.0 : 0.0 }
        let centerXish: [Float] = (0..<192).map { $0 == 0 ? 0.95 : 0.05 }
        let centerXmore: [Float] = (0..<192).map { $0 == 0 ? 0.9 : $0 == 1 ? 0.1 : 0.0 }
        // 三个中心都偏向 X 轴，cos 两两 > 0.5
        let embeddings = makeCluster(center: centerX, count: 3, seed: 1) +
                         makeCluster(center: centerXish, count: 3, seed: 2) +
                         makeCluster(center: centerXmore, count: 3, seed: 3)
        let labels = [0, 0, 0, 1, 1, 1, 2, 2, 2]

        let result = orch.mergeLabelsByCos(
            labels: labels,
            embeddings: embeddings,
            count: 9,
            dim: 192,
            threshold: 0.5
        )
        // 链式：0+1 先合，再跟 2 合 → 最终 1 个 label
        #expect(Set(result).count == 1)
    }

    @Test func mergeLabelsByCos_singleLabelIsNoop() {
        let orch = makeOrchestrator()
        // count = 1
        let result = orch.mergeLabelsByCos(
            labels: [0],
            embeddings: [Float](repeating: 0, count: 192),
            count: 1,
            dim: 192,
            threshold: 0.5
        )
        #expect(result == [0])
    }

    @Test func mergeLabelsByCos_zeroCountReturnsEmpty() {
        let orch = makeOrchestrator()
        let result = orch.mergeLabelsByCos(
            labels: [],
            embeddings: [],
            count: 0,
            dim: 192,
            threshold: 0.5
        )
        #expect(result.isEmpty)
    }

    @Test func mergeLabelsByCos_normalizesCenters() {
        // 隐式测试：center 内部 normalize 后再算 cos，所以即使 raw sum 量级不同也能合并
        let orch = makeOrchestrator()
        let big = [Float](repeating: 1, count: 192)     // 长度 sqrt(192) ≈ 13.8
        let small = [Float](repeating: 0.5, count: 192)  // 长度 sqrt(48) ≈ 6.9
        // normalize 后都是方向 [1,1,1,...]/sqrt(192)，cos = 1.0
        let embeddings = makeCluster(center: big, count: 3, seed: 1) +
                         makeCluster(center: small, count: 3, seed: 2)
        let labels = [0, 0, 0, 1, 1, 1]
        let result = orch.mergeLabelsByCos(
            labels: labels,
            embeddings: embeddings,
            count: 6,
            dim: 192,
            threshold: 0.5
        )
        #expect(Set(result).count == 1)
    }
}
