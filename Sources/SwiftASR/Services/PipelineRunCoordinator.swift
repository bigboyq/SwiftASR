import Foundation
import SwiftData

/// Owns the complete transcription-run lifecycle.
///
/// `FileActionCoordinator` remains the observable UI façade. This coordinator
/// owns the operational boundary instead: startup recovery/model prewarming,
/// run-handle creation, event-stream consumption, durable terminal state, and
/// recovery when a runner stream ends without a terminal event.
@MainActor
final class PipelineRunCoordinator {
    private unowned let coordinator: FileActionCoordinator
    private let pipelineRunnerBuilder: FileActionCoordinator.PipelineRunnerBuilder?
    private let speakerInputWriter: FileActionCoordinator.SpeakerInputWriter
    private let startupRecovery = StartupRecoveryManager()

    init(
        coordinator: FileActionCoordinator,
        pipelineRunnerBuilder: FileActionCoordinator.PipelineRunnerBuilder?,
        speakerInputWriter: @escaping FileActionCoordinator.SpeakerInputWriter
    ) {
        self.coordinator = coordinator
        self.pipelineRunnerBuilder = pipelineRunnerBuilder
        self.speakerInputWriter = speakerInputWriter
    }

    func prewarmModelsIfNeeded() {
        startupRecovery.prewarmModelsIfNeeded()
    }

    func releasePrewarmedModels() {
        startupRecovery.releasePrewarmedModels()
    }

    @discardableResult
    func recoverStaleJobsIfNeeded(modelContext: ModelContext) throws -> Int {
        try startupRecovery.recoverStaleJobsIfNeeded(
            coordinator: coordinator, modelContext: modelContext
        )
    }

    func recoverStaleJobsInBackground(
        modelContext: ModelContext
    ) async throws -> StartupRecoverySnapshot {
        try await startupRecovery.recoverStaleJobsInBackground(
            coordinator: coordinator, modelContext: modelContext
        )
    }

    /// Public façade handoff for import, retry, retranscription, and queue
    /// auto-start paths.
    func runPipeline(jobId: String, audioPath: String, modelContext: ModelContext) {
        guard coordinator.activeRuns.isEmpty else {
            if coordinator.activeRuns[jobId] == nil {
                coordinator.reportActionError("无法启动转写：已有其他任务正在运行。")
            }
            return
        }
        guard let job = startTranscriptionRun(jobId: jobId, modelContext: modelContext) else {
            return
        }
        guard let run = coordinator.activeRuns[jobId] else {
            coordinator.reportActionError("无法启动转写：运行句柄未创建。")
            return
        }
        let task = runPipelineTask(
            jobId: jobId,
            audioPath: audioPath,
            transcriptPath: job.transcriptPath,
            modelsRoot: SettingsStore.modelsRoot,
            run: run,
            modelContext: modelContext
        )
        run.task = task
    }

    /// E-1 manual recovery for historical cancelled/failed runs.
    @discardableResult
    func persistPartialResultIfAvailable(
        job: ASRJob,
        modelContext: ModelContext
    ) -> PartialResultPersistenceOutcome {
        persistPartialResultIfAvailable(
            jobId: job.id,
            storedPath: job.transcriptPath,
            errorMessage: "Speaker 识别失败，ASR + 标点已保存（手动派生）。点 '重新识别说话人' 重试。",
            pipelineMessage: "ASR 完成，Speaker 失败",
            in: modelContext
        )
    }

    private func startTranscriptionRun(
        jobId: String,
        modelContext: ModelContext
    ) -> ASRJob? {
        let job: ASRJob?
        do {
            job = try ASRJobRepository.findById(jobId, in: modelContext)
        } catch {
            coordinator.reportActionError("无法读取待启动任务：\(error.localizedDescription)")
            return nil
        }
        guard let job else {
            coordinator.reportActionError("无法启动转写：任务不存在或已被删除。")
            return nil
        }
        do {
            try JobLifecycleStore(modelContext: modelContext).markPipelineRunning(
                job, kind: .transcription
            )
        } catch {
            coordinator.reportActionError("无法开始转写任务：\(error.localizedDescription)")
            return nil
        }

        let run = PipelineRunHandle(
            jobId: jobId,
            operationKind: .transcription,
            token: CancellationToken()
        )
        do {
            try run.start()
        } catch {
            persistPipelineFailure(error, jobId: jobId, modelContext: modelContext)
            coordinator.reportActionError("无法创建转写运行句柄：\(error.localizedDescription)")
            return nil
        }
        coordinator.activeRuns[jobId] = run
        coordinator.clearCheckedProgress(for: jobId)
        if coordinator.activeTranscriptionJobId != jobId {
            coordinator.activeStageMetrics = nil
        }
        coordinator.activeTranscriptionJobId = jobId
        coordinator.activeTranscriptionStage = "load"
        coordinator.activeTranscriptionFraction = 0
        coordinator.activeTranscriptionMessage = "加载…"
        return job
    }

