import Testing
@testable import SwiftASR

@Test func standardAudioTimebasePreservesFrontendGeometry() {
    let timebase = AudioTimebase.standard

    #expect(timebase.sampleRate == 16_000)
    #expect(timebase.frameLengthSamples == 400)
    #expect(timebase.frameShiftSamples == 160)
    #expect(timebase.featureDimension == 80)
    #expect(timebase.frameCount(forSampleCount: 16_000) == 98)
    #expect(timebase.milliseconds(forFrameCount: 98) == 980)
}

@Test func audioTimebaseUsesFloorForStartsAndCeilForEnds() {
    let timebase = AudioTimebase.standard

    #expect(timebase.sampleIndex(forMilliseconds: 10) == 160)
    #expect(timebase.sampleIndex(forMilliseconds: 1, rounding: .down) == 16)
    #expect(timebase.sampleIndex(forMilliseconds: 1, rounding: .up) == 16)
    #expect(timebase.sampleIndex(forMilliseconds: 1_001, rounding: .down) == 16_016)
    #expect(timebase.sampleIndex(forMilliseconds: 1_001, rounding: .up) == 16_016)

    let range = timebase.sampleRange(
        startMilliseconds: 1,
        endMilliseconds: 11,
        totalSamples: 16_000
    )
    #expect(range == 16..<176)
}

@Test func audioTimebaseFrameRangeClampsAndCoversPartialFrames() {
    let timebase = AudioTimebase.standard

    let range = timebase.frameRange(
        startMilliseconds: 11,
        endMilliseconds: 21,
        totalFrames: 98
    )
    #expect(range == 1..<3)

    let clamped = timebase.frameRange(
        startMilliseconds: -100,
        endMilliseconds: 2_000,
        totalFrames: 98
    )
    #expect(clamped == 0..<98)
}
