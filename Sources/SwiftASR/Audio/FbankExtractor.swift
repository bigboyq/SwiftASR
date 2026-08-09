import Foundation
import Accelerate
import Dispatch

enum FbankExtractionError: Error, LocalizedError {
    case cancelled
    case missingAmMvnBlocks

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Fbank 提取已取消。"
        case .missingAmMvnBlocks:
            return "am.mvn missing <AddShift> or <Rescale> block"
        }
    }
}

/// 16kHz 音频的 log-mel 80 维 Fbank + LFR 拼接 + CMVN 归一化。
///
/// 输出 (T, 80) 维的 log-mel（"LFR 之前"），跟 (T', 80*m/n) 维的 LFR+CMVN 之后。
/// Paraformer / FSMN-VAD 都吃 LFR+CMVN 后的特征；ERes2NetV2 吃 80 维 fbank（带可选 LFR）。
///
/// 对齐的 Python 端是 funasr 的 ``WavFrontendOnline``（vad / paraformer 共享）。
public final class FbankExtractor {
    private let timebase = AudioTimebase.standard

    /// Long recordings benefit from CPU parallelism, while short speaker/ASR
    /// windows are faster without dispatching extra workers.
    public static let maximumParallelWorkers = ComputeConcurrency.performanceCoreCount
    private static let minimumFramesForParallelism = 12_000 // 120 seconds @ 10ms hop

    private let sampleRate: Double
    private let nFft = 512
    private let frameLength: Int
    private let frameShift: Int
    let numMelBins: Int
    private let lowFreq = 20.0
    private let highFreq = 8000.0
    static let officialWaveformScale: Float = Float(1 << 15)

    private var hammingWindow: [Float] = []
    private var melFilters: [[Float]] = [] // [80, 257]
    private var melFilterMatrix: [Float] = [] // Flat [80 * 257]
    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length