    private func runPipelineTask(
        jobId: String,
        audioPath: String,
        transcriptPath: String?,
        modelsRoot: String,
        run: PipelineRunHandle,
        modelContext: ModelContext
    ) -> Task<Void, Never> {
        let eventSink = PipelineEventSink(coordinator: coordinator, modelContext: modelContext)
        let speakerInputPath = ResultStore.speakerInputPath(jobId: jobId)
        let token = run.token
        return Task { @MainActor in
            defer { token.cancel() }
            defer {
                coordinator.cleanupTranscriptionState(
                    jobId: jobId, runID: run.id, advanceQueue: true, modelContext: modelContext
                )
            }

            let runner: PipelineRunner
            do {
                if let pipelineRunnerBuilder {
                    runner = try await pipelineRunnerBuilder(jobId, modelsRoot, modelContext)
                } else {
                    runner = PipelineRunner(pipeline: try await preparedPipeline(
                        jobId: jobId, modelsRoot: modelsRoot, modelContext: modelContext
                    ))
                }
            } catch {
                guard run.claimTerminal() else { return }
                persistPipelineFailure(error, jobId: jobId, modelContext: modelContext)
                try? run.finish(.failed)
                return
            }

            var sidecarWriteError: Error?
            // Track whether the *current* run emitted its own speakerInput.
            // A stale speaker-input sidecar from a previous run must not let a
            // mid-ASR cancellation derive `.partial` from it. Only when this run
            // itself produced ASR+punc (and thus its own speakerInput) is a
            // partial result valid per spec.
            var currentRunProducedSpeakerInput = false
            for await event in runner.events(audioPath: audioPath, token: token) {
                handlePipelineEvent(
                    event,
                    jobId: jobId,
                    audioPath: audioPath,
                    transcriptPath: transcriptPath,
                    run: run,
                    eventSink: eventSink,
                    speakerInputPath: speakerInputPath,
                    speakerInputProduced: &currentRunProducedSpeakerInput,
                    sidecarWriteError: &sidecarWriteError,
                    modelContext: modelContext
                )
            }
            reconcileEndedPipelineStream(
                run: run, token: token, jobId: jobId, modelContext: modelContext
            )
        }
    }

    private func handlePipelineEvent(
        _ event: PipelineRunner.Event,
        jobId: String,
        audioPath: String,
        transcriptPath: String?,
        run: PipelineRunHandle,
        eventSink: PipelineEventSink,
        speakerInputPath: URL,
        speakerInputProduced: inout Bool,
        sidecarWriteError: inout Error?,
        modelContext: ModelContext
    ) {
        switch event {
        case let .progress(stage, fraction, message):
            applyProgress(
                stage: stage,
                fraction: fraction,
                message: message,
                jobId: jobId,
                run: run,
                eventSink: eventSink
            )
        case let .stageMetrics(stage, metrics):
            applyStageMetrics(
                stage: stage,
                metrics: metrics,
                jobId: jobId,
                run: run,
                eventSink: eventSink
            )
        case let .speakerInput(input):
            writeSpeakerInput(
                input,
                path: speakerInputPath,
                sidecarWriteError: &sidecarWriteError
            )
            speakerInputProduced = true
        case let .completed(utterances, speakerProfiles, metrics):
            handleCompleted(
                utterances: utterances,
                speakerProfiles: speakerProfiles,
                metrics: metrics,
                audioPath: audioPath,
                jobId: jobId,
                run: run,
                sidecarWriteError: sidecarWriteError,
                modelContext: modelContext
            )
        case .cancelled:
            handleCancelled(
                transcriptPath: transcriptPath,
                jobId: jobId,
                run: run,
                currentRunProducedSpeakerInput: speakerInputProduced,
                modelContext: modelContext
            )
        case let .failed(error):
            handleFailed(
                error,
                transcriptPath: transcriptPath,
                jobId: jobId,
                run: run,
                modelContext: modelContext
            )
        }
    }

