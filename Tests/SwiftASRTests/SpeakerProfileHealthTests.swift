import Testing
import Foundation
@testable import SwiftASR

// MARK: - ProfileHealth.evaluate tooltip 文案测试
//
// 之前 tooltip 给开发者看 "兄弟 max cos 0.54 < 0.75",对用户不友好。
// 改成三行:
//   1) 触发红的描述
//   2) 同组最相似指纹：fp_xxx(0.54)
//   3) 全局最相似指纹：fp_yyy(0.62)[说话人名]
// 抽到 ProfileHealth.evaluate 是为了能直接调,不挡 SwiftUI view 层级。

@Test func profileHealthRedReasonIncludesThreeLines() {
    let person = Person(id: "p1", name: "Alice")
    let my = profile(id: "fp_mine", person: person, embedding: vectorEmbedding(values: [1.0, 0.0, 0.0]))
    let sibling = profile(id: "fp_sibling", person: person, embedding: vectorEmbedding(values: [0.0, 1.0, 0.0]))
    // cos 故意 < 0.5 触发 .red (2 条 fingerprint 阈值)
    let health = ProfileHealth.evaluate(for: my, allProfiles: [my, sibling])
    guard case .red(let reason) = health else {
        Issue.record("expected .red, got \(health)")
        return
    }
    let lines = reason.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.count == 3, "expected 3 lines, got \(lines.count): \(reason)")
    #expect(lines[0].contains("同组仅 2 条 fingerprint"))
    #expect(lines[0].contains("0.50 阈值"))
    // 第 2 行: 同组最相似
    #expect(lines[1].contains("同组最相似指纹："))
    #expect(lines[1].contains("fp_sibling"))
    #expect(lines[1].contains("0.00"))
    // 第 3 行: 全局最相似 — 这里只有同 person 的人,所以全局最相似也是 fp_sibling
    #expect(lines[2].contains("全局最相似指纹："))
    #expect(lines[2].contains("fp_sibling"))
    #expect(lines[2].contains("[Alice]"))
}

@Test func profileHealthRedReasonForLargeSiblingsUses075Threshold() {
    let person = Person(id: "p1", name: "Bob")
    let my = profile(id: "fp_a", person: person, embedding: vectorEmbedding(values: [1.0, 0.0, 0.0]))
    let s1 = profile(id: "fp_b", person: person, embedding: vectorEmbedding(values: [0.0, 1.0, 0.0]))
    let s2 = profile(id: "fp_c", person: person, embedding: vectorEmbedding(values: [0.0, 0.0, 1.0]))
    // 3 条 fingerprint 阈值是 0.75，最相似的是 0.00 < 0.75
    let health = ProfileHealth.evaluate(for: my, allProfiles: [my, s1, s2])
    guard case .red(let reason) = health else {
        Issue.record("expected .red, got \(health)")
        return
    }
    let lines = reason.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0].contains("同组指纹最大相似度不足 0.75"))
    #expect(lines[1].contains("同组最相似指纹："))
    #expect(lines[1].contains("(0.00)"))
    #expect(lines[2].contains("全局最相似指纹："))
    #expect(lines[2].contains("[Bob]"))
}

@Test func profileHealthRedPicksHighestCosFingerprint() {
    let person = Person(id: "p1", name: "Carol")
    let my = profile(id: "fp_target", person: person, embedding: vectorEmbedding(values: [1.0, 0.0, 0.0]))
    // 多个 sibling,故意让其中一个 cos 最高
    let lowSimilar = profile(id: "fp_low", person: person, embedding: vectorEmbedding(values: [-1.0, 0.0, 0.0]))
    let highSimilar = profile(id: "fp_high", person: person, embedding: vectorEmbedding(values: [0.7, 0.7, 0.0]))
    let mediumSimilar = profile(id: "fp_medium", person: person, embedding: vectorEmbedding(values: [0.5, 0.5, 0.0]))
    let health = ProfileHealth.evaluate(
        for: my,
        allProfiles: [my, lowSimilar, highSimilar, mediumSimilar]
    )
    guard case .red(let reason) = health else {
        Issue.record("expected .red, got \(health)")
        return
    }
    let lines = reason.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.count == 3)
    // 期望同组最相似的是 fp_high (cosine ≈ 0.7/sqrt(0.98) ≈ 0.707)
    #expect(lines[1].contains("fp_high"))
    // 全局也是 fp_high (因为只有同 person 的人)
    #expect(lines[2].contains("fp_high"))
}

