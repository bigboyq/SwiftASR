import Foundation
import Accelerate
import OnnxRuntimeBindings

/// Engine-init / setup failures from the top-level pipeline entry points.
/// Caller-facing so views can `switch` on the case and present targeted
/// remediation hints (e.g. "check ONNX model paths" vs the speaker-only
/// rerun path which doesn't have a modelsRoot in scope).
public enum AudioPipelineError: Error, LocalizedError, Sendable {
    /// 至少一个 ONNX/CV engine 没初始化（VAD/ASR/Decoder/Speaker 任一为 nil）。
    /// 完整跑整条 pipeline 时抛。
    case enginesNotInitialized(modelsRoot: String)
    /// Speaker 单独跑或 rerun 路径抛。`modelsRoot` 为 nil 时不附带路径提示
    /// （speaker-only 入口本身没接收 modelsRoot, 跟完整 pipeline 分开）。
    case speakerEngineNotInitialized(modelsRoot: String?)
    /// 解码后的 pcm 没有可提取的声学帧（音频 < 25ms 或全静音）。
    case fbankEmpty
    /// fbank80 缓存/产物为空或维度损坏（count 不被 80 整除）。
    case fbankDimensionInvalid
    /// VAD streaming producer 没产出 metrics（TaskGroup 被取消或上游 producer 提前 throw）。
    case vadStreamingMetricsMissing
    /// packed speaker feature storage 累积的窗口数 ≠ 期望窗口数（部分 producer 没写满）。
    case speakerFeatureWindowCountMismatch(found: Int, expected: Int)

    public var errorDescription: String? {
        switch self {
        case let .enginesNotInitialized(root):
            return "Engine init failed. Check ONNX model paths in \(root)."
        case let .speakerEngineNotInitialized(root):
            if let root {
                return "Speaker engine init failed. Check ONNX model paths in \(root)."
            } else {
                return "Speaker engine init failed."
            }
        case .fbankEmpty:
            return "音频没有可提取的声学帧（需要至少 25ms 音频）。"
        case .fbankDimensionInvalid:
            return "声学特征为空或维度损坏，无法重新识别说话人。"
        case .vadStreamingMetricsMissing:
            return "VAD streaming producer returned no metrics"
        case let .speakerFeatureWindowCountMismatch(found, expected):
            return "Packed speaker feature preparation returned \(found)/\(expected) windows."
        }
    }
}