    private func applyProgress(
        stage: String,
        fraction: Double,
        message: String,
        jobId: String,
        run: PipelineRunHandle,
        eventSink: PipelineEventSink
    ) {
        eventSink.applyProgress(
                jobId: jobId, runID: run.id, token: run.token,
                stage: stage, fraction: fraction, message: message
        )
    }

    private func applyStageMetrics(
        stage: String,
        metrics: PipelineStageMetrics,
        jobId: String,
        run: PipelineRunHandle,
        eventSink: PipelineEventSink
    ) {
        eventSink.applyStageMetrics(
                jobId: jobId, runID: run.id, token: run.token,
                stage: stage, metrics: metrics
        )
    }

    private func writeSpeakerInput(
        _ input: SpeakerRecognitionInput,
        path: URL,
        sidecarWriteError: inout Error?
    ) {
        do {
            try speakerInputWriter(input, path)
        } catch {
            sidecarWriteError = error
            Logger.shared.error("无法保存 speaker-input sidecar：\(error)")
        }
    }

    private func handleCompleted(
        utterances: [UtteranceData],
        speakerProfiles: [SpeakerProfileData],
        metrics: PipelineStageMetrics,
        audioPath: String,
        jobId: String,
        run: PipelineRunHandle,
        sidecarWriteError: Error?,
        modelContext: ModelContext
    ) {
        guard run.claimTerminal() else { return }
        if let sidecarWriteError {
            persistPipelineFailure(sidecarWriteError, jobId: jobId, modelContext: modelContext)
            try? run.finish(.failed)
            return
        }
        do {
            try PipelineResultPersistence.persistTranscriptionSuccess(
                jobID: jobId,
                audioPath: audioPath,
                utterances: utterances,
                speakerProfiles: speakerProfiles,
                metrics: metrics,
                modelContext: modelContext
            )
            coordinator.activeStageMetrics = metrics
            try run.finish(.completed)
        } catch {
            Logger.shared.error(
                "ASR Pipeline 结果持久化失败（jobId=\(jobId)）：\(error.localizedDescription)"
            )
            persistPipelineFailure(error, jobId: jobId, modelContext: modelContext)
            try? run.finish(.failed)
        }
    }

    private func handleCancelled(
        transcriptPath: String?,
        jobId: String,
        run: PipelineRunHandle,
        currentRunProducedSpeakerInput: Bool,
        modelContext: ModelContext
    ) {
        guard run.claimTerminal() else { return }
        // Only derive `.partial` when the *current* run produced its own
        // speakerInput (i.e. ASR+punc completed this run). Without this guard,
        // a stale speaker-input sidecar from a previous run would let a
        // mid-ASR cancellation look like a valid partial result.
        guard currentRunProducedSpeakerInput else {
            persistPipelineCancellation(jobId: jobId, modelContext: modelContext)
            try? run.finish(.cancelled)
            return
        }
        let outcome = persistPartialResultIfAvailable(
            jobId: jobId,
            storedPath: transcriptPath,
            errorMessage: "已取消。ASR + 标点已保存，Speaker 未完成。点 '重新识别说话人' 重跑。",
            pipelineMessage: "已取消（ASR 已保存）",
            in: modelContext
        )
        if outcome != .persisted {
            persistPipelineCancellation(jobId: jobId, modelContext: modelContext)
        }
        try? run.finish(.cancelled)
    }

    private func handleFailed(
        _ error: Error,
        transcriptPath: String?,
        jobId: String,
        run: PipelineRunHandle,
        modelContext: ModelContext
    ) {
        guard run.claimTerminal() else { return }
        Logger.shared.error("ASR Pipeline failed: \(error)")
        guard (error as? PipelineStageFailure)?.stage == "speaker" else {
            persistPipelineFailure(error, jobId: jobId, modelContext: modelContext)
            try? run.finish(.failed)
            return
        }
        let errPrefix = error.localizedDescription.prefix(80)
        let outcome = persistPartialResultIfAvailable(
            jobId: jobId,
            storedPath: transcriptPath,
            errorMessage: "Speaker 识别失败（\(errPrefix)），ASR + 标点已保存。点 '重新识别说话人' 重试。",
            pipelineMessage: "ASR 完成，Speaker 失败",
            in: modelContext
        )
        if outcome != .persisted {
            persistPipelineFailure(error, jobId: jobId, modelContext: modelContext)
        }
        try? run.finish(.failed)
    }

