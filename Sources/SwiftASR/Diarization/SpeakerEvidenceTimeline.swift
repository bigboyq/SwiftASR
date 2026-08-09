import Foundation

/// Retains every packed-window/profile cosine score until final token routing.
/// No stage is allowed to collapse this plane to a hard TOP1 label.
struct SpeakerEvidenceTimeline: Sendable {
    struct TokenEvidence: Sendable {
        let tokenID: TokenTimeline.TokenID
        let scores: [Int: Float]
        let supportFrames: Int
        /// Distinct packed observations contributing evidence.  This is kept
        /// separately from frame coverage because the router's continuity
        /// gate is deliberately expressed in model observations, not words.
        let supportWindowIDs: Set<Int>

        init(
            tokenID: TokenTimeline.TokenID,
            scores: [Int: Float],
            supportFrames: Int,
            supportWindowIDs: Set<Int> = []
        ) {
            self.tokenID = tokenID
            self.scores = scores
            self.supportFrames = supportFrames
            self.supportWindowIDs = supportWindowIDs
        }

        // R4-P2-9：删除 `var supportWindowCount: Int { supportWindowIDs.count }`，
        // 它在生产路径无 caller（`supportWindowIDs` 仅 round-trip / 诊断用）。

        var ranked: [(label: Int, score: Float)] {
            scores.map { ($0.key, $0.value) }.sorted { left, right in
                if left.score == right.score { return left.label < right.label }
                if left.score.isNaN { return false }
                if right.score.isNaN { return true }
                return left.score > right.score
            }
        }
        var topScore: Float { ranked.first?.score ?? -.infinity }
        var topLabel: Int? { ranked.first?.label }
        /// 胜出 label 与次优 label 的 score 差。
        ///
        /// R4-P1-7：单 label token 视为**无歧义证据**，它的 margin 直接取
        /// 该 token 的 `topScore`（即唯一 score），而不是 `+infinity`。原来
        /// 返回 `+infinity` 会让 L1 投票把它计入 `totalVotes` 分母，却因
        /// `isFinite` 守卫被排除出 `voterMarginSum` 分子，系统性压低
        /// `avgVoterMargin`，可能把本应 `.direct` 的强单 label sub 压成
        /// `.pending`。
        ///
        /// 退化情形：scores 为空时 `topScore` 是 `-.infinity`，margin 也变成
        /// `-.infinity`。下游（L1/L2）对 margin 都有 finite 守卫，不会把
        /// 非有限值塞进 accepted confidence。
        var margin: Float {
            let values = ranked
            guard let top = values.first else { return -.infinity }
            guard values.count > 1 else { return top.score }
            return top.score - values[1].score
        }
    }

    let tokenEvidence: [TokenTimeline.TokenID: TokenEvidence]
    let profileLabels: [Int]

    static func stub(_ evidence: [TokenEvidence]) -> SpeakerEvidenceTimeline {
        SpeakerEvidenceTimeline(
            tokenEvidence: Dictionary(uniqueKeysWithValues: evidence.map { ($0.tokenID, $0) }),
            profileLabels: Array(Set(evidence.flatMap { $0.scores.keys })).sorted()
        )
    }

    private init(tokenEvidence: [TokenTimeline.TokenID: TokenEvidence], profileLabels: [Int]) {
        self.tokenEvidence = tokenEvidence
        self.profileLabels = profileLabels
    }

    init(
        timeline: TokenTimeline,
        windows: [TokenPackedWindowPlanner.Window],
        embeddings: [Float],
        profileCentroids: [Int: [Float]],
        embeddingDimension: Int = 192
    ) {
        let labels = profileCentroids.keys.sorted()
        profileLabels = labels
        // 2026-07-26 M3 (vDSP batch experiment): sgemm-based cosineMatrix
        // path bit-exacts the ASR fingerprint but flips 2 turn decisions
        // (turns 62 → 60) because sgemm's block reduction changes the
        // last-ULP order of `cosine` scores, which sits on the L1/L2
        // margin threshold for exactly 2 tokens.  Reverted to the
        // per-pair `cosineSimilarity` path below.  The batch helper stays
        // in `SpeakerOrchestrator.cosineMatrix` for future diagnostic /
        // large-fixture work where a 2-turn regression is acceptable.
        var weightedSums: [TokenTimeline.TokenID: [Int: Float]] = [:]
        var weights: [TokenTimeline.TokenID: Int] = [:]
        var supportWindowIDs: [TokenTimeline.TokenID: Set<Int>] = [:]
        for (index, window) in windows.enumerated() {
            let offset = index * embeddingDimension
            guard offset + embeddingDimension <= embeddings.count else { continue }
            let embedding = Array(embeddings[offset..<(offset + embeddingDimension)])
            let scores = Dictionary(uniqueKeysWithValues: labels.map {
                ($0, SpeakerOrchestrator.cosineSimilarity(embedding, profileCentroids[$0] ?? []))
            })
            for (position, tokenID) in window.tokenIDs.enumerated() {
                let weight: Int
                if window.tokenFrameCounts.count == window.tokenIDs.count {
                    weight = window.tokenFrameCounts[position]
                } else {
                    // Compatibility for hand-built diagnostic windows created
                    // before tokenFrameCounts existed. Production windows
                    // always carry token-aligned totals.
                    weight = position < window.spans.count ? window.spans[position].sourceFrames.count : 0
                }
                guard weight > 0 else { continue }
                for label in labels {
                    weightedSums[tokenID, default: [:]][label, default: 0] += (scores[label] ?? 0) * Float(weight)
                }
                weights[tokenID, default: 0] += weight
                supportWindowIDs[tokenID, default: []].insert(index)
            }
        }
        var output: [TokenTimeline.TokenID: TokenEvidence] = [:]
        for token in timeline.tokens {
            let weight = weights[token.id, default: 0]
            let sums = weightedSums[token.id, default: [:]]
            let scores = Dictionary(uniqueKeysWithValues: labels.map {
                ($0, weight > 0 ? (sums[$0, default: 0] / Float(weight)) : -.infinity)
            })
            output[token.id] = TokenEvidence(
                tokenID: token.id, scores: scores, supportFrames: weight,
                supportWindowIDs: supportWindowIDs[token.id, default: []]
            )
        }
        tokenEvidence = output
    }
}
