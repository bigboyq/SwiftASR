import Foundation
import Accelerate

// ⚠️ EXPERIMENTAL PARITY UTILITY — NOT PART OF THE SwiftASR APP TARGET
//
// This file holds two vDSP/Accelerate operators recovered from the
// abandoned ANE full-pipeline study (2026-07-24, see AGENTS.md § 1):
//
//   1. `CIFPredictor` (vDSP port of SeACo-Paraformer CifPredictorV3)
//   2. `LayerNormAfterNorm` (vDSP port of the encoder's after_norm)
//
// This file is compiled only by the `CIFExperiments` SwiftPM target,
// which is depended on by tests but not by the `SwiftASR` executable.
// Production ASR runs on the 2-worker ONNX CPU path; the CoreML
// `cif_predictor.mlmodelc` was never used after the ANE attempt failed
// (E5RT "Invalid blob shape" on the data-dependent `[1, T, 512]`
// output).  These two vDSP ports are kept as independent utilities
// for future hybrid schemes, debugging, and `PipelineExecutionProfileTests`
// parity comparison — not for the hot path.
//
// DO NOT wire these into the production AudioPipeline ASR stage without
// re-benchmarking the full pipeline and confirming the operator budgets
// (the previous ANE attempt showed 4-encoder + 2-decoder subgraph IO
// costs dominated the ~1-3 ms ANE compute savings — net regression).

/// Errors raised by `CIFPredictorWeights.loadDefault` and its
/// `loadAfterNorm` helper. Replaces 2 `NSError(domain: "CIFPredictorWeights",
/// code: -N, ...)` templates at the weight load boundary.
public enum CIFPredictorWeightsError: Error, LocalizedError, Sendable {
    case cifWeightsSizeMismatch(gotFloats: Int, expectedFloats: Int)
    case afterNormNpzTooSmall

    public var errorDescription: String? {
        switch self {
        case let .cifWeightsSizeMismatch(got, expected):
            return "cif_weights.bin size mismatch: got \(got) floats, expected \(expected)"
        case .afterNormNpzTooSmall:
            return "after_norm npz too small"
        }
    }
}

/// SeACo-Paraformer CifPredictorV3 在 Apple Silicon 上的 vDSP/Accelerate 原生实现。
///
/// 职责：
/// 1. 从 Encoder 输出 `[1, T, 512]` 计算 CIF alpha 权重
///    - `Conv1d(512→512, kernel=3)` 提取上下文 + ReLU
///    - `Linear(512→1)` + `sigmoid` + `relu(alphas * smooth_factor - noise_threshold)` 投影成 alpha
/// 2. CIF 积分发射 (Continuous Integrate-and-Fire)
///    - 沿时间累加 alpha，累计 ≥ `threshold` (1.0) 时触发一次声学 embedding 发射
/// 3. 输出固定 `targetTokens` 个 acoustic embeddings `[1, N, 512]`
///
/// 设计动机：
/// - CoreML `cif_predictor.mlmodelc` 因为 `[1, ?, 512]` 输出有 data-dependent shape，
///   触发 E5RT 报 `Espresso exception: "Invalid blob shape"`，在 ANE 上无法运行。
/// - 用 vDSP 重新实现，单 batch 5.0s 窗口 (T=500) 全部算下来 < 5ms。
/// - 用 `target_label_length = N` 缩放 alpha，让 N 个 token 固定，方便 Decoder 静态 N=50 输入。
public struct CIFPredictorWeights: Sendable {
    public let conv1dWeight: [Float]   // [out=512, in=512, k=3] = 786432 floats
    public let conv1dBias: [Float]     // [512]
    public let linearWeight: [Float]   // [1, 512]
    public let linearBias: [Float]     // [1]
    public let threshold: Float
    public let smoothFactor: Float
    public let noiseThreshold: Float

    /// Encoder 后的 LayerNorm (`full.encoder.after_norm`) 权重
    /// 形状 (512,)，由 export 后的 .mlmodelc 不包含，必须在 Swift 端手动应用
    public let afterNormWeight: [Float]   // [512]
    public let afterNormBias: [Float]     // [512]
    public let afterNormEps: Float

