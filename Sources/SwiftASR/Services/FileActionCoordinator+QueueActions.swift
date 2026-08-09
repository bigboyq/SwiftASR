import Foundation
import SwiftData

/// Queue-specific user actions. The coordinator remains the UI façade; this
/// extension owns queue policy and has one explicit handoff into a pipeline run.
@MainActor
extension FileActionCoordinator {
    func startQueuedJob(jobId: String, audioPath: String, modelContext: ModelContext) {
        let job: ASRJob?
        do {
            job = try ASRJobRepository.findById(jobId, in: modelContext)
        } catch {
            reportActionError("无法读取排队任务：\(error.localizedDescription)")
            return
        }
        guard let job, job.jobStatus == .queued else { return }
        if hasRunningPipelineExcluding(currentJobId: jobId) {
            showQueueAddedMessage(for: job)
            return
        }
        switch job.queuedOperation {
        case .transcription:
            runPipeline(jobId: jobId, audioPath: audioPath, modelContext: modelContext)
        case .retranscription:
            startQueuedRetranscription(job: job, modelContext: modelContext)
        case .speakerReidentification:
            startQueuedReidentification(job: job, modelContext: modelContext)
        }
    }

    /// Adds a user-requested rerun to the durable queue. When the app is idle,
    /// the item starts immediately; when another pipeline is active (or the
    /// queue is paused), it remains queued and the user gets a clear result.
    func enqueueQueuedOperation(
        job: ASRJob,
        operation: QueuedJobOperationKind,
        modelContext: ModelContext
    ) {
        let restoreStatus = job.jobStatus
        let restoreFinishedAt = job.finishedAt
        do {
            try JobLifecycleStore(modelContext: modelContext).enqueue(
                job,
                operation: operation,
                restoreStatus: restoreStatus,
                restoreFinishedAt: restoreFinishedAt
            )
        } catch {
            reportActionError("无法加入转写队列：\(error.localizedDescription)")
            return
        }

        if !hasActivePipeline && !isQueuePaused {
            startQueuedJob(jobId: job.id, audioPath: job.sourceAudioPath, modelContext: modelContext)
        } else {
            showQueueAddedMessage(for: job)
        }
    }

    private func showQueueAddedMessage(for job: ASRJob) {
        let operationName: String
        switch job.queuedOperation {
        case .transcription: operationName = "转写"
        case .retranscription: operationName = "重新转写"
        case .speakerReidentification: operationName = "重新识别说话人"
        }
        AlertHelper.showInfo(title: "队列添加成功", message: "“\(operationName)”已加入队列，当前任务完成后会自动开始。")
    }

    func retryFailedJob(jobId: String, audioPath: String, modelContext: ModelContext) {
        let job: ASRJob?
        do {
            job = try ASRJobRepository.findById(jobId, in: modelContext)
        } catch {
            reportActionError("无法读取任务：\(error.localizedDescription)")
            return
        }
        guard let job else { return }
        guard [.failed, .cancelled].contains(job.jobStatus) else {
            reportActionError("只能重试失败或取消的任务（当前状态：\(job.jobStatus)）")
            return
        }
        if hasRunningPipelineExcluding(currentJobId: jobId) {
            alertOtherPipelineRunning()
            return
        }
        let lifecycle = JobLifecycleStore(modelContext: modelContext)
        do {
            try lifecycle.markRetryQueued(job)
            try lifecycle.moveQueuedJobToTop(id: jobId)
        } catch {
            reportActionError("无法重新入队：\(error.localizedDescription)")
            return
        }
        runPipeline(jobId: jobId, audioPath: audioPath, modelContext: modelContext)
    }

    func setQueuePaused(_ paused: Bool, modelContext: ModelContext) {
        queueScheduler.setPaused(paused)
        isQueuePaused = paused
        if !paused { startNextQueuedJobIfPossible(modelContext: modelContext) }
    }

    /// The only place that turns queue policy into an operation-specific start.
    func startNextQueuedJobIfPossible(modelContext: ModelContext) {
        guard queueScheduler.shouldAutoStart(pipelineActive: hasActivePipeline) else { return }
        let next: ASRJob?
        do {
            next = try queueScheduler.nextQueued(modelContext: modelContext)
        } catch {
            reportActionError("无法读取排队任务：\(error.localizedDescription)")
            return
        }
        guard let next else { return }
        startQueuedJob(
            jobId: next.id,
            audioPath: next.sourceAudioPath,
            modelContext: modelContext
        )
    }

    func moveQueuedJob(jobId: String, by offset: Int, modelContext: ModelContext) {
        do {
            try queueScheduler.moveQueuedJob(jobId: jobId, by: offset, modelContext: modelContext)
        } catch {
            reportActionError("无法调整队列顺序：\(error.localizedDescription)")
        }
    }

    func reorderQueuedJobs(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        modelContext: ModelContext
    ) {
        do {
            try queueScheduler.reorderQueuedJobs(
                fromOffsets: offsets, toOffset: destination, modelContext: modelContext
            )
        } catch {
            reportActionError("无法拖拽调整队列顺序：\(error.localizedDescription)")
        }
    }
}
