import Foundation

/// Repairs duplicate speakers and short acoustic shadow fragments after profile construction.
///
/// This type owns the complete adaptive-merge decision loop so the quality-repair orchestrator
/// can focus on selecting between primary, healed, and fallback partitions. Keep the thresholds
/// and pair iteration order stable: both affect deterministic speaker labels.
struct SpeakerFragmentShadowMerger {
    static func merge(
        labels: [Int],
        profiles: [SpeakerProfileData],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int,
        policy: SpeakerTemporalPolicy
    ) -> (labels: [Int], profiles: [SpeakerProfileData]) {
        guard profiles.count >= 2 else { return (labels, profiles) }

        let totalMs = chunks.map { max(0, $0.endMs - $0.startMs) }.reduce(0, +)
        guard totalMs > 0 else { return (labels, profiles) }

        if !policy.enableTripleTrackMerge {
            return mergeWithoutTripleTrack(
                labels: labels,
                profiles: profiles,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim,
                policy: policy,
                totalMs: totalMs
            )
        }

        var currentLabels = labels
        var currentProfiles = profiles

        while true {
            let spkCount = currentProfiles.count
            guard spkCount >= 2 else { break }
            let currentProfileLabels = Set(currentLabels.filter { $0 >= 0 }).sorted()
            guard currentProfileLabels.count == spkCount else { break }

            guard let bestPair = bestMergePair(
                profiles: currentProfiles,
                labels: currentLabels,
                profileLabels: currentProfileLabels,
                embeddings: embeddings,
                dim: dim,
                totalMs: totalMs
            ) else { break }
            let (idxA, idxB, bestScore, mergeRuleName) = bestPair

            // complete-link 相似度约束检测
            if bestScore < 0.74 {
                Logger.shared.warn(
                    "SpeakerOrchestrator: merge rejected due to low score \(bestScore) < 0.74"
                )
                break
            }

            // 挑选被合并的和目标
            let ratioA = Double(currentProfiles[idxA].totalDurationMs) / Double(totalMs)
            let ratioB = Double(currentProfiles[idxB].totalDurationMs) / Double(totalMs)
            let (srcIdx, targetIdx) = ratioA >= ratioB ? (idxB, idxA) : (idxA, idxB)

            let srcLabelString = currentProfiles[srcIdx].speakerLabel
            let targetLabelString = currentProfiles[targetIdx].speakerLabel

            let srcLabel = currentProfileLabels[srcIdx]
            let targetLabel = currentProfileLabels[targetIdx]
            var nextLabels = currentLabels
            for idx in nextLabels.indices {
                if nextLabels[idx] == srcLabel {
                    nextLabels[idx] = targetLabel
                }
            }

            let renumbered = renumber(nextLabels, preservingNegativeLabels: true)
            currentLabels = renumbered

            currentProfiles = buildProfiles(
                labels: renumbered,
                chunks: chunks,
                embeddings: embeddings,
                dim: dim,
                policy: policy
            )
            Logger.shared.info(
                "SpeakerOrchestrator: Adaptively merged shadow profile \(srcLabelString) " +
                "into \(targetLabelString) via [\(mergeRuleName)] rule " +
                "(cos_sim=\(String(format: "%.3f", bestScore)))"
            )
        }

        return (currentLabels, currentProfiles)
    }

    private static func bestMergePair(
        profiles: [SpeakerProfileData],
        labels: [Int],
        profileLabels: [Int],
        embeddings: [Float],
        dim: Int,
        totalMs: Int
    ) -> (Int, Int, Float, String)? {
        var bestPair: (Int, Int, Float, String)?
        let limitMs = min(15000, Int(Double(totalMs) * 0.03))
        for i in 0..<profiles.count {
            for j in (i + 1)..<profiles.count {
                let sim = SpeakerOrchestrator.vDSPCosine(
                    profiles[i].centroidEmbedding,
                    profiles[j].centroidEmbedding
                )
                let isDuplicate = sim >= 0.84
                let isFragI = profiles[i].totalDurationMs < limitMs && profiles[i].chunkCount <= 4
                let isFragJ = profiles[j].totalDurationMs < limitMs && profiles[j].chunkCount <= 4
                let cohesionI = calculateCohesion(
                    profile: profiles[i], embeddings: embeddings, labels: labels,
                    dim: dim, profileLabel: profileLabels[i]
                )
                let cohesionJ = calculateCohesion(
                    profile: profiles[j], embeddings: embeddings, labels: labels,
                    dim: dim, profileLabel: profileLabels[j]
                )
                let isShadowMerge =
                    (isFragI && cohesionI < 0.78 || isFragJ && cohesionJ < 0.78)
                    && sim >= 0.72
                    && (
                        calculateSimilarityMargin(profileIdx: i, profiles: profiles) >= 0.06
                        || calculateSimilarityMargin(profileIdx: j, profiles: profiles) >= 0.06
                    )
                guard (isDuplicate || isShadowMerge), bestPair.map({ sim > $0.2 }) ?? true else { continue }
                bestPair = (i, j, sim, isDuplicate ? "duplicate" : "shadow_fragment")
            }
        }
        return bestPair
    }

