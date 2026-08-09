import Foundation
import Accelerate
import OnnxRuntimeBindings

/// FSMN streaming VAD model errors. Distinct cases so callers can react
/// to specific conditions (input contract vs. output contract vs.
/// missing logits at inference time).  Replaces the pre-existing
/// `NSError(domain: "VADStreamingDetector", code: -N, ...)` template
/// (round-1 F2.4 没覆盖到 VADONNXEngine，round-3 M2-N1 补完)。
public enum VADInferenceError: Error, LocalizedError, Sendable {
    case missingSpeechInput(inputNames: [String])
    case missingLogitsOutput(outputNames: [String])
    case incompleteCacheContract
    case streamMissingLogits
    /// 输入 fbank 帧数 × 特征维 ≠ framesCount × featureDim
    case streamInputShapeMismatch
    /// 输出 logits 维数 ≠ framesCount × expectedLogitWidth
    case logitsShapeMismatch(framesCount: Int, found: Int)
    /// run 输出 byte 数 ≠ cacheByteCount
    case cacheShapeMismatch(outputName: String, found: Int)
    /// run 输出无 cache tensor
    case missingCacheOutput(name: String)
    /// run logits 含 NaN / ±Inf
    case nonFiniteLogits

    public var errorDescription: String? {
        switch self {
        case let .missingSpeechInput(inputNames):
            return "VAD model is missing speech input: \(inputNames)"
        case let .missingLogitsOutput(outputNames):
            return "VAD model is missing logits output: \(outputNames)"
        case .incompleteCacheContract:
            return "VAD model cache contract is incomplete"
        case .streamMissingLogits:
            return "VAD stream returned no logits"
        case .streamInputShapeMismatch:
            return "VAD stream input shape mismatch"
        case let .logitsShapeMismatch(framesCount, found):
            return "VAD logits shape mismatch: count=\(found), expected \(framesCount * VADONNXEngine.expectedLogitWidth)"
        case let .cacheShapeMismatch(outputName, found):
            return "VAD cache shape mismatch for \(outputName): \(found) bytes"
        case let .missingCacheOutput(name):
            return "VAD stream returned no cache: \(name)"
        case .nonFiniteLogits:
            return "VAD model returned non-finite logits"
        }
    }
}

/// `@unchecked Sendable` 必要且安全：
/// - 自身所有 `let` 字段（env / session / frameMs）都是 init-only
/// - `OnnxRuntimeBindings` 的 `ORTEnv` / `ORTSession` 没标 `Sendable`（见 ASRONNXEngine 注释），但官方保证单 session 多线程 inference thread-safe
public final class VADONNXEngine: @unchecked Sendable {
    fileprivate static let expectedFeatureDim = InferenceEngineConfig.VAD.expectedFeatureDim
    fileprivate static let expectedLogitWidth = InferenceEngineConfig.VAD.expectedLogitWidth
    private let env: ORTEnv
    private let session: ORTSession
    public let frameMs: Int  // 每帧多少 ms（funasr config: 10）

    public init(modelPath: String, useCoreML: Bool = false) throws {
        self.env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()

        if useCoreML {
            // CoreML EP 在 FSMN-VAD 上不稳定（官方 ONNX 没针对 ANE 优化，硬开容易 fallback CPU）
            do {
                let cmleOptions = ORTCoreMLExecutionProviderOptions()
                cmleOptions.useCPUOnly = false
                try options.appendCoreMLExecutionProvider(with: cmleOptions)
                Logger.shared.info("VADONNXEngine: CoreML Execution Provider successfully appended.")
            } catch {
                Logger.shared.warn("VADONNXEngine: CoreML EP not available. Falling back to CPU. Error: \(error)")
            }
        } else {
            Logger.shared.info("VADONNXEngine: Initialized with high-performance CPU provider.")
        }

        self.session = try ORTSessionInitializationGate.create(
            env: env, modelPath: modelPath, options: options
        )
        self.frameMs = 10
    }

    /// FSMN-VAD 的 cache shape：[1, 128, 19, 1]。4 个 in_cache 同形。
    /// 这是模型权重里 fsmn_block 的 lorder=20 减 1（保留 19 帧历史）。
    static let cacheShape: [NSNumber] = InferenceEngineConfig.VAD.cacheShape
    static let cacheCount = InferenceEngineConfig.VAD.cacheCount

