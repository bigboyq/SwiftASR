import Foundation
import Accelerate
import OnnxRuntimeBindings

public enum ASRExecutionProvider: Sendable {
    case cpu
    case coreML
    case xnnpack(intraOpThreads: Int)
}

/// Caller-facing inference errors from `ASRONNXEngine`. Distinct cases
/// so `switch` at the call site (e.g. `ASRInferencePool`, decoder path)
/// can react to specific conditions — input shape vs. missing tensor
/// vs. empty logits vs. SeACo hotword embedding issues. Replaces the
/// pre-existing `NSError(domain: "ASRONNXEngine", code: -N, ...)`
/// template (round-1 F2.4 只覆盖了 5 处主类，round-3 M2-N1 把 4 个
/// engine init / run 路径也补完)。
public enum ASRInferenceError: Error, LocalizedError, Sendable {
    case shapeMismatch
    case missingLogits
    case emptyLogits
    case missingHotwordEmbedding
    case missingHotwordEmbeddingModel(path: String)
    case invalidHotwordEmbeddingShape(valueCount: Int)
    case invalidBiasEmbeddingShape
    /// `init` 参数校验：cpuIntraOpThreads 必须 > 0
    ///
    /// **MIGRATION NOTE (round-3 M2-N1)**：原 NSError 文本是
    /// `"cpuIntraOpThreads must be positive"`。enum 改用 `(got \(value))`
    /// 后缀把传入值拼到 errorDescription，比原 NSError 信息更丰富（调试时
    /// 能直接看到传错了什么值），但**文本格式跟原 NSError 不等价**。
    /// 如果未来 log 聚合 / crash report 依赖原 NSError 文本做 pattern 匹配，
    /// 会被破坏。`EnumMigrationGoldenTextTests` 钉死这个行为。
    case invalidCPUThreadCount(value: Int)
    /// `init` 参数校验：XNNPACK intra-op threads 必须 > 0
    ///
    /// **MIGRATION NOTE (round-3 M2-N1)**：原 NSError 文本是
    /// `"XNNPACK intra-op thread count must be positive"`。跟
    /// `invalidCPUThreadCount` 同模式 — `errorDescription` 加 `(got \(value))`
    /// 后缀，跟原 NSError 文本不等价。详见 `invalidCPUThreadCount` 注释。
    case invalidXNNPackThreadCount(value: Int)
    /// 模型输入契约不符（缺 "speech" / "speech_lengths"）
    case invalidInputContract(found: [String])
    /// 模型输出契约不符（缺 "logits" / "token_num"）
    case invalidOutputContract(found: [String])
    /// runSession 输出 byte 数 ≠ count * 4
    case invalidOutputByteCount(label: String, found: Int)
    /// runSession 输出 byte 数不是 Int32 / Int64 大小
    case invalidTokenNumByteCount(found: Int)
    /// runSession 输出含 NaN / ±Inf
    case nonFiniteLogits(label: String)

    public var errorDescription: String? {
        switch self {
        case .shapeMismatch:
            return "ASR shape mismatch"
        case .missingLogits:
            return "No output"
        case .emptyLogits:
            return "ASR logits output is empty"
        case .missingHotwordEmbedding:
            return "SeACo embedding output hw_embed is missing"
        case let .missingHotwordEmbeddingModel(path):
            return "Missing SeACo embedding model: \(path)"
        case let .invalidHotwordEmbeddingShape(valueCount):
            return "SeACo embedding shape is invalid: \(valueCount) values"
        case .invalidBiasEmbeddingShape:
            return "ASR bias embedding shape mismatch"
        case let .invalidCPUThreadCount(value):
            return "cpuIntraOpThreads must be positive (got \(value))"
        case let .invalidXNNPackThreadCount(value):
            return "XNNPACK intra-op thread count must be positive (got \(value))"
        case let .invalidInputContract(found):
            return "ASR model input contract is invalid: \(found)"
        case let .invalidOutputContract(found):
            return "ASR model output contract is invalid: \(found)"
        case let .invalidOutputByteCount(label, found):
            return "ASR \(label) output has invalid byte count: \(found)"
        case let .invalidTokenNumByteCount(found):
            return "ASR token_num output has invalid byte count: \(found)"
        case let .nonFiniteLogits(label):
            return "ASR \(label) output contains non-finite values"
        }
    }
}

