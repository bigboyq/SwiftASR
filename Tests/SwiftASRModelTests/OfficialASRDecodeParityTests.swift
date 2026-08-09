import Testing
@testable import SwiftASR

@Test func asrDecodeUsesTokenNumToIgnorePaddedLogits() {
    let vocabSize = 8404
    let logitsFrames = 300
    let tokenNum = 42

    let effective = ASRDecoder.effectiveTokenCount(
        logitsCount: logitsFrames * vocabSize,
        vocabSize: vocabSize,
        tokenNum: tokenNum
    )

    #expect(effective == tokenNum)
}

@Test func asrDecodeFallsBackToLogitsLengthWhenTokenNumMissing() {
    let vocabSize = 8404
    let logitsFrames = 128

    let effective = ASRDecoder.effectiveTokenCount(
        logitsCount: logitsFrames * vocabSize,
        vocabSize: vocabSize,
        tokenNum: 0
    )

    #expect(effective == logitsFrames)
}

@Test func asrDecodeClampsTokenNumToLogitsCapacity() {
    let vocabSize = 8404
    let logitsFrames = 64

    let effective = ASRDecoder.effectiveTokenCount(
        logitsCount: logitsFrames * vocabSize,
        vocabSize: vocabSize,
        tokenNum: 120
    )

    #expect(effective == logitsFrames)
}

@Test func noBiasEmbeddingUsesOfficialTokenAndFixedExportWidth() {
    let tokens = ASRONNXEngine.noBiasHotwordTokens()

    #expect(tokens.count == 10)
    #expect(tokens[0] == 8377)
    #expect(tokens.dropFirst().allSatisfy { $0 == 0 })
}

@Test func officialCIFTimestampsIgnoreNonFirePositivePeaks() {
    let firePlaces = ASRDecoder.cifFirePlaces(
        peaks: [0.01, 0.5, 0.9998, 0.99995, 1.0],
        threshold: 1.0 - 1e-4,
        forceTimeShift: -1.5
    )

    #expect(firePlaces.count == 2)
    #expect(firePlaces[0] == 1.5)
    #expect(firePlaces[1] == 2.5)
}

@Test func officialCIFTimestampsRecomputeFromAlphasWhenPeakCountMismatches() {
    let timestamps = ASRDecoder.officialCIFTokenTimestampsMs(
        usAlphas: [0.5, 0.5, 0.5, 0.5],
        usCifPeak: [0.2, 0.3, 0.4, 0.5],
        tokenCount: 1,
        maxDurationMs: 30_000
    )

    #expect(timestamps.count == 2)
    #expect(timestamps[0] == 0)
    #expect(timestamps[1] == 30)
}

@Test func officialCIFTimestampsClampToCurrentASRBatchDuration() {
    let timestamps = ASRDecoder.officialCIFTokenTimestampsMs(
        usAlphas: [],
        usCifPeak: [Float](repeating: 1.0, count: 2_000),
        tokenCount: 1_999,
        maxDurationMs: 30_000
    )

    #expect(timestamps.count == 2_000)
    #expect(timestamps.allSatisfy { $0 >= 0 && $0 <= 30_000 })
    #expect(timestamps.last == 30_000)
}
