import Foundation

/// The coordinate system shared by the audio frontend and diarization code.
///
/// Audio is decoded to 16 kHz mono PCM. The fbank extractor then produces
/// 25 ms frames every 10 ms. Keeping these conversions here prevents each
/// pipeline stage from quietly choosing its own rounding or frame geometry.
struct AudioTimebase: Sendable, Equatable {
    static let standard = AudioTimebase(
        sampleRate: 16_000,
        frameLengthSamples: 400,
        frameShiftSamples: 160,
        featureDimension: 80
    )

    let sampleRate: Int
    let frameLengthSamples: Int
    let frameShiftSamples: Int
    let featureDimension: Int

    init(
        sampleRate: Int,
        frameLengthSamples: Int = 400,
        frameShiftSamples: Int = 160,
        featureDimension: Int = 80
    ) {
        precondition(sampleRate > 0)
        precondition(frameLengthSamples > 0)
        precondition(frameShiftSamples > 0)
        precondition(featureDimension > 0)
        self.sampleRate = sampleRate
        self.frameLengthSamples = frameLengthSamples
        self.frameShiftSamples = frameShiftSamples
        self.featureDimension = featureDimension
    }

    /// Keeps the existing pipeline behavior: a duration is truncated to an
    /// integer millisecond rather than rounded to the nearest millisecond.
    func milliseconds(forSampleCount sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 0 }
        return Int((Double(sampleCount) * 1_000.0 / Double(sampleRate)).rounded(.down))
    }

    /// Converts milliseconds to a sample index using an explicit rounding
    /// policy. Callers normally use floor for starts and ceil for ends.
    func sampleIndex(
        forMilliseconds milliseconds: Int,
        rounding: FloatingPointRoundingRule = .down
    ) -> Int {
        guard milliseconds > 0 else { return 0 }
        return Int((Double(milliseconds) * Double(sampleRate) / 1_000.0).rounded(rounding))
    }

    /// Converts a millisecond interval into a bounded PCM interval. The
    /// half-open interval preserves the old boundary behavior: start floors,
    /// end ceils, and both sides are clamped to the available PCM.
    func sampleRange(
        startMilliseconds: Int,
        endMilliseconds: Int,
        totalSamples: Int
    ) -> Range<Int>? {
        guard totalSamples > 0, endMilliseconds > startMilliseconds else { return nil }
        let start = min(totalSamples, max(0, sampleIndex(forMilliseconds: startMilliseconds, rounding: .down)))
        let end = min(
            totalSamples,
            max(start, sampleIndex(forMilliseconds: endMilliseconds, rounding: .up))
        )
        guard end > start else { return nil }
        return start..<end
    }

    /// Matches the fbank extractor's valid-frame formula exactly.
    func frameCount(forSampleCount sampleCount: Int) -> Int {
        guard sampleCount >= frameLengthSamples else { return 0 }
        return (sampleCount - frameLengthSamples) / frameShiftSamples + 1
    }

    /// Converts a millisecond interval into a bounded fbank frame interval.
    /// Starts floor to avoid dropping the frame containing the start; ends
    /// ceil to avoid dropping the frame containing the end.
    func frameRange(
        startMilliseconds: Int,
        endMilliseconds: Int,
        totalFrames: Int
    ) -> Range<Int>? {
        guard totalFrames > 0, endMilliseconds > startMilliseconds else { return nil }
        let start = min(
            totalFrames,
            max(0, Int((Double(startMilliseconds) * Double(sampleRate) / 1_000.0 / Double(frameShiftSamples)).rounded(.down)))
        )
        let end = min(
            totalFrames,
            max(start, Int((Double(endMilliseconds) * Double(sampleRate) / 1_000.0 / Double(frameShiftSamples)).rounded(.up)))
        )
        guard end > start else { return nil }
        return start..<end
    }

    /// Converts fbank frame coverage to the same truncated millisecond scale
    /// used by the pipeline's total-duration and speaker-window helpers.
    func milliseconds(forFrameCount frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        return milliseconds(forSampleCount: frameCount * frameShiftSamples)
    }
}
