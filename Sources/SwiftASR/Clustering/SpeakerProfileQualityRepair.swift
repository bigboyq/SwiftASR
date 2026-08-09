import Foundation

extension SpeakerOrchestrator {
    /// Profile 阶段唯一的质量修复主路径。
    ///
    /// 先处理 profile 级垃圾类簇，再处理 partition 级 collapse/lopsided；
    /// 两者共享同一个质量报告，但保留现有修复算法和阈值。
    func repairProfileQuality(
        labels: [Int],
        profiles: [SpeakerProfileData],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int,
        policy: SpeakerTemporalPolicy
    ) -> ProfileRepairResult {
        let repairedGarbage = pruneGarbageProfiles(
            labels: labels,
            profiles: profiles,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy
        )
        let currentLabels = repairedGarbage.labels
        let currentProfiles = repairedGarbage.profiles
        let quality = repairedGarbage.quality

        if currentProfiles.count > 1 {
            logPreMergeSims(currentProfiles)
        }

        let reason: String
        if currentProfiles.count < 2 {
            reason = "primary collapsed to \(currentProfiles.count) profile(s)"
        } else if quality.hasCollapsedCoverage {
            reason = "primary returned \(currentProfiles.count) profiles but profile quality reports lopsided coverage (dominant profile spans entire audio)"
        } else {
            return adaptiveMergeAndReturn(
                labels: currentLabels,
                profiles: currentProfiles,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim,
                policy: policy,
                fallbackTriggered: false,
                fallbackReason: nil
            )
        }

        if chunks.count < Self.minChunksForFallback {
            Logger.shared.warn("SpeakerOrchestrator: fallback needed but chunks=\(chunks.count) < \(Self.minChunksForFallback); keeping primary")
            return adaptiveMergeAndReturn(
                labels: currentLabels,
                profiles: currentProfiles,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim,
                policy: policy,
                fallbackTriggered: true,
                fallbackReason: "below_min_chunks(\(chunks.count))"
            )
        }

        // 保留现有 collapse fallback：改变 pval，重新跑一次 eigengap + spectral clustering。
        Logger.shared.warn("SpeakerOrchestrator: fallback triggered: \(reason) (chunks=\(chunks.count))")
        let fallbackClustering = SpectralClustering(minNumSpks: 2, maxNumSpks: 15, pval: 0.05)
        let rawFallbackLabels = fallbackClustering.cluster(embeddings: embeddings, count: chunks.count)
        guard rawFallbackLabels.count == chunks.count else {
            Logger.shared.error(
                "SpeakerOrchestrator: fallback clustering failed; preserving the current partition " +
                "(expected=\(chunks.count), actual=\(rawFallbackLabels.count))."
            )
            return adaptiveMergeAndReturn(
                labels: currentLabels,
                profiles: currentProfiles,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim,
                policy: policy,
                fallbackTriggered: true,
                fallbackReason: reason
            )
        }
        let mergedFallbackLabels = mergeLabelsByCos(
            labels: rawFallbackLabels,
            embeddings: embeddings,
            count: chunks.count,
            dim: dim,
            threshold: Self.mergeThreshold
        )
        let fallbackLabels = keepRawLabelsIfMergeCollapsedEverything(
            rawLabels: rawFallbackLabels,
            mergedLabels: mergedFallbackLabels,
            count: chunks.count,
            stage: "fallback"
        )
        let fallbackProfiles = buildProfiles(
            labels: fallbackLabels,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy
        )

        if fallbackProfiles.count >= 2 {
            Logger.shared.info("SpeakerOrchestrator: fallback recovered \(fallbackProfiles.count) speakers (primary \(currentProfiles.count))")
            return adaptiveMergeAndReturn(
                labels: fallbackLabels,
                profiles: fallbackProfiles,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim,
                policy: policy,
                fallbackTriggered: true,
                fallbackReason: reason
            )
        }

        Logger.shared.warn("SpeakerOrchestrator: fallback also collapsed to \(fallbackProfiles.count); keeping primary")
        return adaptiveMergeAndReturn(
            labels: currentLabels,
            profiles: currentProfiles,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy,
            fallbackTriggered: true,
            fallbackReason: reason
        )
    }