    private func reconcileEndedPipelineStream(
        run: PipelineRunHandle,
        token: CancellationToken,
        jobId: String,
        modelContext: ModelContext
    ) {
        // `claimTerminal()` 内部已经检查 `!terminalClaimed`，这里不用再
        // 单独 guard。`terminalClaimed` 字段外部不可见，唯一能 claim 的
        // 路径就是本函数 / `handlePipelineEvent` 两个；两者由同一 actor
        // 串行。
        guard run.claimTerminal() else { return }
        let terminal = PipelineRunLifecycle.terminalForEndedEventStream(
            taskCancelled: Task.isCancelled,
            tokenCancelled: token.isCancelled
        )
        switch terminal {
        case .cancelled:
            persistPipelineCancellation(jobId: jobId, modelContext: modelContext)
        case .failed:
            let error = NSError(
                domain: "PipelineRunner",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Pipeline event stream unexpectedly ended before a terminal event."]
            )
            Logger.shared.error(error.localizedDescription)
            persistPipelineFailure(error, jobId: jobId, modelContext: modelContext)
        case .completed:
            break
        }
        try? run.finish(terminal)
    }

    private func persistPartialResultIfAvailable(
        jobId: String,
        storedPath: String?,
        errorMessage: String,
        pipelineMessage: String,
        in modelContext: ModelContext
    ) -> PartialResultPersistenceOutcome {
        guard let speakerInputPath = ResultStore.locateSpeakerInputPath(
            jobId: jobId, storedPath: storedPath
        ), let input = try? ResultStore.readSpeakerInput(from: speakerInputPath) else {
            return .unavailable
        }
        return PartialResultPersister().persist(
            input: input,
            jobId: jobId,
            storedPath: storedPath,
            errorMessage: errorMessage,
            pipelineMessage: pipelineMessage,
            modelContext: modelContext
        )
    }

    private func persistPipelineFailure(
        _ error: Error,
        jobId: String,
        modelContext: ModelContext
    ) {
        swallowAndLog("无法持久化任务失败状态") {
            try applyPipelineTerminal(jobId: jobId, error: error, in: modelContext)
        }
    }

    private func persistPipelineCancellation(jobId: String, modelContext: ModelContext) {
        swallowAndLog("无法持久化任务取消状态") {
            try applyPipelineTerminal(jobId: jobId, error: nil, in: modelContext)
        }
    }

    private func applyPipelineTerminal(
        jobId: String,
        error: Error?,
        in modelContext: ModelContext
    ) throws {
        let isCancelled = error == nil
        guard let job = try ASRJobRepository.findById(jobId, in: modelContext) else { return }
        let errorMessage = error?.localizedDescription
        try JobLifecycleStore(modelContext: modelContext).finishPipeline(
            job,
            status: isCancelled ? .cancelled : .failed,
            pipelineStage: isCancelled ? "cancelled" : "failed",
            pipelineFraction: 0,
            pipelineMessage: isCancelled
                ? "已取消"
                : "失败：\(errorMessage?.prefix(80) ?? "未知错误")",
            errorMessage: errorMessage,
            finishedAt: nil,
            operationKind: .transcription,
            operationStatus: isCancelled ? .cancelled : .failed,
            operationMessage: isCancelled ? "转写已取消" : errorMessage,
            save: true
        )
    }

    func preparedPipeline(
        jobId: String,
        modelsRoot: String,
        modelContext: ModelContext
    ) async throws -> AudioPipeline {
        let message: String?
        switch startupRecovery.prewarmedPipelines.readiness(for: modelsRoot) {
        case .idle:
            message = "正在后台预热转写模型…"
        case .warming:
            message = "正在等待转写模型预热完成…"
        case .ready:
            message = nil
        }
        if let message {
            coordinator.activeTranscriptionStage = "load"
            coordinator.activeTranscriptionFraction = 0
            coordinator.activeTranscriptionMessage = message
            if let job = try ASRJobRepository.findById(jobId, in: modelContext) {
                do {
                    try JobLifecycleStore(modelContext: modelContext).updatePipelineProgress(
                        job, stage: "load", fraction: 0, message: message
                    )
                } catch {
                    Logger.shared.error("保存模型预热进度失败：\(error)")
                }
            }
        }
        return try await startupRecovery.prewarmedPipelines.acquire(modelsRoot: modelsRoot)
    }

    private func swallowAndLog(_ label: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            Logger.shared.error("\(label)：\(error)")
        }
    }
}
