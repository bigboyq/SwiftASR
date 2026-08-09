import Foundation
import CoreML
import Accelerate

/// Caller-facing inference errors from `SpeakerNativeCoreMLEngine`. Distinct
/// cases so the call site (e.g. `AudioPipeline+SpeakerEmbeddings`) can react
/// to specific conditions — model file missing vs. contract violation vs.
/// non-finite embedding. Replaces the pre-existing
/// `NSError(domain: "SpeakerNativeCoreMLEngine", code: -N, ...)` template
/// (round-3 M2-N1).
public enum SpeakerCoreMLError: Error, LocalizedError, Sendable {
    /// 初始化时模型路径不存在
    case modelPathMissing(path: String)
    /// fbank seqLen 不等于模型期望的固定 148 帧
    case invalidSeqLen(expected: Int, found: Int)
    /// fbank 元素总数不等于 expectedSeqLen * expectedInputDim
    case invalidFeatureSize(found: Int, expected: Int)
    /// runBatch 入参 count 不等于 engine.inferenceBatchSize（内部一致性）
    case invalidBatchSize(expected: Int, found: Int)
    /// 推理输出缺 `embs` feature
    case missingEmbsOutput
    /// embs flatten 出来元素数不等于 batchSize * embeddingDim
    case invalidEmbeddingCount(found: Int, expected: Int)
    /// embedding 含 NaN / ±Inf
    case nonFiniteEmbedding

    public var errorDescription: String? {
        switch self {
        case let .modelPathMissing(path):
            return "Speaker model path does not exist: \(path)"
        case let .invalidSeqLen(expected, found):
            return "Speaker model requires exactly \(expected) frames; got \(found)"
        case let .invalidFeatureSize(found, expected):
            return "Speaker feature size mismatch: got \(found); expected \(expected)"
        case let .invalidBatchSize(expected, found):
            return "Expected \(expected) inputs, got \(found)"
        case .missingEmbsOutput:
            return "Speaker model returned no embs output"
        case let .invalidEmbeddingCount(found, expected):
            return "Speaker model returned \(found) values; expected \(expected)"
        case .nonFiniteEmbedding:
            return "Speaker model returned a non-finite embedding"
        }
    }
}

/// Apple 原生 CoreML 声纹识别引擎 (.mlmodelc)。
///
/// 零分配推断路径：
/// - `rawInputPointer`：预分配 64 字节对齐 C 缓冲区，同时作为 `MLMultiArray` 的 backing store
///   与每次 batch 的 scratchpad，彻底跳过 `flatMap` 的 752 KB 中间堆分配。
/// - 每个窗口的 fbank 数据直接按 stride 偏移写入 `rawInputPointer`，无额外拷贝。
/// - `SpeakerInputProvider`：复用单例 `MLFeatureProvider`，不产生 ObjC 堆包装对象。
///
/// `computeUnits` 默认 `.cpuAndGPU`（R4-P2-5：修正文档，原 doc 误写 `.all`）。
/// 选择 `.cpuAndGPU` 是 benchmark 后的结果：ERes2NetV2 speaker 模型在当前
/// 输入 shape 下，`.all` 会让 CoreML 路由到 ANE 但伴随额外的 CPU↔ANE 张量
/// 拷贝，实测反而更慢；`.cpuAndGPU` 在本机稳定且更快。如需做 ANE 性能实验，
/// 可在 init 中覆盖（如 `.cpuOnly`、`.cpuAndNeuralEngine`）。改变默认值必须
/// 先跨设备 benchmark，因为 ANE 路由对 shape 敏感。
public final class SpeakerNativeCoreMLEngine: @unchecked Sendable {
    public static let preferredBatchSize = InferenceEngineConfig.Speaker.preferredBatchSize

    private let model: MLModel
    private let rawInputPointer: UnsafeMutableRawPointer
    private let inputMultiArray: MLMultiArray
    private let inputProvider: SpeakerInputProvider
    private let predictionOptions: MLPredictionOptions
    private let expectedInputDim = 80
    private let seqLenConstraint = 148
    private let embeddingDim = 192
    private let inferenceBatchSize: Int
    /// Serializes access to `rawInputPointer` / `inputMultiArray`, which are a
    /// single preallocated backing buffer shared across all batches. The engine
    /// is `@unchecked Sendable`: production callers route through the
    /// `AudioPipeline` actor (single-writer), but the lock makes that contract
    /// explicit so a future concurrent caller cannot corrupt the buffer.
    private let inferenceLock = NSLock()

