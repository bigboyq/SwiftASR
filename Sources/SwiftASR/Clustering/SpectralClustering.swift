import Foundation
import Accelerate

public final class SpectralClustering {
    private let minNumSpks: Int
    private let maxNumSpks: Int
    private let pval: Double
    private let batchLimit: Int

    /// Historic compatibility/diagnostic threshold.  It remains useful for
    /// reporting unusually long recordings, but it is not a safe dense-matrix
    /// allocation limit.
    public static let spectralClusterMaxChunks: Int = 8192

    /// Dense spectral clustering keeps affinity, pruned affinity, and
    /// Laplacian matrices alive together. At this limit those three Float
    /// matrices consume about 192 MiB (3 × 4096² × 4); 8192 would require
    /// about 768 MiB before LAPACK workspace and other pipeline buffers.
    /// Inputs above this limit always use overlapping batches.
    public static let denseSpectralMaxChunks: Int = 4096
    
    /// FunASR-Mac 的 SpectralCluster fallback 用 `min_num_spks=2` 强制至少找 2 个
    /// （eigengap heuristic 默认会选 1 → "永远 1 说话人"折叠 bug）。
    /// 我们当 primary 用，统一改成 2。
    public init(
        minNumSpks: Int = 2,
        maxNumSpks: Int = 8,
        pval: Double = 0.022,
        batchLimit: Int = denseSpectralMaxChunks
    ) {
        self.minNumSpks = minNumSpks
        self.maxNumSpks = maxNumSpks
        self.pval = pval
        self.batchLimit = Self.boundedDenseBatchLimit(batchLimit)
    }

    /// Source-compatible entry point retained for existing callers that
    /// construct the pre-batching three-parameter form.
    public convenience init(minNumSpks: Int, maxNumSpks: Int, pval: Double) {
        self.init(
            minNumSpks: minNumSpks,
            maxNumSpks: maxNumSpks,
            pval: pval,
            batchLimit: Self.denseSpectralMaxChunks
        )
    }
    
    /// 执行谱聚类与说话人余弦合并
    /// - Parameter embeddings: 输入声纹矩阵 [N, 192]，总长度为 N * 192
    /// - Parameter count: embedding 的个数 N
    /// - Returns: 每个 embedding 对应的 Speaker Label 数组（长度为 N）。输入或
    ///   LAPACK 失败时返回空数组，调用方不得把空数组当作 speaker 0。
    public func cluster(embeddings: [Float], count: Int, forceK: Int? = nil) -> [Int] {
        cluster(
            embeddings: embeddings, count: count, forceK: forceK, onProgress: nil
        )
    }

