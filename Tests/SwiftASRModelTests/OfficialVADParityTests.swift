import Testing
@testable import SwiftASR

@Test func officialVADEndpointKeepsSpeechAcrossBriefPause() {
    var frames = [Bool](repeating: false, count: 50)
    frames += [Bool](repeating: true, count: 30)
    frames += [Bool](repeating: false, count: 50) // 500ms: shorter than official endpoint silence.
    frames += [Bool](repeating: true, count: 50)
    frames += [Bool](repeating: false, count: 100)

    let segments = VADONNXEngine.officialSegmentsFromSpeechFrames(frames)

    #expect(segments.count == 1)
    #expect(segments[0].startMs < 500) // 200ms window + 200ms start extension.
    #expect(segments[0].endMs > 1_800)
}

@Test func officialVADEndpointFlushesOpenSpeechAtEndOfAudio() {
    let frames = [Bool](repeating: true, count: 80)

    let segments = VADONNXEngine.officialSegmentsFromSpeechFrames(frames)

    #expect(segments.count == 1)
    #expect(segments[0].startMs == 0)
    #expect(segments[0].endMs == 800)
}

@Test func streamingVADUsesExpectedFSMNCacheShape() {
    #expect(VADONNXEngine.cacheShape.count == 4)
    #expect(VADONNXEngine.cacheShape[0] as? Int == 1)
    #expect(VADONNXEngine.cacheShape[1] as? Int == 128)
    #expect(VADONNXEngine.cacheShape[2] as? Int == 19)
    #expect(VADONNXEngine.cacheShape[3] as? Int == 1)
    #expect(VADONNXEngine.cacheCount == 4)
}