    /// 当前模型要求的固定 batch 大小。
    public var batchSize: Int { inferenceBatchSize }

    public init(
        modelPath: String,
        inferenceBatchSize: Int = 16,
        computeUnits: MLComputeUnits = .cpuAndGPU
    ) throws {
        let modelURL: URL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDir) {
            modelURL = URL(fileURLWithPath: modelPath)
        } else {
            throw SpeakerCoreMLError.modelPathMissing(path: modelPath)
        }

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.inferenceBatchSize = max(1, inferenceBatchSize)

        let elementCount = self.inferenceBatchSize * seqLenConstraint * expectedInputDim
        let byteCount = elementCount * MemoryLayout<Float>.size
        // 64 字节对齐，同时作为 MLMultiArray backing store 与 per-batch scratchpad。
        // 每个窗口按 windowStride 直接写入此缓冲区，消除 flatMap 的中间堆分配。
        self.rawInputPointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        self.rawInputPointer.initializeMemory(as: Float.self, repeating: 0, count: elementCount)

        // 将 rawInputPointer 的所有权移交给 MLMultiArray 的 deallocator 回调。
        // MLMultiArray 释放时会在自身清理完成后调用 deallocator，确保先释放
        // 内部引用再 free 内存，消除 deinit 里先 deallocate 后 ARC 释放
        // MLMultiArray 时的 use-after-free (SIGSEGV)。
        self.inputMultiArray = try MLMultiArray(
            dataPointer: rawInputPointer,
            shape: [
                NSNumber(value: self.inferenceBatchSize),
                NSNumber(value: seqLenConstraint),
                NSNumber(value: expectedInputDim)
            ],
            dataType: .float32,
            strides: [
                NSNumber(value: seqLenConstraint * expectedInputDim),
                NSNumber(value: expectedInputDim),
                NSNumber(value: 1)
            ],
            deallocator: { ptr in ptr.deallocate() }
        )