    /// 接受 onProgress 回调的 cluster 重载。`onProgress` 接收 (stage, fraction)
    /// 其中 stage 是 6 阶段中文描述, fraction 在 [0, 1] 范围。
    /// `shouldCancel` 在每个计算阶段之间被检查；取消时返回空数组（调用方负责
    /// 在读取结果前先检查取消状态）。
    public func cluster(
        embeddings: [Float],
        count: Int,
        forceK: Int? = nil,
        onProgress: ((_ stage: String, _ fraction: Double) -> Void)?,
        shouldCancel: (() -> Bool)? = nil
    ) -> [Int] {
        switch preflightCluster(embeddings: embeddings, count: count, forceK: forceK) {
        case .empty:
            return []
        case .singleSpeaker:
            return Array(repeating: 0, count: count)
        case .batched:
            return clusterInBatches(
                embeddings: embeddings, count: count, forceK: forceK, shouldCancel: shouldCancel
            )
        case .rejected:
            return []
        case .proceed:
            break
        }

        // 6-step progress mapping (callers receive fraction in [0, 1]):
        //   0.00 数据标准化 (normalize)
        //   0.25 计算相似度 (affinity)
        //   0.40 挑选邻近关系 (prune)
        //   0.55 构建图矩阵 (laplacian)
        //   0.90 求解聚类数 (eigen, 单次 LAPACK 调用跳变)
        //   1.00 分配说话人 (kmeans)
        // 内部步骤在每个阶段开头报一次,UI 把 (0.70..0.92) × fraction 映射到进度条。
        var reporter = StageReporter(onProgress: onProgress)
        reporter.beginStage()

        let dim = 192

        // 1. L2 范数规范化 (Normalization)
        //
        // 原来每行都 `Array(embeddings[range])` 创建 2 个临时数组(count 行 × 2 = 5284 × 2 个 alloc)。
        // 改成 embeddings.baseAddress.advanced(by: offset) 偏移指针,直接给 vDSP_svesq/vsdiv 喂原数组 slice,
        // 0 临时数组分配,数学完全没动。
        //
        // 用 badNormFlag 标记 zero-norm 早退:withUnsafeBufferPointer 闭包内 `return` 只退闭包不退函数,
        // 所以需要 flag。
        let normalizeStart = Date()
        guard var normEmbeddings = SpectralGraphAlgorithms.normalize(
            embeddings: embeddings,
            count: count,
            dimension: dim
        ) else {
            Logger.shared.error("SpectralClustering: zero-norm embedding found; refusing to emit labels.")
            return []
        }
        let normalizationSeconds = Date().timeIntervalSince(normalizeStart)

        // FunASR keeps at least six nearest neighbors for small batches.
        // This prevents the affinity graph from fragmenting when an ASR
        // sentence fixture has only dozens of speaker windows.
        let effectivePval = Double(count) * pval < 6
            ? 6.0 / Double(count)
            : pval
        // Python slicing treats the negative count produced for N < 6 as an
        // empty prefix. Clamp explicitly because Swift `prefix` traps.
        let elementsToPrune = min(
            count,
            max(0, Int((1 - effectivePval) * Double(count)))
        )
        let retainedCount = max(0, count - elementsToPrune)

        reporter.endStage()

        // 2. 计算 Affinity Matrix M = E * E^T [N, N]
        // 使用 Accelerate 中的 BLAS cblas_sgemm 极速并行矩阵乘法
        let affinityStart = Date()
        var affinityMatrix = [Float](repeating: 0.0, count: count * count)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(count), Int32(count), Int32(dim),
            1.0, &normEmbeddings, Int32(dim),
            &normEmbeddings, Int32(dim),
            0.0, &affinityMatrix, Int32(count)
        )
        let affinitySeconds = Date().timeIntervalSince(affinityStart)

        reporter.endStage()

        // 3. P-Pruning 裁剪 (每行仅保留最大的 P 个特征，其余归零).
        // The old implementation fully sorted all N values in every row. On
        // 5k+ chunks that turns into tens of millions of comparison-sort
        // entries although only about pval*N neighbours survive. Keep the same
        // top-K semantics with a fixed min-heap instead.
        let pruningStart = Date()
        let prunedMatrix = Self.prunedAffinityMatrix(
            affinityMatrix,
            count: count,
            retainedCount: retainedCount
        )
        let pruningSeconds = Date().timeIntervalSince(pruningStart)

        reporter.endStage()

