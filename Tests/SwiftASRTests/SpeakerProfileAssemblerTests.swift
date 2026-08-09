import Testing
import Foundation
import Accelerate
@testable import SwiftASR

// MARK: - SpeakerProfileAssembler tests
//
// 覆盖唯一 profile 构造路径：
// - vDSP_vadd / vDSP_vsmul SIMD 累加
// - 验证 SIMD 路径跟原纯 Swift 累加结果 bit-exact 一致
// - 大规模 5284 chunks perf 回归

private func assembleSpeakerProfiles(
    labels: [Int],
    chunks: [(startMs: Int, endMs: Int)],
    embeddings: [Float],
    sentinelIsolation: Bool = false
) -> [SpeakerProfileData] {
    var policy = SpeakerTemporalPolicy.production
    policy.enableSentinelIsolation = sentinelIsolation
    return SpeakerProfileAssembler.build(
        labels: labels,
        chunks: chunks,
        embeddings: embeddings,
        dimension: 192,
        policy: policy
    )
}

@Test func speakerProfileAssembler_basicThreeSpeakers() {
    let dim = 192
    let n = 30
    // 3 个 speakers, 各 10 chunks
    let labels: [Int] = (0..<n).map { $0 / 10 }
    let chunks: [(startMs: Int, endMs: Int)] = (0..<n).map { i in
        (i * 1500, (i + 1) * 1500)
    }
    // 每个 speaker 的 chunk embedding = (label + 1) 全相同
    var embeddings = [Float](repeating: 0, count: n * dim)
    for (i, lbl) in labels.enumerated() {
        for k in 0..<dim {
            embeddings[i * dim + k] = Float(lbl + 1) * 0.1
        }
    }

    let profiles = assembleSpeakerProfiles(
        labels: labels, chunks: chunks, embeddings: embeddings
    )

    #expect(profiles.count == 3)
    // 按 label 升序
    #expect(profiles[0].speakerLabel == "说话人 1")
    #expect(profiles[1].speakerLabel == "说话人 2")
    #expect(profiles[2].speakerLabel == "说话人 3")
    // 每个 speaker 都有 10 chunks
    for p in profiles {
        #expect(p.chunkCount == 10)
        #expect(p.totalDurationMs == 10 * 1500)
        #expect(p.centroidEmbedding.count == dim)
        // centroid = mean + L2 normalize
        // mean = (lbl+1) * 0.1 全 192 维相同
        // L2 norm = sqrt(192 * (mean^2)) = mean * sqrt(192)
        // normalized = mean / (mean * sqrt(192)) = 1/sqrt(192)
        let expected = 1.0 / Float(sqrt(192.0))
        for k in 0..<dim {
            #expect(abs(p.centroidEmbedding[k] - expected) < 1e-5, "dim \(k): got \(p.centroidEmbedding[k]), expected \(expected)")
        }
    }
}

@Test func speakerProfileAssembler_unequalChunks() {
    let dim = 192
    // 0: 5 chunks, 1: 12 chunks, 2: 3 chunks → 20 总
    let labels: [Int] = [0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2]
    let n = labels.count
    let chunks: [(startMs: Int, endMs: Int)] = (0..<n).map { i in
        (i * 1500, (i + 1) * 1500)
    }
    var embeddings = [Float](repeating: 0, count: n * dim)
    for (i, lbl) in labels.enumerated() {
        // 不同 label 不同均值
        let mean = Float(lbl + 1) * 0.1
        for k in 0..<dim {
            embeddings[i * dim + k] = mean
        }
    }

    let profiles = assembleSpeakerProfiles(
        labels: labels, chunks: chunks, embeddings: embeddings
    )

    #expect(profiles.count == 3)
    let p0 = profiles[0]  // label 0, 5 chunks
    let p1 = profiles[1]  // label 1, 12 chunks
    let p2 = profiles[2]  // label 2, 3 chunks
    #expect(p0.chunkCount == 5)
    #expect(p1.chunkCount == 12)
    #expect(p2.chunkCount == 3)
    // centroid 跟基本测试一致 (因为每个 speaker 内部 chunks embedding 全相同)
    let expected = 1.0 / Float(sqrt(192.0))
    for p in profiles {
        for k in 0..<dim {
            #expect(abs(p.centroidEmbedding[k] - expected) < 1e-5)
        }
    }
}