/// 端到端 ASR pipeline：VAD → ASR → Speaker embedding → 谱聚类 → UtteranceData 列表。
/// 实例只持有可复用的 ONNX / CoreML model session；PCM 与 fbank 均是每次 run 的
/// 局部变量。`PrewarmedAudioPipelineStore` 可在全局串行转写间复用此实例而不保留音频数据。
///
/// - Important: `vadEngine` / `puncRestorer` / `speakerEngine` / `asrDecoder` 都是
///   `Optional`，但只是**语言层防御** — 实际不可为 nil。`init` 内每个都是
///   `try X(...)`（无 `?? nil` 兜底），任一 engine 加载失败直接 throw 到 caller，
///   不会让实例带 nil engine 存活。新加 stage 方法应在开头调 `requireReady()`
///   来同时校验 4 个 engine，避免自己写 `guard let X = X else { ... }`。
public actor AudioPipeline {


    let converter = AudioConverter()
    let extractor = FbankExtractor()
    let clustering = SpectralClustering()

    private let vadEngine: VADONNXEngine?
    private let asrEngines: [ASRONNXEngine]
    private let asrDecoder: ASRDecoder?
    let puncRestorer: PunctuationRestorationPipeline?
    let speakerEngine: SpeakerNativeCoreMLEngine?
    private let modelsRoot: String

    /// 一次性校验 4 个 engine 都就绪。Stage 方法开头调它即可，
    /// 避免每个 stage 自己写 `guard let X = X else { throw ... }` 重复链。
    /// 真实失败时抛 `AudioPipelineError.enginesNotInitialized(modelsRoot:)`。
    private func requireReady() throws {
        guard vadEngine != nil, !asrEngines.isEmpty, asrDecoder != nil, speakerEngine != nil else {
            throw AudioPipelineError.enginesNotInitialized(modelsRoot: modelsRoot)
        }
    }

    public init(
        modelsRoot: String,
        asrCPUIntraOpThreads: Int? = ASRCPUConcurrency.performanceCoreHalfIntraOpThreads
    ) throws {
        self.modelsRoot = modelsRoot
        // 模型定死：SeACo-Paraformer + CT-Transformer Punc + FSMN-VAD + ERes2NetV2
        // ASR (SeACo-Paraformer) 输入 shape 剧烈变化（T = 数百到数万帧），
        // CoreML ANE 对动态 shape 编译慢甚至挂掉，所以 ASR 强制 CPU
        // VAD (FSMN-VAD streaming) 同样撞 ANE "Error in building plan" → 强制 CPU
        // Speaker (ERes2Net2) 走 `SpeakerNativeCoreMLEngine` 直接 Native CoreML，
        // 不经过 ONNX Runtime / CoreML EP；.mlmodelc 加载失败时直接报错，没有
        // EP → CPU 的 failover 路径。ModelsAndDataSection 写"speaker 尝试
        // CoreML EP"是旧架构残留文案，已同步修。
        // Punc 在真实长音频逐句恢复时偶发 CoreML prediction error → 强制 CPU
        let asrUseCoreML = false
        let vadUseCoreML = false
        let puncUseCoreML = false
        self.vadEngine = try VADONNXEngine(
            modelPath: ModelCatalog.filePath(definitionID: "vad", file: "model_quant.onnx", modelsRoot: modelsRoot),
            useCoreML: vadUseCoreML
        )
        // R4-P2-15：预热用 `Task.detached` 构建 pipeline，但 init 是同步的，
        // `warmupTask?.cancel()` 不会中断已经开始的 ONNX session 构造。在每个
        // 重型 engine 之间插 `Task.checkCancellation()`，让切换 modelsRoot 时
        // 已取消的预热能尽早 bail，而不是把 4 个 engine 全部构造完才返回。
        try Task.checkCancellation()
        let finalAsrPath = ModelCatalog.filePath(
            definitionID: "asr", file: "model_quant.onnx", modelsRoot: modelsRoot
        )
        self.asrDecoder = try ASRDecoder(
            vocabJsonPath: ModelCatalog.filePath(definitionID: "asr", file: "tokens.json", modelsRoot: modelsRoot)
        )
        try Task.checkCancellation()
        self.asrEngines = try (0..<ASRCPUConcurrency.workerCount).map { _ in
            try ASRONNXEngine(
                modelPath: finalAsrPath,
                useCoreML: asrUseCoreML,
                cpuIntraOpThreads: asrCPUIntraOpThreads
            )
        }
        try Task.checkCancellation()
        self.puncRestorer = try PunctuationRestorationPipeline(
            modelPath: ModelCatalog.filePath(definitionID: "punc", file: "model_quant.onnx", modelsRoot: modelsRoot),
            vocabJsonPath: ModelCatalog.filePath(definitionID: "punc", file: "tokens.json", modelsRoot: modelsRoot),
            useCoreML: puncUseCoreML
        )
        try Task.checkCancellation()
        let finalSpkPath = ModelCatalog.filePath(
            definitionID: "speaker", file: "model_batch16.mlmodelc", modelsRoot: modelsRoot
        )
        self.speakerEngine = try SpeakerNativeCoreMLEngine(
            modelPath: finalSpkPath,
            inferenceBatchSize: SpeakerNativeCoreMLEngine.preferredBatchSize
        )
    }

    /// 执行完整的端到端转写流水线。
    /// - Parameters:
    ///   - audioPath: 输入音频路径（任意 ffmpeg / AVFoundation 能解的格式）
    ///   - onProgress: 进度回调 (stageName, fraction, message)
    /// - Returns: (utterances, speakerProfiles) — utterances 是已带 speakerLabel 的段落；
    ///   speakerProfiles 是该 job 的所有说话人 profile（用于跨 job 库 + auto-archive）。
    public func runPipelineWithProfiles(
        audioPath: String,
        policy: SpeakerTemporalPolicy = .production,
        onProgress: @Sendable @escaping (String, Double, String) -> Void = { _, _, _ in },
        shouldCancel: @Sendable @escaping () -> Bool = { false },
        onSpeakerInput: @Sendable @escaping (SpeakerRecognitionInput) -> Void = { _ in },
        /// Bug fix 2026-07-12: 每个 stage 完成时回调一次, 传累积 metrics.
        /// UI checklist ✅ 后显示关键信息 (e.g. "PCM 8.0s · fbank 2.9s · 5284 帧")
        /// 需要在每个 stage 跑完**立即**拿到 metrics, 不能等整个 pipeline 跑完.
        /// 调用方 coordinator 接后合并到 @Published activeStageMetrics.
        onStageComplete: @Sendable @escaping (String, PipelineStageMetrics) -> Void = { _, _ in }
    ) async throws -> (utterances: [UtteranceData], speakerProfiles: [SpeakerProfileData], metrics: PipelineStageMetrics) {
        let result = try await _runPipelineInternal(
            audioPath: audioPath,
            policy: policy,
            onProgress: onProgress,
            shouldCancel: shouldCancel,
            onSpeakerInput: onSpeakerInput,
            onStageComplete: onStageComplete
        )
        return (result.utterances, result.speakerProfiles, result.metrics)
    }

    /// Diagnostic variant: runs the full pipeline and returns the
    /// `SpeakerDiarizationPipeline.Result` (timeline, token evidence,
    /// L1/L2 per-sub-sentence decisions) alongside the simplified output.
    /// Used by `BoundaryEvidenceDiagnostic` and similar tests that need
    /// per-token evidence to reason about speaker-boundary behavior.
    /// `internal` so it is reachable only via `@testable import SwiftASR`.
    func runPipelineWithFullSpeakerResult(
        audioPath: String,
        policy: SpeakerTemporalPolicy = .production,
        onProgress: @Sendable @escaping (String, Double, String) -> Void = { _, _, _ in },
        shouldCancel: @Sendable @escaping () -> Bool = { false },
        onSpeakerInput: @Sendable @escaping (SpeakerRecognitionInput) -> Void = { _ in },
        onStageComplete: @Sendable @escaping (String, PipelineStageMetrics) -> Void = { _, _ in }
    ) async throws -> (utterances: [UtteranceData], speakerProfiles: [SpeakerProfileData], metrics: PipelineStageMetrics, speakerResult: SpeakerDiarizationPipeline.Result) {
        try await _runPipelineInternal(
            audioPath: audioPath,
            policy: policy,
            onProgress: onProgress,
            shouldCancel: shouldCancel,
            onSpeakerInput: onSpeakerInput,
            onStageComplete: onStageComplete
        )
    }

    /// Internal worker shared by `runPipelineWithProfiles` (public) and
    /// `runPipelineWithFullSpeakerResult` (diagnostic). Owns the full
    /// decode → fbank → VAD → ASR → Punc → speaker pipeline so neither
    /// public method duplicates any stage logic.
    ///
    /// 2026-07-26 (P0 audit): split the 5 pipeline stages into helper
    /// methods (`decodeStage` / `fbankStage` / `vadAsrStage` / speaker
    /// via `recognizeSpeakersFull` / `applyPunctuationStage`) and keep
    /// the orchestrator focused on wiring them together + emitting the
    /// per-stage `onStageComplete` callback.
    private func _runPipelineInternal(
        audioPath: String,
        policy: SpeakerTemporalPolicy,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool,
        onSpeakerInput: @Sendable @escaping (SpeakerRecognitionInput) -> Void,
        onStageComplete: @Sendable @escaping (String, PipelineStageMetrics) -> Void
    ) async throws -> (utterances: [UtteranceData], speakerProfiles: [SpeakerProfileData], metrics: PipelineStageMetrics, speakerResult: SpeakerDiarizationPipeline.Result) {
        try requireReady()
        let vad = vadEngine!

        let pipelineStartedAt = Date()
        // 累积 metrics: 4 阶段 (preprocess / asr / punc / speaker) 各自完成时
        // 增量更新 + 调 onStageComplete, 让 UI checklist 在 ✅ 标记后立即显示
        // 关键信息 (e.g. "PCM 8.0s · fbank 2.9s · 5284 帧"), 不等整个 pipeline
        // 跑完. (Bug fix 2026-07-12)
        var accumulatedMetrics = PipelineStageMetrics()

        // Stage 0：入口的 cancel 检查
        // Do not persist the source path or filename: user recordings often
        // contain private names or project details.
        Logger.shared.info("AudioPipeline 启动")
        if shouldCancel() {
            Logger.shared.warn("AudioPipeline 取消（validate 阶段）")
            throw PipelineCancelled(stage: "validate")
        }

        // Stage 1+2: 委托给 runDecodeAndFbank（pcm 在 sub-function 内 release,
        // 节省 ~1GB for 2h 音频. 详见 SWIFTASR_LONG_AUDIO_MEMORY_PLAN_2026-08-02 §5.1.）
        let stage12 = try await runDecodeAndFbank(
            audioPath: audioPath,
            onProgress: onProgress,
            shouldCancel: shouldCancel,
            onStageComplete: onStageComplete,
            accumulatedMetrics: &accumulatedMetrics
        )

        // Stage 3+4：VAD producer + 双 ASR worker 流水线（D-1: 都从 fbank80 切片）
        let vadAsrOut = try await vadAsrStage(
            fbank80: stage12.fbank80,
            totalFrames: stage12.frameCount,
            totalDurationMs: stage12.totalDurationMs,
            vad: vad,
            asrDecoder: asrDecoder!,
            modelsRoot: modelsRoot,
            pcmSeconds: stage12.pcmSeconds,
            fbankSeconds: stage12.fbankSeconds,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        recordASRMetrics(
            &accumulatedMetrics,
            output: vadAsrOut,
            onStageComplete: onStageComplete
        )
        if vadAsrOut.asrResult.sentences.isEmpty {
            // Keep the anomaly observable without writing transcript content
            // into the seven-day plaintext log.
            Logger.shared.warn(
                "AudioPipeline: WARNING ASR produced 0 sentences; rawTextCharacters=\(vadAsrOut.asrResult.rawText.count)"
            )
        }
        if shouldCancel() { throw PipelineCancelled(stage: "asr") }

        // Stage 4.5：标点恢复（applyPunctuationStage 在 +Punctuation.swift）
        let puncStartedAt = Date()
        let punctuated = try applyPunctuationStage(
            asrResult: vadAsrOut.asrResult, onProgress: onProgress
        )
        let puncSeconds = Date().timeIntervalSince(puncStartedAt)
        // Bug fix 2026-07-12: punc stage 完成, 累积 + 调 onStageComplete
        accumulatedMetrics.puncMs = Int(puncSeconds * 1000)
        onStageComplete("punc", accumulatedMetrics)
        if shouldCancel() { throw PipelineCancelled(stage: "punc") }

        onSpeakerInput(SpeakerRecognitionInput(audioPath: audioPath, sentences: punctuated.sentences))

        let speakerOut = try await runSpeakerStage(
            fbank80: stage12.fbank80,
            sentences: punctuated.sentences,
            audioPath: audioPath,
            policy: policy,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        // Bug fix 2026-07-12: speaker stage 完成, 累积 + 调 onStageComplete
        accumulatedMetrics.speakerMs = Int(speakerOut.speakerSeconds * 1000)
        onStageComplete("speaker", accumulatedMetrics)

        logPipelineSummary(
            startedAt: pipelineStartedAt,
            metrics: accumulatedMetrics,
            pcmSeconds: stage12.pcmSeconds,
            fbankSeconds: stage12.fbankSeconds,
            vadAsr: vadAsrOut,
            puncSeconds: puncSeconds,
            speakerSeconds: speakerOut.speakerSeconds
        )

        return (speakerOut.result.utterances, speakerOut.result.speakerProfiles, accumulatedMetrics, speakerOut.result)
    }

    /// Stage 1+2 合并：解码 + fbank 物化 + 在返回前 release pcm。
    ///
    /// 关键：pcm 引用是 sub-function 内的 local，函数返回时 Swift ARC 释放。
    /// Caller (`_runPipelineInternal`) 拿到 `Stage12Output`（不含 pcm），
    /// 后续 vadAsrStage / speaker / logPipelineSummary 都用 stage12 的元数据。
    ///
    /// 实测收益（2026-08-02 PipelineMemoryStressDiagnostic）：
    /// - 1h 音频：+892 MB → +392 MB（节省 500 MB）
    /// - 2h 音频：+1,784 MB → +784 MB（节省 1,000 MB）
    private func runDecodeAndFbank(
        audioPath: String,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool,
        onStageComplete: @Sendable @escaping (String, PipelineStageMetrics) -> Void,
        accumulatedMetrics: inout PipelineStageMetrics
    ) async throws -> Stage12Output {
        // Soft preflight: 长音频 + 低内存机器时给用户告警（不 throw）。
        // 用 file header 算 duration 而不是先 decode 整个 pcm 数组。
        if let durationSec = AudioConverter.probeDuration(path: audioPath) {
            Self.preflightMemoryCheck(audioPath: audioPath, audioDurationSec: durationSec)
        }

        // Stage 1: 解码 + 重采样到 16kHz mono
        let decodeOut = try await decodeStage(
            audioPath: audioPath,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        // Stage 2: 整段 fbank 物化（6 worker 并发算 1/6 整段）
        let fbankOut = try await fbankStage(
            pcm: decodeOut.pcm,
            totalDurationMs: decodeOut.totalDurationMs,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        recordPreprocessMetrics(
            &accumulatedMetrics,
            decode: decodeOut,
            fbank: fbankOut,
            onStageComplete: onStageComplete
        )
        if shouldCancel() { throw PipelineCancelled(stage: "load") }

        // decodeOut (含 pcm) 在此函数返回时由 Swift ARC release
        return Stage12Output(
            fbank80: fbankOut.fbank80,
            frameCount: fbankOut.frameCount,
            pcmSeconds: decodeOut.pcmSeconds,
            totalDurationMs: decodeOut.totalDurationMs,
            fbankSeconds: fbankOut.fbankSeconds
        )
    }

    private func recordPreprocessMetrics(
        _ metrics: inout PipelineStageMetrics,
        decode: DecodeStageOutput,
        fbank: FbankStageOutput,
        onStageComplete: @Sendable @escaping (String, PipelineStageMetrics) -> Void
    ) {
        metrics.pcmDecodeMs = Int(decode.pcmSeconds * 1000)
        metrics.fbankMaterialiseMs = Int(fbank.fbankSeconds * 1000)
        metrics.fbankFrames = fbank.frameCount
        metrics.totalDurationMs = decode.totalDurationMs
        onStageComplete("preprocess", metrics)
    }

    private func recordASRMetrics(
        _ metrics: inout PipelineStageMetrics,
        output: VadAsrStageOutput,
        onStageComplete: @Sendable @escaping (String, PipelineStageMetrics) -> Void
    ) {
        metrics.vadAsrWallMs = Int(output.vadAsrWallSeconds * 1000)
        metrics.vadSegmentCount = output.vadSegments.count
        onStageComplete("asr", metrics)
    }

    private func runSpeakerStage(
        fbank80: [Float],
        sentences: [ASRSentence],
        audioPath: String,
        policy: SpeakerTemporalPolicy,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> SpeakerStageOutput {
        do {
            return try await speakerStage(
                fbank80: fbank80,
                sentences: sentences,
                audioPath: audioPath,
                policy: policy,
                onProgress: onProgress,
                shouldCancel: shouldCancel
            )
        } catch is PipelineCancelled {
            throw PipelineCancelled(stage: "speaker")
        } catch {
            throw PipelineStageFailure(stage: "speaker", underlying: error)
        }
    }

    private func logPipelineSummary(
        startedAt: Date,
        metrics: PipelineStageMetrics,
        pcmSeconds: Double,
        fbankSeconds: Double,
        vadAsr: VadAsrStageOutput,
        puncSeconds: Double,
        speakerSeconds: Double
    ) {
        let decodeSeconds = Double(metrics.pcmDecodeMs + metrics.fbankMaterialiseMs) / 1000
        let totalParts = [
            "decode=\(String(format: "%.2f", decodeSeconds))s" +
            "(pcm=\(String(format: "%.2f", pcmSeconds))s, fbank=\(String(format: "%.2f", fbankSeconds))s)",
            "vad+asr=\(String(format: "%.2f", vadAsr.vadAsrWallSeconds))s" +
            "(vad=\(String(format: "%.2f", vadAsr.vadSeconds))s, asr=\(String(format: "%.2f", vadAsr.asrSeconds))s)",
            "punc=\(String(format: "%.2f", puncSeconds))s",
            "speaker=\(String(format: "%.2f", speakerSeconds))s"
        ]
        Logger.shared.info(
            "AudioPipeline 耗时汇总: total=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s " +
            totalParts.joined(separator: " ")
        )
    }

    // MARK: - Preflight

    /// 长音频 + 低内存机器软告警。只 log + post notification，不 throw。
    /// 设计原则：数字不精确时给提示而不是 hard reject；让用户自己决定是否
    /// 关闭其他大型应用后重试。监听端（结果页 banner）应展示
    /// "建议关闭其他大型应用" 而不是 "无法处理"。
    ///
    /// 触发条件（任一满足）：
    /// - 长音频 > 1.5h 且低内存机器（< 16GB）
    /// - 超长音频 > 3h（任何机器都告警）
    ///
    /// userInfo: duration (Double 秒), estimatedMB (Int),
    /// machineGB (Int)。
    static func preflightMemoryCheck(
        audioPath: String,
        audioDurationSec: Double
    ) {
        // 1h 以下不值得打扰用户
        guard audioDurationSec > 60 * 60 else { return }

        let estimatedMB = estimateMemoryFootprintMB(
            durationSec: audioDurationSec,
            pcmReleased: true  // B 修后 pcm 在 runDecodeAndFbank 返回时 release
        )
        let machineRAMMB = Double(ProcessInfo.processInfo.physicalMemory) / 1024.0 / 1024.0
        let machineGB = Int(machineRAMMB / 1024)

        Logger.shared.info(
            "AudioPipeline preflight: duration=\(Int(audioDurationSec / 60))min, " +
            "estimated_additional=\(Int(estimatedMB))MB, machine=\(machineGB)GB"
        )

        let isLongAudio = audioDurationSec > 90 * 60       // 1.5h
        let isVeryLongAudio = audioDurationSec > 3 * 60 * 60  // 3h
        let isLowMemoryMachine = machineRAMMB < 16 * 1024  // < 16GB

        guard isVeryLongAudio || (isLongAudio && isLowMemoryMachine) else { return }

        NotificationCenter.default.post(
            name: .audioPipelineMemoryWarning,
            object: nil,
            userInfo: [
                "duration": audioDurationSec,
                "estimatedMB": Int(estimatedMB),
                "machineGB": machineGB,
            ]
        )
        Logger.shared.warn(
            "AudioPipeline memory warning: 估算 \(Int(estimatedMB))MB " +
            "+\(machineGB)GB 机器，建议关闭其他大型应用后重试"
        )
    }

    /// 给定音频时长估算 pipeline 内存占用（MB）。
    /// 数字来源：`PipelineMemoryStressDiagnostic` 2026-08-02 实测。
    /// - ONNX session in-memory: 1,500 MB（variance 1,464~2,104MB）
    /// - PCM Float32: 587 MB / 小时
    /// - fbank80 Float32: 305 MB / 小时
    ///
    /// - Parameters:
    ///   - durationSec: 音频时长（秒）
    ///   - pcmReleased: B 修复后 pcm 在 fbank 完成后释放；false 用于"修前"对比
    /// - Returns: 估算峰值（MB）
    static func estimateMemoryFootprintMB(
        durationSec: Double,
        pcmReleased: Bool
    ) -> Double {
        let onnxMB = 1500.0
        let hours = durationSec / 3600
        let pcmMB = 587.0 * hours
        let fbankMB = 305.0 * hours
        return pcmReleased ? (onnxMB + fbankMB) : (onnxMB + pcmMB + fbankMB)
    }

    // MARK: - Stage helpers

    /// Stage 1+2 输出：解码 + fbank 物化后释放 pcm，只回传下游需要的元数据。
    /// 关键设计：`pcm` 在 `runDecodeAndFbank` 内 release（函数返回时），
    /// caller 不持有 pcm 引用，节省 ~1GB for 2h 音频（实测 2026-08-02 v2）。
    private struct Stage12Output {
        let fbank80: [Float]
        let frameCount: Int
        let pcmSeconds: Double
        let totalDurationMs: Int
        let fbankSeconds: Double
    }

    /// Stage 1 输出：解码 + 重采样到 16kHz mono。pcm 在 caller 拿到 fbank80 后立即释放。
    private struct DecodeStageOutput {
        let pcm: [Float]
        let pcmSeconds: Double
        let totalDurationMs: Int
        let pcmSampleCount: Int
    }

    /// Stage 2 输出：整段 fbank80 物化结果。
    private struct FbankStageOutput {
        let fbank80: [Float]
        let fbankSeconds: Double
        let frameCount: Int
    }

    /// Stage 3+4 输出：VAD+ASR 流水线结果。
    private struct VadAsrStageOutput {
        let asrResult: ASRResult
        let vadSegments: [(startMs: Int, endMs: Int)]
        let vadSeconds: Double
        let asrSeconds: Double
        let vadAsrWallSeconds: Double
    }

    /// Stage 1：解码 + 重采样到 16kHz mono。AudioConverterError 翻译成 PipelineCancelled。
    private func decodeStage(
        audioPath: String,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> DecodeStageOutput {
        onProgress("load", 0.0, "解码音频…")
        let pcmDecodeStartedAt = Date()
        let pcm: [Float]
        do {
            pcm = try converter.loadAndResample(
                path: audioPath,
                shouldCancel: { shouldCancel() || Task.isCancelled }
            )
        } catch AudioConverterError.cancelled {
            throw PipelineCancelled(stage: "load")
        }
        let pcmDecodeSeconds = Date().timeIntervalSince(pcmDecodeStartedAt)
        let timebase = AudioTimebase.standard
        let totalDurationMs = timebase.milliseconds(forSampleCount: pcm.count)
        let totalSeconds = Double(totalDurationMs) / 1000
        onProgress("load", 0.2, "音频解码完成 (\(String(format: "%.1f", totalSeconds))s)")
        guard extractor.frameCount(pcmData: pcm) > 0 else {
            throw AudioPipelineError.fbankEmpty
        }
        if shouldCancel() {
            Logger.shared.warn("AudioPipeline 取消（load 阶段）")
            throw PipelineCancelled(stage: "load")
        }
        return DecodeStageOutput(
            pcm: pcm,
            pcmSeconds: pcmDecodeSeconds,
            totalDurationMs: totalDurationMs,
            pcmSampleCount: pcm.count
        )
    }

    /// Stage 2：整段 fbank 物化（6 worker 并发算 1/6 整段 = 几秒算完）。VAD 跟
    /// ASR 都从整段 fbank80 切片，6 worker 衔接点（audioDurationMs / 性能核数）
    /// 不需要补算。内存预算：1h 音频 ≈ 137MB fbank + 288MB pcm + ~150MB 推理。
    private func fbankStage(
        pcm: [Float],
        totalDurationMs: Int,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> FbankStageOutput {
        onProgress("load", 0.4, "提取声学特征…")
        let materialized = try await materializeFbank(
            pcm: pcm,
            workerCount: nil,
            progressStart: 0.4,
            progressEnd: 1.0,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        onProgress("load", 1.0, "音频特征就绪 (\(materialized.frameCount) 帧)")
        Logger.shared.info(
            "AudioPipeline: pcm samples=\(pcm.count), duration=\(totalDurationMs)ms, " +
            "fbank frames=\(materialized.frameCount), materialised=full, workers=\(materialized.workerCount)"
        )
        return FbankStageOutput(
            fbank80: materialized.fbank80,
            fbankSeconds: materialized.elapsedSeconds,
            frameCount: materialized.frameCount
        )
    }

    /// Stage 3+4：One stateful VAD producer emits only closed segments. Two
    /// independent ASR sessions consume them immediately (D-1: 都从 fbank80
    /// 切片不重算 fbank)。`pcmSeconds` / `fbankSeconds` 用于 stage log 输出。
    private func vadAsrStage(
        fbank80: [Float],
        totalFrames: Int,
        totalDurationMs: Int,
        vad: VADONNXEngine,
        asrDecoder: ASRDecoder,
        modelsRoot: String,
        pcmSeconds: Double,
        fbankSeconds: Double,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> VadAsrStageOutput {
        let streaming = try await Self.transcribeWithStreamingVAD(
            fbank80: fbank80,
            totalFrames: totalFrames,
            totalDurationMs: totalDurationMs,
            vad: vad,
            asrEngines: asrEngines,
            asrDecoder: asrDecoder,
            modelsRoot: modelsRoot,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        Logger.shared.info(
            "AudioPipeline VAD+ASR 流水线: workers=\(asrEngines.count), wall=\(String(format: "%.2f", streaming.wallSeconds))s, " +
            "fbank_materialise=\(String(format: "%.2f", fbankSeconds))s, " +
            "vad_frontend=\(String(format: "%.2f", streaming.vadFrontendSeconds))s, " +
            "vad_inference=\(String(format: "%.2f", streaming.vadInferenceSeconds))s, " +
            "asr_frontend_sum=\(String(format: "%.2f", streaming.asrFrontendSeconds))s, " +
            "asr_engine_sum=\(String(format: "%.2f", streaming.asrInferenceSeconds))s " +
            "(input=\(String(format: "%.2f", streaming.asrInputPreparationSeconds))s, " +
            "session_run=\(String(format: "%.2f", streaming.asrSessionRunSeconds))s, " +
            "output_materialize=\(String(format: "%.2f", streaming.asrOutputMaterializationSeconds))s), " +
            "asr_decode_sum=\(String(format: "%.2f", streaming.asrDecodeSeconds))s, " +
            "batches=\(streaming.asrBatchCount)"
        )
        onProgress("vad", 1.0, "语音分段完成 (\(streaming.vadSegments.count) 段)")
        onProgress("asr", 1.0, "文字识别完成 (\(streaming.asrResult.sentences.count) 句)")
        // vad+asr 合并 wall: 流水线并发，wall = max(vad_wall, asr_wall)
        // vad_wall = VAD 60s window stride 跑完总时间
        // asr_wall = ASR 跑完总时间（包含等 VAD 出 segment 的等待）
        let vadAsrWall = max(streaming.vadWallSeconds, streaming.wallSeconds)
        return VadAsrStageOutput(
            asrResult: streaming.asrResult,
            vadSegments: streaming.vadSegments,
            vadSeconds: streaming.vadWallSeconds,
            asrSeconds: streaming.wallSeconds,
            vadAsrWallSeconds: vadAsrWall
        )
    }

    /// Stage 5：speaker 识别。D-2 改吃整段 fbank80，speaker chunk 从 fbank80
    /// 切片（zero-pad 到 148 帧对齐 funasr sv_chunk 行为）。省 ~150 次 fbank
    /// 重算 / 1h。返回 `speakerSeconds` 让 caller 写 `accumulatedMetrics.speakerMs`。
    private struct SpeakerStageOutput {
        let result: SpeakerDiarizationPipeline.Result
        let speakerSeconds: Double
    }

    private func speakerStage(
        fbank80: [Float],
        sentences: [ASRSentence],
        audioPath: String,
        policy: SpeakerTemporalPolicy,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> SpeakerStageOutput {
        let speakerStartedAt = Date()
        let jobId = ResultStore.hashAudioPath(audioPath)
        let result = try await recognizeSpeakersFull(
            fbank80: fbank80,
            sentences: sentences,
            audioPath: audioPath,
            policy: policy,
            diagnosticsURL: ResultStore.speakerDiagnosticsPath(jobId: jobId),
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        return SpeakerStageOutput(
            result: result,
            speakerSeconds: Date().timeIntervalSince(speakerStartedAt)
        )
    }

    /// Re-runs only diarization using persisted ASR segments. It deliberately
    /// skips VAD, ASR, and punctuation recovery so user text edits remain intact.
    ///
    /// D-2: 整段 fbank 物化（6 worker 并发算 1/6 整段），跟 `runPipelineWithProfiles`
    /// 复用同一个 `extractor.extractFbank` 多线程物化路径。`recognizeSpeakers` 不再
    /// 需要 pcm，可以直接吃 fbank80 切片，1h 音频 ~150 个 speaker chunk 省 150 次 fbank 重算。
    ///
    /// D-4: `precomputedFbank80` 可选参数——如果调用方已经算好 fbank80（例如 UI 端从
    /// result.json 缓存读），直接传进来跳过物化（再省 ~几秒）。没传就自己从 audioPath
    /// 解码 + 物化。同时 pcm / fbank80 用完立即释放（节省 ~425MB for 1h 音频）。
    public func reidentifySpeakers(
        audioPath: String,
        sentences: [ASRSentence],
        policy: SpeakerTemporalPolicy = .production,
        precomputedFbank80: [Float]? = nil,
        diagnosticsURL: URL? = nil,
        onProgress: @Sendable @escaping (String, Double, String) -> Void = { _, _, _ in },
        shouldCancel: @Sendable @escaping () -> Bool = { false }
    ) async throws -> (utterances: [UtteranceData], speakerProfiles: [SpeakerProfileData]) {
        try requireReady()
        guard !sentences.isEmpty else { return ([], []) }
        guard !shouldCancel() else { throw PipelineCancelled(stage: "speaker") }

        // D-4: precomputedFbank80 非空走缓存路径（省 ~几秒），否则解码 + 物化。
        // Shared with reidentifySpeakersFull via loadOrDecodeFbank80.
        let mat = try await loadOrDecodeFbank80(
            audioPath: audioPath,
            precomputedFbank80: precomputedFbank80,
            progressStart: 0.0,
            progressEnd: 1.0,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        if mat.fromCache {
            Logger.shared.info(
                "AudioPipeline speaker reidentify preprocess: source=cache, " +
                "pcm=0.00s, fbank=0.00s, frames=\(mat.frameCount)"
            )
        } else {
            Logger.shared.info(
                "AudioPipeline speaker reidentify preprocess: source=decoded, " +
                "pcm=\(String(format: "%.2f", mat.pcmSeconds))s, " +
                "fbank=\(String(format: "%.2f", mat.fbankSeconds))s, frames=\(mat.frameCount), " +
                "workers=\(mat.workerCount)"
            )
        }
        guard mat.fbank80.count >= 80, mat.fbank80.count.isMultiple(of: 80) else {
            throw AudioPipelineError.fbankDimensionInvalid
        }
        var fbank80 = mat.fbank80
        let output = try await recognizeSpeakers(
            fbank80: fbank80,
            sentences: sentences,
            fallbackSegments: [],
            audioPath: audioPath,
            policy: policy,
            diagnosticsURL: diagnosticsURL,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        // D-4: recognizeSpeakers 完后立即释放 fbank80（节省 ~137MB for 1h 音频）
        fbank80 = []
        return output
    }

    func reidentifySpeakersFull(
        audioPath: String,
        sentences: [ASRSentence],
        policy: SpeakerTemporalPolicy = .production,
        onProgress: @Sendable @escaping (String, Double, String) -> Void = { _, _, _ in },
        shouldCancel: @Sendable @escaping () -> Bool = { false }
    ) async throws -> SpeakerDiarizationPipeline.Result {
        // Always-decode path (no precomputed cache): shared helper handles
        // pcm decode + fbank80 materialization + pcm release. Pass nil for
        // precomputedFbank80 so the helper takes the decode branch.
        let mat = try await loadOrDecodeFbank80(
            audioPath: audioPath,
            precomputedFbank80: nil,
            progressStart: 0.0,
            progressEnd: 1.0,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        return try await recognizeSpeakersFull(
            fbank80: mat.fbank80,
            sentences: sentences,
            audioPath: audioPath,
            policy: policy,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
    }

    func recognizeSpeakers(
        fbank80: [Float],
        sentences: [ASRSentence],
        fallbackSegments: [(startMs: Int, endMs: Int)],
        audioPath: String,
        policy: SpeakerTemporalPolicy,
        diagnosticsURL: URL? = nil,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> (utterances: [UtteranceData], speakerProfiles: [SpeakerProfileData]) {
        let result = try await recognizeSpeakersFull(
            fbank80: fbank80,
            sentences: sentences,
            audioPath: audioPath,
            policy: policy,
            diagnosticsURL: diagnosticsURL,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        return (result.utterances, result.speakerProfiles)
    }

    /// Diagnostic variant of `recognizeSpeakers` that returns the full
    /// `SpeakerDiarizationPipeline.Result` (timeline, evidence, L1/L2
    /// per-sub-sentence decisions).  Used by `BoundaryEvidenceDiagnostic`
    /// and any other test that needs per-token data.
    func recognizeSpeakersFull(
        fbank80: [Float],
        sentences: [ASRSentence],
        audioPath: String,
        policy: SpeakerTemporalPolicy,
        diagnosticsURL: URL? = nil,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> SpeakerDiarizationPipeline.Result {
        try requireReady()
        let speaker = speakerEngine!
        let result = try SpeakerDiarizationPipeline(policy: policy, clustering: clustering).run(
            fbank80: fbank80,
            sentences: sentences,
            speaker: speaker,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        SpeakerArtifactWriter.write(
            result: result, policy: policy,
            audioPath: audioPath, diagnosticsURL: diagnosticsURL
        )
        return result
    }

    /// 为一个长音频 ASR batch 独立构造官方兼容的 frontend 输入。
    ///
    /// `WavFrontend` 的 LFR 左侧填充是相对当前音频片段的首帧，而不是相对原始整段
    /// 音频的任意中间帧。**所以 `applyLFR_CMVN` 必须基于本 batch 起点的 fbank 重算**，
    /// 但 D-1 之后 raw 80 维 fbank 已整段物化，直接从 fbank80 切片即可，不必再算一次。
    /// Converts a millisecond batch range to a bounded PCM range. Kept as a
    /// pure helper so long-audio boundary behavior is unit-testable.
    static func audioSampleRange(
        startMs: Int,
        endMs: Int,
        sampleRate: Int,
        totalSamples: Int
    ) -> Range<Int>? {
        AudioPipelineUtilities.audioSampleRange(
            startMs: startMs, endMs: endMs, sampleRate: sampleRate, totalSamples: totalSamples
        )
    }

    // MARK: - 静态 utility re-exports (audit F5.5 file split, 2026-07-26)
    //
    // The 6 pure-static helpers below used to be declared as `static func`
    // on this actor (lines 813-1034, ~220 lines), but they don't touch any
    // actor-isolated state.  Moved to `AudioPipelineUtilities` enum
    // (`Sources/SwiftASR/Services/AudioPipelineUtilities.swift`) so the
    // actor file shrinks from 1035 → 815 lines.  These thin re-exports
    // keep all existing call sites (e.g. `AudioPipeline.asrBatches(...)`,
    // `AudioPipeline.relabelSpeakerLabelsByFirstOccurrence(...)`) working
    // without changes.  New code should call `AudioPipelineUtilities.X`
    // directly.
    //
    // R4-P2-4 (2026-08-05): 这些 re-export 现在标 `@available(*, deprecated)`，
    // 推动新代码直接用 `AudioPipelineUtilities`。现有 caller 暂时保留以避免
    // 大范围改动；零调用后再删除。

    @available(*, deprecated, message: "Use AudioPipelineUtilities.svChunk directly")
    static func svChunk(
        totalFrames: Int,
        segments: [(startMs: Int, endMs: Int)],
        windowSec: Double,
        shiftSec: Double
    ) -> [(startMs: Int, endMs: Int)] {
        AudioPipelineUtilities.svChunk(
            totalFrames: totalFrames, segments: segments, windowSec: windowSec, shiftSec: shiftSec
        )
    }

    @available(*, deprecated, message: "Use AudioPipelineUtilities.svChunk directly")
    static func svChunk(
        pcm: [Float],
        segments: [(startMs: Int, endMs: Int)],
        windowSec: Double,
        shiftSec: Double,
        sampleRate: Int
    ) -> [(startMs: Int, endMs: Int)] {
        AudioPipelineUtilities.svChunk(
            pcm: pcm, segments: segments, windowSec: windowSec, shiftSec: shiftSec, sampleRate: sampleRate
        )
    }

    @available(*, deprecated, message: "Use AudioPipelineUtilities.speakerChunkFromFbank80 directly")
    static func speakerChunkFromFbank80(
        fbank80: [Float],
        startMs: Int,
        endMs: Int,
        targetFrames: Int = 148
    ) -> [Float]? {
        AudioPipelineUtilities.speakerChunkFromFbank80(
            fbank80: fbank80, startMs: startMs, endMs: endMs, targetFrames: targetFrames
        )
    }

    @available(*, deprecated, message: "Use AudioPipelineUtilities.speakerReferenceSegments directly")
    static func speakerReferenceSegments(
        sentences: [ASRSentence],
        fallback: [(startMs: Int, endMs: Int)],
        totalDurationMs: Int
    ) -> [(startMs: Int, endMs: Int)] {
        AudioPipelineUtilities.speakerReferenceSegments(
            sentences: sentences, fallback: fallback, totalDurationMs: totalDurationMs
        )
    }

    @available(*, deprecated, message: "Use AudioPipelineUtilities.asrBatches directly")
    static func asrBatches(
        from segments: [(startMs: Int, endMs: Int)],
        totalDurationMs: Int,
        maxBatchMs: Int,
        minBatchMs: Int = 500,
        maxMergeGapMs: Int = 1_200,
        targetMergeDurationMs: Int = 15_000
    ) -> [(startMs: Int, endMs: Int)] {
        AudioPipelineUtilities.asrBatches(
            from: segments, totalDurationMs: totalDurationMs, maxBatchMs: maxBatchMs,
            minBatchMs: minBatchMs, maxMergeGapMs: maxMergeGapMs, targetMergeDurationMs: targetMergeDurationMs
        )
    }

    @available(*, deprecated, message: "Use AudioPipelineUtilities.relabelSpeakerLabelsByFirstOccurrence directly")
    static func relabelSpeakerLabelsByFirstOccurrence(
        labels: [Int],
        chunks: [(startMs: Int, endMs: Int)]
    ) -> [Int] {
        AudioPipelineUtilities.relabelSpeakerLabelsByFirstOccurrence(labels: labels, chunks: chunks)
    }
}
