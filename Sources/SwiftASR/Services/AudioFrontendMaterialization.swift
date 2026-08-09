import Foundation
import os

/// The result of the one full-audio fbank materialisation pass.
///
/// PCM is intentionally not owned here. Callers release their local PCM
/// buffer immediately after receiving this result, while retaining exactly
/// one full fbank80 copy for VAD, ASR, and speaker reconstruction.
struct AudioFrontendMaterialization: Sendable {
    let fbank80: [Float]
    let frameCount: Int
    let elapsedSeconds: Double
    let workerCount: Int
}

extension AudioPipeline {
    /// Materialises the full fbank80 matrix and owns the shared progress
    /// polling behavior used by the main pipeline and speaker reidentify.
    ///
    /// `workerCount` is optional so the caller can choose either an explicit
    /// route or FbankExtractor's adaptive policy. The first migration keeps
    /// the existing explicit route; the next cleanup can switch both callers
    /// to nil without duplicating this orchestration again.
    func materializeFbank(
        pcm: [Float],
        workerCount: Int?,
        progressStart: Double,
        progressEnd: Double,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> AudioFrontendMaterialization {
        if shouldCancel() || Task.isCancelled {
            throw PipelineCancelled(stage: "load")
        }
        let totalFramesForProgress = extractor.frameCount(pcmData: pcm)
        let frameCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
        // 进度轮询 task 不需要跑在 @MainActor：闭包内只读
        // `frameCounter.withLock { $0 }` (OSAllocatedUnfairLock 已是 thread-safe)
        // 调 `@Sendable` 的 onProgress 闭包（UI 层会自己 hop 回主 actor）。
        // 原来 `@MainActor` 注解让每秒 1 次循环白白占用主线程，长音频 fbank
        // 阶段（30-60s）累计 30-60 次 main hop。round-3 M2-N3 改回 cooperative pool。
        let pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                let done = frameCounter.withLock { $0 }
                let fraction = progressStart + (progressEnd - progressStart)
                    * min(1.0, Double(done) / Double(max(1, totalFramesForProgress)))
                onProgress("load", fraction, "提取声学特征… \(done)/\(totalFramesForProgress) 帧")
            }
        }

        let startedAt = Date()
        let fbank80: [Float]
        do {
            fbank80 = try extractor.extractFbankCancellable(
                pcmData: pcm,
                workerCount: workerCount,
                reportEveryN: 1000,
                onFrameProcessed: { frames in
                    frameCounter.withLock { $0 += frames }
                },
                shouldCancel: { shouldCancel() || Task.isCancelled }
            )
        } catch FbankExtractionError.cancelled {
            pollingTask.cancel()
            throw PipelineCancelled(stage: "load")
        } catch {
            pollingTask.cancel()
            throw error
        }
        pollingTask.cancel()

        let frameCount = fbank80.count / AudioTimebase.standard.featureDimension
        let selectedWorkers = workerCount ?? extractor.effectiveWorkerCount(pcmData: pcm)
        let actualWorkers = min(max(1, selectedWorkers), max(1, totalFramesForProgress))
        return AudioFrontendMaterialization(
            fbank80: fbank80,
            frameCount: frameCount,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            workerCount: actualWorkers
        )
    }

    /// Result of `loadOrDecodeFbank80`. `fbank80` is the ready-to-use 80-dim
    /// feature matrix (either from cache or freshly materialized).
    /// `fromCache=true` means pcm decode + fbank extraction were both skipped.
    struct FbankMaterialization: Sendable {
        let fbank80: [Float]
        let frameCount: Int
        let pcmSeconds: Double
        let fbankSeconds: Double
        let workerCount: Int
        let fromCache: Bool
    }

    /// Cache-aware fbank80 acquisition shared by `reidentifySpeakers` and
    /// `reidentifySpeakersFull`. When `precomputedFbank80` is non-empty,
    /// pcm decode + fbank extraction are both skipped (saves ~几秒 for 1h
    /// audio on the rerun path). Otherwise pcm is decoded and released
    /// after fbank80 materialization (~425MB peak memory saved for 1h audio).
    ///
    /// `progressStart` / `progressEnd` map the decode + extract steps to
    /// the `load` stage fraction band [start, end] (e.g. 0.6 ... 1.0 in
    /// the rerun path, 0.0 ... 1.0 in the always-decode full path).
    /// The cache path emits a single `load=end` progress event.
    func loadOrDecodeFbank80(
        audioPath: String,
        precomputedFbank80: [Float]?,
        progressStart: Double,
        progressEnd: Double,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> FbankMaterialization {
        if let precomputedFbank80, !precomputedFbank80.isEmpty {
            let fbank80 = precomputedFbank80
            onProgress("load", progressEnd, "声学特征已缓存 (\(fbank80.count / 80) 帧)")
            return FbankMaterialization(
                fbank80: fbank80,
                frameCount: fbank80.count / AudioTimebase.standard.featureDimension,
                pcmSeconds: 0,
                fbankSeconds: 0,
                workerCount: 0,
                fromCache: true
            )
        }
        onProgress("load", progressStart, "解码音频…")
        let pcmStartedAt = Date()
        var pcm: [Float]
        do {
            pcm = try converter.loadAndResample(
                path: audioPath,
                shouldCancel: { shouldCancel() || Task.isCancelled }
            )
        } catch AudioConverterError.cancelled {
            throw PipelineCancelled(stage: "load")
        }
        let pcmSeconds = Date().timeIntervalSince(pcmStartedAt)
        guard extractor.frameCount(pcmData: pcm) > 0 else {
            throw AudioPipelineError.fbankEmpty
        }
        let decodeFraction = progressStart + (progressEnd - progressStart) * 0.4
        onProgress(
            "load",
            decodeFraction,
            "音频解码完成 (\(String(format: "%.1f", Double(pcm.count) / 16000))s)"
        )
        let extractStart = decodeFraction
        onProgress("load", extractStart, "提取声学特征…")
        let materialized = try await materializeFbank(
            pcm: pcm,
            workerCount: nil,
            progressStart: extractStart,
            progressEnd: progressEnd,
            onProgress: onProgress,
            shouldCancel: shouldCancel
        )
        // Release pcm buffer now that fbank80 is materialized (D-4: 1h
        // audio pcm ≈ 288MB, save by clearing before speaker recognition).
        pcm = []
        return FbankMaterialization(
            fbank80: materialized.fbank80,
            frameCount: materialized.frameCount,
            pcmSeconds: pcmSeconds,
            fbankSeconds: materialized.elapsedSeconds,
            workerCount: materialized.workerCount,
            fromCache: false
        )
    }
}
