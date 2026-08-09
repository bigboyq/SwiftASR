import Foundation
import Dispatch

/// Speaker embedding 的两段式工作：并发准备固定窗口特征，再按模型 batch 推理。
extension AudioPipeline {
    /// Token-packed primary pass. Features are materialised only for the
    /// already-pruned production windows and submitted in one global batch
    /// sequence, so only its final model batch needs padding.
    static func extractPackedSpeakerEmbeddings(
        fbank80: [Float],
        windows: [TokenPackedWindowPlanner.Window],
        speaker: SpeakerNativeCoreMLEngine,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) throws -> SpeakerEmbeddingExtraction {
        let preparationStartedAt = Date()
        let features = try preparePackedSpeakerFeatures(
            fbank80: fbank80, windows: windows, shouldCancel: shouldCancel
        )
        onProgress("speaker", 0.20, "准备声纹特征完成 (\(windows.count) 个窗口)")
        let preparationSeconds = Date().timeIntervalSince(preparationStartedAt)
        let inferenceStartedAt = Date()
        // Speaker embedding 推理是 speaker 阶段耗时主体 (30s+ for 1h 音频),
        // 占整体 pipeline 20%→80% 预算 (留 15% 给 clustering, 5% 给 viterbi/build)。
        let embeddingStart = 0.20
        let embeddingEnd = 0.80
        let embeddings = try speaker.extractEmbeddings(
            fbankFeatures: features,
            seqLen: TokenPackedWindowPlanner.capacityFrames,
            checkCancellation: {
                if shouldCancel() { throw PipelineCancelled(stage: "speaker") }
            },
            onProgress: { fraction, completed, total in
                let stageFraction = embeddingStart + (embeddingEnd - embeddingStart) * fraction
                onProgress("speaker", stageFraction, "提取声纹中 (\(completed)/\(total))")
            }
        ).flatMap { $0 }
        onProgress("speaker", embeddingEnd, "声纹提取完成")
        let inferenceSeconds = Date().timeIntervalSince(inferenceStartedAt)
        let batchCount = Int(ceil(Double(windows.count) / Double(speaker.batchSize)))
        Logger.shared.info(
            "Speaker embedding timing: windows=\(windows.count), batches=\(batchCount), " +
            "prepare=\(String(format: "%.2f", preparationSeconds))s, " +
            "inference=\(String(format: "%.2f", inferenceSeconds))s"
        )
        return SpeakerEmbeddingExtraction(
            embeddings: embeddings,
            timing: SpeakerEmbeddingTiming(
                preparationSeconds: preparationSeconds,
                inferenceSeconds: inferenceSeconds,
                preparedCount: windows.count,
                batchCount: batchCount
            )
        )
    }

}

extension AudioPipeline {
    /// Window materialisation and mean normalisation are independent.  Bound
    /// parallelism to performance cores rather than spawning one task per
    /// window; the latter previously caused long-audio scheduler starvation.
    static func preparePackedSpeakerFeatures(
        fbank80: [Float],
        windows: [TokenPackedWindowPlanner.Window],
        shouldCancel: @Sendable @escaping () -> Bool,
        workerCount: Int? = nil
    ) throws -> [[Float]] {
        let workerCount = min(workerCount ?? ComputeConcurrency.performanceCoreCount, windows.count)
        guard workerCount > 1, windows.count >= workerCount * 4 else {
            return try windows.map { window in
                if shouldCancel() { throw PipelineCancelled(stage: "speaker") }
                return SpeakerProfileBuilder.speakerMeanNormalize(
                    try TokenPackedWindowPlanner.materialize(window: window, from: fbank80),
                    featureDim: 80
                )
            }
        }

        let storage = PackedSpeakerFeatureStorage()
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            var partial: [(Int, [Float])] = []
            for index in stride(from: worker, to: windows.count, by: workerCount) {
                if shouldCancel() {
                    storage.record(PipelineCancelled(stage: "speaker"))
                    break
                }
                do {
                    let values = SpeakerProfileBuilder.speakerMeanNormalize(
                        try TokenPackedWindowPlanner.materialize(window: windows[index], from: fbank80),
                        featureDim: 80
                    )
                    partial.append((index, values))
                } catch {
                    storage.record(error)
                    break
                }
            }
            storage.append(partial)
        }
        if let error = storage.failure { throw error }
        return try storage.ordered(windowCount: windows.count)
    }
}

private final class PackedSpeakerFeatureStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var partials: [[(Int, [Float])]] = []
    private(set) var failure: Error?

    func append(_ partial: [(Int, [Float])]) {
        lock.lock()
        partials.append(partial)
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    func ordered(windowCount: Int) throws -> [[Float]] {
        lock.lock()
        let values = partials.flatMap { $0 }
        lock.unlock()
        guard values.count == windowCount else {
            throw AudioPipelineError.speakerFeatureWindowCountMismatch(
                found: values.count, expected: windowCount
            )
        }
        return values.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