    public init(
        conv1dWeight: [Float],
        conv1dBias: [Float],
        linearWeight: [Float],
        linearBias: [Float],
        afterNormWeight: [Float],
        afterNormBias: [Float],
        afterNormEps: Float = 1e-12,
        threshold: Float = 1.0,
        smoothFactor: Float = 1.0,
        noiseThreshold: Float = 0.0
    ) {
        self.conv1dWeight = conv1dWeight
        self.conv1dBias = conv1dBias
        self.linearWeight = linearWeight
        self.linearBias = linearBias
        self.afterNormWeight = afterNormWeight
        self.afterNormBias = afterNormBias
        self.afterNormEps = afterNormEps
        self.threshold = threshold
        self.smoothFactor = smoothFactor
        self.noiseThreshold = noiseThreshold
    }

    /// 从 `cif_predictor_v1.bin` + 同目录 `encoder_after_norm.npz` 加载 CIF 权重。
    /// 路径由调用方传入,通常指向 `<repo>/Resources/cif_weights/` 下的两个文件。
    public static func loadDefault(path: String) throws -> CIFPredictorWeights {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let expectedSize = 786432 + 512 + 512 + 1
        let floatCount = data.count / MemoryLayout<Float>.size
        guard floatCount == expectedSize else {
            throw CIFPredictorWeightsError.cifWeightsSizeMismatch(
                gotFloats: floatCount,
                expectedFloats: expectedSize
            )
        }
        let ptr = data.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: Float.self) }
        var offset = 0
        let convW = Array(UnsafeBufferPointer(start: ptr.advanced(by: offset), count: 786432))
        offset += 786432
        let convB = Array(UnsafeBufferPointer(start: ptr.advanced(by: offset), count: 512))
        offset += 512
        let linW = Array(UnsafeBufferPointer(start: ptr.advanced(by: offset), count: 512))
        offset += 512
        let linB = Array(UnsafeBufferPointer(start: ptr.advanced(by: offset), count: 1))

        // 加载 after_norm 权重 (.npz 文件)
        let afterNormPath = (path as NSString).deletingLastPathComponent + "/encoder_after_norm.npz"
        let (afterW, afterB, afterEps) = try loadAfterNorm(path: afterNormPath)

        return CIFPredictorWeights(
            conv1dWeight: convW,
            conv1dBias: convB,
            linearWeight: linW,
            linearBias: linB,
            afterNormWeight: afterW,
            afterNormBias: afterB,
            afterNormEps: afterEps
        )
    }

    private static func loadAfterNorm(path: String) throws -> ([Float], [Float], Float) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // 解析 .npz 格式 (PKZip-like)
        // 简单实现: 找到 "weight.npy" 和 "bias.npy" 的偏移
        // npz: <local file header><file data>...
        // 我们需要找到 weight 和 bias 的实际数据
        guard data.count > 100 else {
            throw CIFPredictorWeightsError.afterNormNpzTooSmall
        }
        // 解析策略:暴力搜索 npz 里的 npy magic,根据 header 里 shape 推断 weight/bias
        // (npz 是 zip 格式,简单 header 搜索够用,不需要引 Compression framework)
        let npyMagic: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]

        var weightData: [Float] = []
        var biasData: [Float] = []
        let eps: Float = 1e-12

        // 暴力搜索所有 npy magic
        var searchStart = 0
        while searchStart < data.count - 16 {
            let searchRange = searchStart..<data.count
            if let magicIdx = data.range(of: Data(npyMagic), in: searchRange)?.lowerBound {
                // 解析 npy header
                // Format: magic (6) + version (2) + header_len (2) + header + data
                let headerLen = Int(data[magicIdx + 8]) | (Int(data[magicIdx + 9]) << 8)
                let dataStart = magicIdx + 10 + headerLen
                let header = String(data: data.subdata(in: (magicIdx + 10)..<(magicIdx + 10 + headerLen)), encoding: .ascii) ?? ""
                // 推断 dtype 和 shape
                if header.contains("'shape': (512,)") || header.contains("'shape': (512,)\n") {
                    // weight or bias
                    let n = 512
                    let payload = data.subdata(in: dataStart..<(dataStart + n * 4))
                    let arr = payload.withUnsafeBytes { ptr -> [Float] in
                        let bound = ptr.baseAddress!.assumingMemoryBound(to: Float.self)
                        return Array(UnsafeBufferPointer(start: bound, count: n))
                    }
                    // weight 在前, bias 在后
                    if weightData.isEmpty {
                        weightData = arr
                    } else {
                        biasData = arr
                    }
                }
                searchStart = dataStart
            } else {
                break
            }
        }

        if weightData.count != 512 || biasData.count != 512 {
            // fallback: 已知 weight mean=0.081, bias mean=0.001 (从 funasr dump)
            // 但我们不硬编码 - 直接报错
            throw NSError(
                domain: "CIFPredictorWeights",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Failed to parse after_norm npz at \(path): weight=\(weightData.count) bias=\(biasData.count)"]
            )
        }
        return (weightData, biasData, eps)
    }
}

