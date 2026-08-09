import Foundation

struct PipelineRunnerOutput: Sendable {
    let utterances: [UtteranceData]
    let speakerProfiles: [SpeakerProfileData]
    let metrics: PipelineStageMetrics
}

typealias PipelineRunnerOperation = @Sendable (
    String,
    @escaping @Sendable (String, Double, String) -> Void,
    @escaping @Sendable () -> Bool,
    @escaping @Sendable (SpeakerRecognitionInput) -> Void,
    @escaping @Sendable (String, PipelineStageMetrics) -> Void
) async throws -> PipelineRunnerOutput

/// Pipeline 与 UI/lifecycle 之间的事件边界。runner 不接触 SwiftData 或 SwiftUI，
/// 只把底层 pipeline 的回调归一为单个 AsyncStream。
@MainActor
final class PipelineRunner {
    enum Event {
        case progress(stage: String, fraction: Double, message: String)
        case stageMetrics(stage: String, metrics: PipelineStageMetrics)
        case speakerInput(SpeakerRecognitionInput)
        case completed(utterances: [UtteranceData], profiles: [SpeakerProfileData], metrics: PipelineStageMetrics)
        case cancelled
        case failed(Error)
    }

    private let operation: PipelineRunnerOperation

    init(pipeline: AudioPipeline) {
        self.operation = { audioPath, onProgress, shouldCancel, onSpeakerInput, onStageComplete in
            let output = try await pipeline.runPipelineWithProfiles(
                audioPath: audioPath,
                onProgress: onProgress,
                shouldCancel: shouldCancel,
                onSpeakerInput: onSpeakerInput,
                onStageComplete: onStageComplete
            )
            return PipelineRunnerOutput(
                utterances: output.utterances,
                speakerProfiles: output.speakerProfiles,
                metrics: output.metrics
            )
        }
    }

    /// Test and diagnostic injection point. Production callers use the
    /// pipeline-backed initializer above; keeping this overload avoids making
    /// lifecycle tests construct heavyweight model engines.
    init(operation: @escaping PipelineRunnerOperation) {
        self.operation = operation
    }

    func events(audioPath: String, token: CancellationToken) -> AsyncStream<Event> {
        AsyncStream { continuation in
            // `Task` 是由 AsyncStream 建立的非结构化 producer；若 consumer 因视图
            // 销毁、外层 task 取消或提前结束迭代而消失，必须反向取消它。否则 pipeline
            // 会继续占用模型 session，下一条队列任务可能在 UI 已停止等待后启动。
            let producer = Task { @MainActor [operation, token] in
                defer { continuation.finish() }
                do {
                    let output = try await operation(
                        audioPath,
                        { stage, fraction, message in
                            continuation.yield(.progress(stage: stage, fraction: fraction, message: message))
                        },
                        { token.isCancelled },
                        { input in
                            continuation.yield(.speakerInput(input))
                        },
                        { stage, metrics in
                            continuation.yield(.stageMetrics(stage: stage, metrics: metrics))
                        }
                    )
                    continuation.yield(.completed(
                        utterances: output.utterances,
                        profiles: output.speakerProfiles,
                        metrics: output.metrics
                    ))
                } catch is PipelineCancelled {
                    continuation.yield(.cancelled)
                } catch {
                    continuation.yield(.failed(error))
                }
            }
            continuation.onTermination = { @Sendable _ in
                token.cancel()
                producer.cancel()
            }
        }
    }
}