    /// 5 个 `adaptiveMergeAndReturn` 包装合并为一个 helper.
    /// repairProfileQuality 的 5 条 fallback 出口都长这样:
    ///   adaptive -> ProfileRepairResult(labels, profiles, fallbackTriggered, fallbackReason)
    /// 抽到一个 instance helper 节省 ~70 行模板代码.
    /// (instance method 而非 static - `adaptivelyMergeFragmentShadows` 是 instance method)
    private func adaptiveMergeAndReturn(
        labels: [Int],
        profiles: [SpeakerProfileData],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int,
        policy: SpeakerTemporalPolicy,
        fallbackTriggered: Bool,
        fallbackReason: String?
    ) -> ProfileRepairResult {
        let adaptive = SpeakerFragmentShadowMerger.merge(
            labels: labels,
            profiles: profiles,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy
        )
        return ProfileRepairResult(
            labels: adaptive.labels,
            profiles: adaptive.profiles,
            fallbackTriggered: fallbackTriggered,
            fallbackReason: fallbackReason
        )
    }

    /// 把 pre-merge cosine sim 调试日志从 inline 16 行循环抽到独立 helper.
    private func logPreMergeSims(_ profiles: [SpeakerProfileData]) {
        guard profiles.count > 1 else { return }
        var sims: [String] = []
        for i in 0..<profiles.count {
            for j in (i + 1)..<profiles.count {
                let sim = cosineSimDebug(profiles[i].centroidEmbedding, profiles[j].centroidEmbedding)
                sims.append("\(i)-\(j)=\(String(format: "%.3f", sim))")
            }
        }
        Logger.shared.info("SpeakerOrchestrator: pre-merge cos sims: \(sims.joined(separator: ", ")) (threshold=\(Self.mergeThreshold))")
    }


    // MARK: - profile 构建

    func buildProfiles(
        labels: [Int],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int,
        policy: SpeakerTemporalPolicy
    ) -> [SpeakerProfileData] {
        SpeakerProfileAssembler.build(
            labels: labels,
            chunks: chunks,
            embeddings: embeddings,
            dimension: dim,
            policy: policy
        )
    }

    // MARK: - 统一 profile 质量评估

    /// 统一收集 profile 级别和 partition 级别的健康信号。
    ///
    /// 本阶段不引入新的阈值，也不负责选择候选 K；它只把原先分散在
    /// `pruneGarbageProfiles` 和 collapse fallback 里的判断集中起来。
    private func evaluateProfileQuality(
        labels: [Int],
        profiles: [SpeakerProfileData],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int
    ) -> ProfileQualityReport {
        var garbageProfileIndices = Set<Int>()
        let profileLabels = Set(labels.filter { $0 >= 0 }).sorted()
        if profiles.count >= 3 {
            for idx in profiles.indices {
                guard idx < profileLabels.count else { continue }
                let profile = profiles[idx]
                let cohesion = calculateCohesion(
                    profile: profile,
                    embeddings: embeddings,
                    labels: labels,
                    dim: dim,
                    profileLabel: profileLabels[idx]
                )
                if profile.totalDurationMs < 18000 && cohesion < 0.65 {
                    garbageProfileIndices.insert(idx)
                }
            }
        }

        let hasCollapsedCoverage = profiles.count >= 2 && looksLikeCollapsedFirstHalf(
            labels: labels,
            chunks: chunks
        )
        return ProfileQualityReport(
            garbageProfileIndices: garbageProfileIndices,
            hasCollapsedCoverage: hasCollapsedCoverage
        )
    }

    // MARK: - partition 级别 collapse 检测（FunASR `_looks_like_collapsed_first_half`）

