import Foundation
import SwiftData

enum JobLifecycleError: Error, Equatable, LocalizedError {
    case invalidPipelineTerminalStatus(JobStatus)
    case pipelineNotRunning(JobStatus)
    case partialResultNotAllowed(JobStatus)
    case invalidPipelineStage(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPipelineTerminalStatus(status):
            return "不能将 pipeline 写入终态：\(status)。"
        case let .pipelineNotRunning(status):
            return "只能从 running 提交 pipeline 终态，当前状态是 \(status)。"
        case let .partialResultNotAllowed(status):
            return "不能从 \(status) 派生 partial 结果。"
        case let .invalidPipelineStage(stage):
            return "收到非法的 pipeline stage：'\(stage)'。"
        }
    }
}

/// 任务状态迁移与持久化的唯一入口。
///
/// UI coordinator 只决定用户意图和导航；pipeline runner 只产生事件；所有可恢复的
/// job 状态、队列顺序和最近操作记录都在这里写入 SwiftData。方法抛错而非静默 `try?`，
/// 调用者可以选择把失败展示给用户或让 pipeline 进入失败路径。
@MainActor
final class JobLifecycleStore {
    private let modelContext: ModelContext

    /// 进度回调可以写入的 stage。`updatePipelineProgress` 只接受这一组，
    /// 防止迟到的进度事件把终态 stage（如 `done`）写回正在结束或已结束的 job。
    ///
    /// - `""`: 初始 / 清理后（`markPipelineRunning` 之前）
    /// - `"load"`: 解码 + fbank 阶段
    /// - `"vad"`: VAD 阶段
    /// - `"asr"`: ASR 阶段
    /// - `"punc"`: 标点恢复阶段
    /// - `"speaker"`: 说话人识别阶段
    static let legalPipelineProgressStages: Set<String> = [
        "", "load", "vad", "asr", "punc", "speaker"
    ]

    /// 终态写入可以使用的 stage。`finishPipeline` 只接受这一组。
    /// - `"failed"`: 启动恢复标记 `JobStatus.failed` 路径
    /// - `"speaker_failed"`: `markPartialResult` 在 speaker 阶段失败时
    /// - `"cancelled"`: `finishPipeline` 取消分支
    /// - `"done"`: `finishPipeline` 成功分支
    static let legalPipelineTerminalStages: Set<String> = [
        "failed", "speaker_failed", "cancelled", "done"
    ]

    /// 所有已知的 production stage，供审计和迁移测试使用。
    static let legalPipelineStages: Set<String> =
        legalPipelineProgressStages.union(legalPipelineTerminalStages)

    struct PipelineSnapshot {
        private let state: PipelineStateSnapshot
        private let metrics: PipelineMetricsSnapshot
        private let cleanup: CleanupSnapshot
        private let operation: OperationSnapshot
        private let transcriptPath: String?

        init(_ job: ASRJob) {
            state = PipelineStateSnapshot(job)
            metrics = PipelineMetricsSnapshot(job)
            cleanup = CleanupSnapshot(job)
            operation = OperationSnapshot(job)
            transcriptPath = job.transcriptPath
        }

        func restore(_ job: ASRJob) {
            state.restore(job)
            metrics.restore(job)
            cleanup.restore(job)
            operation.restore(job)
            job.transcriptPath = transcriptPath
        }
    }

    /// Fields that define the persisted pipeline/queue state machine.
    private struct PipelineStateSnapshot {
        let status: String
        let errorMessage: String?
        let pipelineStage: String
        let pipelineFraction: Double
        let pipelineMessage: String
        let queuedOperationKind: String?
        let queuedRestoreStatus: String?
        let queuedRestoreFinishedAt: Date?
        let finishedAt: Date?
        let artifactDeletionTransactionID: String?

        init(_ job: ASRJob) {
            status = job.status
            errorMessage = job.errorMessage
            pipelineStage = job.pipelineStage
            pipelineFraction = job.pipelineFraction
            pipelineMessage = job.pipelineMessage
            queuedOperationKind = job.queuedOperationKind
            queuedRestoreStatus = job.queuedRestoreStatus
            queuedRestoreFinishedAt = job.queuedRestoreFinishedAt
            finishedAt = job.finishedAt
            artifactDeletionTransactionID = job.artifactDeletionTransactionID
        }

