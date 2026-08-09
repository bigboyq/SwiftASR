import Foundation
import SwiftData

/// Coordinates a cleanup run around `ResultsCleanupExecutor`: it owns the
/// job lock, SwiftData lifecycle transitions and terminal UI outcomes, while
/// the executor remains responsible for the resumable chunk loop itself.
@MainActor
enum ResultsCleanupCoordinator {
    struct ViewCallbacks {
        let isShowingJob: () -> Bool
        let updatePayload: (ResultPayload) -> Void
        let setCleanupError: (String?) -> Void
        let setPersistenceError: (String?) -> Void
        let setSyncBanner: (String?) -> Void
        let showCompletedPreview: () -> Void
    }

    static func start(
        payload initialPayload: ResultPayload,
        jobID: String,
        storedPath: String?,
        currentJob: ASRJob?,
        modelContext: ModelContext,
        fileCoordinator: FileActionCoordinator,
        activeSegments: [ResultSegment],
        speakerNames: [String: String],
        glossary: [String],
        service: LLMCleanupService,
        token: CancellationToken,
        settings: SettingsStore.CleanupSettings,
        mode: CleanupStartMode,
        callbacks: ViewCallbacks
    ) {
        guard !activeSegments.isEmpty else { return }
        guard fileCoordinator.startCleanupIfIdle(jobId: jobID) else {
            fileCoordinator.alertOtherCleanupRunning()
            return
        }

        callbacks.setCleanupError(nil)
        fileCoordinator.activeCleanupToken = token
        let cleanupStartedAt = Date()
        let previousLLMProcessingSeconds: Double
        if let currentJob {
            do {
                previousLLMProcessingSeconds = try JobLifecycleStore(modelContext: modelContext)
                    .markCleanupRunning(currentJob, resuming: mode == .resume)
            } catch {
                callbacks.setCleanupError(
                    "无法保存润色启动状态：" + UserFacingErrorMapper.message(
                        for: error, context: .cleanupPersistence
                    )
                )
                Logger.shared.error("无法保存润色启动状态：\(error)")
                fileCoordinator.finishCleanup(jobId: jobID)
                return
            }
        } else {
            previousLLMProcessingSeconds = 0
        }

        var payload = initialPayload
        switch mode {
        case .restart:
            if payload.speakerSplitOperation != nil {
                let previous = payload.speakerSplitOperation!.derivedMergedResults
                payload.speakerSplitOperation!.derivedMergedResults = SegmentMerger().buildMergedResults(
                    segments: ResultsPresentation.activeSegments(in: payload),
                    preservingManualAssignmentsFrom: previous
                )
            } else {
                payload.mergedResults = SegmentMerger().buildMergedResults(
                    segments: payload.segments,
                    preservingManualAssignmentsFrom: payload.mergedResults
                )
            }
            payload.cleanedModel = nil
            do {
                try ResultStore.write(
                    payload,
                    to: ResultStore.writePath(jobId: jobID, storedPath: storedPath)
                )
            } catch {
                callbacks.setCleanupError(
                    "无法清除旧润色结果：" + UserFacingErrorMapper.message(
                        for: error, context: .cleanupPersistence
                    )
                )
                Logger.shared.error("无法清除旧润色结果：\(error)")
                if let currentJob {
                    do {
                        try JobLifecycleStore(modelContext: modelContext)
                            .markCleanupFailed(currentJob, clearCompletion: false)
                    } catch {
                        callbacks.setPersistenceError(
                            "无法保存润色失败状态：" + UserFacingErrorMapper.message(
                                for: error, context: .cleanupPersistence
                            )
                        )
                        Logger.shared.error("无法保存润色失败状态：\(error)")
                    }
                }
                fileCoordinator.finishCleanup(jobId: jobID)
                return
            }
            callbacks.updatePayload(payload)
        case .resume:
            break
        }

        let mergedResults = ResultsPresentation.activeMergedResults(in: payload)
        let totalSegments = mergedResults.count
        let needsCleanup = mergedResults.filter {
            $0.cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if needsCleanup.isEmpty {
            callbacks.setCleanupError(
                mode == .resume ? "没有可继续的润色段, 全部已完成." : "没有需要润色的段."
            )
            if let currentJob {
                do {
                    try JobLifecycleStore(modelContext: modelContext).markCleanupCompleted(
                        currentJob,
                        model: payload.cleanedModel ?? settings.model,
                        processingSeconds: previousLLMProcessingSeconds
                    )
                } catch {
                    callbacks.setPersistenceError(
                        "无法保存润色完成状态：" + UserFacingErrorMapper.message(
                            for: error, context: .cleanupPersistence
                        )
                    )
                    Logger.shared.error("无法保存润色完成状态：\(error)")
                }
            }
            fileCoordinator.finishCleanup(jobId: jobID)
            return
        }

        let chunks = LLMCleanupService.chunkResults(needsCleanup, chunkChars: settings.chunkChars)
        let initialCleanedCount = totalSegments - needsCleanup.count
        fileCoordinator.activeCleanupProgress =
            "\(initialCleanedCount)/\(totalSegments) paras · 预计 \(chunks.count) chunks"

        let task = Task { @MainActor in
            do {
                Logger.shared.info(
                    "LLMCleanupService \(mode == .resume ? "续跑" : "启动"): " +
                    "\(totalSegments) 段 → \(needsCleanup.count) 段待润色 → \(chunks.count) chunk (model=\(settings.model))"
                )
                let completed = try await ResultsCleanupExecutor.run(
                    initialPayload: payload,
                    chunks: chunks,
                    totalSegments: totalSegments,
                    initialCleanedCount: initialCleanedCount,
                    jobId: jobID,
                    storedPath: storedPath,
                    glossary: glossary,
                    speakerNames: speakerNames,
                    service: service,
                    token: token,
                    settings: settings,
                    onCheckpoint: { checkpoint, progress in
                        if callbacks.isShowingJob() { callbacks.updatePayload(checkpoint) }
                        fileCoordinator.activeCleanupProgress = progress
                    }
                )
                if let job = try ASRJobRepository.findById(jobID, in: modelContext) {
                    try JobLifecycleStore(modelContext: modelContext).markCleanupCompleted(
                        job,
                        model: settings.model,
                        processingSeconds: previousLLMProcessingSeconds + Date().timeIntervalSince(cleanupStartedAt)
                    )
                }
                fileCoordinator.activeCleanupProgress = nil
                let message: String
                if !completed.tierEscalations.isEmpty {
                    let escalationDetails = completed.tierEscalations.map {
                        $0.userFacingDescription
                    }.joined(separator: "，")
                    message = completed.fallbackCount > 0
                        ? "润色完成（\(totalSegments) 段, \(completed.fallbackCount) 段 ⚠️原文占位；\(escalationDetails)）"
                        : "润色完成（\(totalSegments) 段；\(escalationDetails)）"
                } else {
                    message = completed.fallbackCount > 0
                        ? "润色完成（\(totalSegments) 段, \(completed.fallbackCount) 段 ⚠️原文占位）"
                        : "润色完成（\(totalSegments) 段）"
                }
                fileCoordinator.recordCleanupOutcome(jobId: jobID, kind: .success, message: message)

                if callbacks.isShowingJob() {
                    callbacks.setSyncBanner(message)
                    callbacks.showCompletedPreview()
                }
                fileCoordinator.finishCleanup(jobId: jobID)
            } catch is CleanupCancelled {
                fileCoordinator.activeCleanupProgress = nil
                fileCoordinator.recordCleanupOutcome(jobId: jobID, kind: .cancelled, message: "润色已取消")
                if callbacks.isShowingJob() { callbacks.setSyncBanner("润色已取消") }
                updateCancelledLifecycle(jobID: jobID, modelContext: modelContext, callbacks: callbacks)
                fileCoordinator.finishCleanup(jobId: jobID)
            } catch {
                // R4-P1-6：润色失败要给用户稳定中文文案，不直接拼接
                // localizedDescription（Gemini 401/403 等可能含技术细节）。
                let userMessage = "润色失败：" + UserFacingErrorMapper.message(
                    for: error, context: .cleanupPersistence
                )
                Logger.shared.error("润色失败：\(error)")
                fileCoordinator.recordCleanupOutcome(
                    jobId: jobID, kind: .failure, message: userMessage
                )
                if callbacks.isShowingJob() {
                    callbacks.setCleanupError(userMessage)
                }
                fileCoordinator.activeCleanupProgress = nil
                updateFailedLifecycle(jobID: jobID, modelContext: modelContext, callbacks: callbacks)
                fileCoordinator.finishCleanup(jobId: jobID)
            }
        }
        fileCoordinator.activeCleanupTask = task
    }

    private static func updateCancelledLifecycle(
        jobID: String,
        modelContext: ModelContext,
        callbacks: ViewCallbacks
    ) {
        do {
            if let job = try ASRJobRepository.findById(jobID, in: modelContext) {
                do {
                    try JobLifecycleStore(modelContext: modelContext).markCleanupCancelled(job)
                } catch {
                    callbacks.setPersistenceError(
                        "无法保存润色取消状态：" + UserFacingErrorMapper.message(
                            for: error, context: .cleanupPersistence
                        )
                    )
                    Logger.shared.error("无法保存润色取消状态：\(error)")
                }
            }
        } catch {
            callbacks.setPersistenceError(
                "无法读取润色任务状态：" + UserFacingErrorMapper.message(
                    for: error, context: .cleanupPersistence
                )
            )
            Logger.shared.error("无法读取润色任务状态：\(error)")
        }
    }

    private static func updateFailedLifecycle(
        jobID: String,
        modelContext: ModelContext,
        callbacks: ViewCallbacks
    ) {
        do {
            if let job = try ASRJobRepository.findById(jobID, in: modelContext) {
                do {
                    try JobLifecycleStore(modelContext: modelContext)
                        .markCleanupFailed(job, clearCompletion: true)
                } catch {
                    callbacks.setPersistenceError(
                        "无法保存润色失败状态：" + UserFacingErrorMapper.message(
                            for: error, context: .cleanupPersistence
                        )
                    )
                    Logger.shared.error("无法保存润色失败状态：\(error)")
                }
            }
        } catch {
            callbacks.setPersistenceError(
                "无法读取润色任务状态：" + UserFacingErrorMapper.message(
                    for: error, context: .cleanupPersistence
                )
            )
            Logger.shared.error("无法读取润色任务状态：\(error)")
        }
    }
}
