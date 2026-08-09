import Foundation
import SwiftData

/// Owns the durable job CRUD actions. `FileActionCoordinator` remains the
/// UI-facing façade and supplies alert routing plus the pipeline handoff.
@MainActor
final class JobActionService {
    private unowned let coordinator: FileActionCoordinator

    init(coordinator: FileActionCoordinator) {
        self.coordinator = coordinator
    }

    @discardableResult
    func importAudioFile(
        url: URL,
        jobs: [ASRJob],
        selectedJobId: inout String?,
        modelContext: ModelContext,
        autoStart: Bool
    ) -> Bool {
        // R4-P2-7：拒绝空路径。URL(fileURLWithPath: "") 会解析成 cwd，
        // hashAudioPath 会基于 cwd 产生一个看起来合法的 job id，导致后续
        // stage 路径都指向错误位置。在入口处拦掉，避免静默数据错位。
        let path = url.path
        guard !path.isEmpty, path != "/" else {
            coordinator.reportActionError("无法导入音频：文件路径为空。")
            return false
        }
        var inheritedArtifactDeletionTransactionID: String?
        // Prefer an existing row located at the same canonical file. This
        // preserves jobs created before case-sensitive-volume hashing was
        // introduced, whose historical ID may have lowercased the path.
        let jobId = jobs.first(where: {
            ResultStore.audioPathsReferToSameLocation($0.sourceAudioPath, url.path)
        })?.id ?? ResultStore.hashAudioPath(url.path)
        if let existing = jobs.first(where: { $0.id == jobId }) {
            selectedJobId = jobId
            if [.done, .partial, .processing, .running, .queued].contains(existing.jobStatus) {
                return false
            }
            if [.failed, .cancelled].contains(existing.jobStatus) {
                let artifactDeletion: ResultArtifactDeletionTransaction
                do {
                    try finalizePreviousArtifactDeletion(for: existing)
                    artifactDeletion = try ResultArtifactDeletionTransaction(
                        jobId: existing.id, storedPath: existing.transcriptPath
                    )
                } catch {
                    coordinator.reportActionError("无法重新导入音频：旧任务文件清理失败。请检查文件权限后重试。")
                    return false
                }
                existing.artifactDeletionTransactionID = artifactDeletion.id
                modelContext.delete(existing)
                guard saveModelChanges(modelContext, action: "删除旧失败任务") else {
                    try? artifactDeletion.restore()
                    coordinator.reportActionError("无法重新导入音频：旧任务删除失败。请检查数据库权限后重试。")
                    return false
                }
                inheritedArtifactDeletionTransactionID = artifactDeletion.id
                do {
                    try artifactDeletion.commit()
                } catch {
                    Logger.shared.warn(
                        "旧任务已删除，制品事务将在启动恢复时完成清理：\(error)"
                    )
                }
            }
        }

        let newJob = ASRJob(
            id: jobId, sourceAudioPath: url.path, sourceAudioHash: jobId,
            durationSeconds: 0.0, status: JobStatus.queued.rawValue,
            artifactDeletionTransactionID: inheritedArtifactDeletionTransactionID
        )
        modelContext.insert(newJob)
        do {
            try JobLifecycleStore(modelContext: modelContext).enqueue(newJob)
        } catch {
            modelContext.delete(newJob)
            reportActionFailure("无法将音频加入转写队列", error)
            return false
        }
        selectedJobId = jobId
        if autoStart {
            if coordinator.hasRunningPipelineExcluding(currentJobId: jobId) {
                coordinator.alertOtherPipelineRunning()
                return false
            }
            coordinator.runPipeline(jobId: jobId, audioPath: url.path, modelContext: modelContext)
            return true
        }
        return false
    }

    func retranscribe(job: ASRJob, modelContext: ModelContext) {
        guard ![.processing, .running, .queued].contains(job.jobStatus) else { return }
        if job.jobStatus == .done {
            let confirmed = AlertHelper.confirm(
                title: "重新转写会覆盖现有结果",
                message: "当前 job 已完成，重新转写会覆盖 result.json（包括已有的润色结果）。\n\n确定要继续吗？",
                confirmTitle: "重新转写"
            )
            if !confirmed { return }
        }
        coordinator.enqueueQueuedOperation(
            job: job,
            operation: .retranscription,
            modelContext: modelContext
        )
    }