/// CIF (Continuous Integrate-and-Fire) vDSP 原生实现。
public enum CIFPredictor {
    /// 输入参数：
    /// - hiddenPtr: 指向 `[T, hiddenSize=512]` row-major 的 float 指针（Encoder 输出）
    /// - timeSteps T: 实际帧数（≤ `paddedT`）
    /// - validFrames: 真实有效帧数（mask=1 的部分，通常 = T）
    /// - targetTokens N: 期望输出的 acoustic embedding 数
    /// - weights: CIF 权重
    ///
    /// 返回值：`[N, hiddenSize]` row-major 的 float 数组，长度 = N * 512
    public static func run(
        hiddenPtr: UnsafePointer<Float>,
        timeSteps T: Int,
        validFrames: Int,
        targetTokens N: Int,
        hiddenSize: Int = 512,
        weights: CIFPredictorWeights
    ) -> [Float] {
        precondition(T > 0, "timeSteps T must be > 0")
        precondition(N > 0, "targetTokens N must be > 0")
        precondition(hiddenSize == 512, "SeACo-Paraformer CIF hiddenSize must be 512")

        // -------- 步骤 0: Encoder 后的 LayerNorm (after_norm) --------
        // export 后的 .mlmodelc 不包含 after_norm，必须在 Swift 端手动应用
        // y = (x - mean(x)) / sqrt(var(x) + eps) * weight + bias
        // 在最后一维 (512) 上计算 mean 和 var
        var normalized = [Float](repeating: 0.0, count: T * hiddenSize)
        applyLayerNormLastDim(
            input: hiddenPtr,
            output: &normalized,
            timeSteps: T,
            features: hiddenSize,
            weight: weights.afterNormWeight,
            bias: weights.afterNormBias,
            eps: weights.afterNormEps
        )

        // -------- 步骤 1: Conv1d(512→512, k=3, pad=1) + ReLU --------
        // 输入 normalized: [T, 512] row-major (已归一化)
        // 输出 convOut:    [T, 512] row-major
        var convOut = [Float](repeating: 0.0, count: T * hiddenSize)
        conv1dReLU(
            input: normalized,
            weight: weights.conv1dWeight,  // [out, in, k=3]
            bias: weights.conv1dBias,      // [out]
            timeSteps: T,
            inChannels: hiddenSize,
            outChannels: hiddenSize,
            kernelSize: 3,
            padLeft: 1,
            padRight: 1,
            output: &convOut
        )

        // -------- 步骤 2: Linear(512→1) + Sigmoid + ReLU(*smooth - noise) -> alphas[T] --------
        var alphas = [Float](repeating: 0.0, count: T)
        linearSigmoidRelu(
            input: convOut,                 // [T, 512]
            weight: weights.linearWeight,   // [1, 512]
            bias: weights.linearBias,       // [1]
            timeSteps: T,
            inFeatures: hiddenSize,
            outFeatures: 1,
            smoothFactor: weights.smoothFactor,
            noiseThreshold: weights.noiseThreshold,
            output: &alphas                 // [T]
        )

        // -------- 步骤 3: 屏蔽 padding 帧 (alphas[t] = 0 for t >= validFrames) --------
        if validFrames < T {
            for t in validFrames..<T {
                alphas[t] = 0.0
            }
        }

        // -------- 步骤 4: 缩放 alphas 使 sum(alphas) = N (target_label_length 路径) --------
        var sum: Float = 0
        vDSP_sve(alphas, 1, &sum, vDSP_Length(T))
        let tokenNum = sum
        if tokenNum > 1e-6 && N > 0 {
            let scale = Float(N) / tokenNum
            var s = scale
            vDSP_vsmul(alphas, 1, &s, &alphas, 1, vDSP_Length(T))
        }

        // -------- 步骤 5: CIF 积分发射 (返回 [N, 512]) --------
        let embeddings = cifIntegrate(
            hiddenPtr: hiddenPtr,
            alphas: alphas,
            timeSteps: T,
            targetTokens: N,
            hiddenSize: hiddenSize,
            threshold: weights.threshold
        )
        return embeddings
    }