    /// Creates one stateful FSMN VAD stream. Call consume in source-frame
    /// order; completed segments can be handed to ASR immediately while the
    /// VAD cache continues into the next chunk.
    public func makeStreamingDetector() throws -> VADStreamingDetector {
        try VADStreamingDetector(session: session, frameMs: frameMs)
    }

    /// Runs FunASR's WindowDetector / dynamic_vad endpoint rules against
    /// already-classified frames. Kept internal for deterministic parity tests.
    static func officialSegmentsFromSpeechFrames(
        _ frames: [Bool],
        frameMs: Int = 10
    ) -> [(startMs: Int, endMs: Int)] {
        var segmenter = OfficialVADEndpointSegmenter(frameMs: frameMs)
        segmenter.consume(speechFrames: frames)
        return segmenter.finish()
    }


}
/// Stateful half of FSMN-VAD. It deliberately exposes only closed endpoint
/// segments: an open trailing segment remains in the detector until a later
/// chunk closes it or finish() flushes the stream.
public final class VADStreamingDetector {
    private let session: ORTSession
    private let inputName: String
    private let cacheNames: [String]
    private let outputCacheNames: [String]
    private let logitsName: String
    private let cacheByteCount: Int
    private let frameMs: Int
    private var cacheData: [String: Data]
    private var segmenter: OfficialVADEndpointSegmenter

    fileprivate init(session: ORTSession, frameMs: Int) throws {
        self.session = session
        self.frameMs = frameMs
        let inputNames = try session.inputNames()
        let outputNames = try session.outputNames()
        guard inputNames.contains("speech") else {
            throw VADInferenceError.missingSpeechInput(inputNames: inputNames)
        }
        self.inputName = "speech"
        self.cacheNames = (0..<VADONNXEngine.cacheCount).map { "in_cache\($0)" }
            .filter(inputNames.contains)
        self.outputCacheNames = (0..<VADONNXEngine.cacheCount).map { "out_cache\($0)" }
            .filter(outputNames.contains)
        guard outputNames.contains("logits") else {
            throw VADInferenceError.missingLogitsOutput(outputNames: outputNames)
        }
        self.logitsName = "logits"
        guard cacheNames.count == VADONNXEngine.cacheCount,
              outputCacheNames.count == VADONNXEngine.cacheCount else {
            throw VADInferenceError.incompleteCacheContract
        }
        let cacheByteCount = VADONNXEngine.cacheShape.map(\.intValue).reduce(1, *) * MemoryLayout<Float>.size
        self.cacheByteCount = cacheByteCount
        self.cacheData = Dictionary(uniqueKeysWithValues: self.cacheNames.map {
            ($0, Data(count: cacheByteCount))
        })
        self.segmenter = OfficialVADEndpointSegmenter(frameMs: frameMs)
    }

    /// Consumes at most one standard 60-second VAD chunk and returns only
    /// segments that have become endpoint-final.
    public func consume(
        fbankFeatures: [Float],
        framesCount: Int
    ) throws -> [(startMs: Int, endMs: Int)] {
        let featureDim = fbankFeatures.count / max(framesCount, 1)
        guard framesCount > 0,
              featureDim == VADONNXEngine.expectedFeatureDim,
              fbankFeatures.count == framesCount * featureDim else {
            throw VADInferenceError.streamInputShapeMismatch
        }
        var chunk = fbankFeatures
        let chunkData = Data(bytes: &chunk, count: chunk.count * MemoryLayout<Float>.size)
        let speechTensor = try ORTValue(
            tensorData: NSMutableData(data: chunkData),
            elementType: .float,
            shape: [1, NSNumber(value: framesCount), NSNumber(value: featureDim)]
        )
        var inputs: [String: ORTValue] = [inputName: speechTensor]
        for cacheName in cacheNames {
            inputs[cacheName] = try ORTValue(
                tensorData: NSMutableData(data: cacheData[cacheName] ?? Data(count: cacheByteCount)),
                elementType: .float,
                shape: VADONNXEngine.cacheShape
            )
        }
        var requested = Set(outputCacheNames)
        requested.insert(logitsName)
        let outputs = try session.run(withInputs: inputs, outputNames: requested, runOptions: nil)
        guard let logitsTensor = outputs[logitsName] ?? outputs["logits"] else {
            throw VADInferenceError.streamMissingLogits
        }
        let outputData = try logitsTensor.tensorData() as Data
        let logits = outputData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard logits.count == framesCount * VADONNXEngine.expectedLogitWidth else {
            throw VADInferenceError.logitsShapeMismatch(
                framesCount: framesCount, found: logits.count
            )
        }
        try Self.validateLogits(logits, frameCount: framesCount)
        for outputCacheName in outputCacheNames {
            guard let output = outputs[outputCacheName] else {
                throw VADInferenceError.missingCacheOutput(name: outputCacheName)
            }
            let data = try output.tensorData() as Data
            guard data.count == cacheByteCount else {
                throw VADInferenceError.cacheShapeMismatch(
                    outputName: outputCacheName, found: data.count
                )
            }
            let inputCacheName = outputCacheName.replacingOccurrences(of: "out_", with: "in_")
            cacheData[inputCacheName] = data
        }
        segmenter.consume(logits: logits, frameCount: framesCount)
        return segmenter.drainClosedSegments()
    }