        func restore(_ job: ASRJob) {
            job.status = status
            job.errorMessage = errorMessage
            job.pipelineStage = pipelineStage
            job.pipelineFraction = pipelineFraction
            job.pipelineMessage = pipelineMessage
            job.queuedOperationKind = queuedOperationKind
            job.queuedRestoreStatus = queuedRestoreStatus
            job.queuedRestoreFinishedAt = queuedRestoreFinishedAt
            job.finishedAt = finishedAt
            job.artifactDeletionTransactionID = artifactDeletionTransactionID
        }
    }

    /// Numeric outputs that are committed together with a pipeline result.
    private struct PipelineMetricsSnapshot {
        let durationSeconds: Double
        let namedSpeakers: Int
        let totalSpeakers: Int
        let asrProcessingSeconds: Double
        let speakerProcessingSeconds: Double

        init(_ job: ASRJob) {
            durationSeconds = job.durationSeconds
            namedSpeakers = job.namedSpeakers
            totalSpeakers = job.totalSpeakers
            asrProcessingSeconds = job.asrProcessingSeconds
            speakerProcessingSeconds = job.speakerProcessingSeconds
        }

        func restore(_ job: ASRJob) {
            job.durationSeconds = durationSeconds
            job.namedSpeakers = namedSpeakers
            job.totalSpeakers = totalSpeakers
            job.asrProcessingSeconds = asrProcessingSeconds
            job.speakerProcessingSeconds = speakerProcessingSeconds
        }
    }

    private struct CleanupSnapshot {
        let cleanupStatus: String?
        let cleanedAt: Date?
        let cleanedModel: String?
        let llmProcessingSeconds: Double

        init(_ job: ASRJob) {
            cleanupStatus = job.cleanupStatus
            cleanedAt = job.cleanedAt
            cleanedModel = job.cleanedModel
            llmProcessingSeconds = job.llmProcessingSeconds
        }

        func restore(_ job: ASRJob) {
            job.cleanupStatus = cleanupStatus
            job.cleanedAt = cleanedAt
            job.cleanedModel = cleanedModel
            job.llmProcessingSeconds = llmProcessingSeconds
        }
    }

    /// Last-operation audit fields are restored as one unit.
    private struct OperationSnapshot {
        let kind: String?
        let status: String?
        let message: String?
        let at: Date?

        init(_ job: ASRJob) {
            kind = job.lastOperationKind
            status = job.lastOperationStatus
            message = job.lastOperationMessage
            at = job.lastOperationAt
        }

        func restore(_ job: ASRJob) {
            job.lastOperationKind = kind
            job.lastOperationStatus = status
            job.lastOperationMessage = message
            job.lastOperationAt = at
        }
    }

    struct PipelinePreparationRollback {
        private let snapshot: PipelineSnapshot
        private let modelContext: ModelContext

        fileprivate init(snapshot: PipelineSnapshot, modelContext: ModelContext) {
            self.snapshot = snapshot
            self.modelContext = modelContext
        }

        func restore(_ job: ASRJob) throws {
            snapshot.restore(job)
            try modelContext.save()
        }
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func enqueue(
        _ job: ASRJob,
        operation: QueuedJobOperationKind = .transcription,
        restoreStatus: JobStatus? = nil,
        restoreFinishedAt: Date? = nil
    ) throws {
        let queued = try orderedQueuedJobs()
        job.queueOrder = (queued.last?.queueOrder ?? -1) + 1
        job.jobStatus = .queued
        job.queuedOperationKind = operation.rawValue
        job.queuedRestoreStatus = restoreStatus?.rawValue
        job.queuedRestoreFinishedAt = restoreFinishedAt
        job.lastOperationAt = Date()
        try modelContext.save()
    }