    // MARK: - LayerNorm (per-frame, 最后一维)

    /// PyTorch `nn.LayerNorm(normalized_shape=(D,), eps=1e-12)` 在最后一维上做归一化:
    ///   y[d] = (x[d] - mean(x)) / sqrt(var(x) + eps) * weight[d] + bias[d]
    /// 输入: [T, D] (row-major)，输出相同 shape
    static func applyLayerNormLastDim(
        input: UnsafePointer<Float>,    // [T, D]
        output: inout [Float],          // [T, D]
        timeSteps T: Int,
        features D: Int,
        weight: [Float],                // [D]
        bias: [Float],                  // [D]
        eps: Float
    ) {
        precondition(weight.count == D)
        precondition(bias.count == D)
        precondition(output.count >= T * D)

        let inBuf = UnsafeBufferPointer(start: input, count: T * D)
        for t in 0..<T {
            let rowStart = t * D
            // 计算 mean
            var mean: Float = 0
            vDSP_sve(inBuf.baseAddress!.advanced(by: rowStart), 1, &mean, vDSP_Length(D))
            mean /= Float(D)
            // 计算 var = mean((x - mean)^2)
            var negMean = -mean
            var shifted = [Float](repeating: 0.0, count: D)
            vDSP_vsadd(inBuf.baseAddress!.advanced(by: rowStart), 1, &negMean, &shifted, 1, vDSP_Length(D))
            var sq = [Float](repeating: 0.0, count: D)
            vDSP_vsq(shifted, 1, &sq, 1, vDSP_Length(D))
            var varSum: Float = 0
            vDSP_sve(sq, 1, &varSum, vDSP_Length(D))
            let variance = varSum / Float(D)
            // 3. rstd = 1 / sqrt(var + eps)
            let rstd: Float = 1.0 / sqrt(variance + eps)
            // 4. y = (x - mean) * rstd * weight + bias
            for d in 0..<D {
                let normalized = (inBuf[rowStart + d] - mean) * rstd
                output[rowStart + d] = normalized * weight[d] + bias[d]
            }
        }
    }

    // MARK: - Conv1d 3-tap + ReLU

    /// 实现 PyTorch `Conv1d(in, out, k=3, padding=(1,1))` (i.e. l_order=1, r_order=1)
    /// + 偏置 + ReLU。
    ///
    /// PyTorch Conv1d weight layout: `[out_channels, in_channels, kernel_size]`
    /// 这里用 im2col 一次性 sgemm 算出整个 [T, out_channels] 输出：
    ///   X[t, c*3+i] = padded_input[t-1+i, c]   (i ∈ {0,1,2}, c ∈ 0..in_channels-1)
    ///   out[t, oc]  = bias[oc] + sum_{c,i} W[oc, c, i] * X[t, c*3+i]
    static func conv1dReLU(
        input: UnsafePointer<Float>,          // [T, inChannels]
        weight: [Float],                       // [out, in, k]
        bias: [Float],                         // [out]
        timeSteps T: Int,
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int,
        padLeft: Int,
        padRight: Int,
        output: inout [Float]                  // [T, outChannels]
    ) {
        precondition(weight.count == outChannels * inChannels * kernelSize)
        precondition(bias.count == outChannels)
        precondition(output.count >= T * outChannels)

        // 1) 构造 im2col 矩阵 X[T, inChannels * kernelSize]
        let colSize = inChannels * kernelSize
        var im2col = [Float](repeating: 0.0, count: T * colSize)

        let inputBuf = UnsafeBufferPointer(start: input, count: T * inChannels)
        for t in 0..<T {
            let rowBase = t * colSize
            for c in 0..<inChannels {
                for i in 0..<kernelSize {
                    let tapT = t - padLeft + i  // 原始 t 位置
                    let dstIdx = rowBase + c * kernelSize + i
                    if tapT >= 0, tapT < T {
                        im2col[dstIdx] = inputBuf[tapT * inChannels + c]
                    } else {
                        im2col[dstIdx] = 0  // 边界 padding = 0
                    }
                }
            }
        }

        // 2) cblas_sgemm: output[T, outChannels] = im2col[T, colSize] @ weight.T[colSize, outChannels]
        //    weight 物理布局是 [outChannels, colSize]，所以用 transB='T' 让 BLAS 当成 [colSize, outChannels] 算
        im2col.withUnsafeBufferPointer { colBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                weight.withUnsafeBufferPointer { wBuf in
                    cblas_sgemm(
                        CblasRowMajor,
                        CblasNoTrans,   // op(A) = im2col  (T x colSize)
                        CblasTrans,     // op(B) = weight^T  (colSize x outChannels)
                        Int32(T), Int32(outChannels), Int32(colSize),
                        1.0,
                        colBuf.baseAddress, Int32(colSize),
                        wBuf.baseAddress, Int32(colSize),
                        0.0,
                        outBuf.baseAddress, Int32(outChannels)
                    )
                }
            }
        }

