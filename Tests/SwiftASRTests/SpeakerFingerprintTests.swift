import Testing
import Foundation
@testable import SwiftASR

// MARK: - Speaker Fingerprint 全面测试

@Test func fingerprintStableForSameEmbedding() {
    let emb: [Float] = (0..<192).map { Float($0) / 192.0 }
    let id1 = SpeakerFingerprint.makeId(embedding: emb)
    let id2 = SpeakerFingerprint.makeId(embedding: emb)
    #expect(id1 == id2)
    #expect(id1.hasPrefix("fp_"))
    #expect(id1.count == "fp_".count + 12, "got \(id1.count): \(id1)")
}

@Test func fingerprintDifferentForDifferentEmbedding() {
    let emb1: [Float] = (0..<192).map { Float($0) / 192.0 }
    let emb2: [Float] = (0..<192).map { Float($0 + 1) / 192.0 }
    let id1 = SpeakerFingerprint.makeId(embedding: emb1)
    let id2 = SpeakerFingerprint.makeId(embedding: emb2)
    #expect(id1 != id2)
}

@Test func fingerprintDifferentForScalePerturbation() {
    // 同一个 speaker 的 centroid embedding 会因为 chunk 数变化有微小数值差异
    // 但指纹算法是基于 exact bytes，scale 变了指纹也会变（这跟 FunASR-Mac 一致）
    let emb1: [Float] = (0..<192).map { Float($0) / 192.0 }
    let emb2: [Float] = emb1.map { $0 * 1.001 }  // scale 0.1%
    let id1 = SpeakerFingerprint.makeId(embedding: emb1)
    let id2 = SpeakerFingerprint.makeId(embedding: emb2)
    // 注意：这里跟 FunASR-Mac 一致，指纹是 exact hash，不抗 scale
    // 真正的"是否同 speaker"判断用 cosine_similarity
    #expect(id1 != id2, "exact-byte hash is sensitive to tiny scale changes")
    #expect(SpeakerFingerprint.cosine(emb1, emb2) > 0.999)
}

@Test func cosineIdenticalVectors() {
    let v: [Float] = [1, 2, 3, 4]
    #expect(SpeakerFingerprint.cosine(v, v) > 0.999)
}

@Test func cosineOrthogonal() {
    let a: [Float] = [1, 0, 0]
    let b: [Float] = [0, 1, 0]
    #expect(abs(SpeakerFingerprint.cosine(a, b)) < 1e-6)
}

@Test func cosineOpposite() {
    let a: [Float] = [1, 0, 0]
    let b: [Float] = [-1, 0, 0]
    #expect(SpeakerFingerprint.cosine(a, b) < -0.999)
}

@Test func cosineZeroVectorReturnsZero() {
    let a: [Float] = [0, 0, 0]
    let b: [Float] = [1, 2, 3]
    #expect(SpeakerFingerprint.cosine(a, b) == 0)
}

@Test func cosineEmptyReturnsZero() {
    #expect(SpeakerFingerprint.cosine([], []) == 0)
}

@Test func cosineMismatchedLengthReturnsZero() {
    let a: [Float] = [1, 2, 3]
    let b: [Float] = [1, 2]
    #expect(SpeakerFingerprint.cosine(a, b) == 0)
}