    /// 重新入队一个失败 / 取消的任务，append 到队列尾部。
    /// 调用方（如 `retryFailedJob`）通常会立刻 `moveQueuedJobToTop` 把它推到头部。
    /// - 为什么单独抽方法：跟 `enqueue` 的差别是"原本就是 queued 状态
    ///   还是从 failed/cancelled 回来"，要清 lastOperationKind / lastOperationStatus
    ///   等字段，避免 UI 端误显示"上次的失败原因"。
    func markRetryQueued(_ job: ASRJob) throws {
        let queued = try orderedQueuedJobs()
        job.queueOrder = (queued.last?.queueOrder ?? -1) + 1
        job.jobStatus = .queued
        job.queuedOperationKind = QueuedJobOperationKind.transcription.rawValue
        job.queuedRestoreStatus = nil
        job.queuedRestoreFinishedAt = nil
        job.errorMessage = nil
        job.lastOperationKind = nil
        job.lastOperationStatus = nil
        job.lastOperationMessage = nil
        try modelContext.save()
    }

    /// Converts a queued operation that cannot be started back to its
    /// pre-queue terminal state. This prevents a bad sidecar or a filesystem
    /// error from leaving the head of the queue stuck forever.
    func failQueuedOperation(
        _ job: ASRJob,
        operation: QueuedJobOperationKind,
        restoreStatus: JobStatus?,
        restoreFinishedAt: Date?,
        message: String
    ) throws {
        guard job.jobStatus == .queued else { return }
        let status = restoreStatus ?? .failed
        job.jobStatus = status
        job.finishedAt = restoreFinishedAt
        job.pipelineStage = status == .partial ? "speaker_failed" : (status == .done ? "done" : "failed")
        job.pipelineFraction = [.done, .partial].contains(status) ? 1.0 : 0.0
        job.pipelineMessage = message
        job.errorMessage = message
        job.queuedOperationKind = nil
        job.queuedRestoreStatus = nil
        job.queuedRestoreFinishedAt = nil
        let operationKind: JobOperationKind = operation == .speakerReidentification
            ? .speakerReidentification
            : .transcription
        try recordOperation(
            kind: operationKind,
            status: .failed,
            message: message,
            for: job
        )
    }

    func markPipelineRunning(_ job: ASRJob, kind: JobOperationKind) throws {
        let snapshot = PipelineSnapshot(job)
        job.jobStatus = .running
        job.errorMessage = nil
        job.pipelineStage = "load"
        job.pipelineFraction = 0
        job.pipelineMessage = "加载…"
        job.queuedOperationKind = nil
        job.queuedRestoreStatus = nil
        job.queuedRestoreFinishedAt = nil
        if kind == .speakerReidentification {
            invalidateCleanupFields(job)
        }
        try recordOperation(kind: kind, status: .running, message: nil, for: job, save: false)
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
    }

    /// Clears downstream result state before a user-requested full
    /// retranscription. Keeping this mutation here prevents views from
    /// writing raw status strings and half-resetting a job before the runner
    /// is actually started.
    @discardableResult
    func prepareForRetranscription(
        _ job: ASRJob,
        artifactDeletionTransactionID: String? = nil
    ) throws -> PipelinePreparationRollback {
        let snapshot = PipelineSnapshot(job)
        if let artifactDeletionTransactionID {
            job.artifactDeletionTransactionID = artifactDeletionTransactionID
        }
        job.jobStatus = .processing
        job.errorMessage = nil
        job.finishedAt = nil
        job.durationSeconds = 0
        job.pipelineStage = ""
        job.pipelineFraction = 0
        job.pipelineMessage = ""
        job.transcriptPath = nil
        job.namedSpeakers = 0
        job.totalSpeakers = 0
        invalidateCleanupFields(job)
        job.asrProcessingSeconds = 0
        job.speakerProcessingSeconds = 0
        job.llmProcessingSeconds = 0
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
        return PipelinePreparationRollback(snapshot: snapshot, modelContext: modelContext)
    }

    func updatePipelineProgress(
        _ job: ASRJob,
        stage: String,
        fraction: Double,
        message: String
    ) throws {
        // M5.4: 防止 typo / 终态 stage / 旧 stage 字符串污染进度持久化。
        guard Self.legalPipelineProgressStages.contains(stage) else {
            throw JobLifecycleError.invalidPipelineStage(stage)
        }
        let snapshot = PipelineSnapshot(job)
        let stageChanged = job.pipelineStage != stage
        job.pipelineStage = stage
        job.pipelineFraction = fraction
        job.pipelineMessage = message
        if stageChanged || fraction >= 1 || fraction == 0 {
            do {
                try modelContext.save()
            } catch {
                snapshot.restore(job)
                throw error
            }
        }
    }

