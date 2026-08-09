import Testing
import Foundation
@testable import SwiftASR

// MARK: - FbankExtractor 全面测试

@Test func fbankFrameCount() {
    // 16kHz 1s 静音 = 98 帧
    let pcm = [Float](repeating: 0.0, count: 16000)
    let extractor = FbankExtractor()
    let fbank = extractor.extractFbank(pcmData: pcm)
    #expect(fbank.count / 80 == 98)
}

@Test func fbankSilenceIsNegativeLogMel() {
    let pcm = [Float](repeating: 0.0, count: 16000)
    let extractor = FbankExtractor()
    let fbank = extractor.extractFbank(pcmData: pcm)
    // log(1e-10) 接近 -23；实际 0 信号 → 极小正数 → log 负数
    #expect(fbank.allSatisfy { $0 < 0 })
    #expect(fbank.allSatisfy { $0 > -30 }, "log(1e-10)=-23, fbank should not be more negative than that")
}

@Test func fbankShortAudioHandled() {
    // 长度 < frameLength (400) → 应该返回空
    let pcm = [Float](repeating: 0.0, count: 200)
    let extractor = FbankExtractor()
    let fbank = extractor.extractFbank(pcmData: pcm)
    #expect(fbank.isEmpty)
}

@Test func fbankDeterministicAcrossCalls() {
    let pcm = [Float](repeating: 0.5, count: 16000)
    let extractor = FbankExtractor()
    let a = extractor.extractFbank(pcmData: pcm)
    let b = extractor.extractFbank(pcmData: pcm)
    #expect(a == b)
}

@Test func fbankParallelMatchesSingleWorkerExactly() {
    // Frame outputs are independent. Parallel scheduling must not change a
    // single Float, otherwise VAD/ASR parity can silently drift at boundaries.
    let pcm = (0..<(16_000 * 8)).map { index in
        Float(sin(2.0 * .pi * 440.0 * Double(index) / 16_000.0) * 0.3)
    }
    let extractor = FbankExtractor()
    let single = extractor.extractFbank(pcmData: pcm, workerCount: 1)
    let parallel = extractor.extractFbank(pcmData: pcm, workerCount: 4)
    #expect(parallel == single)
}

@Test func fbankSineWaveHigherEnergyThanSilence() {
    // 440Hz 正弦波的能量应该比静音高
    var sinePcm = [Float]()
    for i in 0..<16000 {
        let s = sin(2.0 * .pi * 440.0 * Double(i) / 16000.0) * 0.3
        sinePcm.append(Float(s))
    }
    let silencePcm = [Float](repeating: 0, count: 16000)
    let extractor = FbankExtractor()
    let sineFbank = extractor.extractFbank(pcmData: sinePcm)
    let silenceFbank = extractor.extractFbank(pcmData: silencePcm)
    let sineMean = sineFbank.reduce(0, +) / Float(sineFbank.count)
    let silenceMean = silenceFbank.reduce(0, +) / Float(silenceFbank.count)
    #expect(sineMean > silenceMean)
}

@Test func lfrStackSizingSeaco() {
    // LFR(7, 6) for SeACo / Paraformer: output dim = 80 * 7 = 560
    let fbank = [Float](repeating: 0, count: 100 * 80)
    let extractor = FbankExtractor()
    let lfr = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 7, lfrN: 6, mvn: nil)
    #expect(lfr.count == 17 * 560)
}

@Test func lfrStackSizingVAD() {
    // LFR(5, 1) for VAD: output dim = 80 * 5 = 400
    let fbank = [Float](repeating: 0, count: 100 * 80)
    let extractor = FbankExtractor()
    let lfr = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 5, lfrN: 1, mvn: nil)
    #expect(lfr.count == 100 * 400)
}

@Test func lfrRangeMatchesWholeVADFrontend() {
    let fbank = (0..<(137 * 80)).map { Float($0 % 31) / 31.0 }
    let extractor = FbankExtractor()
    let whole = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 5, lfrN: 1, mvn: nil)
    let first = extractor.applyLFR_CMVNRange(
        fbank80: fbank, lfrM: 5, lfrN: 1,
        outputFrameRange: 0..<61, mvn: nil
    )
    let last = extractor.applyLFR_CMVNRange(
        fbank80: fbank, lfrM: 5, lfrN: 1,
        outputFrameRange: 61..<137, mvn: nil
    )
    #expect(first + last == whole)
}

@Test func lfrStackSizingSpeaker() {
    // LFR(4, 1) for Speaker 3D-Speaker ERes2NetV2: output dim = 80 * 4 = 320
    let fbank = [Float](repeating: 0, count: 100 * 80)
    let extractor = FbankExtractor()
    let lfr = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 4, lfrN: 1, mvn: nil)
    #expect(lfr.count == 100 * 320)
}

@Test func lfrCenterPadding() {
    // LFR 在 t=0 应该用 replicate pad
    let fbank = [Float](repeating: 1.0, count: 100 * 80)  // 全部 = 1
    let extractor = FbankExtractor()
    let lfr = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 7, lfrN: 6, mvn: nil)
    // 第一帧的 LFR 输出应该全部 = 1 (因为 replicate padding)
    let firstFrame = Array(lfr[0..<560])
    #expect(firstFrame.allSatisfy { abs($0 - 1.0) < 1e-5 }, "first LFR frame should be all 1s (replicate padding)")
}

@Test func lfrCMSNAppliesAddShiftAndRescale() throws {
    let fbank = [Float](repeating: 1.0, count: 10 * 80)
    let extractor = FbankExtractor()
    let lfrNoMvn = extractor.applyLFR_CMVN(fbank80: fbank, lfrM: 1, lfrN: 1, mvn: nil)
    #expect(lfrNoMvn.count == 10 * 80)

    // 构造 80 维 am.mvn
    var meanVals: [String] = []
    for i in 0..<80 { meanVals.append(String(i)) }
    var rescaleVals: [String] = []
    for _ in 0..<80 { rescaleVals.append("0.5") }
    var mvn80 = "<Nnet>\n"
    mvn80 += "<Splice> 80 80\n[ 0 ]\n"
    mvn80 += "<AddShift> 80 80\n<LearnRateCoef> 0 [ " + meanVals.joined(separator: " ") + " ]\n"
    mvn80 += "<Rescale> 80 80\n<LearnRateCoef> 0 [ " + rescaleVals.joined(separator: " ") + " ]\n"
    mvn80 += "</Nnet>\n"
    let mvn80Path = FileManager.default.temporaryDirectory.appendingPathComponent("test80_\(UUID()).mvn").path
    try mvn80.write(toFile: mvn80Path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: mvn80Path) }

    let mvn = try FbankExtractor.loadMvnFile(path: mvn80Path)
    let lfr80 = extractor.applyLFR_CMVN(
        fbank80: [Float](repeating: 2.0, count: 10 * 80),
        lfrM: 1, lfrN: 1,
        mvn: mvn
    )
    // 第一个特征: (2 + 0) * 0.5 = 1.0
    #expect(abs(lfr80[0] - 1.0) < 1e-3, "got \(lfr80[0])")
}