    /// Queue entry point for a retranscription. Destructive artifact cleanup
    /// is deliberately delayed until the queued item actually starts.
    func startQueuedRetranscription(job: ASRJob, modelContext: ModelContext) {
        guard job.jobStatus == .queued, job.queuedOperation == .retranscription else { return }

        let artifactDeletion: ResultArtifactDeletionTransaction
        do {
            try finalizePreviousArtifactDeletion(for: job)
            artifactDeletion = try ResultArtifactDeletionTransaction(
                jobId: job.id, storedPath: job.transcriptPath
            )
        } catch {
            reportActionFailure("无法清理旧任务文件", error)
            failQueuedRetranscription(job, message: actionErrorMessage("无法清理旧任务文件", error), modelContext: modelContext)
            return
        }
        let lifecycle = JobLifecycleStore(modelContext: modelContext)
        var preparation: JobLifecycleStore.PipelinePreparationRollback?
        do {
            preparation = try lifecycle.prepareForRetranscription(
                job,
                artifactDeletionTransactionID: artifactDeletion.id
            )
        } catch {
            try? artifactDeletion.restore()
            try? preparation?.restore(job)
            reportActionFailure("准备重新转写失败", error)
            failQueuedRetranscription(job, message: actionErrorMessage("准备重新转写失败", error), modelContext: modelContext)
            return
        }
        do {
            try artifactDeletion.commit()
        } catch {
            Logger.shared.warn(
                "重新转写的旧制品事务将在启动恢复时完成清理：\(error)"
            )
        }
        coordinator.runPipeline(jobId: job.id, audioPath: job.sourceAudioPath, modelContext: modelContext)
    }

    private func failQueuedRetranscription(
        _ job: ASRJob,
        message: String,
        modelContext: ModelContext
    ) {
        do {
            try JobLifecycleStore(modelContext: modelContext).failQueuedOperation(
                job,
                operation: .retranscription,
                restoreStatus: job.queuedRestoreJobStatus,
                restoreFinishedAt: job.queuedRestoreFinishedAt,
                message: message
            )
            coordinator.startNextQueuedJobIfPossible(modelContext: modelContext)
        } catch {
            reportActionFailure("无法恢复重新转写任务状态", error)
        }
    }

    func deleteJob(
        job: ASRJob,
        selectedJobId: inout String?,
        modelContext: ModelContext,
        confirm: Bool
    ) {
        if confirm {
            let confirmed = AlertHelper.confirm(
                title: "确认删除",
                message: "删除记录 \(URL(fileURLWithPath: job.sourceAudioPath).lastPathComponent)？\n会删除数据库记录和对应的 result.json。\n不会删除原始音频文件。",
                confirmTitle: "删除"
            )
            if !confirmed { return }
        }
        let artifactDeletion: ResultArtifactDeletionTransaction
        do {
            try finalizePreviousArtifactDeletion(for: job)
            artifactDeletion = try ResultArtifactDeletionTransaction(
                jobId: job.id, storedPath: job.transcriptPath
            )
        } catch {
            Logger.shared.error("无法删除任务文件：\(error)")
            AlertHelper.showInfo(
                title: "无法删除任务",
                message: "结果或诊断文件删除失败，数据库记录已保留。请检查文件权限后重试。\n\n"
                    + UserFacingErrorMapper.message(for: error),
                style: .warning
            )
            return
        }
        job.artifactDeletionTransactionID = artifactDeletion.id
        modelContext.delete(job)
        guard saveModelChanges(modelContext, action: "删除任务") else {
            do {
                try artifactDeletion.restore()
            } catch {
                coordinator.reportActionError(
                    "删除任务失败，且无法恢复结果文件："
                        + UserFacingErrorMapper.message(for: error)
                )
            }
            return
        }
        do {
            try artifactDeletion.commit()
        } catch {
            Logger.shared.warn(
                "任务记录已删除，制品事务将在启动恢复时完成清理：\(error)"
            )
        }
        if selectedJobId == job.id { selectedJobId = nil }
    }

    /// A surviving job stores one durable deletion token. Finish the previous
    /// token before replacing it so startup can never mistake an older,
    /// already-persisted deletion for an uncommitted transaction.
    private func finalizePreviousArtifactDeletion(for job: ASRJob) throws {
        guard let transactionID = job.artifactDeletionTransactionID else { return }
        try ResultArtifactDeletionTransaction.finalizePersistedTransaction(
            id: transactionID,
            jobID: job.id
        )
    }

    private func saveModelChanges(_ modelContext: ModelContext, action: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            Logger.shared.error("\(action)失败：\(error)")
            return false
        }
    }

    private func reportActionFailure(_ prefix: String, _ error: Error) {
        coordinator.reportActionError(actionErrorMessage(prefix, error))
    }

    private func actionErrorMessage(_ prefix: String, _ error: Error) -> String {
        "\(prefix)：\(UserFacingErrorMapper.message(for: error))"
    }
}