    func updateStageMetrics(
        _ job: ASRJob,
        stage: String,
        metrics: PipelineStageMetrics
    ) throws {
        let snapshot = PipelineSnapshot(job)
        switch stage {
        case "asr", "punc":
            job.asrProcessingSeconds = Double(metrics.asrProcessingMilliseconds) / 1_000
        case "speaker":
            job.speakerProcessingSeconds = Double(metrics.speakerMs) / 1_000
        default:
            break
        }
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
    }

    func recordOperation(
        kind: JobOperationKind,
        status: JobOperationStatus,
        message: String?,
        for job: ASRJob,
        save: Bool = true
    ) throws {
        let snapshot = save ? PipelineSnapshot(job) : nil
        job.lastOperationKind = kind.rawValue
        job.lastOperationStatus = status.rawValue
        job.lastOperationMessage = message
        job.lastOperationAt = Date()
        if save {
            do {
                try modelContext.save()
            } catch {
                snapshot?.restore(job)
                throw error
            }
        }
    }

    /// 统一提交 pipeline 的持久化终态。
    ///
    /// 所有 pipeline 终态都必须从 `.running` 进入，避免迟到的异步回调覆盖
    /// 新一轮运行或重复写入终态。调用方可通过 `save: false` 在补充统计字段后
    /// 与 operation 记录一起保存。
    func finishPipeline(
        _ job: ASRJob,
        status: JobStatus,
        pipelineStage: String,
        pipelineFraction: Double,
        pipelineMessage: String,
        errorMessage: String?,
        finishedAt: Date?,
        operationKind: JobOperationKind,
        operationStatus: JobOperationStatus,
        operationMessage: String?,
        save: Bool = true
    ) throws {
        let snapshot = PipelineSnapshot(job)
        guard [.done, .partial, .failed, .cancelled].contains(status) else {
            throw JobLifecycleError.invalidPipelineTerminalStatus(status)
        }
        // M5.4 follow-up: 终态入口只接受终态 stage，防止 caller 传进度 stage
        // 或 typo（如 "donee"）让 result UI 短暂显示未知 stage。
        guard Self.legalPipelineTerminalStages.contains(pipelineStage) else {
            throw JobLifecycleError.invalidPipelineStage(pipelineStage)
        }
        guard job.jobStatus == .running else {
            throw JobLifecycleError.pipelineNotRunning(job.jobStatus)
        }

        job.jobStatus = status
        job.pipelineStage = pipelineStage
        job.pipelineFraction = pipelineFraction
        job.pipelineMessage = pipelineMessage
        job.errorMessage = errorMessage
        job.finishedAt = finishedAt
        try recordOperation(
            kind: operationKind,
            status: operationStatus,
            message: operationMessage,
            for: job,
            save: false
        )
        if save {
            do {
                try modelContext.save()
            } catch {
                snapshot.restore(job)
                throw error
            }
        }
    }

    /// 派生 ASR partial 结果的持久化入口。
    ///
    /// 与完整 pipeline 终态不同，用户可以从历史 `.failed` / `.cancelled` 任务
    /// 手动派生 partial，因此允许这两个状态；运行中的 pipeline 也可以通过此
    /// 入口在 speaker 失败时收敛为 `.partial`。
    func markPartialResult(
        _ job: ASRJob,
        resultPath: String,
        errorMessage: String,
        pipelineMessage: String,
        operationKind: JobOperationKind = .transcription,
        save: Bool = true
    ) throws {
        let snapshot = PipelineSnapshot(job)
        guard [.running, .failed, .cancelled].contains(job.jobStatus) else {
            throw JobLifecycleError.partialResultNotAllowed(job.jobStatus)
        }
        job.jobStatus = .partial
        job.errorMessage = errorMessage
        job.pipelineStage = "speaker_failed"
        job.pipelineFraction = 1.0
        job.pipelineMessage = pipelineMessage
        job.transcriptPath = resultPath
        job.finishedAt = Date()
        try recordOperation(
            kind: operationKind,
            status: .failed,
            message: errorMessage,
            for: job,
            save: false
        )
        if save {
            do {
                try modelContext.save()
            } catch {
                snapshot.restore(job)
                throw error
            }
        }
    }

