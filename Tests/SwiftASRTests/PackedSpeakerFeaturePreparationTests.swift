import Testing
@testable import SwiftASR

@Test func packedSpeakerFeaturePreparationMatchesSerialExactly() throws {
    let frameCount = 360
    let fbank = (0..<(frameCount * 80)).map { index in
        Float((index * 17) % 101) / 100
    }
    let windows = (0..<24).map { index in
        let start = index * 9
        return TokenPackedWindowPlanner.Window(
            islandID: 0,
            tokenIDs: [TokenTimeline.TokenID(sentenceIndex: 0, tokenIndex: index)],
            spans: [TokenPackedWindowPlanner.FbankSpan(
                sourceFrames: start..<(start + 80), packedFrames: 0..<80
            )],
            tokenFrameCounts: [80],
            packedFrameCount: 80,
            isOverlongTokenSubwindow: false
        )
    }

    let serial = try AudioPipeline.preparePackedSpeakerFeatures(
        fbank80: fbank, windows: windows, shouldCancel: { false }, workerCount: 1
    )
    let parallel = try AudioPipeline.preparePackedSpeakerFeatures(
        fbank80: fbank, windows: windows, shouldCancel: { false }, workerCount: 4
    )

    #expect(parallel == serial)
}
