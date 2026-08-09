import Foundation

// MARK: - API Key 配置

public struct APIKeyConfig: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var keyValue: String
    public var isEnabled: Bool
    /// priority 数字，0-99，越小越优先；同 provider 内唯一（重复会被 SettingsTab 拒绝）
    public var priority: Int
    /// Tier 升级：cost group，0=免费，越大越贵。0-9 范围。429 在同 tier 内轮询，
    /// 5xx / 529 升 tier。默认 0。同 (tier, priority) 只能放一个 key。
    public var tier: Int
    /// provider 名（"gemini" 唯一合法值；schema 字段预留，UI 暂不暴露多 provider）
    public var provider: String
    /// keyValue 前 4 字符 + 后 4 字符 拼出来的前缀（用于 UI 展示，不含中间明文）
    public var keyPrefix: String
    /// 上次成功 cleanup 的时间。SettingsStore.recordSuccess 自动写。
    public var lastUsedAt: Date?
    /// 成功调用次数：每次 cleanup 成功完成一个 chunk 就 +1（per-call 计数，
    /// 失败 / 4xx / 5xx / 取消都不算）。testConnection 不计。
    public var successCount: Int
    /// 创建时间。SettingsStore 在首次添加时填。
    public var createdAt: Date?
    /// 自由备注（"家用" / "公司" / "test" 等）
    public var notes: String?

    /// Whether this entry can be used by the only cleanup provider currently
    /// exposed by the product. Whitespace-only keys are never usable.
    public var isUsableGeminiKey: Bool {
        isEnabled
            && provider.caseInsensitiveCompare("gemini") == .orderedSame
            && !keyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, label, keyValue, isEnabled, priority, tier
        case provider, keyPrefix, lastUsedAt, successCount, createdAt, notes
    }

    public init(
        id: String = UUID().uuidString,
        label: String,
        keyValue: String,
        isEnabled: Bool = true,
        priority: Int = 0,
        tier: Int = 0,
        provider: String = "gemini",
        keyPrefix: String? = nil,
        lastUsedAt: Date? = nil,
        successCount: Int = 0,
        createdAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.label = label
        self.keyValue = keyValue
        self.isEnabled = isEnabled
        self.priority = max(0, min(99, priority))
        self.tier = max(0, min(9, tier))
        self.provider = provider
        // 自动算 keyPrefix：前 4 + "••••" + 后 4（funasr 用前 4 + 后 4 拼接，这里用同样格式）
        self.keyPrefix = keyPrefix ?? APIKeyConfig.deriveKeyPrefix(from: keyValue)
        self.lastUsedAt = lastUsedAt
        // successCount 钳到 ≥0：JSON 损坏兜底，正常数据本来就是 0+
        self.successCount = max(0, successCount)
        self.createdAt = createdAt
        self.notes = notes
    }

    /// 从 keyValue 推导展示用的前缀。前 4 + "••••" + 后 4（不满 8 字符就显示全）。
    public static func deriveKeyPrefix(from keyValue: String) -> String {
        let trimmed = keyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8 { return trimmed }
        return String(trimmed.prefix(4)) + "••••" + String(trimmed.suffix(4))
    }

    // 自定义 init(from:)：身份和 key 内容是最小必需字段；后续版本新增的
    // 配置字段均带向后兼容默认值。损坏的非关键字段也回退默认值，避免一个
    // tier/successCount 类型错误导致整份 settings.json 无法读取。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let keyValue = try c.decode(String.self, forKey: .keyValue)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            label: (try? c.decode(String.self, forKey: .label)) ?? "Gemini",
            keyValue: keyValue,
            isEnabled: (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true,
            priority: (try? c.decode(Int.self, forKey: .priority)) ?? 0,
            tier: (try? c.decode(Int.self, forKey: .tier)) ?? 0,
            provider: (try? c.decode(String.self, forKey: .provider)) ?? "gemini",
            keyPrefix: try? c.decodeIfPresent(String.self, forKey: .keyPrefix),
            lastUsedAt: try? c.decodeIfPresent(Date.self, forKey: .lastUsedAt),
            successCount: (try? c.decode(Int.self, forKey: .successCount)) ?? 0,
            createdAt: try? c.decodeIfPresent(Date.self, forKey: .createdAt),
            notes: try? c.decodeIfPresent(String.self, forKey: .notes)
        )
    }
}
