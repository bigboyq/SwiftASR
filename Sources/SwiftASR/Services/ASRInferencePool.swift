import Foundation

/// Owns the dual-session ASR inference stage.
///
/// The pool preserves the existing two-worker concurrency and bounded channel:
/// VAD remains the only producer, each batch is consumed once, and a failed
/// worker closes the channel so the whole pipeline fails instead of silently
/// dropping a batch.
struct ASRInferencePool {
    static func run(
        fbank80: [Float],
        engines: [ASRONNXEngine],
        decoder: ASRDecoder,
        frontend: ASRFrontend,
        channel: AudioPipeline.StreamingASRBatchChannel,
        progress: AudioPipeline.StreamingASRProgress,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> [AudioPipeline.ASRWorkerMetrics] {
        try await withThrowingTaskGroup(of: AudioPipeline.ASRWorkerMetrics.self) { group in
            for engine in engines {
                group.addTask {
                    let localExtractor = FbankExtractor()
                    var sentences: [ASRSentence] = []
                    var frontendSeconds = 0.0
                    var inferenceSeconds = 0.0
                    var inputPreparationSeconds = 0.0
                    var sessionRunSeconds = 0.0
                    var outputMaterializationSeconds = 0.0
                    var decodeSeconds = 0.0
                    var batchCount = 0
                    do {
                        while let batch = await channel.next() {
                            if shouldCancel() { throw PipelineCancelled(stage: "asr") }
                            batchCount += 1
                            let frontendStartedAt = Date()
                            guard let input = frontend.makeInput(
                                fbank80: fbank80,
                                batch: (startMs: batch.startMs, endMs: batch.endMs),
                                extractor: localExtractor
                            ) else {
                                frontendSeconds += Date().timeIntervalSince(frontendStartedAt)
                                throw AudioPipeline.ASRBatchFailure.frontendUnavailable(
                                    ordinal: batch.ordinal, startMs: batch.startMs, endMs: batch.endMs
                                )
                            }
                            frontendSeconds += Date().timeIntervalSince(frontendStartedAt)

                            do {
                                let inferenceStartedAt = Date()
                                let output = try engine.infer(
                                    fbankFeatures: input.features,
                                    seqLen: input.seqLen
                                )
                                inferenceSeconds += Date().timeIntervalSince(inferenceStartedAt)
                                inputPreparationSeconds += output.inputPreparationSeconds
                                sessionRunSeconds += output.sessionRunSeconds
                                outputMaterializationSeconds += output.outputMaterializationSeconds

                                let decodeStartedAt = Date()
                                let partial = try decoder.decode(output: output, seqLen: input.seqLen)
                                decodeSeconds += Date().timeIntervalSince(decodeStartedAt)
                                sentences.append(contentsOf: AudioPipeline.offsetAndTrimASRSentences(
                                    partial.sentences,
                                    by: batch.startMs,
                                    ownershipRangesMs: batch.ownershipRangesMs
                                ))
                            } catch {
                                throw AudioPipeline.ASRBatchFailure.inferenceFailed(
                                    ordinal: batch.ordinal,
                                    startMs: batch.startMs,
                                    endMs: batch.endMs,
                                    message: error.localizedDescription
                                )
                            }
                            await progress.incrementCompleted(batch)
                        }
                    } catch {
                        await channel.finish()
                        throw error
                    }
                    return AudioPipeline.ASRWorkerMetrics(
                        sentences: sentences,
                        frontendSeconds: frontendSeconds,
                        inferenceSeconds: inferenceSeconds,
                        inputPreparationSeconds: inputPreparationSeconds,
                        sessionRunSeconds: sessionRunSeconds,
                        outputMaterializationSeconds: outputMaterializationSeconds,
                        decodeSeconds: decodeSeconds,
                        batchCount: batchCount
                    )
                }
            }

            var results: [AudioPipeline.ASRWorkerMetrics] = []
            for try await result in group { results.append(result) }
            return results
        }
    }
}