    private static func mergeWithoutTripleTrack(
        labels: [Int],
        profiles: [SpeakerProfileData],
        chunks: [(startMs: Int, endMs: Int)],
        embeddings: [Float],
        dim: Int,
        policy: SpeakerTemporalPolicy,
        totalMs: Int
    ) -> (labels: [Int], profiles: [SpeakerProfileData]) {
        var parent: [Int: Int] = [:]
        for idx in 0..<profiles.count { parent[idx] = idx }
        var mergedAny = false
        for i in 0..<profiles.count {
            for j in (i + 1)..<profiles.count {
                let rootI = findRoot(i, in: parent)
                let rootJ = findRoot(j, in: parent)
                if rootI == rootJ { continue }

                let sim = SpeakerOrchestrator.vDSPCosine(
                    profiles[i].centroidEmbedding,
                    profiles[j].centroidEmbedding
                )
                let ratioI = Double(profiles[i].totalDurationMs) / Double(totalMs)
                let ratioJ = Double(profiles[j].totalDurationMs) / Double(totalMs)
                let shouldMerge = sim >= 0.82
                    || ((ratioI < 0.10 || ratioJ < 0.10) && sim >= 0.72)
                guard shouldMerge else { continue }
                if ratioI >= ratioJ { parent[rootJ] = rootI }
                else { parent[rootI] = rootJ }
                mergedAny = true
            }
        }
        guard mergedAny else { return (labels, profiles) }

        var newLabels = labels
        for idx in newLabels.indices {
            let oldVal = newLabels[idx]
            if oldVal >= 0 && oldVal < profiles.count {
                newLabels[idx] = findRoot(oldVal, in: parent)
            }
        }
        let renumbered = renumber(newLabels, preservingNegativeLabels: true)
        let newProfiles = buildProfiles(
            labels: renumbered,
            chunks: chunks,
            embeddings: embeddings,
            dim: dim,
            policy: policy
        )
        return (renumbered, newProfiles)
    }

    private static func buildProfiles(
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

    private static func renumber(
        _ labels: [Int],
        preservingNegativeLabels: Bool
    ) -> [Int] {
        let remaining = Array(Set(labels.filter { !preservingNegativeLabels || $0 >= 0 })).sorted()
        var remap: [Int: Int] = [:]
        for (index, label) in remaining.enumerated() {
            remap[label] = index
        }
        return labels.map { label in
            if preservingNegativeLabels, label < 0 { return label }
            return remap[label] ?? 0
        }
    }

    private static func findRoot(_ label: Int, in parent: [Int: Int]) -> Int {
        var current = label
        while let next = parent[current], next != current {
            current = next
        }
        return current
    }

    private static func calculateCohesion(
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
                let emb = Array(embeddings[off..<(off + dim)])
                let sim = SpeakerOrchestrator.vDSPCosine(profile.centroidEmbedding, emb)
                sumSim += sim
                matchCount += 1
            }
        }
        return matchCount > 0 ? sumSim / Float(matchCount) : 0.0
    }

    private static func calculateSimilarityMargin(
        profileIdx: Int,
        profiles: [SpeakerProfileData]
    ) -> Float {
        guard profiles.count >= 3 else { return 1.0 }
        let targetEmb = profiles[profileIdx].centroidEmbedding
        var sims: [Float] = []
        for i in 0..<profiles.count {
            if i != profileIdx {
                sims.append(
                    SpeakerOrchestrator.vDSPCosine(
                        targetEmb,
                        profiles[i].centroidEmbedding
                    )
                )
            }
        }
        sims.sort(by: >)
        return sims[0] - sims[1]
    }
}
