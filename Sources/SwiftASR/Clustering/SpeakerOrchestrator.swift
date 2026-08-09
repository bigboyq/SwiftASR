import Foundation
import Accelerate

/// Speaker 聚类编排：primary SpectralCluster + 统一 profile 质量评估 + fallback 重试 + 迭代余弦合并。
/// 跟 FunASR-Mac `pipeline/_speaker.py` + `_speaker_clustering.py` + `_speaker_fallback.py` 对齐。
///
/// 流程：
/// 1. primary SpectralCluster (eigengap min=2)
/// 2. 把 labels 转成 profiles
/// 3. 统一 profile 质量评估：
///    - 单 profile：短时长 + 低 cohesion → 垃圾 profile，自愈重聚类
///    - 整体 partition：dominant profile 覆盖 >= 80% audio span、过早开始且其他
///      profile 晚于 30% 才出现 → collapse/lopsided
/// 4. 如果质量评估发现 collapse + chunks >= 30：用 SpectralCluster 重试（funasr 的 fallback 就是 SpectralCluster
///    第二次跑，这次强制 min_num_spks=2 + 改变 pval 做 eigengap 抖动）
/// 5. 迭代余弦合并（greedy best-pair，每次合并最大相似的，直到 < 0.78）
public enum SpeakerOrchestratorError: Error, Sendable, Equatable {
    case invalidEmbeddingShape(expected: Int, actual: Int)
    case nonFiniteEmbedding(index: Int)
    case zeroNormEmbedding(index: Int)
    case clusteringFailed(expected: Int, actual: Int)
}

public final class SpeakerOrchestrator {
    /// 跟 FunASR-Mac `CLUSTER_MERGE_THRESHOLD` 对齐
    public static let mergeThreshold: Float = 0.78
    /// 跟 FunASR-Mac `MIN_CHUNKS_FOR_FALLBACK` 对齐 = 30
    public static let minChunksForFallback: Int = 30

    public static let collapseCoverageThreshold: Double = 0.80
    public static let collapseStartThreshold: Double = 0.05
    public static let collapseLateThreshold: Double = 0.30

    public init(
        clustering: SpectralClustering = SpectralClustering()
    ) {
        self.clustering = clustering
    }

    let clustering: SpectralClustering

    public struct Output: Sendable {
        public let labels: [Int]
        public let profiles: [SpeakerProfileData]
        public let fallbackTriggered: Bool
        public let fallbackReason: String?
        public let failure: SpeakerOrchestratorError?
    }

    /// 统一承载单 profile 和整体 partition 的健康检查结果。
    ///
    /// 这一步只统一“发现问题”的入口，暂时保留现有两种修复动作：
    /// 垃圾 profile 走 healthy-K 重聚类，collapse/lopsided 走 pval 抖动 fallback。
    /// 更复杂的候选 K 评分和稳定性搜索留到后续探索，不在本次改变行为。
    struct ProfileQualityReport {
        let garbageProfileIndices: Set<Int>
        let hasCollapsedCoverage: Bool
    }

    struct ProfileRepairResult {
        let labels: [Int]
        let profiles: [SpeakerProfileData]
        let fallbackTriggered: Bool
        let fallbackReason: String?
    }

    /// 主入口
    /// - embeddings: 声纹矩阵 [N, 192]，长度 = N * 192
    /// - chunks: 每个 chunk 的 (startMs, endMs)，长度 = N
    public func cluster(
        embeddings: [Float],
        chunks: [(startMs: Int, endMs: Int)],
        policy: SpeakerTemporalPolicy = .production
    ) -> Output {
        cluster(
            embeddings: embeddings,
            chunks: chunks,
            policy: policy,
            onProgress: nil
        )
    }