    /// "dominant profile covers 80%+ audio span AND starts < 5% AND at least one other
    /// profile starts after 30%" → 折叠 bug
    ///
    /// 跟 FunASR-Mac `_looks_like_collapsed_first_half` 对齐（_speaker_fallback.py:71-151）。
    /// 直接从 labels + chunks 算 per-profile range，不依赖 SpeakerProfileData.segments。
    func looksLikeCollapsedFirstHalf(
        labels: [Int],
        chunks: [(startMs: Int, endMs: Int)]
    ) -> Bool {
        // 1. unique labels < 2 → false
        let uniqueLabels = Set(labels)
        guard uniqueLabels.count >= 2 else { return false }

        // 2. 拼 spans，过滤 endMs > startMs
        var spans: [(Int, Int)] = []
        for chunk in chunks {
            if chunk.endMs > chunk.startMs {
                spans.append((chunk.startMs, chunk.endMs))
            }
        }
        guard spans.count >= 2 else { return false }

        // 3. audio 整体 span
        let audioStart = spans.map { $0.0 }.min()!
        let audioEnd = spans.map { $0.1 }.max()!
        let audioSpan = audioEnd - audioStart
        guard audioSpan > 0 else { return false }

        // 4. per-label range（min start, max end）
        var profileRanges: [(Int, Int)] = []
        for label in uniqueLabels {
            let memberChunks = zip(labels, chunks).filter { $0.0 == label }.map { $0.1 }
            let valid = memberChunks.filter { $0.endMs > $0.startMs }
            guard !valid.isEmpty else { continue }
            let starts = valid.map { $0.startMs }
            let ends = valid.map { $0.endMs }
            profileRanges.append((starts.min()!, ends.max()!))
        }
        guard profileRanges.count >= 2 else { return false }

        // 5. biggest profile by span
        profileRanges.sort { ($0.1 - $0.0) > ($1.1 - $1.0) }
        let (biggestStart, biggestEnd) = profileRanges[0]
        let biggestSpan = biggestEnd - biggestStart

        // 6. 三道阈值（跟 Python 版完全一致）
        let coverageT = Self.collapseCoverageThreshold   // 0.80
        let startT    = Self.collapseStartThreshold      // 0.05
        let lateT     = Self.collapseLateThreshold       // 0.30

        if Double(biggestSpan) < coverageT * Double(audioSpan) { return false }
        if Double(biggestStart - audioStart) > startT * Double(audioSpan) { return false }
        let lateThreshold = audioStart + Int(Double(audioSpan) * lateT)
        if !profileRanges.dropFirst().contains(where: { $0.0 >= lateThreshold }) { return false }

        return true
    }

    func keepRawLabelsIfMergeCollapsedEverything(
        rawLabels: [Int],
        mergedLabels: [Int],
        count: Int,
        stage: String
    ) -> [Int] {
        let rawCount = Set(rawLabels).count
        let mergedCount = Set(mergedLabels).count
        if count >= Self.minChunksForFallback, rawCount >= 2, mergedCount < 2 {
            Logger.shared.warn("SpeakerOrchestrator: \(stage) cosine merge collapsed \(rawCount) raw clusters to 1; keeping raw spectral labels")
            return renumber(rawLabels)
        }
        return mergedLabels
    }

    func renumber(_ labels: [Int], preservingNegativeLabels: Bool = false) -> [Int] {
        let remaining = Array(Set(labels.filter { !preservingNegativeLabels || $0 >= 0 })).sorted()
        var remap: [Int: Int] = [:]
        for (index, label) in remaining.enumerated() { remap[label] = index }
        return labels.map { label in
            if preservingNegativeLabels, label < 0 { return label }
            return remap[label] ?? 0
        }
    }

