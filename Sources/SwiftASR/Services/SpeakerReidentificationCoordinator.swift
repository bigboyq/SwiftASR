import Foundation
import SwiftData

/// User-visible prerequisite failures for speaker-only reidentification.
/// Keeping the wording classification separate from AppKit presentation makes
/// filesystem and validation failures observable instead of silently ignored.
enum ReidentificationPrecheckFailure: Equatable {
    case unsupportedStatus
    case resultMissing
    case resultUnreadable
    case noTranscriptSegments
    case speakerInputMissing
    case speakerInputUnreadable

    var alertTitle: String {
        switch self {
        case .unsupportedStatus: return "当前任务不能重新识别说话人"
        case .resultMissing: return "找不到转写结果"
        case .resultUnreadable: return "转写结果无法读取"
        case .noTranscriptSegments: return "转写结果没有可识别的内容"
        case .speakerInputMissing: return "需要重新转写一次"
        case .speakerInputUnreadable: return "说话人重识别数据无法读取"
        }
    }

    func alertMessage(detail: String? = nil) -> String {
        switch self {
        case .unsupportedStatus:
            return "请先完成转写，或在已有 ASR 结果的失败任务中重新尝试。"
        case .resultMissing:
            return "此任务没有可读取的 result.json。请先重新转写。"
        case .resultUnreadable:
            return "result.json 已损坏或与当前任务不匹配。请重新转写。" + detailSuffix(detail)
        case .noTranscriptSegments:
            return "result.json 不包含可用于说话人识别的转写片段。请重新转写。"
        case .speakerInputMissing:
            return "此历史任务没有保存说话人重识别所需的 ASR 时间轴。重新转写一次后，后续可直接重新识别说话人，无需再次运行 ASR。"
        case .speakerInputUnreadable:
            return "speaker-input.json 已损坏，无法安全重建说话人分段。请重新转写。" + detailSuffix(detail)
        }
    }

    private func detailSuffix(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        return "（\(detail)）"
    }
}

/// Owns the complete speaker-only rerun: prerequisite validation, the
/// pipeline task, result transaction, and restoring the original result after
/// cancellation or failure. `FileActionCoordinator` remains the owner of
/// shared pipeline state and queue scheduling, but no longer contains this
/// feature's branching lifecycle.
@MainActor
final class SpeakerReidentificationCoordinator {
    private unowned let fileActions: FileActionCoordinator
    private unowned let pipelineRuns: PipelineRunCoordinator

    init(fileActions: FileActionCoordinator, pipelineRuns: PipelineRunCoordinator) {
        self.fileActions = fileActions
        self.pipelineRuns = pipelineRuns
    }

    /// Re-runs only speaker diarization against the persisted ASR result.
    /// Transcript text and cleaned_text are retained; speaker names and local
    /// speaker profiles are replaced because their labels are no longer valid.
    func reidentifySpeakers(job: ASRJob, modelContext: ModelContext) {
        guard precheck(job: job) != nil else { return }
        fileActions.enqueueQueuedOperation(
            job: job,
            operation: .speakerReidentification,
            modelContext: modelContext
        )
    }

    /// Starts a queued speaker-only rerun after re-reading its persisted
    /// speaker input. The original terminal state is restored if startup
    /// validation fails before a pipeline run exists.
    func startQueuedReidentification(job: ASRJob, modelContext: ModelContext) {
        guard job.jobStatus == .queued, job.queuedOperation == .speakerReidentification else { return }
        let originalStatus = job.queuedRestoreJobStatus ?? .done
        let originalFinishedAt = job.queuedRestoreFinishedAt
        guard let inputs = loadInputsForQueuedJob(job) else {
            restoreQueuedJob(
                job,
                status: originalStatus,
                finishedAt: originalFinishedAt,
                message: "排队的说话人重新识别无法启动，已保留原结果",
                error: "说话人重识别所需的数据无法读取",
                modelContext: modelContext
            )
            return
        }
        guard let run = startRun(
            job: job,
            originalStatus: originalStatus,
            originalFinishedAt: originalFinishedAt,
            modelContext: modelContext
        ) else { return }
        fileActions.activeRuns[job.id] = run
        run.task = makeTask(
            jobId: job.id,
            modelContext: modelContext,
            inputs: inputs,
            audioPath: job.sourceAudioPath,
            originalStatus: originalStatus,
            originalFinishedAt: originalFinishedAt,
            run: run
        )
    }