@Test func profileHealthRedShowsGlobalMostSimilarAcrossPersons() {
    // 跨 person 撞 fingerprint: 自己的 person 内只有自己,但有个
    // 别的 person 下的 fingerprint 跟自己的 cos 很高 → 全局最相似
    // 应该是那条跨 person 的 fingerprint, 后面 [说话人名] 是那个人
    // 的名字 (不是自己的 person 名)
    let alice = Person(id: "p1", name: "Alice")
    let bob = Person(id: "p2", name: "Bob")
    // my 跟 bobFp 高度相似 (≈0.7), 跟 aliceFp 正交
    let my = profile(id: "fp_mine", person: alice, embedding: vectorEmbedding(values: [1.0, 0.0, 0.0]))
    let aliceOther = profile(id: "fp_alice_other", person: alice, embedding: vectorEmbedding(values: [0.0, 1.0, 0.0]))
    // bobFp 用 [0.7, 0.7, 0.0] 跟 my cos ≈ 0.707
    let bobFp = profile(id: "fp_bob_close", person: bob, embedding: vectorEmbedding(values: [0.7, 0.7, 0.0]))

    let health = ProfileHealth.evaluate(
        for: my,
        allProfiles: [my, aliceOther, bobFp]
    )
    // 同组 (Alice) 仅 2 条 fp, max cos = 0 < 0.50 → .red
    guard case .red(let reason) = health else {
        Issue.record("expected .red, got \(health)")
        return
    }
    let lines = reason.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.count == 3)
    // 第 2 行: 同组最相似 = aliceOther。同组最相似按 user 格式不带 [说话人名]
    // (自己 person 名字 user 当然知道, 拼上去反而冗余)
    #expect(lines[1].contains("同组最相似指纹："))
    #expect(lines[1].contains("fp_alice_other"))
    #expect(!lines[1].contains("["))  // 不带 [说话人名] 后缀
    // 第 3 行: 全局最相似 = bobFp (跨 person)
    #expect(lines[2].contains("全局最相似指纹："))
    #expect(lines[2].contains("fp_bob_close"))
    #expect(lines[2].contains("[Bob]"))  // bob 的 person — 关键: 跟"同组"是不同 person
    #expect(lines[2].contains("0.7"))    // cos 0.707 ≈ "0.71"
}

@Test func profileHealthGreenForSimilarSiblings() {
    let person = Person(id: "p1", name: "Dave")
    let emb = vectorEmbedding(values: [1.0, 0.0, 0.0])
    let my = profile(id: "fp_x", person: person, embedding: emb)
    let sibling = profile(id: "fp_y", person: person, embedding: emb)
    let health = ProfileHealth.evaluate(for: my, allProfiles: [my, sibling])
    #expect({
        if case .green = health { return true }
        return false
    }(), "expected .green for identical embeddings")
}

@Test func profileHealthGrayForUnbound() {
    let my = profile(id: "fp_orphan", person: nil, embedding: unitEmbedding(seed: 5))
    let health = ProfileHealth.evaluate(for: my, allProfiles: [my])
    guard case .gray(let reason) = health else {
        Issue.record("expected .gray, got \(health)")
        return
    }
    #expect(reason.contains("未归属"))
}

@Test func profileHealthGrayForLoneSibling() {
    let person = Person(id: "p1", name: "Eve")
    let my = profile(id: "fp_lonely", person: person, embedding: unitEmbedding(seed: 6))
    let health = ProfileHealth.evaluate(for: my, allProfiles: [my])
    guard case .gray(let reason) = health else {
        Issue.record("expected .gray, got \(health)")
        return
    }
    #expect(reason.contains("只有 1 条 fingerprint"))
}

@Test func profileHealthGrayForMissingEmbedding() {
    let person = Person(id: "p1", name: "Frank")
    let my = profile(id: "fp_no_emb", person: person, embedding: nil)
    let sibling = profile(id: "fp_has_emb", person: person, embedding: unitEmbedding(seed: 8))
    let health = ProfileHealth.evaluate(for: my, allProfiles: [my, sibling])
    guard case .gray(let reason) = health else {
        Issue.record("expected .gray, got \(health)")
        return
    }
    #expect(reason.contains("缺少 embedding"))
}

// MARK: - helpers

private func unitEmbedding(seed: Int) -> Data {
    // 跟某固定基向量平行的"噪声"embedding
    var emb = [Float](repeating: 0, count: 192)
    for k in 0..<192 {
        emb[k] = sin(Float(seed) * 0.7 + Float(k) * 0.1) * 0.5
    }
    // 归一化
    var sumSq: Float = 0
    for v in emb { sumSq += v * v }
    let norm = (sumSq > 0) ? sqrt(sumSq) : 1
    let normalized = emb.map { $0 / norm }
    return normalized.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func vectorEmbedding(values: [Float]) -> Data {
    // 短 embedding(测试用,cosine 不在乎 dim 长度,只要 a.count == b.count)
    // 但 SpeakerProfile 要求固定 192 dim,这里把短 vector 扩展到 192
    var emb = [Float](repeating: 0, count: 192)
    for (k, v) in values.enumerated() {
        if k < 192 { emb[k] = v }
    }
    var sumSq: Float = 0
    for v in emb { sumSq += v * v }
    let norm = (sumSq > 0) ? sqrt(sumSq) : 1
    let normalized = emb.map { $0 / norm }
    return normalized.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func profile(
    id: String,
    person: Person?,
    embedding: Data?
) -> SpeakerProfile {
    SpeakerProfile(
        fingerprintId: id,
        speakerLabel: id,
        embeddingData: embedding,
        person: person
    )
}