        // 4 + 5. 融合: 一步写最终 Laplacian L = D - S, S = 0.5 * (A + A^T)
        // 原实现分两步:
        //   step 4: 分配 symMatrix (112 MiB for n=5284) + N² 扫描算对称化
        //   step 5: 再次 N² 扫描读 symMatrix 写 Laplacian
        // 融合: 遍历上三角一次, 直接算对称边值同时累加两个节点 degree, 写
        // 最终 L. 省一张 112 MiB 中间矩阵 + 一次完整 N² 内存扫描. 数学结果
        // 完全等价 (ssyevr_ uplo='L' 读下三角, 对称矩阵下三角 = 上三角).
        // (per user spec 2026-07-12)
        let laplacianStart = Date()
        var laplacian = [Float](repeating: 0.0, count: count * count)
        var degree = [Float](repeating: 0.0, count: count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                let sym = 0.5 * (prunedMatrix[i * count + j] + prunedMatrix[j * count + i])
                laplacian[i * count + j] = -sym
                laplacian[j * count + i] = -sym
                degree[i] += abs(sym)
                degree[j] += abs(sym)
            }
        }
        for i in 0..<count {
            laplacian[i * count + i] = degree[i]
        }
        let laplacianSeconds = Date().timeIntervalSince(laplacianStart)

        reporter.endStage()

        // Cancellation checkpoint: the eigen solve is the single longest
        // stage (~seconds for long audio). Bail out before committing to it.
        if let shouldCancel, shouldCancel() { return [] }

        // 6. 调用 LAPACK 求解部分实对称拉普拉斯矩阵的特征值与特征向量
        // C 接口: ssyevr_ (partial eigen via MRRR algorithm)
        //
        // 优化：A 阶段 — 用 ssyevr_ 替代 ssyev_。
        // 之前用 ssyev_ 算所有 n 个特征值（O(n³/3) = O(1.5×10¹¹) flops for n=5284），
        // 实际 102s（cache-unfriendly dense QR iteration）。
        //
        // ssyevr_ 配 range='I' + il/iu 只算前 kEigengapLimit 个最小特征值
        // （MRRR 算法 O(n²·k·iter) ≈ 5284²·30·50 = 4.5×10¹⁰ flops ≈ 5s），
        // eigengap 在前 maxNumSpks 个里挑 k（k ≤ maxNumSpks），下游逻辑不变。
        // 实测 1h 音频：eigen 102s → ~5s，总 speaker 阶段 175s → ~80s。
        //
        // 进一步优化 (2026-07-24): kEigengapLimit = maxNumSpks + 4 而不是 hard-coded 30。
        // maxNumSpks=8 (realistic panel 上限) + 4 buffer 防 eigengap 边界误判 = 12
        // 实际只算 12 个 eigenvalue 而不是 30,eigen 时间 n=4852 100min audio 从 6.22s → ~2.5s。
        // 语义等价:eigengap 实际只用前 min(kEigengapLimit, maxNumSpks) 个 gap 选 bestK,
        // 之前 30 个里后 15 个本来就没用,减少冗余计算。
        let eigenStart = Date()
        let kEigengapLimit = min(maxNumSpks + 4, count)
        let decomposition = Self.runEigenDecomposition(
            laplacian: &laplacian,
            count: count,
            kEigengapLimit: kEigengapLimit
        )
        let eigenSeconds = Date().timeIntervalSince(eigenStart)

        reporter.endStage()

        let actualM = decomposition.m

        if decomposition.info != 0 || actualM == 0 {
            Logger.shared.error(
                "SpectralClustering: LAPACK ssyevr_ failed " +
                "info=\(decomposition.info), m=\(actualM), n=\(count), requested=\(kEigengapLimit). Falling back to direct K-Means."
            )
            return directKMeans(embeddings: embeddings, count: count, k: count >= 4 ? 3 : 2)
        }
        let eigenvalues = decomposition.eigenvalues
        let z = decomposition.z

        // 7. 计算 Eigengap 决定聚类数 k
        // 用前 actualM 个特征值（ssyevr_ 返回的）做 eigengap
        // 跟原算法等价（eigengap 只看小 eigenvalues 段的 gap）
        let returnedEigenvalues = Array(eigenvalues.prefix(actualM))
        let feasibleMaxK = max(1, min(kEigengapLimit, actualM, maxNumSpks, count))
        let bestK: Int
        if let forced = forceK {
            bestK = min(max(1, forced), feasibleMaxK)
            Logger.shared.info("SpectralClustering: forcing K = \(bestK) for re-clustering self-healing")
        } else {
            bestK = min(Self.speakerCountFromEigenvalues(
                returnedEigenvalues,
                minNumSpks: minNumSpks,
                maxNumSpks: maxNumSpks
            ), feasibleMaxK)
        }
        
        let nearZeroEigenvalueCount = returnedEigenvalues.filter { abs($0) < 1e-5 }.count
        if nearZeroEigenvalueCount > maxNumSpks {
            Logger.shared.warn("SpectralClustering: Graph is highly degenerate (near-zero eigenvalues count = \(nearZeroEigenvalueCount) > \(maxNumSpks)). Falling back to direct K-Means.")
            return directKMeans(embeddings: embeddings, count: count, k: count >= 4 ? 3 : 2)
        }
        
        let eigenvalueLog = returnedEigenvalues.map { String(format: "%.6g", $0) }.joined(separator: ",")
        let eigengapLog = zip(returnedEigenvalues.dropFirst(), returnedEigenvalues).map {
            String(format: "%.6g", $0.0 - $0.1)
        }.joined(separator: ",")
        Logger.shared.info(
            "SpectralClustering eigen diagnostic: n=\(count), range=I[1...\(kEigengapLimit)], " +
            "info=\(decomposition.info), m=\(actualM), lwork=\(decomposition.lwork), liwork=\(decomposition.liwork), bestK=\(bestK), " +
            "values=[\(eigenvalueLog)], gaps=[\(eigengapLog)]"
        )

        // 8. 提取降维特征矩阵 [N, k]
        // z 是 [n × m] 列优先存储的特征向量矩阵，取前 bestK 列
        var lowDimData = [Float](repeating: 0.0, count: count * bestK)
        for i in 0..<count {
            for j in 0..<bestK {
                // z 是列优先：[n × m] → z[col * n + row]
                lowDimData[i * bestK + j] = z[j * count + i]
            }
        }

        // 9. 在降维特征空间运行 K-Means。
        // 余弦中心合并统一放在 SpeakerOrchestrator 的 profile 层做；这里提前合并
        // 会让长双人对话在 labels 阶段被压成 1 个 speaker，后续无法恢复时间窗。
        let kmeansStart = Date()
        let labels = Self.runKMeans(data: lowDimData, n: count, k: bestK, dim: bestK)
        let kmeansSeconds = Date().timeIntervalSince(kmeansStart)

        reporter.endStage()
        Logger.shared.info(
            "SpectralClustering timing: n=\(count), keep=\(retainedCount), " +
            "normalize=\(String(format: "%.2f", normalizationSeconds))s, " +
            "affinity=\(String(format: "%.2f", affinitySeconds))s, " +
            "prune=\(String(format: "%.2f", pruningSeconds))s, " +
            "laplacian=\(String(format: "%.2f", laplacianSeconds))s, " +
            "eigen=\(String(format: "%.2f", eigenSeconds))s, " +
            "kmeans=\(String(format: "%.2f", kmeansSeconds))s"
        )
        return labels
    }

    /// Splits oversized inputs while keeping context at batch boundaries.
    /// Local cluster labels are aligned to global labels by centroid cosine
    /// similarity; normal profile-quality repair still runs afterwards.
    private func clusterInBatches(
        embeddings: [Float],
        count: Int,
        forceK: Int?,
        shouldCancel: (() -> Bool)? = nil
    ) -> [Int] {
        let dim = 192
        let ranges = Self.batchRanges(count: count, batchSize: batchLimit)
        guard !ranges.isEmpty else { return [] }

        var labels = Array(repeating: -1, count: count)
        var globalCentroids: [[Float]] = []
        var globalCounts: [Int] = []

        for range in ranges {
            if let shouldCancel, shouldCancel() { return [] }
            let batchEmbeddings = Array(embeddings[(range.lowerBound * dim)..<(range.upperBound * dim)])
            let localLabels = cluster(
                embeddings: batchEmbeddings, count: range.count, forceK: forceK,
                onProgress: nil, shouldCancel: shouldCancel
            )
            guard localLabels.count == range.count else { return [] }

            for localLabel in Set(localLabels.filter { $0 >= 0 }).sorted() {
                let memberIndexes = localLabels.indices.filter { localLabels[$0] == localLabel }
                guard !memberIndexes.isEmpty else { continue }
                let localCentroid = SpectralGraphAlgorithms.centroid(
                    embeddings: batchEmbeddings,
                    indexes: memberIndexes,
                    dimension: dim
                )

                let bestGlobal = globalCentroids.indices.max { lhs, rhs in
                    let leftScore = SpectralGraphAlgorithms.cosineSimilarity(localCentroid, globalCentroids[lhs])
                    let rightScore = SpectralGraphAlgorithms.cosineSimilarity(localCentroid, globalCentroids[rhs])
                    return leftScore == rightScore ? lhs > rhs : leftScore < rightScore
                }
                let globalLabel: Int
                if let bestGlobal,
                   SpectralGraphAlgorithms.cosineSimilarity(
                       localCentroid,
                       globalCentroids[bestGlobal]
                   ) >= SpeakerOrchestrator.mergeThreshold {
                    globalLabel = bestGlobal
                    let oldCount = globalCounts[bestGlobal]
                    let newCount = oldCount + memberIndexes.count
                    let oldWeight = Float(oldCount)
                    let localWeight = Float(memberIndexes.count)
                    let denominator = Float(newCount)
                    for dimension in 0..<dim {
                        let previous = globalCentroids[bestGlobal][dimension]
                        let incoming = localCentroid[dimension]
                        let blended: Float = (previous * oldWeight + incoming * localWeight) / denominator
                        globalCentroids[bestGlobal][dimension] = blended
                    }
                    globalCounts[bestGlobal] = newCount
                } else {
                    globalLabel = globalCentroids.count
                    globalCentroids.append(localCentroid)
                    globalCounts.append(memberIndexes.count)
                }

                for localIndex in memberIndexes {
                    let globalIndex = range.lowerBound + localIndex
                    // Overlap belongs to the first batch that saw it. The
                    // second batch still contributes to centroid alignment.
                    if labels[globalIndex] < 0 {
                        labels[globalIndex] = globalLabel
                    }
                }
            }
        }

        return labels.allSatisfy { $0 >= 0 } ? labels : []
    }

    /// Deterministic ranges used by oversized clustering. The overlap stays
    /// inside the per-batch memory ceiling.
    static func batchRanges(
        count: Int,
        batchSize: Int = denseSpectralMaxChunks,
        overlap: Int = 256
    ) -> [Range<Int>] {
        SpectralGraphAlgorithms.batchRanges(
            count: count,
            batchSize: batchSize,
            overlap: overlap,
            maximumBatchSize: denseSpectralMaxChunks
        )
    }

    /// Kept internal for boundary tests. Callers may request a smaller batch
    /// for diagnostics, but can never opt into an unsafe dense allocation.
    static func boundedDenseBatchLimit(_ requested: Int) -> Int {
        min(max(2, requested), denseSpectralMaxChunks)
    }

    /// Produces the same dense P-pruned graph as the serial implementation.
    ///
    /// Accelerate owns the parallelism inside SGEMM above. Only the
    /// independent row-local min-heaps run concurrently here, and their
    /// worker count is bounded by performance cores so the two phases do not
    /// oversubscribe the CPU. Each worker first records its selections and
    /// final dense writes happen in a fixed order, making the output bit
    /// identical to the one-worker path.
    static func prunedAffinityMatrix(
        _ affinityMatrix: [Float],
        count: Int,
        retainedCount: Int,
        workerCount requestedWorkerCount: Int? = nil
    ) -> [Float] {
        SpectralGraphAlgorithms.prunedAffinityMatrix(
            affinityMatrix,
            count: count,
            retainedCount: retainedCount,
            workerCount: requestedWorkerCount
        )
    }

    /// Returns indexes of the largest keep values in one contiguous matrix
    /// row. The binary min-heap is O(N log K), whereas a full sort is
    /// O(N log N); no affinity value is approximated or recomputed.
    static func topKIndices(
        values: [Float],
        offset: Int,
        count: Int,
        keep: Int
    ) -> [Int] {
        SpectralGraphAlgorithms.topKIndices(
            values: values,
            offset: offset,
            count: count,
            keep: keep
        )
    }

    /// Matches FunASR `SpectralCluster.get_spec_embs`: for candidate K, the
    /// eigengap is lambda[K] - lambda[K - 1]. Starting at `minNumSpks - 1`
    /// is essential: starting at `minNumSpks` skips the two-speaker gap and
    /// systematically favors an extra cluster in two-speaker recordings.
    static func speakerCountFromEigenvalues(
        _ eigenvalues: [Float],
        minNumSpks: Int,
        maxNumSpks: Int
    ) -> Int {
        guard eigenvalues.count >= 2 else { return max(1, minNumSpks) }

        let minimum = min(max(1, minNumSpks), eigenvalues.count - 1)
        let maximum = min(max(minimum, maxNumSpks), eigenvalues.count - 1)
        let gapCount = maximum - (minimum - 1)  // gap[i] = eigenvalues[i+1] - eigenvalues[i]
        guard gapCount > 0 else { return minimum }

        // vDSP: 一次性算 diff + argmax。
        //   gap[i] = eigenvalues[(minimum - 1) + i + 1] - eigenvalues[(minimum - 1) + i]
        //   bestK = (minimum - 1) + argmax(gap) + 1
        // 30 个 eigenvalue 的小数组,SIMD 收益主要是省 dispatch,不是省算量。
        // bit-exact 跟原标量一致 (Float - Float 一拍 SIMD 减,无 Double 中间精度问题)。
        return eigenvalues.withUnsafeBufferPointer { ebuf in
            guard let ebase = ebuf.baseAddress else { return minimum }
            let baseIdx = minimum - 1
            var gaps = [Float](repeating: 0, count: gapCount)
            gaps.withUnsafeMutableBufferPointer { gbuf in
                guard let gbase = gbuf.baseAddress else { return }
                // vDSP_vsub(A, B, C) → C = B - A。
                // 要 C[i] = e[i+1] - e[i]:A = e[i] (减数),B = e[i+1] (被减数)
                vDSP_vsub(
                    ebase.advanced(by: baseIdx), 1,
                    ebase.advanced(by: baseIdx + 1), 1,
                    gbase, 1,
                    vDSP_Length(gapCount)
                )
            }
            var maxGap: Float = 0
            var maxIdx: vDSP_Length = 0
            gaps.withUnsafeBufferPointer { gbuf in
                guard let gbase = gbuf.baseAddress else { return }
                vDSP_maxvi(gbase, 1, &maxGap, &maxIdx, vDSP_Length(gapCount))
            }
            // 跟原 `if gap > maxGap { maxGap = gap; bestK = index + 1 }` 一致:
            // vDSP_maxvi 在并列时取最小 idx,标量 `>` 严格比较也是保留首次出现 (= 最小 index) → bit-exact。
            return baseIdx + Int(maxIdx) + 1
        }
    }
    
    public func directKMeans(embeddings: [Float], count: Int, k: Int) -> [Int] {
        guard count > 0, k > 0, k <= count,
              embeddings.count == count * 192,
              embeddings.allSatisfy(\.isFinite) else {
            Logger.shared.error(
                "SpectralClustering: invalid direct K-Means input (count=\(count), k=\(k), values=\(embeddings.count))."
            )
            return []
        }
        return Self.runKMeans(data: embeddings, n: count, k: k, dim: 192)
    }
    
    /// 2026-07-26 P2 F3.7: cluster() 入口的前置校验（count / dim /
    /// finite / batchLimit）抽到独立 helper。5 个 outcome 走 enum
    /// 让 caller 一个 switch 处理，避免之前一连串 guard + 早退的写法。
    /// 日志在 helper 内发，caller 不再关心 log 路径。
    private enum Preflight {
        case empty                // count == 0
        case singleSpeaker        // count == 1
        case batched              // count > batchLimit, need clusterInBatches
        case rejected             // dim mismatch or non-finite
        case proceed              // all checks pass
    }

    private func preflightCluster(
        embeddings: [Float],
        count: Int,
        forceK: Int?
    ) -> Preflight {
        if count == 0 { return .empty }
        if count == 1 { return .singleSpeaker }

        let dim = 192
        guard embeddings.count == count * dim else {
            Logger.shared.error("SpectralClustering: Embeddings dimension mismatch.")
            return .rejected
        }
        // 全数组 isFinite check: 用 vDSP_sve 一次性求和再判 finite。
        // 任一元素 NaN/Inf 都会让 sum 变 NaN/Inf,反之全 finite 元素求和也 finite (FP32 不会溢出 5284*192*1e10 这种量级)。
        // 跟 SpeakerONNXEngine 80d3360 同模式。
        var embeddingsSum: Float = 0
        embeddings.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_sve(base, 1, &embeddingsSum, vDSP_Length(ptr.count))
        }
        guard embeddingsSum.isFinite else {
            Logger.shared.error("SpectralClustering: non-finite embedding value found; refusing to emit labels.")
            return .rejected
        }
        if count > batchLimit {
            Logger.shared.info("SpectralClustering: \(count) chunks > batch limit \(batchLimit); clustering in overlapping batches.")
            return .batched
        }
        _ = forceK  // forceK 仅在 bestK 选择时用，不影响 preflight
        return .proceed
    }

    /// 2026-07-26 P2 F3.7: ssyevr_ 调用抽到独立 static 函数。LAPACK
    /// 调用本来就是无状态的：workspace query + actual 两次调用 + workspace
    /// 分配 + result 拷贝。把它从 cluster body 抽出来，cluster body
    /// 只剩 5 行（`runEigenDecomposition(laplacian:count:kEigengapLimit:)`）。
    /// EigenDecomposition 是 Sendable 值类型，所有 out-param 都打包在里面。
    struct EigenDecomposition: Sendable {
        let m: Int
        let info: Int32
        let eigenvalues: [Float]
        let z: [Float]
        let lwork: Int32
        let liwork: Int32
    }

    static func runEigenDecomposition(
        laplacian: inout [Float],
        count: Int,
        kEigengapLimit: Int
    ) -> EigenDecomposition {
        let result = SpectralSolverAlgorithms.runEigenDecomposition(
            laplacian: &laplacian,
            count: count,
            kEigengapLimit: kEigengapLimit
        )
        return EigenDecomposition(
            m: result.m,
            info: result.info,
            eigenvalues: result.eigenvalues,
            z: result.eigenvectors,
            lwork: result.lwork,
            liwork: result.liwork
        )
    }

    /// Shared by the dense route and opt-in spectral diagnostics. The caller
    /// supplies the spectral feature width, so this is not limited to 192-D
    /// speaker embeddings.
    static func runKMeans(data: [Float], n: Int, k: Int, dim: Int) -> [Int] {
        SpectralSolverAlgorithms.runKMeans(
            data: data,
            sampleCount: n,
            clusterCount: k,
            dimension: dim
        )
    }

    /// Drives the 12-event onProgress sequence for the 6 fixed cluster
    /// stages (6 × 2: each stage emits a (label, 0.0) on entry and a
    /// (label, 1.0) on exit). The 6th endStage fires the final 1.0
    /// event and no further start.
    ///
    /// Encapsulating the 12 explicit `onProgress?(label, fraction)`
    /// calls keeps the cluster() body focused on algorithm work; the
    /// progress mapping (which stage boundary maps to which label) is
    /// in one place.
    private struct StageReporter {
        let onProgress: ((String, Double) -> Void)?
        private var currentIndex: Int = 0
        private static let stages: [String] = [
            "数据标准化",
            "计算相似度",
            "挑选邻近关系",
            "构建图矩阵",
            "求解聚类数",
            "分配说话人"
        ]

        fileprivate init(onProgress: ((String, Double) -> Void)?) {
            self.onProgress = onProgress
        }

        mutating func beginStage() {
            guard currentIndex < Self.stages.count else { return }
            onProgress?(Self.stages[currentIndex], 0.00)
        }

        mutating func endStage() {
            guard currentIndex < Self.stages.count else { return }
            let ended = Self.stages[currentIndex]
            currentIndex += 1
            onProgress?(ended, 1.00)
            if currentIndex < Self.stages.count {
                onProgress?(Self.stages[currentIndex], 0.00)
            }
        }
    }

}
