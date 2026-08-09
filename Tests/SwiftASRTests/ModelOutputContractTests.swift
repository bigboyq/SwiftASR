import Foundation
import Testing
@testable import SwiftASR

@Suite("Model output contracts")
struct ModelOutputContractTests {
    @Test func speakerEmbeddingRejectsNonFiniteValues() {
        #expect(throws: Error.self) {
            try SpeakerNativeCoreMLEngine.validatedEmbeddings(
                flat: [0, .nan, 1, 2],
                batchSize: 1,
                embeddingDim: 4
            )
        }
    }

    @Test func speakerEmbeddingKeepsBatchBoundaries() throws {
        let result = try SpeakerNativeCoreMLEngine.validatedEmbeddings(
            flat: [1, 2, 3, 4, 5, 6],
            batchSize: 2,
            embeddingDim: 3
        )
        #expect(result == [[1, 2, 3], [4, 5, 6]])
    }

    @Test func speakerFeatureContractRejectsNonModelSequenceLengths() {
        #expect(throws: Error.self) {
            try SpeakerNativeCoreMLEngine.validateFeatureContract(
                [[Float](repeating: 0, count: 147 * 80)],
                seqLen: 147
            )
        }
        #expect(throws: Error.self) {
            try SpeakerNativeCoreMLEngine.validateFeatureContract(
                [[Float](repeating: 0, count: 149 * 80)],
                seqLen: 149
            )
        }
    }

    @Test func speakerFeatureContractAcceptsOnlyExactModelShape() throws {
        try SpeakerNativeCoreMLEngine.validateFeatureContract(
            [[Float](repeating: 0, count: 148 * 80)],
            seqLen: 148
        )
        #expect(throws: Error.self) {
            try SpeakerNativeCoreMLEngine.validateFeatureContract(
                [[Float](repeating: 0, count: 148 * 80 - 1)],
                seqLen: 148
            )
        }
    }

    @Test func punctuationArgmaxRejectsNonFiniteLogits() {
        #expect(throws: Error.self) {
            try PuncONNXEngine.argmaxPerFrame(logits: [0, .infinity, 1, 2], numClasses: 2)
        }
    }

    @Test func punctuationArgmaxRemainsDeterministicForFiniteLogits() throws {
        let result = try PuncONNXEngine.argmaxPerFrame(logits: [0, 4, 3, 2, 1, 8], numClasses: 3)
        #expect(result == [1, 2])
    }

    @Test func vadLogitsRejectWrongShapeAndNonFiniteValues() {
        #expect(throws: Error.self) {
            try VADStreamingDetector.validateLogits([Float](repeating: 0, count: 248), frameCount: 2)
        }
        #expect(throws: Error.self) {
            try VADStreamingDetector.validateLogits(
                [Float](repeating: 0, count: 247) + [.nan],
                frameCount: 1
            )
        }
    }

    @Test func asrFloatOutputRejectsNonFiniteValuesAndBadByteCounts() {
        let nonFinite = Data(bytes: [Float.nan], count: MemoryLayout<Float>.size)
        #expect(throws: Error.self) {
            try ASRONNXEngine.decodeFloatArray(nonFinite, label: "logits")
        }
        let innerNonFinite = Data(bytes: [0.0, Float.nan, 1.0], count: 3 * MemoryLayout<Float>.size)
        #expect(throws: Error.self) {
            try ASRONNXEngine.decodeFloatArray(innerNonFinite, label: "logits")
        }
        #expect(throws: Error.self) {
            try ASRONNXEngine.decodeFloatArray(Data([0, 1, 2]), label: "logits")
        }
    }
}