        self.inputProvider = SpeakerInputProvider(inputMultiArray: inputMultiArray)
        self.predictionOptions = MLPredictionOptions()
        let unitName: String
        switch computeUnits {
        case .all:                  unitName = "all (ANE+GPU+CPU)"
        case .cpuOnly:              unitName = "cpuOnly"
        case .cpuAndGPU:            unitName = "cpuAndGPU"
        case .cpuAndNeuralEngine:   unitName = "cpuAndNeuralEngine"
        @unknown default:           unitName = "unknown"
        }
        Logger.shared.info("SpeakerNativeCoreMLEngine 就绪: CoreML原生引擎 batch=\(self.inferenceBatchSize) computeUnits=\(unitName)")
    }

    // rawInputPointer 的内存由 MLMultiArray deallocator 负责释放，无需 deinit。

    /// 提取多个声纹 embedding，自动按 `inferenceBatchSize` 分批推进。
    public func extractEmbeddings(
        fbankFeatures: [[Float]],
        seqLen: Int,
        checkCancellation: () throws -> Void = {}
    ) throws -> [[Float]] {
        return try extractEmbeddings(
            fbankFeatures: fbankFeatures,
            seqLen: seqLen,
            checkCancellation: checkCancellation,
            onProgress: nil
        )
    }

    /// 提取多个声纹 embedding，每完成一个 batch 调一次 onProgress。
    /// `onProgress` 传入 (0, 1] 范围 fraction, 总数, 已完成数。
    /// 调用方可以按 fraction × (自己的 stage 占比) 报 UI。
    public func extractEmbeddings(
        fbankFeatures: [[Float]],
        seqLen: Int,
        checkCancellation: () throws -> Void = {},
        onProgress: ((_ fraction: Double, _ completed: Int, _ total: Int) -> Void)?
    ) throws -> [[Float]] {
        guard !fbankFeatures.isEmpty else { return [] }
        try Self.validateFeatureContract(
            fbankFeatures,
            seqLen: seqLen,
            expectedSeqLen: seqLenConstraint,
            expectedInputDim: expectedInputDim
        )

        let total = fbankFeatures.count
        var results: [[Float]] = []
        results.reserveCapacity(total)
        var completed = 0
        for start in stride(from: 0, to: total, by: inferenceBatchSize) {
            try checkCancellation()
            let end = min(start + inferenceBatchSize, total)
            let valid = Array(fbankFeatures[start..<end])
            var padded = valid
            if let last = valid.last, padded.count < inferenceBatchSize {
                padded.append(contentsOf: repeatElement(last, count: inferenceBatchSize - padded.count))
            }
            let embeddings = try runBatch(padded, seqLen: seqLen)
            results.append(contentsOf: embeddings.prefix(valid.count))
            completed = end
            onProgress?(Double(completed) / Double(total), completed, total)
        }
        return results
    }

    /// Validates the fixed-shape speaker model contract before touching the
    /// preallocated CoreML backing buffer. Keeping this check at the engine
    /// boundary prevents callers from changing the memcpy stride and writing
    /// beyond the `[batch, 148, 80]` allocation.
    static func validateFeatureContract(
        _ features: [[Float]],
        seqLen: Int,
        expectedSeqLen: Int = 148,
        expectedInputDim: Int = 80
    ) throws {
        guard seqLen == expectedSeqLen else {
            throw SpeakerCoreMLError.invalidSeqLen(expected: expectedSeqLen, found: seqLen)
        }
        guard features.allSatisfy({ $0.count == expectedSeqLen * expectedInputDim }) else {
            let actual = features.first(where: { $0.count != expectedSeqLen * expectedInputDim })?.count
                ?? features.first?.count
                ?? 0
            throw SpeakerCoreMLError.invalidFeatureSize(
                found: actual,
                expected: expectedSeqLen * expectedInputDim
            )
        }
    }

    private func runBatch(_ features: [[Float]], seqLen: Int) throws -> [[Float]] {
        guard features.count == inferenceBatchSize else {
            throw SpeakerCoreMLError.invalidBatchSize(
                expected: inferenceBatchSize, found: features.count
            )
        }

        // The memcpy into rawInputPointer and the model prediction both touch
        // the shared backing buffer. Hold the lock for the whole batch so
        // concurrent extractEmbeddings calls cannot overwrite each other's input.
        inferenceLock.lock()
        defer { inferenceLock.unlock() }

        // 路线 C：零堆分配写入。每个窗口按 windowStride 直接 memcpy 到 rawInputPointer
        // 对应偏移，rawInputPointer 本身就是 MLMultiArray 的 backing store，无需中间 buffer。
        // 替代原来 flatMap { $0 } 产生的每 batch 752 KB 临时堆分配。
        let windowStride = seqLen * expectedInputDim
        for (i, window) in features.enumerated() {
            window.withUnsafeBufferPointer { src in
                let targetPtr = rawInputPointer.advanced(by: i * windowStride * MemoryLayout<Float>.stride)
                targetPtr.copyMemory(from: src.baseAddress!, byteCount: windowStride * MemoryLayout<Float>.stride)
            }
        }

        let output = try model.prediction(from: inputProvider, options: predictionOptions)
        guard let embsFeature = output.featureValue(for: "embs")?.multiArrayValue else {
            throw SpeakerCoreMLError.missingEmbsOutput
        }

        let flat: [Float]
        if embsFeature.dataType == .float16 {
            flat = embsFeature.withUnsafeBytes { ptr in
                let fp16Ptr = ptr.bindMemory(to: Float16.self)
                return fp16Ptr.map { Float($0) }
            }
        } else {
            flat = embsFeature.withUnsafeBytes { ptr in
                Array(ptr.bindMemory(to: Float.self))
            }
        }

        guard flat.count == inferenceBatchSize * embeddingDim else {
            throw SpeakerCoreMLError.invalidEmbeddingCount(
                found: flat.count, expected: inferenceBatchSize * embeddingDim
            )
        }

        return try Self.validatedEmbeddings(
            flat: flat,
            batchSize: inferenceBatchSize,
            embeddingDim: embeddingDim
        )
    }

    static func validatedEmbeddings(
        flat: [Float],
        batchSize: Int,
        embeddingDim: Int
    ) throws -> [[Float]] {
        var sum: Float = 0
        vDSP_sve(flat, 1, &sum, vDSP_Length(flat.count))
        guard sum.isFinite else {
            throw SpeakerCoreMLError.nonFiniteEmbedding
        }
        return (0..<batchSize).map { index in
            Array(flat[(index * embeddingDim)..<((index + 1) * embeddingDim)])
        }
    }
}

private final class SpeakerInputProvider: NSObject, MLFeatureProvider {
    let featureNames: Set<String> = ["speech"]
    let inputMultiArray: MLMultiArray

    init(inputMultiArray: MLMultiArray) {
        self.inputMultiArray = inputMultiArray
        super.init()
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "speech" {
            return MLFeatureValue(multiArray: inputMultiArray)
        }
        return nil
    }
}
