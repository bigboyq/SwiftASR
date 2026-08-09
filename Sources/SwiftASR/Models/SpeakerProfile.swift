import Foundation
import SwiftData

@Model
public final class SpeakerProfile {
    @Attribute(.unique) public var id: String
    public var fingerprintId: String
    public var speakerLabel: String

    // Phase 2 / A1：speaker backend tag（"eres2netv2" / "campplus" 等）
    // SwiftData 给非 optional 字段补 default 是 safe migration
    public var backend: String = "eres2netv2"

    public var totalUtterances: Int
    public var totalDurationSeconds: Double
    // Phase 2 / A1：Swift 默认值 + Optional 都能帮 migration，
    // 但 SwiftData/CoreData 的 lightweight migration 认 Swift 属性 default（@Model 转 model 时注入）
    public var firstSeenAt: Date = Date()
    public var lastSeenAt: Date = Date()

    // 二进制存储声纹向量数据 (192维 float，对应 768 字节)
    public var embeddingData: Data?

    /// 每个 job 对全局 profile 的独立贡献。不能用单一 `job` 反向关系，
    /// 否则跨 job 复用会覆盖来源，重跑也无法做幂等统计。
    @Relationship(deleteRule: .cascade, inverse: \JobSpeakerProfileOccurrence.profile)
    public var jobOccurrences: [JobSpeakerProfileOccurrence] = []

    // Phase 2 / A1：可选关联到 Person（用户命名后写入）
    // nil = unbound（unbound = 还没绑到 Person，需要手工或工具辅助）
    public var person: Person?

    public init(
        id: String = UUID().uuidString,
        fingerprintId: String,
        speakerLabel: String,
        backend: String = "eres2netv2",
        totalUtterances: Int = 0,
        totalDurationSeconds: Double = 0.0,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        embeddingData: Data? = nil,
        person: Person? = nil
    ) {
        self.id = id
        self.fingerprintId = fingerprintId
        self.speakerLabel = speakerLabel
        self.backend = backend
        self.totalUtterances = totalUtterances
        self.totalDurationSeconds = totalDurationSeconds
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.embeddingData = embeddingData
        self.person = person
    }

    // 助手属性，将 Data 转换为 Float 数组
    public var embedding: [Float]? {
        guard let data = embeddingData else { return nil }
        // ERes2NetV2 production embeddings are fixed 192-dim. Treat legacy
        // or truncated blobs as unavailable instead of exposing a partial
        // vector to matching/health calculations.
        guard data.count == 192 * MemoryLayout<Float>.size else { return nil }
        let count = 192
        return data.withUnsafeBytes { bytes in
            Array(UnsafeBufferPointer(start: bytes.baseAddress?.assumingMemoryBound(to: Float.self), count: count))
        }
    }
}
