import Foundation

/// Speaker embedding extraction timing shared by production passes.
struct SpeakerEmbeddingTiming: Sendable {
    let preparationSeconds: TimeInterval
    let inferenceSeconds: TimeInterval
    let preparedCount: Int
    let batchCount: Int
}

/// Flat, fixed-dimension speaker embeddings produced by a single extraction pass.
struct SpeakerEmbeddingExtraction: Sendable {
    let embeddings: [Float]
    let timing: SpeakerEmbeddingTiming
}
