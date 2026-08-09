import Testing
@testable import SwiftASR

@Test func diarizationPipelinePropagatesClusteringFailureWithoutMakingSpeakerZero() {
    let sentence = ASRSentence(
        text: "甲",
        startMs: 0,
        endMs: 200,
        tokens: [ASRToken(text: "甲", startMs: 0, endMs: 200)]
    )

    do {
        _ = try SpeakerDiarizationPipeline().run(
            fbank80: [Float](repeating: 0, count: 20 * 80),
            sentences: [sentence],
            speaker: nil,
            precomputedEmbeddings: [Float](repeating: 0, count: 192),
            onProgress: { _, _, _ in },
            shouldCancel: { false }
        )
        Issue.record("zero-norm clustering input must be propagated as a failure")
    } catch let SpeakerDiarizationPipeline.Error.clusteringInputInvalid(error) {
        #expect(error == .zeroNormEmbedding(index: 0))
    } catch {
        Issue.record("unexpected pipeline error: \(error)")
    }
}