    /// Validates every persisted artifact before asking for confirmation.
    /// Returning nil means the user was told what needs repairing, or chose
    /// not to start the destructive speaker-layer replacement.
    private func precheck(job: ASRJob) -> Inputs? {
        guard [.done, .partial, .failed].contains(job.jobStatus) else {
            showPrecheckFailure(.unsupportedStatus)
            return nil
        }
        let inputs: Inputs
        switch loadPersistedInputs(for: job) {
        case let .success(value):
            inputs = value
        case let .failure(failure, detail):
            showPrecheckFailure(failure, detail: detail)
            return nil
        }
        guard AlertHelper.confirm(
            title: "重新识别说话人",
            message: "将按新的说话人边界重建原始分段并清除润色结果。已有声纹库不会被删除；新 profile 会重新匹配到库。",
            confirmTitle: "重新识别"
        ) else { return nil }

        return inputs
    }

    private func loadInputsForQueuedJob(_ job: ASRJob) -> Inputs? {
        guard case let .success(inputs) = loadPersistedInputs(for: job) else { return nil }
        return inputs
    }

    private enum PersistedInputLoadResult {
        case success(Inputs)
        case failure(ReidentificationPrecheckFailure, detail: String?)
    }

    /// Reads and validates the result + speaker-input pair once. Interactive
    /// preflight maps the typed failure to a precise alert; queued execution
    /// intentionally treats every failure as a startup rollback.
    private func loadPersistedInputs(for job: ASRJob) -> PersistedInputLoadResult {
        let resultPath: URL
        do {
            resultPath = try ResultStore.readPath(jobId: job.id, storedPath: job.transcriptPath)
        } catch {
            return .failure(.resultMissing, detail: nil)
        }

        let payload: ResultPayload
        do {
            payload = try ResultStore.read(from: resultPath)
            try payload.validate(expectedJobID: job.id)
        } catch {
            return .failure(.resultUnreadable, detail: error.localizedDescription)
        }
        guard !payload.segments.isEmpty else {
            return .failure(.noTranscriptSegments, detail: nil)
        }
        guard let inputPath = ResultStore.locateSpeakerInputPath(
            jobId: job.id, storedPath: resultPath.path
        ) else {
            return .failure(.speakerInputMissing, detail: nil)
        }
        do {
            let speakerInput = try ResultStore.readSpeakerInput(from: inputPath)
            return .success(Inputs(resultPath: resultPath, payload: payload, speakerInput: speakerInput))
        } catch {
            return .failure(.speakerInputUnreadable, detail: error.localizedDescription)
        }
    }

    private func restoreQueuedJob(
        _ job: ASRJob,
        status: JobStatus,
        finishedAt: Date?,
        message: String,
        error: String,
        modelContext: ModelContext
    ) {
        do {
            job.jobStatus = status
            job.finishedAt = finishedAt
            job.pipelineStage = status == .partial ? "speaker_failed" : "done"
            job.pipelineFraction = status == .partial ? job.pipelineFraction : 1.0
            job.pipelineMessage = message
            job.errorMessage = error
            job.queuedOperationKind = nil
            job.queuedRestoreStatus = nil
            job.queuedRestoreFinishedAt = nil
            try JobLifecycleStore(modelContext: modelContext).recordOperation(
                kind: .speakerReidentification,
                status: .failed,
                message: error,
                for: job
            )
            fileActions.startNextQueuedJobIfPossible(modelContext: modelContext)
        } catch {
            fileActions.reportActionError("无法恢复排队任务状态：\(error.localizedDescription)")
        }
    }

    private func showPrecheckFailure(
        _ failure: ReidentificationPrecheckFailure,
        detail: String? = nil
    ) {
        AlertHelper.showInfo(title: failure.alertTitle, message: failure.alertMessage(detail: detail))
    }

