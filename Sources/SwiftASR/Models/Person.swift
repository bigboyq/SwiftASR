import Foundation
import SwiftData

/// Person 实体：用户命名的"人"。
/// 一个 Person 可关联多个 SpeakerProfile（同一人的不同 cluster / 跨 job 命中）。
/// 命名唯一（按 name 去重），由 PersonRepository.getOrCreate 维护。
@Model
public final class Person {
    @Attribute(.unique) public var id: String
    @Attribute(.unique) public var name: String
    public var createdAt: Date

    // 反向关联
    @Relationship(deleteRule: .nullify, inverse: \SpeakerProfile.person)
    public var profiles: [SpeakerProfile] = []

    public init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
