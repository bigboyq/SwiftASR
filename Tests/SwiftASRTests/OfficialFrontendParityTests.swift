import Testing
@testable import SwiftASR

@Test func officialFrontendUsesFunASRWaveformScale() {
    #expect(FbankExtractor.officialWaveformScale == 32768)
}

@Test func officialLFRPaddingMatchesFunASREvenWindow() {
    let indexes = FbankExtractor.officialLFRPaddedFrameIndexes(
        totalFrames: 5,
        lfrM: 4,
        lfrN: 1,
        outputFrames: 5
    )

    #expect(Array(indexes.prefix(8)) == [0, 0, 1, 2, 3, 4, 4, 4])
}

@Test func applyLFRUsesOfficialLeftPaddingWindowOrder() {
    var fbank: [Float] = []
    for frame in 0..<5 {
        fbank.append(contentsOf: [Float](repeating: Float(frame), count: 80))
    }

    let extractor = FbankExtractor()
    let lfr = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 4, lfrN: 1, mvn: nil)

    #expect(lfr.count == 5 * 320)
    #expect(lfr[0] == 0)
    #expect(lfr[80] == 0)
    #expect(lfr[160] == 1)
    #expect(lfr[240] == 2)

    let secondRow = 320
    #expect(lfr[secondRow + 0] == 0)
    #expect(lfr[secondRow + 80] == 1)
    #expect(lfr[secondRow + 160] == 2)
    #expect(lfr[secondRow + 240] == 3)
}