    private func startRun(
        job: ASRJob,
        originalStatus: JobStatus,
        originalFinishedAt: Date?,
        modelContext: ModelContext
    ) -> PipelineRunHandle? {
        let jobId = job.id
        let token = CancellationToken()
        fileActions.activeTranscriptionJobId = jobId
        fileActions.activeTranscriptionStage = "speaker"
        fileActions.activeTranscriptionFraction = 0
        fileActions.activeTranscriptionMessage = "重新识别说话人…"
        do {
            try JobLifecycleStore(modelContext: modelContext)
                .markPipelineRunning(job, kind: .speakerReidentification)
        } catch {
            Logger.shared.error("无法开始说话人重新识别：\(error)")
            fileActions.activeTranscriptionJobId = nil
            fileActions.activeTranscriptionStage = ""
            fileActions.activeTranscriptionFraction = 0
            fileActions.activeTranscriptionMessage = ""
            return nil
        }

        let run = PipelineRunHandle(
            jobId: jobId,
            operationKind: .speakerReidentification,
            token: token
        )
        do {
            try run.start()
            return run
        } catch {
            Logger.shared.error("无法创建说话人重新识别运行句柄：\(error)")
            persistRestoredJob(
                jobId: jobId,
                restoredStatus: originalStatus,
                restoredFinishedAt: originalFinishedAt,
                message: "无法启动重新识别，已保留原结果",
                operationError: error.localizedDescription,
                operationStatus: .failed,
                modelContext: modelContext
            )
            fileActions.activeTranscriptionJobId = nil
            fileActions.activeTranscriptionStage = ""
            fileActions.activeTranscriptionFraction = 0
            fileActions.activeTranscriptionMessage = ""
            return nil
        }
    }