    func mergeLabelsByCos(
        labels: [Int],
        embeddings: [Float],
        count: Int,
        dim: Int,
        threshold: Float
    ) -> [Int] {
        guard labels.count == count,
              count >= 0,
              dim > 0,
              embeddings.count == count * dim else {
            Logger.shared.error(
                "SpeakerOrchestrator: refusing cosine merge with mismatched inputs " +
                "(labels=\(labels.count), count=\(count), embeddings=\(embeddings.count), dim=\(dim))."
            )
            return []
        }
        var labelsCopy = labels
        while true {
            let activeLabels = Array(Set(labelsCopy)).sorted()
            guard activeLabels.count >= 2 else { break }

            var centers: [Int: [Float]] = [:]
            for label in activeLabels {
                var center = [Float](repeating: 0, count: dim)
                var memberCount = 0
                for index in 0..<count where labelsCopy[index] == label {
                    memberCount += 1
                    let offset = index * dim
                    for component in 0..<dim {
                        center[component] += embeddings[offset + component]
                    }
                }
                guard memberCount > 0 else { continue }
                for component in 0..<dim { center[component] /= Float(memberCount) }
                normalize(&center)
                centers[label] = center
            }

            var bestPair: (left: Int, right: Int)?
            var bestSim: Float = -.infinity
            for i in 0..<activeLabels.count {
                for j in (i + 1)..<activeLabels.count {
                    let left = activeLabels[i]
                    let right = activeLabels[j]
                    guard let leftCenter = centers[left], let rightCenter = centers[right] else { continue }
                    let sim = Self.vDSPCosine(leftCenter, rightCenter)
                    if sim > bestSim {
                        bestSim = sim
                        bestPair = (left, right)
                    }
                }
            }
            guard let pair = bestPair, bestSim >= threshold else { break }
            // Recompute centers from the updated partition on the next pass;
            // comparing stale pre-merge centers can trigger a wrong chain merge.
            for index in labelsCopy.indices where labelsCopy[index] == pair.right {
                labelsCopy[index] = pair.left
            }
        }

        let remaining = Array(Set(labelsCopy)).sorted()
        for i in labelsCopy.indices {
            if let newLabel = remaining.firstIndex(of: labelsCopy[i]) {
                labelsCopy[i] = newLabel
            }
        }
        return labelsCopy
    }

    private func normalize(_ values: inout [Float]) {
        var sumSq: Float = 0
        for v in values { sumSq += v * v }
        let norm = sqrt(sumSq)
        guard norm > 1e-10 else { return }
        for i in values.indices {
            values[i] /= norm
        }
    }

    // DEBUG
    private func cosineSimDebug(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0; var na: Float = 0; var nb: Float = 0
        let n = min(a.count, b.count)
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        return denom > 1e-10 ? dot / denom : 0
    }

    private func calculateCohesion(
        profile: SpeakerProfileData,
        embeddings: [Float],
        labels: [Int],
        dim: Int,
        profileLabel: Int
    ) -> Float {
        var sumSim: Float = 0
        var matchCount = 0
        for i in 0..<labels.count {
            if labels[i] == profileLabel {
                let off = i * dim
                let emb = Array(embeddings[off..<(off+dim)])
                let sim = Self.vDSPCosine(profile.centroidEmbedding, emb)
                sumSim += sim
                matchCount += 1
            }
        }
        return matchCount > 0 ? sumSim / Float(matchCount) : 0.0
    }
    
    private func pruneGarbageProfiles(
        labels: [Int],
        profiles: [SpeakerProfileData],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int,
        policy: SpeakerTemporalPolicy
    ) -> (labels: [Int], profiles: [SpeakerProfileData], quality: ProfileQualityReport) {
        guard profiles.count >= 3 else {
            return (
                labels,
                profiles,
                evaluateProfileQuality(
                    labels: labels,
                    profiles: profiles,
                    chunks: chunks,
                    embeddings: embeddings,
                    dim: dim
                )
            )
        }

        switch runGarbageProfileIterations(
            labels: labels,
            profiles: profiles,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy
        ) {
        case let .finished(currentLabels, currentProfiles, quality):
            return (currentLabels, currentProfiles, quality)
        case let .failed(currentLabels, currentProfiles, quality):
            return (currentLabels, currentProfiles, quality)
        case let .fallback(currentLabels, currentProfiles, quality, garbageIndices):
            return applyGarbageProfileFallback(
                labels: currentLabels,
                profiles: currentProfiles,
                quality: quality,
                garbageIndices: garbageIndices,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim,
                policy: policy
            )
        }

    }

    private enum GarbageProfileIterationOutcome {
        case finished(labels: [Int], profiles: [SpeakerProfileData], quality: ProfileQualityReport)
        case fallback(labels: [Int], profiles: [SpeakerProfileData], quality: ProfileQualityReport, garbageIndices: Set<Int>)
        case failed(labels: [Int], profiles: [SpeakerProfileData], quality: ProfileQualityReport)
    }