struct ASRInferenceOutput: Sendable {
    let logits: [Float]
    let usCifPeak: [Float]
    let usAlphas: [Float]
    let tokenNum: Int
    let inputPreparationSeconds: TimeInterval
    let sessionRunSeconds: TimeInterval
    let outputMaterializationSeconds: TimeInterval
}

/// `@unchecked Sendable` 必要且安全：
/// - 自身 `let` 字段（env / session / hasBiasEmbed / biasDim / noBiasEmbedding / executionRoute）都是 init-only，构造后不可变
/// - `var vocabulary` 只在 `init` 末尾的 `loadVocabulary` 里写一次，构造后只读
///   （写入路径收敛在 init 内，并发读不冲突）
/// - `OnnxRuntimeBindings` 的 `ORTEnv` / `ORTSession` 没标 `Sendable`，但官方文档承诺
///   单 session 多线程 inference 是 thread-safe 的（内部用 pthread_mutex），所以并发
///   调 `transcribe` 安全
/// 不能直接改 `Sendable` — 编译器会因为 ORTSession 字段报 `stored property ... has
/// non-Sendable type` 错误（实测 PuncONNXEngine 去掉 @unchecked 就炸）。
public final class ASRONNXEngine: @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession

    // SeACo 多出来的输入 (热词嵌入)
    private let hasBiasEmbed: Bool
    private let biasDim: Int
    private let noBiasEmbedding: [Float]
    private let executionRoute: String
    private let requestedOutputNames: Set<String>

    private static let noBiasToken: Int32 = InferenceEngineConfig.ASR.noBiasToken
    private static let hotwordTokenLimit = InferenceEngineConfig.ASR.hotwordTokenLimit

    public init(
        modelPath: String,
        useCoreML: Bool = true,
        cpuIntraOpThreads: Int? = nil,
        executionProvider: ASRExecutionProvider? = nil
    ) throws {
        self.env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()

        if let cpuIntraOpThreads {
            guard cpuIntraOpThreads > 0 else {
                throw ASRInferenceError.invalidCPUThreadCount(value: cpuIntraOpThreads)
            }
            try options.setIntraOpNumThreads(Int32(cpuIntraOpThreads))
        }

        let selectedProvider = executionProvider ?? (useCoreML ? .coreML : .cpu)
        let route: String
        switch selectedProvider {
        case .cpu:
            route = "CPU"
        case .coreML:
            do {
                let cmleOptions = ORTCoreMLExecutionProviderOptions()
                cmleOptions.useCPUOnly = false
                try options.appendCoreMLExecutionProvider(with: cmleOptions)
                route = "CoreML EP"
            } catch {
                Logger.shared.warn("ASRONNXEngine: CoreML EP not available, fallback CPU: \(error)")
                route = "CPU (CoreML unavailable)"
            }
        case let .xnnpack(intraOpThreads):
            guard intraOpThreads > 0 else {
                throw ASRInferenceError.invalidXNNPackThreadCount(value: intraOpThreads)
            }
            let xnnpackOptions = ORTXnnpackExecutionProviderOptions()
            xnnpackOptions.intra_op_num_threads = Int32(intraOpThreads)
            try options.appendXnnpackExecutionProvider(with: xnnpackOptions)
            try options.addConfigEntry(
                withKey: "session.intra_op.allow_spinning",
                value: "0"
            )
            route = "XNNPACK EP (\(intraOpThreads) threads)"
        }

        self.session = try ORTSessionInitializationGate.create(
            env: env, modelPath: modelPath, options: options
        )
        self.executionRoute = route
        let inputNames = try session.inputNames()
        guard inputNames.contains("speech"), inputNames.contains("speech_lengths") else {
            throw ASRInferenceError.invalidInputContract(found: inputNames)
        }
        let outputNames = try session.outputNames()
        guard outputNames.contains("logits"), outputNames.contains("token_num") else {
            throw ASRInferenceError.invalidOutputContract(found: outputNames)
        }
        // 探测 bias_embed 是否存在（SeACo 才有，Paraformer 没有）
        self.hasBiasEmbed = inputNames.contains("bias_embed")
        self.biasDim = 512  // SeACo hardcode
        self.requestedOutputNames = Set(outputNames)
        if hasBiasEmbed {
            let dir = URL(fileURLWithPath: modelPath).deletingLastPathComponent()
            let embeddingPath = dir.appendingPathComponent("model_eb_quant.onnx").path
            self.noBiasEmbedding = try Self.loadNoBiasEmbedding(
                env: env,
                modelPath: embeddingPath,
                biasDim: biasDim
            )
        } else {
            self.noBiasEmbedding = []
        }
        Logger.shared.info("ASRONNXEngine 就绪: route=\(executionRoute), bias=\(hasBiasEmbed)")
    }

    /// SeACo / Paraformer model inference. Decoding is deliberately outside
    /// this type so the ONNX session has one responsibility: produce raw model
    /// evidence for the decoder.
    /// - Parameters:
    ///   - fbankFeatures: LFR(m=7, n=6) + CMVN 后的 560 维特征，shape = [1, T, 560]
    ///   - seqLen: T
    ///   - biasEmbeddings: 可选，SeACo 上下文 bias（不传 = 退化成普通 Paraformer 行为）
    /// - Returns: raw logits and CIF evidence; no labels or sentences yet.
    func infer(
        fbankFeatures: [Float],
        seqLen: Int,
        biasEmbeddings: [Float]? = nil
    ) throws -> ASRInferenceOutput {
        let prep = try prepareASRInputs(
            fbankFeatures: fbankFeatures,
            seqLen: seqLen,
            biasEmbeddings: biasEmbeddings
        )
        let runStart = Date()
        let outputs: [String: ORTValue] = try session.run(
            withInputs: prep.inputs,
            outputNames: requestedOutputNames,
            runOptions: nil
        )
        let sessionRunSeconds = Date().timeIntervalSince(runStart)
        let mat = try materializeASROutputs(outputs)
        return ASRInferenceOutput(
            logits: mat.logits,
            usCifPeak: mat.usCifPeak,
            usAlphas: mat.usAlphas,
            tokenNum: mat.tokenNum,
            inputPreparationSeconds: prep.elapsedSeconds,
            sessionRunSeconds: sessionRunSeconds,
            outputMaterializationSeconds: mat.elapsedSeconds
        )
    }

    /// Phase 1 of `infer`: build the ORT input dict. Validates shapes,
    /// packages fbank / lengths / optional SeACo bias_embed into ORTValue
    /// tensors. Caller feeds the returned dict into `session.run`.
    private func prepareASRInputs(
        fbankFeatures: [Float],
        seqLen: Int,
        biasEmbeddings: [Float]?
    ) throws -> (inputs: [String: ORTValue], elapsedSeconds: Double) {
        let featureDim = 560
        guard fbankFeatures.count == seqLen * featureDim, seqLen > 0 else {
            throw ASRInferenceError.shapeMismatch
        }
        let start = Date()
        var mutableFeatures = fbankFeatures
        let featuresData = Data(bytes: &mutableFeatures, count: mutableFeatures.count * MemoryLayout<Float>.size)
        let speechTensor = try ORTValue(
            tensorData: NSMutableData(data: featuresData),
            elementType: .float,
            shape: [1, NSNumber(value: seqLen), NSNumber(value: featureDim)]
        )

        var lengths: [Int32] = [Int32(seqLen)]
        let lengthsData = Data(bytes: &lengths, count: lengths.count * MemoryLayout<Int32>.size)
        let lengthsTensor = try ORTValue(
            tensorData: NSMutableData(data: lengthsData),
            elementType: .int32,
            shape: [1]
        )

        var inputDict: [String: ORTValue] = ["speech": speechTensor, "speech_lengths": lengthsTensor]

        // SeACo 的 bias_embed：缺省时必须传 model_eb_quant 对 NO_BIAS=8377
        // 的 LSTM embedding。全零向量并不等价，会改变 SeACo decoder 的分支选择。
        let bias: [Float]
        if let provided = biasEmbeddings, !provided.isEmpty {
            bias = provided
        } else {
            bias = noBiasEmbedding
        }
        if hasBiasEmbed {
            guard !bias.isEmpty, bias.count.isMultiple(of: biasDim) else {
                throw ASRInferenceError.invalidBiasEmbeddingShape
            }
            let numHot = bias.count / max(biasDim, 1)
            var biasData = bias
            let biasDataBytes = bias.isEmpty
                ? Data()
                : Data(bytes: &biasData, count: biasData.count * MemoryLayout<Float>.size)
            let biasTensor = try ORTValue(
                tensorData: NSMutableData(data: biasDataBytes),
                elementType: .float,
                shape: [1, NSNumber(value: numHot), NSNumber(value: biasDim)]
            )
            inputDict["bias_embed"] = biasTensor
        }
        return (inputDict, Date().timeIntervalSince(start))
    }

    /// Phase 3 of `infer`: pull the four named output tensors out of the
    /// session's output dict and decode them into Swift arrays. logits is
    /// required; the three SeACo / Paraformer timestamp / count outputs
    /// are optional and default to empty / zero when absent.
    private func materializeASROutputs(
        _ outputs: [String: ORTValue]
    ) throws -> (logits: [Float], usCifPeak: [Float], usAlphas: [Float], tokenNum: Int, elapsedSeconds: Double) {
        let start = Date()
        guard let logitsTensor = outputs["logits"] else {
            throw ASRInferenceError.missingLogits
        }
        let logitsData = try logitsTensor.tensorData() as Data
        let logits = try Self.decodeFloatArray(logitsData, label: "logits")
        guard !logits.isEmpty else {
            throw ASRInferenceError.emptyLogits
        }

        // 找 us_cif_peak / us_alphas（SeACo 时间戳）和 token_num
        var usCifPeak: [Float] = []
        if let t = outputs["us_cif_peak"] {
            let d = try t.tensorData() as Data
            usCifPeak = try Self.decodeFloatArray(d, label: "us_cif_peak")
        }
        var usAlphas: [Float] = []
        if let t = outputs["us_alphas"] {
            let d = try t.tensorData() as Data
            usAlphas = try Self.decodeFloatArray(d, label: "us_alphas")
        }
        var tokenNum: Int = 0
        if let t = outputs["token_num"] {
            let d = try t.tensorData() as Data
            tokenNum = try Self.decodeScalarInt(d)
        }
        return (logits, usCifPeak, usAlphas, tokenNum, Date().timeIntervalSince(start))
    }

    static func noBiasHotwordTokens() -> [Int32] {
        [noBiasToken] + [Int32](repeating: 0, count: hotwordTokenLimit - 1)
    }

    private static func loadNoBiasEmbedding(
        env: ORTEnv,
        modelPath: String,
        biasDim: Int
    ) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ASRInferenceError.missingHotwordEmbeddingModel(path: modelPath)
        }

        let options = try ORTSessionOptions()
        let embeddingSession = try ORTSessionInitializationGate.create(
            env: env, modelPath: modelPath, options: options
        )
        var tokens = noBiasHotwordTokens()
        let tokenData = Data(bytes: &tokens, count: tokens.count * MemoryLayout<Int32>.size)
        let hotword = try ORTValue(
            tensorData: NSMutableData(data: tokenData),
            elementType: .int32,
            shape: [1, NSNumber(value: hotwordTokenLimit)]
        )
        let outputs = try embeddingSession.run(
            withInputs: ["hotword": hotword],
            outputNames: ["hw_embed"],
            runOptions: nil
        )
        guard let output = outputs["hw_embed"] else {
            throw ASRInferenceError.missingHotwordEmbedding
        }
        let data = try output.tensorData() as Data
        let values = try decodeFloatArray(data, label: "hw_embed")
        guard values.count == Self.hotwordTokenLimit * biasDim else {
            throw ASRInferenceError.invalidHotwordEmbeddingShape(valueCount: values.count)
        }

        // model_eb returns [token_position, hotword, 512]. NO_BIAS contains exactly
        // one real token, so its sequence representation is position zero.
        return Array(values.prefix(biasDim))
    }

    static func decodeFloatArray(_ data: Data, label: String) throws -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard data.count == count * MemoryLayout<Float>.size else {
            throw ASRInferenceError.invalidOutputByteCount(label: label, found: data.count)
        }
        guard count > 0 else { return [] }
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var sum: Float = 0
        vDSP_sve(values, 1, &sum, vDSP_Length(count))
        guard sum.isFinite else {
            throw ASRInferenceError.nonFiniteLogits(label: label)
        }
        return values
    }

    private static func decodeScalarInt(_ data: Data) throws -> Int {
        guard data.count == MemoryLayout<Int32>.size || data.count == MemoryLayout<Int64>.size else {
            throw ASRInferenceError.invalidTokenNumByteCount(found: data.count)
        }
        return data.withUnsafeBytes { raw in
            if raw.count == MemoryLayout<Int64>.size {
                return Int(raw.load(as: Int64.self))
            }
            return Int(raw.load(as: Int32.self))
        }
    }

}
