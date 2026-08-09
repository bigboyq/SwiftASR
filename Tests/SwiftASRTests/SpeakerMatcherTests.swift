import Testing
import Foundation
@testable import SwiftASR

@Suite("SpeakerMatcher.topPersonMatches tests")
struct SpeakerMatcherTests {

    // Helper: 用 192 维向量（前 2 维有效，其余 0）模拟 fingerprint
    private static func embedding(_ x: Float, _ y: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 192)
        v[0] = x
        v[1] = y
        return v
    }

    // Helper: 在临时 modelContext 里建 unbound / person / profile（用真实 SwiftData）
    // 不依赖 mock，直接建内存实例
    private static func makePerson(name: String) -> Person {
        Person(name: name)
    }

    private static func makeProfile(
        speakerLabel: String,
        person: Person? = nil,
        emb: [Float]
    ) -> SpeakerProfile {
        let data = emb.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        return SpeakerProfile(
            fingerprintId: SpeakerFingerprint.makeId(embedding: emb),
            speakerLabel: speakerLabel,
            backend: "eres2netv2",
            totalUtterances: 1,
            totalDurationSeconds: 1.0,
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            embeddingData: data,
            person: person
        )
    }

    // MARK: - 基本场景

    @Test func singlePersonTopMatch() {
        let person = Self.makePerson(name: "雅冬")
        let p1 = Self.makeProfile(speakerLabel: "S1", person: person, emb: Self.embedding(1, 0))
        let unbound = Self.makeProfile(speakerLabel: "UNB", person: nil, emb: Self.embedding(0.9, 0.1))

        let result = SpeakerMatcher.topPersonMatches(unbound: unbound, boundProfiles: [p1], limit: 5)
        #expect(result.count == 1)
        #expect(result[0].personName == "雅冬")
        #expect(result[0].score > 0.99, "max cos 应该接近 1.0")
    }

    @Test func excludesCurrentFingerprintForReferenceMatches() {
        let selfPerson = Self.makePerson(name: "当前人物")
        let otherPerson = Self.makePerson(name: "其他人物")
        let selfFingerprint = Self.makeProfile(
            speakerLabel: "SELF", person: selfPerson, emb: Self.embedding(1, 0)
        )
        let otherFingerprint = Self.makeProfile(
            speakerLabel: "OTHER", person: otherPerson, emb: Self.embedding(0.8, 0.6)
        )
        let unbound = Self.makeProfile(
            speakerLabel: "UNB", person: nil, emb: Self.embedding(1, 0)
        )

        let result = SpeakerMatcher.topPersonMatches(
            unbound: unbound,
            boundProfiles: [selfFingerprint, otherFingerprint],
            limit: 3,
            excludingFingerprintId: selfFingerprint.fingerprintId
        )

        #expect(result.map(\.personName) == ["其他人物"])
        #expect(result[0].score < 0.98)
    }

    @Test func multiPersonRankedByMaxCos() {
        let ya = Self.makePerson(name: "雅冬")
        let sh = Self.makePerson(name: "说话人乙")
        let wq = Self.makePerson(name: "王琦")
        // 雅冬下两个 fingerprint，max 跟 unbound 最像
        let yaFp1 = Self.makeProfile(speakerLabel: "S1", person: ya, emb: Self.embedding(0.8, 0.2))
        let yaFp2 = Self.makeProfile(speakerLabel: "S2", person: ya, emb: Self.embedding(0.3, 0.7))
        let shFp = Self.makeProfile(speakerLabel: "S3", person: sh, emb: Self.embedding(0.5, 0.5))
        let wqFp = Self.makeProfile(speakerLabel: "S4", person: wq, emb: Self.embedding(-0.5, -0.5))
        let unbound = Self.makeProfile(speakerLabel: "UNB", person: nil, emb: Self.embedding(1, 0))

        let result = SpeakerMatcher.topPersonMatches(
            unbound: unbound,
            boundProfiles: [yaFp1, yaFp2, shFp, wqFp],
            limit: 5
        )
        #expect(result.count == 3)
        #expect(result[0].personName == "雅冬", "max sim 最高的 person 排第一")
        #expect(result[1].personName == "说话人乙")
        #expect(result[2].personName == "王琦")
        #expect(result[0].score > result[1].score)
        #expect(result[1].score > result[2].score)
        #expect(result[0].fingerprintCount == 2, "雅冬的两条指纹只占一个人物名次")
        #expect(result[0].minScore < result[0].maxScore, "聚合结果保留同一人的 min~max")
        #expect(result[0].minScore > 0.3)
        #expect(result[0].maxScore > 0.95)
    }

    @Test func limitTruncatesResults() {
        let p1 = Self.makePerson(name: "A"); let p2 = Self.makePerson(name: "B")
        let p3 = Self.makePerson(name: "C"); let p4 = Self.makePerson(name: "D"); let p5 = Self.makePerson(name: "E")
        let unbound = Self.makeProfile(speakerLabel: "UNB", person: nil, emb: Self.embedding(1, 0))
        let fps = [p1, p2, p3, p4, p5].enumerated().map { (i, p) in
            Self.makeProfile(speakerLabel: "S\(i)", person: p, emb: Self.embedding(Float(i + 1), 0))
        }
        let result = SpeakerMatcher.topPersonMatches(unbound: unbound, boundProfiles: fps, limit: 3)
        #expect(result.count == 3, "limit=3 截断到 3 个")
    }

    // MARK: - 边界

    @Test func unboundNoEmbeddingReturnsEmpty() {
        let person = Self.makePerson(name: "雅冬")
        let p1 = Self.makeProfile(speakerLabel: "S1", person: person, emb: Self.embedding(1, 0))
        let unbound = Self.makeProfile(speakerLabel: "UNB", person: nil, emb: [])  // 空 embedding
        let result = SpeakerMatcher.topPersonMatches(unbound: unbound, boundProfiles: [p1], limit: 5)
        #expect(result.isEmpty)
    }

    @Test func boundProfileNoEmbeddingSkipped() {
        let ya = Self.makePerson(name: "雅冬")
        let p1 = Self.makeProfile(speakerLabel: "S1", person: ya, emb: [])
        let unbound = Self.makeProfile(speakerLabel: "UNB", person: nil, emb: Self.embedding(1, 0))
        let result = SpeakerMatcher.topPersonMatches(unbound: unbound, boundProfiles: [p1], limit: 5)
        #expect(result.isEmpty, "bound 没 embedding 的人不出现")
    }

    @Test func emptyBoundProfilesReturnsEmpty() {
        let unbound = Self.makeProfile(speakerLabel: "UNB", person: nil, emb: Self.embedding(1, 0))
        let result = SpeakerMatcher.topPersonMatches(unbound: unbound, boundProfiles: [], limit: 5)
        #expect(result.isEmpty)
    }

    @Test func emptyLimitReturnsEmpty() {
        let person = Self.makePerson(name: "雅冬")
        let p1 = Self.makeProfile(speakerLabel: "S1", person: person, emb: Self.embedding(1, 0))
        let unbound = Self.makeProfile(speakerLabel: "UNB", person: nil, emb: Self.embedding(1, 0))
        let result = SpeakerMatcher.topPersonMatches(unbound: unbound, boundProfiles: [p1], limit: 0)
        #expect(result.isEmpty, "limit=0 返回空")
    }

    @Test func dimMismatchSilentSkip() {
        let ya = Self.makePerson(name: "雅冬")
        // 故意造一个 wrong-dim embedding
        let wrongDim = [Float](repeating: 0.5, count: 100)  // 不是 192
        let p1 = Self.makeProfile(speakerLabel: "S1", person: ya, emb: wrongDim)
        let unbound = Self.makeProfile(speakerLabel: "UNB", person: nil, emb: Self.embedding(1, 0))
        let result = SpeakerMatcher.topPersonMatches(unbound: unbound, boundProfiles: [p1], limit: 5)
        #expect(result.isEmpty, "dim 不匹配静默跳过")
    }

    @Test func unboundProfileItselfInBoundListIgnored() {
        // 边界：unbound 不应该出现在 boundProfiles 里
        // 但万一传了，保证它不会通过 nil 筛选（因为有 person）
        let person = Self.makePerson(name: "雅冬")
        let p1 = Self.makeProfile(speakerLabel: "S1", person: person, emb: Self.embedding(1, 0))
        let unbound = Self.makeProfile(speakerLabel: "S1", person: nil, emb: Self.embedding(1, 0))
        let result = SpeakerMatcher.topPersonMatches(unbound: unbound, boundProfiles: [unbound, p1], limit: 5)
        #expect(result.count == 1, "unbound 自己没 person，nil 筛选掉")
        #expect(result[0].personName == "雅冬")
    }

}
