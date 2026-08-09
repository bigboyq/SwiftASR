import Testing
import Foundation
@testable import SwiftASR

@Suite("FbankExtractor Progress Reporting")
struct FbankExtractorProgressTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var callbackCount = 0
        private var lastBatch = 0

        func record(frames: Int) {
            lock.lock(); defer { lock.unlock() }
            count += frames
            callbackCount += 1
            lastBatch = frames
        }

        func snapshot() -> (count: Int, callbackCount: Int, lastBatch: Int) {
            lock.lock(); defer { lock.unlock() }
            return (count, callbackCount, lastBatch)
        }
    }

    private func makePCM(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(16_000 * seconds))
    }

    @Test func batching_1000Frames_10Callbacks() {
        let counter = Counter()
        _ = FbankExtractor().extractFbank(
            pcmData: makePCM(seconds: 1), workerCount: 1, reportEveryN: 10,
            onFrameProcessed: { counter.record(frames: $0) }
        )
        let snap = counter.snapshot()
        #expect(snap.count == 98)
        #expect(snap.callbackCount == 10)
        #expect(snap.lastBatch == 8)
    }

    @Test func batching_exactMultiple_noFlush() {
        let counter = Counter()
        _ = FbankExtractor().extractFbank(
            pcmData: makePCM(seconds: 1.5), workerCount: 1, reportEveryN: 37,
            onFrameProcessed: { counter.record(frames: $0) }
        )
        let snap = counter.snapshot()
        #expect(snap.count == 148)
        #expect(snap.callbackCount == 4)
        #expect(snap.lastBatch == 37)
    }

    @Test func batching_partialFlush_148FramesN37_4Full1Flush() {
        let counter = Counter()
        _ = FbankExtractor().extractFbank(
            pcmData: makePCM(seconds: 1.5), workerCount: 1, reportEveryN: 50,
            onFrameProcessed: { counter.record(frames: $0) }
        )
        let snap = counter.snapshot()
        #expect(snap.count == 148)
        #expect(snap.callbackCount == 3)
        #expect(snap.lastBatch == 48)
    }

    @Test func batching_zeroN_disablesReporting() {
        let counter = Counter()
        _ = FbankExtractor().extractFbank(
            pcmData: makePCM(seconds: 1), workerCount: 1, reportEveryN: 0,
            onFrameProcessed: { counter.record(frames: $0) }
        )
        let snap = counter.snapshot()
        #expect(snap.callbackCount == 0)
        #expect(snap.count == 0)
    }

    @Test func batching_nilClosure_disablesReporting() {
        let fbank = FbankExtractor().extractFbank(
            pcmData: makePCM(seconds: 1), workerCount: 1, reportEveryN: 1_000
        )
        #expect(fbank.count == 98 * 80)
    }

    @Test func cancellableExtractionStopsBeforeCompletingInput() {
        do {
            _ = try FbankExtractor().extractFbankCancellable(
                pcmData: makePCM(seconds: 10), workerCount: 1, shouldCancel: { true }
            )
            Issue.record("cancellable extraction should throw")
        } catch is FbankExtractionError {
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
    }

    @Test func malformedFrontendInputReturnsEmptyInsteadOfCrashing() {
        let extractor = FbankExtractor()
        #expect(extractor.applyLFR_CMVN(fbank80: [0, 1, 2], lfrM: 7, lfrN: 6, mvn: nil).isEmpty)
        #expect(extractor.applyLFR_CMVN(
            fbank80: [Float](repeating: 0, count: 80), lfrM: 1, lfrN: 1,
            mvn: (addShift: [], rescale: [])
        ).isEmpty)
        #expect(extractor.applyLFR_CMVNRange(
            fbank80: [Float](repeating: 0, count: 80), lfrM: 5, lfrN: 1,
            outputFrameRange: 0..<1, mvn: (addShift: [], rescale: [])
        ).isEmpty)
    }

    @Test func batching_singleWorker_countEqualsFrameCount() {
        let counter = Counter()
        _ = FbankExtractor().extractFbank(
            pcmData: makePCM(seconds: 1), workerCount: 1, reportEveryN: 50,
            onFrameProcessed: { counter.record(frames: $0) }
        )
        #expect(counter.snapshot().count == 98)
    }
}