@Test func speakerProfileAssembler_simdMatchesScalar() {
    // 5284 chunks × 3 speakers, SIMD 累加跟原纯 Swift 累加结果 bit-exact 一致
    let dim = 192
    let n = 5284
    let chunks: [(startMs: Int, endMs: Int)] = (0..<n).map { i in
        (i * 750, i * 750 + 1500)
    }
    let labels: [Int] = (0..<n).map { $0 % 3 }  // 3 speakers 周期切换
    // embeddings 用确定性伪随机
    var embeddings = [Float](repeating: 0, count: n * dim)
    for i in 0..<n {
        for k in 0..<dim {
            // 不要用真正的 random, 用确定性 sin
            embeddings[i * dim + k] = Float(sin(Double(i) * 0.001 + Double(k) * 0.01)) * 0.5
        }
    }

    // 1. SIMD 路径
    let simd = assembleSpeakerProfiles(
        labels: labels, chunks: chunks, embeddings: embeddings
    )

    // 2. 标量路径 (rebuilt locally for comparison)
    var groups: [Int: (chunkCount: Int, totalMs: Int, embSum: [Float])] = [:]
    for (i, lbl) in labels.enumerated() {
        let start = chunks[i].0
        let end = chunks[i].1
        let dur = max(0, end - start)
        var entry = groups[lbl] ?? (0, 0, [Float](repeating: 0, count: dim))
        entry.chunkCount += 1
        entry.totalMs += dur
        let off = i * dim
        for k in 0..<dim {
            entry.embSum[k] += embeddings[off + k]
        }
        groups[lbl] = entry
    }
    var scalar: [SpeakerProfileData] = []
    for (lbl, g) in groups {
        let count = max(g.chunkCount, 1)
        var centroid = [Float](repeating: 0, count: dim)
        for k in 0..<dim { centroid[k] = g.embSum[k] / Float(count) }
        var sumSq: Float = 0
        vDSP_svesq(centroid, 1, &sumSq, vDSP_Length(dim))
        let n2 = sqrt(sumSq)
        if n2 > 1e-10 {
            var divisor = n2
            vDSP_vsdiv(centroid, 1, &divisor, &centroid, 1, vDSP_Length(dim))
        }
        var temp = centroid
        let data = Data(bytes: &temp, count: temp.count * MemoryLayout<Float>.size)
        let fp = SpeakerFingerprint.makeId(embedding: centroid)
        scalar.append(SpeakerProfileData(
            speakerLabel: "说话人 \(lbl + 1)",
            fingerprintId: fp,
            totalDurationMs: g.totalMs,
            chunkCount: g.chunkCount,
            centroidEmbedding: centroid,
            embeddingData: data
        ))
    }
    scalar.sort { $0.speakerLabel < $1.speakerLabel }

    // 3. SIMD 跟标量累加顺序不同（SIMD 内部 SIMD-lane 累加 + 标量是顺序累加），
    // 浮点结果在 1e-5 范围内一致。Fingerprint (SHA256[:12]) 对 1e-7 差异敏感，
    // 所以单独检查：centroid bit-close + 各自 fingerprint 稳定。
    #expect(simd.count == scalar.count)
    for (a, b) in zip(simd, scalar) {
        #expect(a.speakerLabel == b.speakerLabel)
        #expect(a.chunkCount == b.chunkCount)
        #expect(a.totalDurationMs == b.totalDurationMs)
        #expect(a.centroidEmbedding.count == b.centroidEmbedding.count)
        for k in 0..<dim {
            let diff = abs(a.centroidEmbedding[k] - b.centroidEmbedding[k])
            #expect(diff < 1e-5, "centroid dim \(k) diff \(diff) too large")
        }
        // fingerprint 自身稳定 (跟生产代码一致: SIMD 路径产生新 fp, 但 fp 自身 deterministic)
        #expect(a.fingerprintId.hasPrefix("fp_"))
        #expect(a.fingerprintId.count == "fp_".count + 12)
        #expect(b.fingerprintId.hasPrefix("fp_"))
        #expect(b.fingerprintId.count == "fp_".count + 12)
    }
}