    func orderedQueuedJobs() throws -> [ASRJob] {
        try ASRJobRepository.fetchAll(in: modelContext)
            .filter { $0.jobStatus == .queued }
            .sorted {
                if $0.queueOrder != $1.queueOrder { return $0.queueOrder < $1.queueOrder }
                return $0.createdAt < $1.createdAt
            }
    }

    func moveQueuedJob(id: String, by offset: Int) throws {
        var jobs = try orderedQueuedJobs()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard jobs.indices.contains(target) else { return }
        jobs.swapAt(index, target)
        for (position, job) in jobs.enumerated() { job.queueOrder = position }
        try modelContext.save()
    }

    /// Persist the order produced by SwiftUI's `List.onMove`. Only queued
    /// jobs participate, so dragging can never reshuffle failed/running rows.
    func reorderQueuedJobs(fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
        var jobs = try orderedQueuedJobs()
        guard !offsets.isEmpty,
              offsets.allSatisfy({ jobs.indices.contains($0) }),
              (0...jobs.count).contains(destination) else { return }

        let moved = offsets.sorted().map { jobs[$0] }
        for index in offsets.sorted(by: >) {
            jobs.remove(at: index)
        }
        let adjustedDestination = destination - offsets.filter { $0 < destination }.count
        jobs.insert(contentsOf: moved, at: adjustedDestination)
        for (position, job) in jobs.enumerated() { job.queueOrder = position }
        try modelContext.save()
    }

    /// Move a queued job to the head of the queue (queueOrder = 0) and
    /// shift every other queued job down by 1.  Used by the "重试" /
    /// "失败后置顶" workflow: a failed job is re-queued and bounced to
    /// the front so it gets retried before any other pending work.
    /// - Returns: `true` if the job was found in the queue and moved;
    ///   `false` if the id didn't match any queued job (caller can
    ///   still proceed to enqueue from scratch).
    @discardableResult
    func moveQueuedJobToTop(id: String) throws -> Bool {
        var jobs = try orderedQueuedJobs()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let job = jobs.remove(at: index)
        jobs.insert(job, at: 0)
        for (position, queuedJob) in jobs.enumerated() { queuedJob.queueOrder = position }
        try modelContext.save()
        return true
    }

    /// 润色状态独立于转写状态。所有写入都显式抛错，避免 result.json checkpoint
    /// 已落盘而 job 仍显示“润色中”或旧状态。
    func markCleanupRunning(_ job: ASRJob, resuming: Bool) throws -> Double {
        let snapshot = CleanupSnapshot(job)
        let previousDuration = resuming ? job.llmProcessingSeconds : 0
        job.cleanupJobStatus = .running
        if !resuming {
            // A restart replaces the previous cleanup result instead of
            // continuing its checkpoint. Clear every completion field in the
            // same persisted transition so cancellation/failure cannot expose
            // the previous run's model or completion time.
            job.cleanedAt = nil
            job.cleanedModel = nil
            job.llmProcessingSeconds = 0
        }
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
        return previousDuration
    }

    func markCleanupCompleted(
        _ job: ASRJob,
        model: String,
        processingSeconds: Double
    ) throws {
        let snapshot = CleanupSnapshot(job)
        job.cleanedModel = model
        job.cleanedAt = Date()
        job.llmProcessingSeconds = processingSeconds
        job.cleanupJobStatus = .done
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
    }

    func markCleanupCancelled(_ job: ASRJob) throws {
        let snapshot = CleanupSnapshot(job)
        job.cleanupJobStatus = .cancelled
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
    }

    func markCleanupFailed(_ job: ASRJob, clearCompletion: Bool) throws {
        let snapshot = CleanupSnapshot(job)
        job.cleanupJobStatus = .failed
        if clearCompletion {
            job.cleanedAt = nil
            job.cleanedModel = nil
        }
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
    }

    /// A Split Set changes the current preview's merge boundaries, so any
    /// cleanup completion attached to the previous preview is no longer valid.
    func invalidateCleanup(_ job: ASRJob) throws {
        let snapshot = CleanupSnapshot(job)
        invalidateCleanupFields(job)
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
    }