    static func validateLogits(_ logits: [Float], frameCount: Int) throws {
        guard logits.count == frameCount * VADONNXEngine.expectedLogitWidth else {
            throw VADInferenceError.logitsShapeMismatch(
                framesCount: frameCount, found: logits.count
            )
        }
        guard Self.allFinite(logits) else {
            throw VADInferenceError.nonFiniteLogits
        }
    }

    /// 全数组 finite check: vDSP_sve 一次性求和再判 finite。
    /// 跟 SpeakerONNXEngine 80d3360 模式同源(VAD logits 是 0-1 概率,sum 不会溢出)。
    /// 任何 NaN/Inf 输入 → sum 是 NaN/Inf → 抛错。Bit-exact 等价 `logits.allSatisfy(\.isFinite)`。
    static func allFinite(_ values: [Float]) -> Bool {
        guard !values.isEmpty else { return true }
        var sum: Float = 0
        values.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_sve(base, 1, &sum, vDSP_Length(ptr.count))
        }
        return sum.isFinite
    }

    public func finish() -> [(startMs: Int, endMs: Int)] {
        _ = segmenter.finish()
        return segmenter.drainClosedSegments()
    }
}

/// Swift port of the endpoint-relevant parts of FunASR
/// `fsmn_vad_streaming/model.py`: WindowDetector plus DetectOneFrame.
/// The ONNX model supplies frame probabilities; this type owns only temporal
/// state, so it can be tested independently of ONNX Runtime.
private struct OfficialVADEndpointSegmenter {
    private enum Change {
        case silenceToSpeech
        case speechToSilence
        case speechToSpeech
        case silenceToSilence
    }

    private let frameMs: Int
    private let windowFrames: Int
    private let speechTransitionFrames: Int
    private let silenceTransitionFrames: Int
    private let startLatencyFrames: Int
    private let maxEndSilenceFrames: Int
    private let endLookbackFrames: Int
    private let maxSegmentFrames: Int

    private var window: [Bool]
    private var windowIndex = 0
    private var windowSpeechCount = 0
    private var windowStateIsSpeech = false
    private var inSpeech = false
    private var speechStartFrame = 0
    private var continuousSilenceFrames = 0
    private var nextFrame = 0
    private var segments: [(startMs: Int, endMs: Int)] = []
    private var drainedSegmentCount = 0

    init(
        frameMs: Int,
        windowSizeMs: Int = 200,
        silenceToSpeechMs: Int = 150,
        speechToSilenceMs: Int = 150,
        lookbackStartMs: Int = 200,
        lookaheadEndMs: Int = 100,
        maxEndSilenceMs: Int = 800,
        maxSingleSegmentMs: Int = 30_000
    ) {
        self.frameMs = frameMs
        self.windowFrames = max(1, windowSizeMs / frameMs)
        self.speechTransitionFrames = max(1, silenceToSpeechMs / frameMs)
        self.silenceTransitionFrames = max(0, speechToSilenceMs / frameMs)
        self.startLatencyFrames = max(0, windowSizeMs / frameMs + lookbackStartMs / frameMs)
        self.maxEndSilenceFrames = max(1, (maxEndSilenceMs - speechToSilenceMs) / frameMs)
        self.endLookbackFrames = max(0, self.maxEndSilenceFrames - lookaheadEndMs / frameMs - 1)
        self.maxSegmentFrames = max(1, maxSingleSegmentMs / frameMs)
        self.window = [Bool](repeating: false, count: max(1, windowSizeMs / frameMs))
    }