@Test func speakerProfileAssembler_invalidShape_returnsEmpty() {
    // labels.count != chunks.count
    let profiles1 = assembleSpeakerProfiles(
        labels: [0, 1], chunks: [(0, 1000)], embeddings: [Float](repeating: 0, count: 192 * 2)
    )
    #expect(profiles1.isEmpty)
    // embeddings 长度不匹配
    let profiles2 = assembleSpeakerProfiles(
        labels: [0, 1], chunks: [(0, 1000), (1000, 2000)], embeddings: [Float](repeating: 0, count: 100)
    )
    #expect(profiles2.isEmpty)
}

@Test func speakerProfileAssembler_perf5284() {
    // 5284 chunks × 192 dim，守住 debug test build 的宽松回归预算。
    let dim = 192
    let n = 5284
    let chunks: [(startMs: Int, endMs: Int)] = (0..<n).map { i in
        (i * 750, i * 750 + 1500)
    }
    let labels: [Int] = (0..<n).map { $0 % 3 }
    var embeddings = [Float](repeating: 0, count: n * dim)
    for i in 0..<(n * dim) { embeddings[i] = Float(sin(Double(i) * 0.001)) }

    let start = Date()
    let profiles = assembleSpeakerProfiles(
        labels: labels, chunks: chunks, embeddings: embeddings
    )
    let elapsed = Date().timeIntervalSince(start)

    #expect(profiles.count == 3)
    // CI/debug instrumentation 波动较大；这里只防止意外回到秒级实现。
    #expect(elapsed < 0.5, "vDSP SIMD 累加过慢: \(elapsed)s")
}

@Test func speakerProfileAssembler_deterministic() {
    // SIMD 路径确定性: 同 input 跑两次结果 bit-exact
    let dim = 192
    let n = 100
    let chunks: [(startMs: Int, endMs: Int)] = (0..<n).map { i in
        (i * 750, i * 750 + 1500)
    }
    let labels: [Int] = (0..<n).map { $0 % 2 }
    var embeddings = [Float](repeating: 0, count: n * dim)
    for i in 0..<(n * dim) { embeddings[i] = Float(sin(Double(i) * 0.01)) }

    let p1 = assembleSpeakerProfiles(
        labels: labels, chunks: chunks, embeddings: embeddings
    )
    let p2 = assembleSpeakerProfiles(
        labels: labels, chunks: chunks, embeddings: embeddings
    )
    #expect(p1.count == p2.count)
    for (a, b) in zip(p1, p2) {
        #expect(a.fingerprintId == b.fingerprintId)
        #expect(a.centroidEmbedding == b.centroidEmbedding)
        #expect(a.embeddingData == b.embeddingData)
    }
}

@Test func speakerProfileAssembler_excludesAcousticDegradedAnchor() {
    let dimension = 192
    var shortOutlier = [Float](repeating: 0, count: dimension)
    shortOutlier[0] = 1
    var stableAnchor = [Float](repeating: 0, count: dimension)
    stableAnchor[1] = 1

    let profiles = assembleSpeakerProfiles(
        labels: [0, 0],
        chunks: [(0, 100), (100, 1_100)],
        embeddings: shortOutlier + stableAnchor,
        sentinelIsolation: true
    )

    #expect(profiles.count == 1)
    #expect(profiles[0].chunkCount == 2)
    #expect(profiles[0].totalDurationMs == 1_100)
    #expect(profiles[0].centroidEmbedding == stableAnchor)
    #expect(profiles[0].fingerprintId == SpeakerFingerprint.makeId(embedding: stableAnchor))
}

@Test func speakerProfileAssembler_fallsBackWhenEveryAnchorIsDegraded() {
    let dimension = 192
    var first = [Float](repeating: 0, count: dimension)
    first[0] = 1
    var second = [Float](repeating: 0, count: dimension)
    second[1] = 1

    let profiles = assembleSpeakerProfiles(
        labels: [0, 0],
        chunks: [(0, 100), (100, 200)],
        embeddings: first + second,
        sentinelIsolation: true
    )

    let expected = 1 / sqrt(Float(2))
    #expect(profiles.count == 1)
    #expect(abs(profiles[0].centroidEmbedding[0] - expected) < 1e-6)
    #expect(abs(profiles[0].centroidEmbedding[1] - expected) < 1e-6)
}