        // 3) 加 bias + ReLU (per-row broadcast: out[t, :] += bias; then max-with-zero)
        output.withUnsafeMutableBufferPointer { outBuf in
            // bias 是 [outChannels]，对 output [T, outChannels] 每行加一次
            // 循环 T 次、每次 vDSP_vsadd 1 个 outChannels 长度，比 stride 2D 高效
            for t in 0..<T {
                let rowStart = outBuf.baseAddress!.advanced(by: t * outChannels)
                vDSP_vadd(rowStart, 1, bias, 1, rowStart, 1, vDSP_Length(outChannels))
                // ReLU
                var zero: Float = 0
                vDSP_vthres(rowStart, 1, &zero, rowStart, 1, vDSP_Length(outChannels))
            }
        }
    }

    // MARK: - Linear + Sigmoid + ReLU

    /// `output = ReLU( sigmoid(input @ linearWeight.T + linearBias) * smoothFactor - noiseThreshold )`
    /// 这里线性层把 [T, 512] 投影到 [T, 1]，再 squeeze 成 [T]。
    static func linearSigmoidRelu(
        input: [Float],                        // [T, inFeatures]
        weight: [Float],                       // [outFeatures, inFeatures]
        bias: [Float],                         // [outFeatures]
        timeSteps T: Int,
        inFeatures: Int,
        outFeatures: Int,
        smoothFactor: Float,
        noiseThreshold: Float,
        output: inout [Float]                  // [T * outFeatures]
    ) {
        precondition(weight.count == outFeatures * inFeatures)
        precondition(bias.count == outFeatures)
        precondition(output.count >= T * outFeatures)

        // 1) sgemm: out[T, outFeatures] = input[T, inFeatures] @ weight^T
        input.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                weight.withUnsafeBufferPointer { wBuf in
                    cblas_sgemm(
                        CblasRowMajor,
                        CblasNoTrans,   // op(A) = input  (T x inFeatures)
                        CblasTrans,     // op(B) = weight^T  (inFeatures x outFeatures)
                        Int32(T), Int32(outFeatures), Int32(inFeatures),
                        1.0,
                        inBuf.baseAddress, Int32(inFeatures),
                        wBuf.baseAddress, Int32(inFeatures),
                        0.0,
                        outBuf.baseAddress, Int32(outFeatures)
                    )
                }
            }
        }

        // 2) 加 bias + sigmoid + relu(*smooth - noise)
        //    per element:  y = ReLU(sigmoid(z + bias) * smooth - noise)
        let count = T * outFeatures
        output.withUnsafeMutableBufferPointer { outBuf in
            // 加上 bias
            if outFeatures == 1 {
                // 简单 case: 全部加同一个 bias
                var b = bias[0]
                vDSP_vsadd(outBuf.baseAddress!, 1, &b, outBuf.baseAddress!, 1, vDSP_Length(count))
            } else {
                for t in 0..<T {
                    let rowStart = outBuf.baseAddress!.advanced(by: t * outFeatures)
                    vDSP_vadd(rowStart, 1, bias, 1, rowStart, 1, vDSP_Length(outFeatures))
                }
            }
            // sigmoid: 1 / (1 + exp(-x))
            var negOne: Float = -1
            vDSP_vsmul(outBuf.baseAddress!, 1, &negOne, outBuf.baseAddress!, 1, vDSP_Length(count))
            // exp
            var intCount = Int32(count)
            vvexpf(outBuf.baseAddress!, outBuf.baseAddress!, &intCount)
            // +1
            var one: Float = 1
            vDSP_vsadd(outBuf.baseAddress!, 1, &one, outBuf.baseAddress!, 1, vDSP_Length(count))
            // 1/x
            var x: Float = 1
            vDSP_svdiv(&x, outBuf.baseAddress!, 1, outBuf.baseAddress!, 1, vDSP_Length(count))
            // * smoothFactor
            var s = smoothFactor
            vDSP_vsmul(outBuf.baseAddress!, 1, &s, outBuf.baseAddress!, 1, vDSP_Length(count))
            // - noiseThreshold
            var n = -noiseThreshold
            vDSP_vsadd(outBuf.baseAddress!, 1, &n, outBuf.baseAddress!, 1, vDSP_Length(count))
            // ReLU
            var zero: Float = 0
            vDSP_vthres(outBuf.baseAddress!, 1, &zero, outBuf.baseAddress!, 1, vDSP_Length(count))
        }
    }

    // MARK: - CIF 积分发射 (Continuous Integrate-and-Fire)

    /// 复刻 PyTorch `cif()` 函数 (cif_predictor.py line 758) 的 batch=1 路径：
    ///
    /// ```
    /// integrate = 0
    /// frame     = zeros[hiddenSize]
    /// for t in 0..<T:
    ///     alpha = alphas[t]
    ///     integrate += alpha
    ///     fire = (integrate >= threshold)
    ///     if fire: integrate -= 1.0
    ///     cur = (fire ? (1 - prev_integrate) : alpha)
    ///     remainds = alpha - cur
    ///     frame += cur * hidden[t]            // 总是先累加
    ///     list_frames.append(frame)           // 再 push 当前 frame
    ///     if fire: frame = remainds * hidden[t]  // fire 时重置
    /// ```
    ///
    /// 返回 `[N, hiddenSize]` (N = `targetTokens`)，超出实际 firing 数的尾部置 0。
    static func cifIntegrate(
        hiddenPtr: UnsafePointer<Float>,   // [T, hiddenSize]
        alphas: [Float],                    // [T]，已缩放到 sum == N
        timeSteps T: Int,
        targetTokens N: Int,
        hiddenSize: Int,
        threshold: Float
    ) -> [Float] {
        var embeddings = [Float](repeating: 0.0, count: N * hiddenSize)
        var frame = [Float](repeating: 0.0, count: hiddenSize)
        var integrate: Float = 0
        var fireCount = 0

        for t in 0..<T {
            let alpha = alphas[t]
            let prevIntegrate = integrate
            integrate += alpha

            let fire = integrate >= threshold
            if fire {
                integrate -= threshold
            }

            // cur = (fire ? (1 - prev_integrate) : alpha)
            let cur = fire ? (1.0 - prevIntegrate) : alpha
            // remainds = alpha - cur
            let hiddenRow = hiddenPtr.advanced(by: t * hiddenSize)

            // 关键: 先 frame += cur * hidden[t] (总是累加)
            for d in 0..<hiddenSize {
                frame[d] += cur * hiddenRow[d]
            }

            // 然后再 PUSH 当前 frame
            if fire {
                if fireCount < N {
                    let dst = fireCount * hiddenSize
                    for d in 0..<hiddenSize {
                        embeddings[dst + d] = frame[d]
                    }
                    fireCount += 1
                }
                // fire 时重置 frame = remainds * hidden[t]
                let remainds = alpha - cur
                for d in 0..<hiddenSize {
                    frame[d] = remainds * hiddenRow[d]
                }
            }
        }

        // 末尾 partial fire (若 integrate > 0，最后再发射一次)
        if fireCount < N, integrate > 0 {
            let dst = fireCount * hiddenSize
            for d in 0..<hiddenSize {
                embeddings[dst + d] = frame[d]
            }
            fireCount += 1
        }

        return embeddings
    }
}