    /// Restores the task-level cleanup state captured with a baseline result
    /// when the final Split Set member is removed.
    func restoreCleanup(_ job: ASRJob, from baseline: SpeakerSplitBaselineCleanup) throws {
        let snapshot = CleanupSnapshot(job)
        job.cleanupStatus = baseline.status
        job.cleanedAt = baseline.completedAt
        job.cleanedModel = baseline.model
        job.llmProcessingSeconds = baseline.processingSeconds
        do {
            try modelContext.save()
        } catch {
            snapshot.restore(job)
            throw error
        }
    }

    /// Persists the result-transaction reference installed by a split replay.
    /// This named entry point keeps the durable recovery metadata owned by the
    /// lifecycle store without moving speaker-mapping rules into it.
    func persistResultTransactionReference(_ job: ASRJob) throws {
        try modelContext.save()
    }

    func normalizeQueue() throws {
        for (position, job) in try orderedQueuedJobs().enumerated() { job.queueOrder = position }
        try modelContext.save()
    }

    // MARK: - Success-path metrics (full pipeline)

    /// 写 success 路径下 7 个 SwiftData job 字段（时长、ASR/Speaker 耗时、
    /// transcriptPath、totalSpeakers、namedSpeakers）。SwiftData 持久化由
    /// `finishPipeline(save: true)` 统一负责，本方法只负责设字段。
    /// - `audioPath` 用于从 `FileSystemMetadata` 取文件时长；
    ///   `utterances` 用于派生结果时长（max(source, result)）。
    /// - 抽到这里让 `applyPipelineSuccess` 不再直接 mutate job 字段（audit #2）。
    func writeSuccessJobMetrics(
        _ job: ASRJob,
        audioPath: String,
        utterances: [UtteranceData],
        metrics: PipelineStageMetrics,
        resultPath: URL,
        speakersCount: Int
    ) {
        let sourceDuration = fileMetadata(at: audioPath).durationSeconds
        let resultDuration = Double(utterances.last?.endMs ?? 0) / 1000.0
        job.durationSeconds = max(sourceDuration, resultDuration)
        job.asrProcessingSeconds = Double(metrics.asrProcessingMilliseconds) / 1_000
        job.speakerProcessingSeconds = Double(metrics.speakerMs) / 1_000
        job.transcriptPath = resultPath.path
        job.totalSpeakers = speakersCount
        job.namedSpeakers = 0
    }

    // MARK: - Reidentification-path metrics (speaker-only rerun)

    /// `reidentifySpeakers` 成功路径的 SwiftData 字段写入。
    /// 跟 `writeSuccessJobMetrics` 平行，但是 speaker-only：只覆盖
    /// speakerProcessingSeconds / totalSpeakers / namedSpeakers，并清空
    /// cleanup 字段（result.json 的 cleanup 跟旧 routing 已经失效）。
    /// SwiftData 持久化由 `finishPipeline(save: true)` 统一负责，本方法
    /// 只负责设字段。
    /// - Parameters:
    ///   - totalSpeakers: 派生自 `ResultPayload.segments` 的 distinct label 数。
    ///   - namedSpeakers: 派生自 profile 解析后绑定到 Person 的数量。
    ///   - speakerProcessingSeconds: speaker 阶段 wall time。
    /// - Returns: `finishedAt = Date()`，caller 传给 `finishPipeline`。
    @discardableResult
    func writeReidentificationJobMetrics(
        _ job: ASRJob,
        totalSpeakers: Int,
        namedSpeakers: Int,
        speakerProcessingSeconds: Double
    ) -> Date {
        job.speakerProcessingSeconds = speakerProcessingSeconds
        job.totalSpeakers = totalSpeakers
        job.namedSpeakers = namedSpeakers
        // 重新识别清空旧的润色结果（result.json 里的 cleanup 字段失效）
        invalidateCleanupFields(job)
        return Date()
    }

    private func invalidateCleanupFields(_ job: ASRJob) {
        job.cleanupStatus = nil
        job.cleanedAt = nil
        job.cleanedModel = nil
        job.llmProcessingSeconds = 0
    }
}