    private func makeTask(
        jobId: String,
        modelContext: ModelContext,
        inputs: Inputs,
        audioPath: String,
        originalStatus: JobStatus,
        originalFinishedAt: Date?,
        run: PipelineRunHandle
    ) -> Task<Void, Never> {
        let eventSink = PipelineEventSink(coordinator: fileActions, modelContext: modelContext)
        return Task { @MainActor [self] in
            defer {
                if !run.terminalClaimed {
                    _ = run.claimTerminal()
                    persistRestoredJob(
                        jobId: jobId,
                        restoredStatus: originalStatus,
                        restoredFinishedAt: originalFinishedAt,
                        message: "重新识别中断，已保留原结果",
                        operationError: "说话人重新识别未完成",
                        operationStatus: .failed,
                        modelContext: modelContext
                    )
                    try? run.finish(.failed)
                }
                fileActions.cleanupTranscriptionState(
                    jobId: jobId, runID: run.id, advanceQueue: true, modelContext: modelContext
                )
            }
            do {
                let pipeline = try await pipelineRuns.preparedPipeline(
                    jobId: jobId,
                    modelsRoot: SettingsStore.modelsRoot,
                    modelContext: modelContext
                )
                let speakerStartedAt = Date()
                let (utterances, profiles) = try await pipeline.reidentifySpeakers(
                    audioPath: audioPath,
                    sentences: inputs.speakerInput.sentences,
                    onProgress: { [token = run.token, eventSink, runID = run.id] stage, fraction, message in
                        Task { @MainActor in
                            eventSink.applyProgress(
                                jobId: jobId, runID: runID, token: token, stage: stage,
                                fraction: fraction, message: message
                            )
                        }
                    },
                    shouldCancel: { [token = run.token] in token.isCancelled }
                )
                guard inputs.payload.replaceSegmentsWithSpeakerTurns(from: utterances) else {
                    throw NSError(
                        domain: "SpeakerReidentificationCoordinator",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Speaker pass text differs from the existing ASR result; existing result was left untouched."]
                    )
                }
                guard run.claimTerminal() else { return }
                guard let currentJob = try ASRJobRepository.findById(jobId, in: modelContext) else {
                    throw NSError(
                        domain: "SpeakerReidentificationCoordinator",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "找不到正在重新识别的任务。"]
                    )
                }
                try persistSuccess(
                    inputs: inputs,
                    profiles: profiles,
                    currentJob: currentJob,
                    speakerStartedAt: speakerStartedAt,
                    modelContext: modelContext
                )
                try run.finish(.completed)
            } catch is PipelineCancelled {
                _ = run.claimTerminal()
                persistRestoredJob(
                    jobId: jobId,
                    restoredStatus: originalStatus,
                    restoredFinishedAt: originalFinishedAt,
                    message: "已取消重新识别",
                    operationError: nil,
                    operationStatus: .cancelled,
                    modelContext: modelContext
                )
                try? run.finish(.cancelled)
            } catch {
                Logger.shared.error("Speaker re-identification failed: \(error)")
                _ = run.claimTerminal()
                persistRestoredJob(
                    jobId: jobId,
                    restoredStatus: originalStatus,
                    restoredFinishedAt: originalFinishedAt,
                    message: "重新识别失败：\(error.localizedDescription.prefix(80))",
                    operationError: error.localizedDescription,
                    operationStatus: .failed,
                    modelContext: modelContext
                )
                try? run.finish(.failed)
            }
        }
    }

    private func persistSuccess(
        inputs: Inputs,
        profiles: [SpeakerProfileData],
        currentJob: ASRJob,
        speakerStartedAt: Date,
        modelContext: ModelContext
    ) throws {
        let profileResolution = try PipelineResultPersistence.prepareSpeakerProfileResolution(
            profiles, modelContext: modelContext
        )
        let profileIDs = profileResolution.ids
        let fingerprintIDs = PipelineResultPersistence.outputFingerprintIDs(profiles)
        inputs.payload.speakers = PipelineResultPersistence.makeSpeakers(
            labels: inputs.payload.segments.map(\.speakerLabel).uniqueElements(),
            fingerprintIDs: fingerprintIDs,
            profileIDs: profileIDs
        )
        let transaction = try ResultWriteTransaction(payload: inputs.payload, to: inputs.resultPath)
        let previousResultTransactionID = currentJob.resultTransactionID
        do {
            try SpeakerProfileOccurrenceStore.apply(
                profiles, profileIDs: profileResolution.ids, job: currentJob, modelContext: modelContext
            )
            let speakerProcessingSeconds = Date().timeIntervalSince(speakerStartedAt)
            let totalSpeakers = Set(inputs.payload.segments.map(\.speakerLabel)).count
            let namedPersonIDs = try inputs.payload.speakers
                .compactMap { profileIDs[$0.speakerLabel] }
                .compactMap { id in try SpeakerProfileRepository.findById(id, in: modelContext)?.person?.id }
                .uniqueElements()
            let finishedAt = JobLifecycleStore(modelContext: modelContext)
                .writeReidentificationJobMetrics(
                    currentJob,
                    totalSpeakers: totalSpeakers,
                    namedSpeakers: namedPersonIDs.count,
                    speakerProcessingSeconds: speakerProcessingSeconds
            )
            try transaction.commit()
            currentJob.resultTransactionID = transaction.id
            try JobLifecycleStore(modelContext: modelContext).finishPipeline(
                currentJob,
                status: .done,
                pipelineStage: "done",
                pipelineFraction: 1.0,
                pipelineMessage: "说话人识别完成",
                errorMessage: nil,
                finishedAt: finishedAt,
                operationKind: .speakerReidentification,
                operationStatus: .succeeded,
                operationMessage: "说话人重新识别完成",
                save: true
            )
            do {
                try transaction.markPersistenceSucceeded()
                try transaction.finalize()
            } catch {
                Logger.shared.warn("reidentify result transaction cleanup failed: \(error)")
            }
        } catch {
            currentJob.resultTransactionID = previousResultTransactionID
            try? transaction.rollback()
            modelContext.rollback()
            throw error
        }
    }

    /// A failed speaker rerun must preserve the pre-existing result.json and
    /// restore its terminal job state while recording the new operation error.
    private func persistRestoredJob(
        jobId: String,
        restoredStatus: JobStatus,
        restoredFinishedAt: Date?,
        message: String,
        operationError: String?,
        operationStatus: JobOperationStatus,
        modelContext: ModelContext
    ) {
        do {
            guard let job = try ASRJobRepository.findById(jobId, in: modelContext) else { return }
            try JobLifecycleStore(modelContext: modelContext).finishPipeline(
                job,
                status: restoredStatus,
                pipelineStage: restoredStatus == .partial ? "speaker_failed" : "done",
                pipelineFraction: restoredStatus == .partial ? job.pipelineFraction : 1.0,
                pipelineMessage: message,
                errorMessage: operationError,
                finishedAt: restoredFinishedAt,
                operationKind: .speakerReidentification,
                operationStatus: operationStatus,
                operationMessage: operationError,
                save: true
            )
        } catch {
            Logger.shared.error("无法持久化说话人重新识别状态：\(error)")
        }
    }

    /// Reference type because the pipeline task replaces segments and speaker
    /// mappings before committing the result transaction.
    private final class Inputs {
        let resultPath: URL
        var payload: ResultPayload
        let speakerInput: SpeakerRecognitionInput

        init(resultPath: URL, payload: ResultPayload, speakerInput: SpeakerRecognitionInput) {
            self.resultPath = resultPath
            self.payload = payload
            self.speakerInput = speakerInput
        }
    }
}
