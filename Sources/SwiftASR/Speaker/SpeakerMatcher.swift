import Foundation

/// Person-level 推荐匹配：先按每条 fingerprint 的相似度排名，再按 person 聚合，
/// 最后取前 N 个不同的人。
///
/// `topPersonMatches` 面向"未归属指纹详情展示 + PersonPickerSheet 推荐"场景。
///
/// 算法：
/// 1. 对每个有效 fingerprint 跟 unbound 算 cosine，并按分数降序排列
/// 2. 按 person 聚合，计算该 person 的 min/max/count；首次出现顺序决定排名
/// 3. 取前 `limit` 个不同的人
///
/// 不落盘：即时调用只负责兜底；常规展示由 SpeakerMatchIndex 复用分数缓存。
public enum SpeakerMatcher {

    /// 单条 fingerprint 的相似度，供实时计算和全局索引共用聚合逻辑。
    struct FingerprintMatch: Equatable, Sendable {
        let profileId: String
        let fingerprintId: String
        let personId: String
        let personName: String
        let score: Float
    }

    /// Person-level 匹配结果
    public struct PersonMatch: Equatable, Sendable {
        public let personId: String
        public let personName: String
        /// 兼容原有 picker：仍表示这个人最高的 fingerprint 相似度。
        public let score: Float
        public let minScore: Float
        public let maxScore: Float
        public let fingerprintCount: Int
        public init(
            personId: String,
            personName: String,
            score: Float,
            fingerprintCount: Int,
            minScore: Float? = nil,
            maxScore: Float? = nil
        ) {
            self.personId = personId
            self.personName = personName
            self.score = score
            self.minScore = minScore ?? score
            self.maxScore = maxScore ?? score
            self.fingerprintCount = fingerprintCount
        }
    }

    /// 给一个 unbound profile，从所有 person 中取 top-N 推荐。
    /// - Parameters:
    ///   - unbound: 未归属的 SpeakerProfile（**必须**有 embedding）
    ///   - boundProfiles: 全部已绑定 person 的 SpeakerProfile（**person != nil**）
    ///   - limit: 返回前 N 个
    ///   - excludingFingerprintId: 可选的当前 fingerprint；该指纹不参与聚合。
    /// - Returns: 按 max cos 降序的 [(Person, Float)]，长度 ≤ limit
    public static func topPersonMatches(
        unbound: SpeakerProfile,
        boundProfiles: [SpeakerProfile],
        limit: Int,
        excludingFingerprintId: String? = nil
    ) -> [PersonMatch] {
        guard let uEmb = unbound.embedding, !uEmb.isEmpty else { return [] }
        guard limit > 0 else { return [] }
        guard !boundProfiles.isEmpty else { return [] }

        // 1. 先以 fingerprint 为单位计算相似度。
        var scored: [FingerprintMatch] = []
        for profile in boundProfiles {
            if let excludingFingerprintId, profile.fingerprintId == excludingFingerprintId { continue }
            guard let person = profile.person else { continue }
            guard let fpEmb = profile.embedding, fpEmb.count == uEmb.count else { continue }
            let score = SpeakerFingerprint.cosine(uEmb, fpEmb)
            guard score.isFinite else { continue }
            scored.append(FingerprintMatch(
                profileId: profile.id,
                fingerprintId: profile.fingerprintId,
                personId: person.id,
                personName: person.name,
                score: score
            ))
        }
        return aggregatePersonMatches(
            scored,
            limit: limit,
            excludingFingerprintId: excludingFingerprintId
        )
    }

    /// 将已计算的 fingerprint 分数聚合为 person-level 结果。
    /// 排序、去重、min/max/count 统一从这里走，避免实时路径和缓存路径产生分叉。
    static func aggregatePersonMatches(
        _ scored: [FingerprintMatch],
        limit: Int,
        excludingFingerprintId: String? = nil
    ) -> [PersonMatch] {
        guard limit > 0 else { return [] }
        let filtered = scored.filter {
            guard let excludingFingerprintId else { return true }
            return $0.fingerprintId != excludingFingerprintId
        }
        guard !filtered.isEmpty else { return [] }
        var ranked = filtered
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.personId != $1.personId { return $0.personId < $1.personId }
            return $0.personName < $1.personName
        }

        // 2. 按 fingerprint 排名后的首次出现顺序聚合到 person。
        var aggregates: [String: (name: String, scores: [Float])] = [:]
        var personOrder: [String] = []
        for item in ranked {
            if aggregates[item.personId] == nil {
                personOrder.append(item.personId)
                aggregates[item.personId] = (item.personName, [item.score])
            } else {
                aggregates[item.personId]?.scores.append(item.score)
            }
        }

        // 3. personOrder 已按其最高 fingerprint 的排名排序。
        return personOrder.prefix(limit).compactMap { personId in
            guard let aggregate = aggregates[personId], !aggregate.scores.isEmpty else { return nil }
            let minScore = aggregate.scores.min() ?? 0
            let maxScore = aggregate.scores.max() ?? 0
            return PersonMatch(
                personId: personId,
                personName: aggregate.name,
                score: maxScore,
                fingerprintCount: aggregate.scores.count,
                minScore: minScore,
                maxScore: maxScore
            )
        }
    }

}
