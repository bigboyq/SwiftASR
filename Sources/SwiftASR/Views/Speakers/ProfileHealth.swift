import SwiftUI

// MARK: - 健康度

/// 说话人 profile 在库中的"健康度"标识，用于 `BoundProfileRow` 左侧的 icon + tooltip。
/// - `.green`：唯一 fingerprint 或跟兄弟 fingerprint 相似度足够高
/// - `.red(reason:)`：兄弟 max cos 低于阈值（可能是 cross-recording 漂移）。
///   reason 3 行：
///     1) 触发红的描述（"同组指纹最大相似度不足 0.75"）
///     2) 同组最相似指纹：fp_xxx(0.54)
///     3) 全局最相似指纹：fp_yyy(0.62)[说话人名]
///   全局最相似即使跟同组最相似是同一条 fingerprint 也照常显示——user
///   看到"[自己 person 名]" 就知道"全局也没撞"；反之看到"其他 person
///   名"就立刻知道"这条 fingerprint 跟别人撞了"。
/// - `.gray(reason:)`：未归属 / 唯一 fingerprint / 无 embedding
enum ProfileHealth {
    case green
    case red(reason: String)
    case gray(reason: String)

    /// SF Symbol 名字（iOS 14+/macOS 11+ 都支持）
    var icon: String {
        switch self {
        case .green: return "checkmark.seal.fill"
        case .red:   return "exclamationmark.triangle.fill"
        case .gray:  return "circle.dashed"
        }
    }

    /// 着色：green 绿 / red 红 / gray secondary
    var color: Color {
        switch self {
        case .green: return .green
        case .red:   return .red
        case .gray:  return .secondary
        }
    }

    var tooltip: String {
        switch self {
        case .green:           return "健康"
        case .red(let r):      return "⚠️\n\(r)"
        case .gray(let r):     return "ℹ️ \(r)"
        }
    }

    /// 纯函数：根据 `profile` 在 `allProfiles` 库里的"同 person 兄弟" 算健康度。
    /// 抽到 enum 上是让单测能直接调，不依赖 SwiftUI view 层级。
    ///
    /// 阈值规则（保持跟原 SpeakersTab.profileHealth 一致）：
    /// - 同组仅 1 条 fingerprint → `.gray`（"此人下只有 1 条 fingerprint"）
    /// - 同组仅 2 条 fingerprint, max cos < 0.50 → `.red`
    /// - 同组 ≥ 3 条 fingerprint, max cos < 0.75 → `.red`
    /// - 其他 → `.green`
    ///
    /// 阈值不达时 reason 三行: 触发描述 / 同组最相似 / 全局最相似。
    /// 全局最相似扫描 `allProfiles` 里所有 profile（跨 person），找到 cos
    /// 最高的 fingerprint（排除自身），如果它属于某个 person 就拼 [person 名]。
    static func evaluate(
        for profile: SpeakerProfile,
        allProfiles: [SpeakerProfile]
    ) -> ProfileHealth {
        guard let person = profile.person else {
            return .gray(reason: "未归属到任何说话人")
        }
        let siblings = allProfiles.filter {
            $0.person?.id == person.id && $0.id != profile.id
        }
        let allFps = siblings.count + 1
        if allFps == 1 {
            return .gray(reason: "此人下只有 1 条 fingerprint（无法对比相似度）")
        }
        guard let myEmb = profile.embedding else {
            return .gray(reason: "fingerprint 缺少 embedding 数据")
        }

        // 同 person 内 max cos
        var inGroupMaxCos: Float = -1
        var inGroupMostSimilarId: String? = nil
        for s in siblings {
            guard let sEmb = s.embedding, sEmb.count == myEmb.count else { continue }
            let cos = SpeakerFingerprint.cosine(myEmb, sEmb)
            if cos > inGroupMaxCos {
                inGroupMaxCos = cos
                inGroupMostSimilarId = s.fingerprintId
            }
        }

        // 全局（跨 person）max cos
        var globalMaxCos: Float = -1
        var globalMostSimilar: (id: String, personName: String)? = nil
        for p in allProfiles where p.id != profile.id {
            guard let pEmb = p.embedding, pEmb.count == myEmb.count else { continue }
            let cos = SpeakerFingerprint.cosine(myEmb, pEmb)
            if cos > globalMaxCos {
                globalMaxCos = cos
                globalMostSimilar = (id: p.fingerprintId, personName: p.person?.name ?? "未命名")
            }
        }

        // 拼第 2 行: 同组最相似
        let inGroupLine: String
        if let id = inGroupMostSimilarId {
            inGroupLine = "同组最相似指纹：\(id)(\(Self.formatCos(inGroupMaxCos)))"
        } else {
            inGroupLine = "同组最相似指纹：?(\(Self.formatCos(inGroupMaxCos)))"
        }

        // 拼第 3 行: 全局最相似（始终显示，让 user 知道全局是否撞）
        let globalLine: String
        if let hit = globalMostSimilar {
            globalLine = "全局最相似指纹：\(hit.id)(\(Self.formatCos(globalMaxCos)))[\(hit.personName)]"
        } else {
            globalLine = "全局最相似指纹：?(\(Self.formatCos(globalMaxCos)))"
        }

        if allFps == 2 {
            if inGroupMaxCos < 0.50 {
                let summary = "同组仅 2 条 fingerprint，低于 0.50 阈值"
                return .red(reason: [summary, inGroupLine, globalLine].joined(separator: "\n"))
            }
            return .green
        } else {
            if inGroupMaxCos < 0.75 {
                let summary = "同组指纹最大相似度不足 0.75"
                return .red(reason: [summary, inGroupLine, globalLine].joined(separator: "\n"))
            }
            return .green
        }
    }

    private static func formatCos(_ value: Float) -> String {
        String(format: "%.2f", value)
    }
}