    public func cluster(
        embeddings: [Float],
        chunks: [(startMs: Int, endMs: Int)],
        policy: SpeakerTemporalPolicy = .production,
        onProgress: ((_ stage: String, _ fraction: Double) -> Void)?,
        shouldCancel: (() -> Bool)? = nil
    ) -> Output {
        let count = chunks.count
        guard count > 0 else {
            return Output(labels: [], profiles: [], fallbackTriggered: false, fallbackReason: nil, failure: nil)
        }
        let dim = 192
        guard embeddings.count == count * dim else {
            return Output(
                labels: [], profiles: [], fallbackTriggered: false, fallbackReason: nil,
                failure: .invalidEmbeddingShape(expected: count * dim, actual: embeddings.count)
            )
        }
        // 2026-07-26 P2 F3.11: was two separate loops — a full array
        // scan for any non-finite element, then a per-chunk scan for
        // the sum-of-squares. Fold both into a single per-chunk
        // pass: emit the existing failure cases (.nonFiniteEmbedding
        // for the offending element index, .zeroNormEmbedding for the
        // chunk) without ever materialising an intermediate
        // sub-array or making a second pass over the embeddings.
        for chunkIndex in 0..<count {
            let offset = chunkIndex * dim
            var normSquared: Float = 0
            for inner in 0..<dim {
                let value = embeddings[offset + inner]
                guard value.isFinite else {
                    return Output(
                        labels: [], profiles: [], fallbackTriggered: false, fallbackReason: nil,
                        failure: .nonFiniteEmbedding(index: offset + inner)
                    )
                }
                normSquared += value * value
            }
            guard normSquared.isFinite, normSquared > 1e-20 else {
                return Output(
                    labels: [], profiles: [], fallbackTriggered: false, fallbackReason: nil,
                    failure: .zeroNormEmbedding(index: chunkIndex)
                )
            }
        }

        // A single packed window is a valid one-speaker recording. It cannot
        // use spectral clustering, but it still needs a real acoustic profile
        // for the downstream evidence stage.
        if count == 1 {
            let profiles = buildProfiles(
                labels: [0], chunks: chunks, embeddings: embeddings, dim: dim,
                policy: policy
            )
            return Output(labels: [0], profiles: profiles, fallbackTriggered: false, fallbackReason: nil, failure: nil)
        }

        // 1. primary SpectralCluster (eigengap, min=2)
        let rawPrimaryLabels = clustering.cluster(
            embeddings: embeddings, count: count, onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        // If cancelled during primary clustering, bail before the label-count
        // guard: buildResult checks shouldCancel before reading this output.
        if let shouldCancel, shouldCancel() {
            return Output(labels: [], profiles: [], fallbackTriggered: false, fallbackReason: nil, failure: nil)
        }
        guard rawPrimaryLabels.count == count else {
            return Output(
                labels: [], profiles: [], fallbackTriggered: false, fallbackReason: nil,
                failure: .clusteringFailed(expected: count, actual: rawPrimaryLabels.count)
            )
        }
        let mergedPrimaryLabels = mergeLabelsByCos(
            labels: rawPrimaryLabels,
            embeddings: embeddings,
            count: count,
            dim: dim,
            threshold: Self.mergeThreshold
        )
        let primaryLabels = keepRawLabelsIfMergeCollapsedEverything(
            rawLabels: rawPrimaryLabels,
            mergedLabels: mergedPrimaryLabels,
            count: count,
            stage: "primary"
        )
        let rawPrimaryProfiles = buildProfiles(
            labels: primaryLabels,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy
        )
        // Cancellation checkpoint before profile-quality repair, which can
        // trigger up to 3 re-clustering passes.
        if let shouldCancel, shouldCancel() {
            return Output(labels: [], profiles: [], fallbackTriggered: false, fallbackReason: nil, failure: nil)
        }
        let repaired = repairProfileQuality(
            labels: primaryLabels,
            profiles: rawPrimaryProfiles,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy
        )
        return Output(
            labels: repaired.labels,
            profiles: repaired.profiles,
            fallbackTriggered: repaired.fallbackTriggered,
            fallbackReason: repaired.fallbackReason,
            failure: nil
        )
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var aNorm: Float = 0
        var bNorm: Float = 0
        for index in 0..<min(a.count, b.count) {
            dot += a[index] * b[index]
            aNorm += a[index] * a[index]
            bNorm += b[index] * b[index]
        }
        let denominator = sqrt(aNorm) * sqrt(bNorm)
        return denominator > 1e-10 ? dot / denominator : 0
    }

    /// vDSP batched cosine: compute all (embedding × centroid) scores in a
    /// single BLAS sgemm call.  2026-07-26 M3 — replaces the per-pair
    /// `cosineSimilarity` invocation pattern in `SpeakerEvidenceTimeline.init`
    /// (~1354 scalar calls per 10min fixture) with one (n × k) matrix.
    ///
    /// Preconditions (production inputs always satisfy):
    ///   - `embeddings.count >= n * dim` and `centroids.count >= k * dim`
    ///   - rows are L2-normalized in their first `dim` entries
    ///     (`SpectralClustering.normalize` and `SpeakerProfileBuilder`
    ///      both divide each row by its L2 norm before this point, so
    ///      `||row|| ≈ 1`).
    ///
    /// Because the rows are already normalized, the cosine reduces to the
    /// unnormalized dot product, and we skip the svesq/sqrt pass.  This
    /// matches the production code path; if the precondition ever changes,
    /// switch to the svesq + dotpr variant and re-run
    /// `PipelineExecutionProfileTests` to confirm fingerprint stability.
    ///
    /// Output layout: `outScores[i * k + j] = cosine(embeddings[i], centroids[j])`
    /// for `0 ≤ i < n` and `0 ≤ j < k`.  `outScores.count` must be ≥ `n * k`.
    public static func cosineMatrix(
        embeddings: [Float],
        n: Int,
        centroids: [Float],
        k: Int,
        dim: Int,
        outScores: inout [Float]
    ) {
        precondition(n >= 0 && k >= 0 && dim > 0, "cosineMatrix: invalid dimensions")
        precondition(embeddings.count >= n * dim, "cosineMatrix: embeddings buffer too small")
        precondition(centroids.count >= k * dim, "cosineMatrix: centroids buffer too small")
        precondition(outScores.count >= n * k, "cosineMatrix: outScores buffer too small")
        if n == 0 || k == 0 { return }
        // C = A * B^T where A is (n × dim) and B is (k × dim, transposed to dim × k).
        // Row-major sgemm with opA=N (A as-is) and opB=T (B transposed on the fly).
        embeddings.withUnsafeBufferPointer { aPtr in
            centroids.withUnsafeBufferPointer { bPtr in
                outScores.withUnsafeMutableBufferPointer { cPtr in
                    cblas_sgemm(
                        CblasRowMajor, CblasNoTrans, CblasTrans,
                        Int32(n), Int32(k), Int32(dim),
                        1.0,
                        aPtr.baseAddress, Int32(dim),
                        bPtr.baseAddress, Int32(dim),
                        0.0,
                        cPtr.baseAddress, Int32(k)
                    )
                }
            }
        }
    }

    /// 标量变体：在 normalized 输入上算单个 cosine，1 次 vDSP_dotpr。  保留给
    /// `SpeakerProfileQualityRepair` 之类的小批量 caller，避免 vDSP_dotpr
    /// 跟标量 for-loop 的最后一位 ULP 差异扩散到 decision 路径。
    public static func vDSPCosine(_ a: [Float], _ b: [Float]) -> Float {
        let len = vDSP_Length(min(a.count, b.count))
        guard len > 0 else { return 0 }
        var dot: Float = 0
        a.withUnsafeBufferPointer { aPtr in
            b.withUnsafeBufferPointer { bPtr in
                vDSP_dotpr(aPtr.baseAddress!, 1, bPtr.baseAddress!, 1, &dot, len)
            }
        }
        return dot
    }

}