    mutating func consume(logits: [Float], frameCount: Int) {
        guard frameCount > 0 else { return }
        // 等价 silence <= 0.25 (Float 比较,bit-exact 跟原 Double 中间一致)
        // 预分配 [Bool] 避免每次 append 的 heap 开销。
        // 原来的 `speech >= silence + 0.5` 涉及 Double 中间 (silence+0.5: Float+Double→Double),
        // 改 Float 比较后边界 0.25 处的 true/false 结果一致 (algebraic equivalent + 0.25 在 Float/Double 都 exact)。
        // FunASR 的 dynamic offline 路径对每个 VAD chunk 显式设 0.5,覆盖 config.yaml 里的 0.6。
        var frames = [Bool](repeating: false, count: frameCount)
        for frame in 0..<frameCount {
            frames[frame] = logits[frame * 248] <= 0.25
        }
        consume(speechFrames: frames)
    }

    mutating func consume(speechFrames: [Bool]) {
        for isSpeech in speechFrames {
            consume(frameIsSpeech: isSpeech, frameIndex: nextFrame)
            nextFrame += 1
        }
    }

    mutating func finish() -> [(startMs: Int, endMs: Int)] {
        if inSpeech, nextFrame > 0 {
            closeSegment(at: nextFrame - 1)
        }
        return segments
    }

    mutating func drainClosedSegments() -> [(startMs: Int, endMs: Int)] {
        guard drainedSegmentCount < segments.count else { return [] }
        let result = Array(segments[drainedSegmentCount...])
        drainedSegmentCount = segments.count
        return result
    }

    private mutating func consume(frameIsSpeech: Bool, frameIndex: Int) {
        let change = updateWindow(frameIsSpeech)
        switch change {
        case .silenceToSpeech:
            continuousSilenceFrames = 0
            if !inSpeech {
                inSpeech = true
                speechStartFrame = max(0, frameIndex - startLatencyFrames)
            }
        case .speechToSpeech:
            continuousSilenceFrames = 0
            if inSpeech, frameIndex - speechStartFrame + 1 > maxSegmentFrames {
                closeSegment(at: frameIndex)
            }
        case .speechToSilence:
            continuousSilenceFrames = 0
            if inSpeech, frameIndex - speechStartFrame + 1 > maxSegmentFrames {
                closeSegment(at: frameIndex)
            }
        case .silenceToSilence:
            guard inSpeech else { return }
            continuousSilenceFrames += 1
            if continuousSilenceFrames >= maxEndSilenceFrames {
                closeSegment(at: max(speechStartFrame, frameIndex - endLookbackFrames))
            } else if frameIndex - speechStartFrame + 1 > maxSegmentFrames {
                closeSegment(at: frameIndex)
            }
        }
    }

    private mutating func updateWindow(_ frameIsSpeech: Bool) -> Change {
        if window[windowIndex] {
            windowSpeechCount -= 1
        }
        window[windowIndex] = frameIsSpeech
        if frameIsSpeech {
            windowSpeechCount += 1
        }
        windowIndex = (windowIndex + 1) % windowFrames

        if !windowStateIsSpeech, windowSpeechCount >= speechTransitionFrames {
            windowStateIsSpeech = true
            return .silenceToSpeech
        }
        if windowStateIsSpeech, windowSpeechCount <= silenceTransitionFrames {
            windowStateIsSpeech = false
            return .speechToSilence
        }
        return windowStateIsSpeech ? .speechToSpeech : .silenceToSilence
    }

    private mutating func closeSegment(at endFrame: Int) {
        let startMs = speechStartFrame * frameMs
        let endMs = max(startMs + frameMs, (endFrame + 1) * frameMs)
        segments.append((startMs, endMs))
        inSpeech = false
        continuousSilenceFrames = 0
        window = [Bool](repeating: false, count: windowFrames)
        windowIndex = 0
        windowSpeechCount = 0
        windowStateIsSpeech = false
    }
}