    private func runGarbageProfileIterations(
        labels: [Int],
        profiles: [SpeakerProfileData],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int,
        policy: SpeakerTemporalPolicy
    ) -> GarbageProfileIterationOutcome {
        var currentLabels = labels
        var currentProfiles = profiles

        for iteration in 1...3 {
            let quality = evaluateProfileQuality(
                labels: currentLabels,
                profiles: currentProfiles,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim
            )
            let garbageIndices = quality.garbageProfileIndices
            if garbageIndices.isEmpty {
                return .finished(labels: currentLabels, profiles: currentProfiles, quality: quality)
            }

            let healthyK = currentProfiles.count - garbageIndices.count
            guard healthyK >= 2 else {
                Logger.shared.warn("SpeakerOrchestrator: [Iteration \(iteration)] Healthy K (\(healthyK)) < 2. Falling back to local assignment.")
                return .fallback(
                    labels: currentLabels,
                    profiles: currentProfiles,
                    quality: quality,
                    garbageIndices: garbageIndices
                )
            }

            Logger.shared.info("SpeakerOrchestrator: [Iteration \(iteration)] Found \(garbageIndices.count) garbage profiles. Re-clustering globally with forced K = \(healthyK)...")
            let rawHealedLabels = clustering.cluster(embeddings: embeddings, count: labels.count, forceK: healthyK)
            guard rawHealedLabels.count == labels.count else {
                Logger.shared.error(
                    "SpeakerOrchestrator: healed clustering failed at iteration \(iteration); " +
                    "preserving the current partition (expected=\(labels.count), actual=\(rawHealedLabels.count))."
                )
                return .failed(labels: currentLabels, profiles: currentProfiles, quality: quality)
            }

            let mergedHealedLabels = mergeLabelsByCos(
                labels: rawHealedLabels,
                embeddings: embeddings,
                count: labels.count,
                dim: dim,
                threshold: Self.mergeThreshold
            )
            let healedLabels = keepRawLabelsIfMergeCollapsedEverything(
                rawLabels: rawHealedLabels,
                mergedLabels: mergedHealedLabels,
                count: labels.count,
                stage: "healed_iter_\(iteration)"
            )
            currentLabels = healedLabels
            currentProfiles = buildProfiles(
                labels: healedLabels,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim,
                policy: policy
            )
        }

        let quality = evaluateProfileQuality(
            labels: currentLabels,
            profiles: currentProfiles,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim
        )
        if quality.garbageProfileIndices.isEmpty {
            return .finished(labels: currentLabels, profiles: currentProfiles, quality: quality)
        }
        return .fallback(
            labels: currentLabels,
            profiles: currentProfiles,
            quality: quality,
            garbageIndices: quality.garbageProfileIndices
        )
    }

    private func applyGarbageProfileFallback(
        labels: [Int],
        profiles: [SpeakerProfileData],
        quality: ProfileQualityReport,
        garbageIndices: Set<Int>,
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int,
        policy: SpeakerTemporalPolicy
    ) -> (labels: [Int], profiles: [SpeakerProfileData], quality: ProfileQualityReport) {
        guard !garbageIndices.isEmpty else { return (labels, profiles, quality) }

        let currentProfileLabels = Set(labels.filter { $0 >= 0 }).sorted()
        var validProfiles: [(label: Int, centroid: [Float])] = []
        for idx in 0..<profiles.count where !garbageIndices.contains(idx) && idx < currentProfileLabels.count {
            validProfiles.append((currentProfileLabels[idx], profiles[idx].centroidEmbedding))
        }

        var reassignedLabels = labels
        for i in reassignedLabels.indices where garbageIndices.contains(reassignedLabels[i]) {
            let off = i * dim
            let emb = Array(embeddings[off..<(off + dim)])
            var bestIdx = -1
            var bestSim: Float = -1.0
            for profile in validProfiles {
                let sim = Self.vDSPCosine(emb, profile.centroid)
                if sim > bestSim {
                    bestSim = sim
                    bestIdx = profile.label
                }
            }
            reassignedLabels[i] = bestSim < policy.sentinelInterjectionThreshold ? -1 : bestIdx
        }

        let renumbered = renumber(reassignedLabels, preservingNegativeLabels: true)
        let cleanProfiles = buildProfiles(
            labels: renumbered,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy
        )
        let finalQuality = evaluateProfileQuality(
            labels: renumbered,
            profiles: cleanProfiles,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim
        )
        return (renumbered, cleanProfiles, finalQuality)
    }
}