    public init() {
        self.sampleRate = Double(timebase.sampleRate)
        self.frameLength = timebase.frameLengthSamples
        self.frameShift = timebase.frameShiftSamples
        self.numMelBins = timebase.featureDimension
        // 1. 初始化汉明窗
        self.hammingWindow = vDSP.window(ofType: Float.self, usingSequence: .hamming, count: frameLength, isHalfWindow: false)

        // 2. 初始化 vDSP FFT setup (512 点 FFT 对应 2^9)
        self.log2n = vDSP_Length(9)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // 3. 构建并缓存 Mel 滤波器组
        buildMelFilters()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Returns the worker count used by the default fbank path for this input.
    /// It is exposed so pipeline logs can state whether a long recording used
    /// the parallel route.
    public func effectiveWorkerCount(pcmData: [Float]) -> Int {
        let totalFrames = frameCount(pcmData: pcmData)
        guard totalFrames >= Self.minimumFramesForParallelism else { return 1 }
        return min(
            Self.maximumParallelWorkers,
            ComputeConcurrency.performanceCoreCount,
            totalFrames
        )
    }

    /// 提取 16kHz PCM 的 80 维 log-mel 特征，不做 LFR 也不做 CMVN。
    /// 输出是扁平 1D 数组 [T * 80]。长录音按独立 frame range 并行处理，
    /// 每个 worker 都拥有自己的 FFTSetup，输出保持原始时间顺序。
    ///
    /// - Parameters:
    ///   - pcmData: 16kHz mono PCM samples
    ///   - workerCount: override worker 数量（默认按 PCM 长度自动选）
    ///   - reportEveryN: 每个 worker 跑满 N 帧回调一次 `onFrameProcessed`。
    ///     batching 发生在 worker 内部的 local counter 上，hot path 不持锁。
    ///     0 = 不报告。1h 音频默认 1000 帧 ≈ 1s 音频 / worker，闭包频率约 3/秒/worker。
    ///   - onFrameProcessed: 增量回调，每次本 worker 累计完成 `reportEveryN` 帧时调一次
    ///     （最后一次会 flush 剩余的 < N 帧）。闭包跑在 GCD global queue，需 `@Sendable`。
    public func extractFbank(
        pcmData: [Float],
        workerCount: Int? = nil,
        reportEveryN: Int = 1000,
        onFrameProcessed: (@Sendable (Int) -> Void)? = nil
    ) -> [Float] {
        (try? extractFbankCancellable(
            pcmData: pcmData,
            workerCount: workerCount,
            reportEveryN: reportEveryN,
            onFrameProcessed: onFrameProcessed,
            shouldCancel: { false }
        )) ?? []
    }

    /// Cancellable variant used by the end-to-end pipeline. The legacy
    /// non-throwing API remains available for deterministic/unit callers, but
    /// long-running production work must be able to stop between frames.
    func extractFbankCancellable(
        pcmData: [Float],
        workerCount: Int? = nil,
        reportEveryN: Int = 1000,
        onFrameProcessed: (@Sendable (Int) -> Void)? = nil,
        shouldCancel: @Sendable @escaping () -> Bool
    ) throws -> [Float] {
        guard pcmData.count >= frameLength else { return [] }
        if shouldCancel() { throw FbankExtractionError.cancelled }

        let totalFrames = (pcmData.count - frameLength) / frameShift + 1
        let workers = min(
            totalFrames,
            max(1, workerCount ?? effectiveWorkerCount(pcmData: pcmData))
        )
        guard workers > 1 else {
            return try extractFbankFrames(
                pcmData: pcmData,
                frameRange: 0..<totalFrames,
                reportEveryN: reportEveryN,
                onFrameProcessed: onFrameProcessed,
                shouldCancel: shouldCancel
            )
        }

        let storage = ParallelFbankStorage(totalFrames: totalFrames, featureDim: numMelBins)
        let cancellation = FbankCancellationFlag()
        DispatchQueue.concurrentPerform(iterations: workers) { workerIndex in
            guard !cancellation.isCancelled, !shouldCancel() else {
                cancellation.cancel()
                return
            }
            let start = totalFrames * workerIndex / workers
            let end = totalFrames * (workerIndex + 1) / workers
            let worker = FbankExtractor()
            do {
                let features = try worker.extractFbankFrames(
                    pcmData: pcmData,
                    frameRange: start..<end,
                    reportEveryN: reportEveryN,
                    onFrameProcessed: onFrameProcessed,
                    shouldCancel: shouldCancel
                )
                guard !cancellation.isCancelled else { return }
                storage.store(features: features, frameRange: start..<end)
            } catch {
                cancellation.cancel()
            }
        }
        if cancellation.isCancelled || shouldCancel() {
            throw FbankExtractionError.cancelled
        }
        return storage.takeResult()
    }

    /// One range has no dependency on its neighbours: pre-emphasis uses the
    /// first sample of the same 25ms frame, matching the existing Kaldi rule.
    ///
    /// `reportEveryN` / `onFrameProcessed` per-worker batching: the per-frame
    /// loop is hot, so the counter stays on a local stack variable and only
    /// the boundary crossings invoke the closure.  1h audio × 6 workers ×
    /// 1000-frame batching ≈ 18 closures/sec — well below any reasonable
    /// UI polling cadence.
    private func extractFbankFrames(
        pcmData: [Float],
        frameRange: Range<Int>,
        reportEveryN: Int = 1000,
        onFrameProcessed: (@Sendable (Int) -> Void)? = nil,
        shouldCancel: @Sendable @escaping () -> Bool = { false }
    ) throws -> [Float] {
        var fbankFeatures = [Float](repeating: 0.0, count: frameRange.count * numMelBins)

        var frameSamples = [Float](repeating: 0.0, count: frameLength)
        var frameBuffer = [Float](repeating: 0.0, count: nFft)
        var real = [Float](repeating: 0.0, count: nFft / 2)
        var imag = [Float](repeating: 0.0, count: nFft / 2)
        var powerSpectrum = [Float](repeating: 0.0, count: nFft / 2 + 1)

        // Per-worker local batching: 累加 N 帧才调一次闭包. reportEveryN==0
        // 视为不报告, 跳过 batching 逻辑 (跟原来行为完全一致).
        let shouldReport = onFrameProcessed != nil && reportEveryN > 0

        try renderFbankFrames(
            pcmData: pcmData,
            frameRange: frameRange,
            shouldReport: shouldReport,
            reportEveryN: reportEveryN,
            onFrameProcessed: onFrameProcessed,
            shouldCancel: shouldCancel,
            fbankFeatures: &fbankFeatures,
            frameSamples: &frameSamples,
            frameBuffer: &frameBuffer,
            real: &real,
            imag: &imag,
            powerSpectrum: &powerSpectrum
        )

        return fbankFeatures
    }

    /// Owns the pointer-heavy FFT/Mel kernel so the public extraction method
    /// remains responsible only for buffer lifetime, cancellation and progress.
    private func renderFbankFrames(
        pcmData: [Float],
        frameRange: Range<Int>,
        shouldReport: Bool,
        reportEveryN: Int,
        onFrameProcessed: (@Sendable (Int) -> Void)?,
        shouldCancel: @Sendable @escaping () -> Bool,
        fbankFeatures: inout [Float],
        frameSamples: inout [Float],
        frameBuffer: inout [Float],
        real: inout [Float],
        imag: inout [Float],
        powerSpectrum: inout [Float]
    ) throws {
        var scaleWaveform = Self.officialWaveformScale
        let scaleVal: Float = 0.25
        let halfFft = nFft / 2
        let melFilterDim = halfFft + 1
        var localCount = 0

        try pcmData.withUnsafeBufferPointer { pcmBuf in
            try fbankFeatures.withUnsafeMutableBufferPointer { outBuf in
                try melFilterMatrix.withUnsafeBufferPointer { melMatBuf in
                    try hammingWindow.withUnsafeBufferPointer { hammingBuf in
                        try frameSamples.withUnsafeMutableBufferPointer { frameSamplesBuf in
                            try frameBuffer.withUnsafeMutableBufferPointer { frameBufferBuf in
                                try real.withUnsafeMutableBufferPointer { realBuf in
                                    try imag.withUnsafeMutableBufferPointer { imagBuf in
                                        try powerSpectrum.withUnsafeMutableBufferPointer { powerSpectrumBuf in
                                            guard let pcmPtr = pcmBuf.baseAddress,
                                                  let outPtr = outBuf.baseAddress,
                                                  let melMatPtr = melMatBuf.baseAddress,
                                                  let hammingPtr = hammingBuf.baseAddress,
                                                  let frameSamplesPtr = frameSamplesBuf.baseAddress,
                                                  let frameBufferPtr = frameBufferBuf.baseAddress,
                                                  let rPtr = realBuf.baseAddress,
                                                  let iPtr = imagBuf.baseAddress,
                                                  let pSpectrumPtr = powerSpectrumBuf.baseAddress else { return }

                                            for f in frameRange {
                                                if shouldCancel() { throw FbankExtractionError.cancelled }
                                                let startIdx = f * frameShift
                                                let outputOffset = (f - frameRange.lowerBound) * numMelBins

                                                vDSP_vsmul(pcmPtr.advanced(by: startIdx), 1, &scaleWaveform, frameSamplesPtr, 1, vDSP_Length(frameLength))

                                                var meanVal: Float = 0
                                                vDSP_meanv(frameSamplesPtr, 1, &meanVal, vDSP_Length(frameLength))
                                                var negMeanVal = -meanVal
                                                vDSP_vsadd(frameSamplesPtr, 1, &negMeanVal, frameSamplesPtr, 1, vDSP_Length(frameLength))

                                                // Keep the scalar Double intermediate for bit-exact parity.
                                                frameBufferPtr[0] = (frameSamplesPtr[0] - 0.97 * frameSamplesPtr[0]) * hammingPtr[0]
                                                for i in 1..<frameLength {
                                                    frameBufferPtr[i] = (frameSamplesPtr[i] - 0.97 * frameSamplesPtr[i - 1]) * hammingPtr[i]
                                                }

                                                bzero(frameBufferPtr.advanced(by: frameLength), (nFft - frameLength) * MemoryLayout<Float>.size)

                                                var splitComplex = DSPSplitComplex(realp: rPtr, imagp: iPtr)
                                                let inputComplexPtr = UnsafeRawPointer(frameBufferPtr).assumingMemoryBound(to: DSPComplex.self)
                                                vDSP_ctoz(inputComplexPtr, 2, &splitComplex, 1, vDSP_Length(halfFft))
                                                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                                                pSpectrumPtr[0] = (rPtr[0] * rPtr[0]) * scaleVal
                                                pSpectrumPtr[halfFft] = (iPtr[0] * iPtr[0]) * scaleVal
                                                var splitRest = DSPSplitComplex(realp: rPtr.advanced(by: 1), imagp: iPtr.advanced(by: 1))
                                                vDSP_zvmags(&splitRest, 1, pSpectrumPtr.advanced(by: 1), 1, vDSP_Length(halfFft - 1))
                                                var sVal = scaleVal
                                                vDSP_vsmul(pSpectrumPtr.advanced(by: 1), 1, &sVal, pSpectrumPtr.advanced(by: 1), 1, vDSP_Length(halfFft - 1))

                                                let outFramePtr = outPtr.advanced(by: outputOffset)
                                                for m in 0..<numMelBins {
                                                    var melWeight: Float = 0.0
                                                    let filterPtr = melMatPtr.advanced(by: m * melFilterDim)
                                                    vDSP_dotpr(pSpectrumPtr, 1, filterPtr, 1, &melWeight, vDSP_Length(melFilterDim))
                                                    outFramePtr[m] = log(max(melWeight, 1e-10))
                                                }

                                                if shouldReport {
                                                    localCount += 1
                                                    if localCount >= reportEveryN {
                                                        onFrameProcessed?(reportEveryN)
                                                        localCount = 0
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if shouldReport && localCount > 0 {
            onFrameProcessed?(localCount)
        }
    }

    private final class FbankCancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func cancel() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// The storage serializes only the final range copy; FFT and Mel
    /// computation remain fully parallel and no frame order is changed.
    private final class ParallelFbankStorage: @unchecked Sendable {
        private let lock = NSLock()
        private let featureDim: Int
        private var result: [Float]

        init(totalFrames: Int, featureDim: Int) {
            self.featureDim = featureDim
            self.result = [Float](repeating: 0.0, count: totalFrames * featureDim)
        }

        func store(features: [Float], frameRange: Range<Int>) {
            let start = frameRange.lowerBound * featureDim
            let end = frameRange.upperBound * featureDim
            lock.lock()
            result.replaceSubrange(start..<end, with: features)
            lock.unlock()
        }

        func takeResult() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    /// 计算 fbank 总帧数（已知 PCM 长度）。调用方用它把 ms ↔ frame 互相转换。
    /// 公式：``(pcm.count - frameLength) / frameShift + 1``，保证 frameLength 长度能取到。
    public func frameCount(pcmData: [Float]) -> Int {
        timebase.frameCount(forSampleCount: pcmData.count)
    }

    // LFR/CMVN transforms are implemented in FbankExtractor+Frontend.swift.
    /// Kaldi 格式 am.mvn 解析：``<AddShift>`` 后跟 mean（首行是 "0 [ v0 v1 ... ]"），
    /// ``<Rescale>`` 后跟 rescale（同格式）。
    ///
    /// am.mvn 长这样（VAD 400 维）：
    /// ```
    /// <Nnet>
    /// <Splice> 400 400
    /// [ 0 ]
    /// <AddShift> 400 400
    /// <LearnRateCoef> 0 [ -8.31 -8.60 ... -8.31 ... ]   ← mean（已在负对数域，直接加）
    /// <Rescale> 400 400
    /// <LearnRateCoef> 0 [ 0.156 0.154 ... 0.156 ... ]   ← rescale = 1/sqrt(var)
    /// </Nnet>
    /// ```
    /// Loads CMVN without constructing the DSP state (FFT setup and Mel filters).
    /// Pipeline callers only need the file parser, not a second extractor.
    public static func loadMvnFile(path: String) throws -> (addShift: [Float], rescale: [Float]) {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try Self.parseMvn(text: text)
    }

    public static func parseMvn(text: String) throws -> (addShift: [Float], rescale: [Float]) {
        // Kaldi 格式是单行 mean / single-line rescale，中间是 "[ v0 v1 ... vN ]"。
        // 不能用通用 "[...]" 正则（文件里 <Splice> 下面还有 "[ 0 ]" 这种会先匹配到）。
        // 按 <AddShift> / <Rescale> 标签切成两段，每段独立抓一个 "[ ... ]"。
        guard let addShiftBlock = extractBracketBlock(afterTag: "AddShift", in: text),
              let rescaleBlock = extractBracketBlock(afterTag: "Rescale", in: text) else {
            throw FbankExtractionError.missingAmMvnBlocks
        }
        let addShift = parseFloatList(addShiftBlock)
        let rescale = parseFloatList(rescaleBlock)
        return (addShift, rescale)
    }

    private static func extractBracketBlock(afterTag tag: String, in text: String) -> String? {
        // 找 "<tag>" 之后第一个 "[ ... ]"
        guard let tagRange = text.range(of: "<\(tag)>") else { return nil }
        let afterTag = text[tagRange.upperBound...]
        guard let openBracket = afterTag.firstIndex(of: "["),
              let closeBracket = afterTag[afterTag.index(after: openBracket)...].firstIndex(of: "]") else {
            return nil
        }
        return String(afterTag[openBracket..<closeBracket])
    }

    private static func parseFloatList(_ s: String) -> [Float] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .compactMap { Float($0) }
    }

    private func hzToMel(_ hz: Double) -> Double {
        return 1127.0 * log(1.0 + hz / 700.0)
    }

    private func buildMelFilters() {
        let minMel = hzToMel(lowFreq)
        let maxMel = hzToMel(highFreq)
        let melFreqDelta = (maxMel - minMel) / Double(numMelBins + 1)
        let fftBinWidth = sampleRate / Double(nFft)

        melFilters = [[Float]](repeating: [Float](repeating: 0.0, count: nFft / 2 + 1), count: numMelBins)
        melFilterMatrix = [Float](repeating: 0.0, count: numMelBins * (nFft / 2 + 1))

        for m in 0..<numMelBins {
            let leftMel = minMel + Double(m) * melFreqDelta
            let centerMel = minMel + Double(m + 1) * melFreqDelta
            let rightMel = minMel + Double(m + 2) * melFreqDelta

            for i in 0..<(nFft / 2) {
                let freqHz = Double(i) * fftBinWidth
                let melF = hzToMel(freqHz)

                var weight: Double = 0.0
                if melF > leftMel && melF <= centerMel {
                    weight = (melF - leftMel) / (centerMel - leftMel)
                } else if melF > centerMel && melF < rightMel {
                    weight = (rightMel - melF) / (rightMel - centerMel)
                }
                let w = Float(weight)
                melFilters[m][i] = w
                melFilterMatrix[m * (nFft / 2 + 1) + i] = w
            }
            melFilters[m][nFft / 2] = 0.0
            melFilterMatrix[m * (nFft / 2 + 1) + nFft / 2] = 0.0
        }
    }
}
