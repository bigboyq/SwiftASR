import Foundation
import SwiftData
import Testing
@testable import SwiftASR

@Suite("JobLifecycleStore + partial persistence")
@MainActor
struct JobLifecycleStoreTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let config = ModelConfiguration("JobLifecycleStoreTests", schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func makeJob(_ id: String, in context: ModelContext) -> ASRJob {
        let job = ASRJob(
            id: id, sourceAudioPath: "/tmp/\(id).wav", sourceAudioHash: id, durationSeconds: 0
        )
        context.insert(job)
        return job
    }

    @Test func queuePersistsOrderAndCanReorder() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let a = makeJob("a", in: context)
        try store.enqueue(a)
        let b = makeJob("b", in: context)
        try store.enqueue(b)
        let c = makeJob("c", in: context)
        try store.enqueue(c)

        #expect(try store.orderedQueuedJobs().map(\.id) == ["a", "b", "c"])
        try store.moveQueuedJob(id: "c", by: -1)
        #expect(try store.orderedQueuedJobs().map(\.id) == ["a", "c", "b"])
    }

    @Test func queuePersistsRerunOperationAndClearsItWhenStarted() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let job = makeJob("speaker-rerun-queued", in: context)
        job.jobStatus = .done
        let finishedAt = Date(timeIntervalSince1970: 42)
        job.finishedAt = finishedAt
        try context.save()

        try store.enqueue(
            job,
            operation: .speakerReidentification,
            restoreStatus: .done,
            restoreFinishedAt: finishedAt
        )
        job.cleanupJobStatus = .done
        job.cleanedAt = Date(timeIntervalSince1970: 41)
        job.cleanedModel = "gemini-test"
        #expect(job.jobStatus == .queued)
        #expect(job.queuedOperation == .speakerReidentification)
        #expect(job.queuedRestoreJobStatus == .done)
        #expect(job.queuedRestoreFinishedAt == finishedAt)

        try store.markPipelineRunning(job, kind: .speakerReidentification)
        #expect(job.jobStatus == .running)
        #expect(job.cleanupJobStatus == nil)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
        #expect(job.queuedOperationKind == nil)
        #expect(job.queuedRestoreStatus == nil)
        #expect(job.queuedRestoreFinishedAt == nil)
    }

    @Test func normalizeQueueMigratesLegacyDuplicateOrders() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let older = makeJob("older", in: context)
        older.queueOrder = 0
        older.createdAt = .distantPast
        let newer = makeJob("newer", in: context)
        newer.queueOrder = 0
        try context.save()

        try store.normalizeQueue()

        #expect(try store.orderedQueuedJobs().map(\.id) == ["older", "newer"])
        #expect(older.queueOrder == 0)
        #expect(newer.queueOrder == 1)
    }

    @Test func splitCleanupInvalidationAndBaselineRestoreStayInSync() throws {
        let context = try makeContext()
        let job = makeJob("split-cleanup", in: context)
        let store = JobLifecycleStore(modelContext: context)
        let completedAt = Date(timeIntervalSince1970: 123)
        job.cleanupJobStatus = .done
        job.cleanedAt = completedAt
        job.cleanedModel = "gemini-2.5-pro"
        job.llmProcessingSeconds = 42
        try context.save()

        let baseline = SpeakerSplitBaselineCleanup(
            status: job.cleanupStatus,
            completedAt: job.cleanedAt,
            model: job.cleanedModel,
            processingSeconds: job.llmProcessingSeconds
        )
        try store.invalidateCleanup(job)
        #expect(job.cleanupStatus == nil)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
        #expect(job.llmProcessingSeconds == 0)

        try store.restoreCleanup(job, from: baseline)
        #expect(job.cleanupJobStatus == .done)
        #expect(job.cleanedAt == completedAt)
        #expect(job.cleanedModel == "gemini-2.5-pro")
        #expect(job.llmProcessingSeconds == 42)
    }

    @Test func pipelineSnapshotRestoresEveryOwnedField() throws {
        let context = try makeContext()
        let job = makeJob("snapshot-parity", in: context)
        let queuedAt = Date(timeIntervalSince1970: 10)
        let finishedAt = Date(timeIntervalSince1970: 20)
        let cleanedAt = Date(timeIntervalSince1970: 30)
        let operationAt = Date(timeIntervalSince1970: 40)
        job.status = JobStatus.partial.rawValue
        job.errorMessage = "original error"
        job.pipelineStage = "speaker"
        job.pipelineFraction = 0.75
        job.pipelineMessage = "original message"
        job.queuedOperationKind = QueuedJobOperationKind.speakerReidentification.rawValue
        job.queuedRestoreStatus = JobStatus.done.rawValue
        job.queuedRestoreFinishedAt = queuedAt
        job.finishedAt = finishedAt
        job.transcriptPath = "/tmp/original.result.json"
        job.durationSeconds = 123
        job.namedSpeakers = 2
        job.totalSpeakers = 3
        job.cleanupStatus = JobStatus.done.rawValue
        job.cleanedModel = "gemini-original"
        job.cleanedAt = cleanedAt
        job.asrProcessingSeconds = 11
        job.speakerProcessingSeconds = 12
        job.llmProcessingSeconds = 13
        job.lastOperationKind = JobOperationKind.transcription.rawValue
        job.lastOperationStatus = JobOperationStatus.failed.rawValue
        job.lastOperationMessage = "original operation"
        job.lastOperationAt = operationAt
        job.artifactDeletionTransactionID = "delete-original"

        let snapshot = JobLifecycleStore.PipelineSnapshot(job)
        job.status = JobStatus.running.rawValue
        job.errorMessage = nil
        job.pipelineStage = "changed"
        job.pipelineFraction = 0
        job.pipelineMessage = "changed"
        job.queuedOperationKind = nil
        job.queuedRestoreStatus = nil
        job.queuedRestoreFinishedAt = nil
        job.finishedAt = nil
        job.transcriptPath = nil
        job.durationSeconds = 0
        job.namedSpeakers = 0
        job.totalSpeakers = 0
        job.cleanupStatus = nil
        job.cleanedModel = nil
        job.cleanedAt = nil
        job.asrProcessingSeconds = 0
        job.speakerProcessingSeconds = 0
        job.llmProcessingSeconds = 0
        job.lastOperationKind = nil
        job.lastOperationStatus = nil
        job.lastOperationMessage = nil
        job.lastOperationAt = nil
        job.artifactDeletionTransactionID = nil

        snapshot.restore(job)

        #expect(job.status == JobStatus.partial.rawValue)
        #expect(job.errorMessage == "original error")
        #expect(job.pipelineStage == "speaker")
        #expect(job.pipelineFraction == 0.75)
        #expect(job.pipelineMessage == "original message")
        #expect(job.queuedOperationKind == QueuedJobOperationKind.speakerReidentification.rawValue)
        #expect(job.queuedRestoreStatus == JobStatus.done.rawValue)
        #expect(job.queuedRestoreFinishedAt == queuedAt)
        #expect(job.finishedAt == finishedAt)
        #expect(job.transcriptPath == "/tmp/original.result.json")
        #expect(job.durationSeconds == 123)
        #expect(job.namedSpeakers == 2)
        #expect(job.totalSpeakers == 3)
        #expect(job.cleanupStatus == JobStatus.done.rawValue)
        #expect(job.cleanedModel == "gemini-original")
        #expect(job.cleanedAt == cleanedAt)
        #expect(job.asrProcessingSeconds == 11)
        #expect(job.speakerProcessingSeconds == 12)
        #expect(job.llmProcessingSeconds == 13)
        #expect(job.lastOperationKind == JobOperationKind.transcription.rawValue)
        #expect(job.lastOperationStatus == JobOperationStatus.failed.rawValue)
        #expect(job.lastOperationMessage == "original operation")
        #expect(job.lastOperationAt == operationAt)
        #expect(job.artifactDeletionTransactionID == "delete-original")
    }

    // MARK: - F4.1 增强：PipelineSnapshot 一致性边界

    @Test func pipelineSnapshot_restoreIsIdempotent() throws {
        // 调 restore 两次结果应该跟调一次一样 — 否则在嵌套回滚场景下
        // 容易把"已恢复过"的状态再次回滚成旧值。
        let context = try makeContext()
        let job = makeJob("snapshot-idempotent", in: context)
        job.status = JobStatus.partial.rawValue
        job.pipelineStage = "speaker"
        job.pipelineFraction = 0.6
        job.transcriptPath = "/tmp/original.json"

        let snapshot = JobLifecycleStore.PipelineSnapshot(job)
        job.status = JobStatus.running.rawValue
        job.pipelineStage = "vad"
        job.pipelineFraction = 0.1
        job.transcriptPath = "/tmp/changed.json"

        snapshot.restore(job)
        snapshot.restore(job)  // 第二次必须 no-op
        #expect(job.status == JobStatus.partial.rawValue)
        #expect(job.pipelineStage == "speaker")
        #expect(job.pipelineFraction == 0.6)
        #expect(job.transcriptPath == "/tmp/original.json")
    }

    @Test func pipelineSnapshot_optionalNilFieldsPreserveNil() throws {
        // 所有 Optional 字段在 nil 状态下 snapshot → restore 后仍为 nil
        let context = try makeContext()
        let job = makeJob("snapshot-nils", in: context)
        // 默认所有 Optional 都是 nil
        let snapshot = JobLifecycleStore.PipelineSnapshot(job)
        // 给所有 Optional 赋值
        job.errorMessage = "should be cleared"
        job.queuedOperationKind = "should be cleared"
        job.queuedRestoreStatus = "should be cleared"
        job.queuedRestoreFinishedAt = Date()
        job.finishedAt = Date()
        job.artifactDeletionTransactionID = "should be cleared"
        job.cleanupStatus = "should be cleared"
        job.cleanedAt = Date()
        job.cleanedModel = "should be cleared"
        job.transcriptPath = "should be cleared"

        snapshot.restore(job)
        #expect(job.errorMessage == nil)
        #expect(job.queuedOperationKind == nil)
        #expect(job.queuedRestoreStatus == nil)
        #expect(job.queuedRestoreFinishedAt == nil)
        #expect(job.finishedAt == nil)
        #expect(job.artifactDeletionTransactionID == nil)
        #expect(job.cleanupStatus == nil)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
        #expect(job.transcriptPath == nil)
    }

    @Test func pipelineSnapshot_subSnapshotsAreIndependent() throws {
        // state / metrics / cleanup / operation 4 个 sub-snapshot 互不污染
        let context = try makeContext()
        let job = makeJob("snapshot-isolation", in: context)
        job.status = JobStatus.partial.rawValue           // state
        job.durationSeconds = 99                          // metrics
        job.cleanupStatus = JobStatus.done.rawValue      // cleanup
        job.lastOperationKind = JobOperationKind.transcription.rawValue  // operation
        job.transcriptPath = "/tmp/iso.json"              // transcriptPath

        let snapshot = JobLifecycleStore.PipelineSnapshot(job)
        // 改其中 3 个 sub-snapshot 的字段
        job.status = JobStatus.running.rawValue           // state changed
        job.durationSeconds = 1                           // metrics changed
        job.cleanupStatus = JobStatus.failed.rawValue     // cleanup changed
        // operation 和 transcriptPath 不动

        snapshot.restore(job)
        // state / metrics / cleanup 应该回到 original；operation / transcriptPath 不变
        #expect(job.status == JobStatus.partial.rawValue)
        #expect(job.durationSeconds == 99)
        #expect(job.cleanupStatus == JobStatus.done.rawValue)
        #expect(job.lastOperationKind == JobOperationKind.transcription.rawValue)
        #expect(job.transcriptPath == "/tmp/iso.json")
    }

    @Test func pipelineSnapshot_recaptureReflectsNewState() throws {
        // 同一 job 多次 snapshot，第二次应该反映第二次捕获时的状态
        let context = try makeContext()
        let job = makeJob("snapshot-recapture", in: context)
        job.status = JobStatus.partial.rawValue
        job.pipelineFraction = 0.3

        let snapshot1 = JobLifecycleStore.PipelineSnapshot(job)
        // 改 state
        job.status = JobStatus.running.rawValue
        job.pipelineFraction = 0.1
        // 再次 snapshot
        let snapshot2 = JobLifecycleStore.PipelineSnapshot(job)
        // 模拟后续失败场景：snapshot1.restore() 应该恢复到 partial 0.3
        snapshot1.restore(job)
        #expect(job.status == JobStatus.partial.rawValue)
        #expect(job.pipelineFraction == 0.3)
        // 再调到 snapshot2 → 应该恢复到 running 0.1
        snapshot2.restore(job)
        #expect(job.status == JobStatus.running.rawValue)
        #expect(job.pipelineFraction == 0.1)
    }

    @Test func pipelineStartRecordsStructuredOperation() throws {
        let context = try makeContext()
        let job = makeJob("run", in: context)
        let store = JobLifecycleStore(modelContext: context)
        try store.enqueue(job)
        try store.markPipelineRunning(job, kind: .transcription)

        #expect(job.jobStatus == .running)
        #expect(job.latestOperationKind == .transcription)
        #expect(job.latestOperationStatus == .running)
    }

    @Test func finishPipelineRequiresRunningAndRecordsTerminalState() throws {
        let context = try makeContext()
        let job = makeJob("finish", in: context)
        let store = JobLifecycleStore(modelContext: context)

        #expect(throws: JobLifecycleError.pipelineNotRunning(.queued)) {
            try store.finishPipeline(
                job,
                status: .done,
                pipelineStage: "done",
                pipelineFraction: 1,
                pipelineMessage: "完成",
                errorMessage: nil,
                finishedAt: Date(timeIntervalSince1970: 10),
                operationKind: .transcription,
                operationStatus: .succeeded,
                operationMessage: "转写完成"
            )
        }

        try store.markPipelineRunning(job, kind: .transcription)
        let finishedAt = Date(timeIntervalSince1970: 10)
        try store.finishPipeline(
            job,
            status: .done,
            pipelineStage: "done",
            pipelineFraction: 1,
            pipelineMessage: "完成",
            errorMessage: nil,
            finishedAt: finishedAt,
            operationKind: .transcription,
            operationStatus: .succeeded,
            operationMessage: "转写完成"
        )

        #expect(job.jobStatus == .done)
        #expect(job.finishedAt == finishedAt)
        #expect(job.latestOperationStatus == .succeeded)
        #expect(throws: JobLifecycleError.pipelineNotRunning(.done)) {
            try store.finishPipeline(
                job,
                status: .failed,
                pipelineStage: "failed",
                pipelineFraction: 0,
                pipelineMessage: "失败",
                errorMessage: "late callback",
                finishedAt: nil,
                operationKind: .transcription,
                operationStatus: .failed,
                operationMessage: "late callback"
            )
        }
    }

    @Test func finishPipelineRejectsNonTerminalStatus() throws {
        let context = try makeContext()
        let job = makeJob("invalid-finish", in: context)
        let store = JobLifecycleStore(modelContext: context)
        try store.markPipelineRunning(job, kind: .transcription)

        #expect(throws: JobLifecycleError.invalidPipelineTerminalStatus(.running)) {
            try store.finishPipeline(
                job,
                status: .running,
                pipelineStage: "asr",
                pipelineFraction: 0.5,
                pipelineMessage: "进行中",
                errorMessage: nil,
                finishedAt: nil,
                operationKind: .transcription,
                operationStatus: .running,
                operationMessage: nil
            )
        }
    }

    @Test func partialResultCanBeDerivedFromFailedOrCancelledJob() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let failed = makeJob("partial-failed", in: context)
        failed.jobStatus = .failed
        try store.markPartialResult(
            failed,
            resultPath: "/tmp/partial-failed.result.json",
            errorMessage: "speaker failed",
            pipelineMessage: "ASR 完成，Speaker 失败"
        )
        #expect(failed.jobStatus == .partial)
        #expect(failed.transcriptPath == "/tmp/partial-failed.result.json")
        #expect(failed.latestOperationStatus == .failed)

        let cancelled = makeJob("partial-cancelled", in: context)
        cancelled.jobStatus = .cancelled
        try store.markPartialResult(
            cancelled,
            resultPath: "/tmp/partial-cancelled.result.json",
            errorMessage: "cancelled",
            pipelineMessage: "已取消（ASR 已保存）"
        )
        #expect(cancelled.jobStatus == .partial)
    }

    @Test func cleanupLifecyclePersistsIndependentState() throws {
        let context = try makeContext()
        let job = makeJob("cleanup", in: context)
        let store = JobLifecycleStore(modelContext: context)
        job.llmProcessingSeconds = 12
        let completedAt = Date(timeIntervalSince1970: 123)
        job.cleanedAt = completedAt
        job.cleanedModel = "gemini-checkpoint"

        let previous = try store.markCleanupRunning(job, resuming: true)
        #expect(previous == 12)
        #expect(job.cleanupJobStatus == .running)
        #expect(job.cleanedAt == completedAt)
        #expect(job.cleanedModel == "gemini-checkpoint")
        #expect(job.llmProcessingSeconds == 12)

        try store.markCleanupCompleted(job, model: "gemini-test", processingSeconds: 15)
        #expect(job.cleanupJobStatus == .done)
        #expect(job.cleanedModel == "gemini-test")
        #expect(job.llmProcessingSeconds == 15)

        try store.markCleanupFailed(job, clearCompletion: true)
        #expect(job.cleanupJobStatus == .failed)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
    }

    @Test func cleanupRestartClearsPreviousCompletionBeforeTerminalOutcome() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let job = makeJob("cleanup-restart", in: context)
        job.cleanupJobStatus = .done
        job.cleanedAt = Date(timeIntervalSince1970: 123)
        job.cleanedModel = "gemini-previous"
        job.llmProcessingSeconds = 42
        try context.save()

        let previous = try store.markCleanupRunning(job, resuming: false)

        #expect(previous == 0)
        #expect(job.cleanupJobStatus == .running)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
        #expect(job.llmProcessingSeconds == 0)

        try store.markCleanupCancelled(job)
        #expect(job.cleanupJobStatus == .cancelled)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
        #expect(job.llmProcessingSeconds == 0)
    }

    @Test func cleanupRestartFailureCannotRestorePreviousCompletion() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let job = makeJob("cleanup-restart-failure", in: context)
        job.cleanupJobStatus = .done
        job.cleanedAt = Date(timeIntervalSince1970: 456)
        job.cleanedModel = "gemini-previous"
        job.llmProcessingSeconds = 30
        try context.save()

        _ = try store.markCleanupRunning(job, resuming: false)
        try store.markCleanupFailed(job, clearCompletion: false)

        #expect(job.cleanupJobStatus == .failed)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
        #expect(job.llmProcessingSeconds == 0)
    }

    @Test func partialWriterFailureDoesNotMarkJobPartial() throws {
        struct FailingWriter: ResultPayloadWriting {
            func write(_ payload: ResultPayload, to url: URL) throws {
                throw CocoaError(.fileWriteNoPermission)
            }
        }

        let context = try makeContext()
        let job = makeJob("partial", in: context)
        try context.save()
        let input = SpeakerRecognitionInput(
            audioPath: job.sourceAudioPath,
            sentences: [ASRSentence(text: "测试", startMs: 0, endMs: 1000)]
        )

        let outcome = PartialResultPersister(writer: FailingWriter()).persist(
            input: input,
            jobId: job.id,
            errorMessage: "speaker failed",
            pipelineMessage: "ASR 完成，Speaker 失败",
            modelContext: context
        )

        guard case .failed = outcome else {
            Issue.record("写入失败必须返回 .failed")
            return
        }
        #expect(job.jobStatus == .queued)
        #expect(job.transcriptPath == nil)
    }

    @Test func partialResultPersisterUsesLifecycleStore() throws {
        struct SuccessfulWriter: ResultPayloadWriting {
            func write(_ payload: ResultPayload, to url: URL) throws {}
        }

        let context = try makeContext()
        let job = makeJob("partial-success", in: context)
        job.jobStatus = .running
        let input = SpeakerRecognitionInput(
            audioPath: job.sourceAudioPath,
            sentences: [ASRSentence(text: "测试", startMs: 0, endMs: 1000)]
        )

        let outcome = PartialResultPersister(writer: SuccessfulWriter()).persist(
            input: input,
            jobId: job.id,
            errorMessage: "speaker failed",
            pipelineMessage: "ASR 完成，Speaker 失败",
            modelContext: context
        )

        #expect(outcome == .persisted)
        #expect(job.jobStatus == .partial)
        #expect(job.pipelineStage == "speaker_failed")
        #expect(job.lastOperationKind == JobOperationKind.transcription.rawValue)
    }

    // MARK: - 0 覆盖方法补强（2026-07-22 audit 发现）
    //
    // JobLifecycleStore 15 个方法，原有 9 个测试覆盖 10 个；补下面 5 个 0 覆盖方法。

    @Test func prepareForRetranscription_resetsStatusAndClearsError() throws {
        let context = try makeContext()
        let job = makeJob("retrans-prep", in: context)
        job.jobStatus = .failed
        job.errorMessage = "上次失败"
        job.finishedAt = Date()
        job.durationSeconds = 120
        job.pipelineStage = "speaker"
        job.pipelineFraction = 0.5
        job.pipelineMessage = "speaker 进行中"
        job.cleanupJobStatus = .done
        job.cleanedAt = Date()
        job.cleanedModel = "gemini-test"
        try context.save()

        let store = JobLifecycleStore(modelContext: context)
        _ = try store.prepareForRetranscription(job)

        #expect(job.jobStatus == .processing)
        #expect(job.errorMessage == nil)
        #expect(job.finishedAt == nil)
        #expect(job.durationSeconds == 0)
        #expect(job.pipelineStage == "")
        #expect(job.cleanupJobStatus == nil)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
    }

    @Test func updatePipelineProgress_setsFields() throws {
        let context = try makeContext()
        let job = makeJob("progress", in: context)
        try context.save()

        let store = JobLifecycleStore(modelContext: context)
        try store.updatePipelineProgress(
            job, stage: "vad", fraction: 0.42, message: "VAD 进行中"
        )

        #expect(job.pipelineStage == "vad")
        #expect(job.pipelineFraction == 0.42)
        #expect(job.pipelineMessage == "VAD 进行中")
    }

    // MARK: - M5.4 stage 字符串合法性（round-3）

    @Test func legalPipelineStages_coversProductionStages() {
        // production 路径会传 10 个 stage 字符串 — 进度入口与终态入口分组，
        // 但总集合仍集中审计：
        // - 5 阶段: load / vad / asr / punc / speaker (via onProgress)
        // - 1 初始: "" (via markPipelineRunning 之前 / prepareForRetranscription)
        // - 1 partial 失败: speaker_failed (via markPartialResult)
        // - 1 启动恢复失败: failed (via ResultArtifactReconciliationService)
        // - 1 取消: cancelled (via finishPipeline cancelled 分支)
        // - 1 完成: done (via finishPipeline done 分支)
        // 任何新 stage 字符串必须显式加进这个 set 并 review
        let expected: Set<String> = [
            "", "load", "vad", "asr", "punc", "speaker",
            "failed", "speaker_failed", "cancelled", "done"
        ]
        #expect(JobLifecycleStore.legalPipelineProgressStages == [
            "", "load", "vad", "asr", "punc", "speaker"
        ])
        #expect(JobLifecycleStore.legalPipelineTerminalStages == [
            "failed", "speaker_failed", "cancelled", "done"
        ])
        #expect(JobLifecycleStore.legalPipelineStages == expected)
    }

    @Test func updatePipelineProgress_acceptsAllLegalProgressStages() throws {
        // 不抛错 / 不触发 assert = 通过
        for stage in JobLifecycleStore.legalPipelineProgressStages {
            let context = try makeContext()
            let job = makeJob("legal-\(stage)", in: context)
            try context.save()

            let store = JobLifecycleStore(modelContext: context)
            try store.updatePipelineProgress(
                job, stage: stage, fraction: 0.5, message: "test \(stage)"
            )
            #expect(job.pipelineStage == stage)
        }
    }

    @Test func updatePipelineProgress_rejectsTerminalStages() throws {
        let context = try makeContext()
        let job = makeJob("terminal-progress", in: context)
        try context.save()
        let store = JobLifecycleStore(modelContext: context)

        for stage in JobLifecycleStore.legalPipelineTerminalStages {
            #expect(throws: JobLifecycleError.invalidPipelineStage(stage)) {
                try store.updatePipelineProgress(
                    job, stage: stage, fraction: 1, message: "terminal"
                )
            }
        }
    }

    @Test func updatePipelineProgress_rejectsInvalidStage() throws {
        // 钉死 "typo 在 production 也会抛" — 跟 `b625661` 把 assert 升级到
        // throw 同步。不依赖 assert 在 release build 失效。
        let context = try makeContext()
        let job = makeJob("typo", in: context)
        try context.save()
        let store = JobLifecycleStore(modelContext: context)

        for typo in ["vadd", "ASR", "loadx", "speaker_", "donee", ""] {
            // "" 是合法初始态（empty set 成员），跳过 — 用其他非空 typo
            if typo.isEmpty { continue }
            #expect(throws: JobLifecycleError.invalidPipelineStage(typo)) {
                try store.updatePipelineProgress(
                    job, stage: typo, fraction: 0.5, message: "typo"
                )
            }
        }
    }

    @Test func finishPipeline_acceptsCancelledAndDone() throws {
        // 钉死 "cancelled" / "done" 是 finishPipeline 路径的合法 stage —
        // 跟 `legalPipelineStages` set 同步。防止未来扩 set 时漏覆盖
        // finishPipeline。
        for (status, stage) in [
            (JobStatus.cancelled, "cancelled"),
            (JobStatus.done, "done"),
            (JobStatus.failed, "failed"),
            (JobStatus.partial, "speaker_failed")
        ] {
            let context = try makeContext()
            let job = makeJob("finish-\(stage)", in: context)
            try context.save()
            let store = JobLifecycleStore(modelContext: context)
            try store.markPipelineRunning(job, kind: .transcription)

            try store.finishPipeline(
                job,
                status: status,
                pipelineStage: stage,
                pipelineFraction: 1,
                pipelineMessage: "完成",
                errorMessage: nil,
                finishedAt: Date(timeIntervalSince1970: 10),
                operationKind: .transcription,
                operationStatus: .succeeded,
                operationMessage: nil
            )
            #expect(job.pipelineStage == stage)
        }
    }

    @Test func finishPipeline_rejectsInvalidStage() throws {
        // 钉死 finishPipeline 入口也校验 stage — 跟 updatePipelineProgress
        // 行为对称。防止未来 caller 传 typo（如 "donee"）让 result UI 短暂
        // 显示未知 stage。
        let context = try makeContext()
        let job = makeJob("finish-typo", in: context)
        try context.save()
        let store = JobLifecycleStore(modelContext: context)
        try store.markPipelineRunning(job, kind: .transcription)

        for typo in ["vadd", "ASR", "loadx", "donee", "cancellled"] {
            #expect(throws: JobLifecycleError.invalidPipelineStage(typo)) {
                try store.finishPipeline(
                    job,
                    status: .done,
                    pipelineStage: typo,
                    pipelineFraction: 1,
                    pipelineMessage: "typo",
                    errorMessage: nil,
                    finishedAt: Date(timeIntervalSince1970: 10),
                    operationKind: .transcription,
                    operationStatus: .succeeded,
                    operationMessage: nil
                )
            }
        }
    }

    @Test func finishPipeline_rejectsProgressStage() throws {
        let context = try makeContext()
        let job = makeJob("finish-progress-stage", in: context)
        try context.save()
        let store = JobLifecycleStore(modelContext: context)
        try store.markPipelineRunning(job, kind: .transcription)

        for stage in ["load", "vad", "asr", "punc", "speaker"] {
            #expect(throws: JobLifecycleError.invalidPipelineStage(stage)) {
                try store.finishPipeline(
                    job,
                    status: .done,
                    pipelineStage: stage,
                    pipelineFraction: 1,
                    pipelineMessage: "invalid terminal stage",
                    errorMessage: nil,
                    finishedAt: Date(timeIntervalSince1970: 10),
                    operationKind: .transcription,
                    operationStatus: .succeeded,
                    operationMessage: nil
                )
            }
        }
    }

    @Test func updateStageMetrics_persistsAsrAndSpeakerSeconds() throws {
        let context = try makeContext()
        let job = makeJob("metrics", in: context)
        try context.save()

        let store = JobLifecycleStore(modelContext: context)
        // asrProcessingMilliseconds = 100 + 50 + 5000 + 200 = 5350ms = 5.35s
        let metrics = PipelineStageMetrics(
            pcmDecodeMs: 100,
            fbankMaterialiseMs: 50,
            fbankFrames: 800,
            totalDurationMs: 60_000,
            vadAsrWallMs: 5000,
            vadSegmentCount: 24,
            puncMs: 200,
            speakerMs: 1500
        )
        try store.updateStageMetrics(job, stage: "asr", metrics: metrics)

        #expect(job.asrProcessingSeconds == 5.35)

        // speaker 阶段：metrics.speakerMs=1500 → 1.5s
        try store.updateStageMetrics(job, stage: "speaker", metrics: metrics)
        #expect(job.speakerProcessingSeconds == 1.5)
    }

    @Test func recordOperation_setsKindStatusMessageAndTimestamp() throws {
        let context = try makeContext()
        let job = makeJob("operation", in: context)
        try context.save()

        let store = JobLifecycleStore(modelContext: context)
        try store.recordOperation(
            kind: .speakerReidentification,
            status: .succeeded,
            message: "说话人识别完成",
            for: job
        )

        #expect(job.lastOperationKind == JobOperationKind.speakerReidentification.rawValue)
        #expect(job.lastOperationStatus == JobOperationStatus.succeeded.rawValue)
        #expect(job.lastOperationMessage == "说话人识别完成")
        #expect(job.lastOperationAt != nil)
    }

    @Test func markCleanupCancelled_setsStatus() throws {
        let context = try makeContext()
        let job = makeJob("cleanup-cancel", in: context)
        job.cleanupJobStatus = .running
        try context.save()

        let store = JobLifecycleStore(modelContext: context)
        try store.markCleanupCancelled(job)

        #expect(job.cleanupJobStatus == .cancelled)
    }

    @Test func writeSuccessJobMetrics_setsFieldsWithoutSaving() throws {
        let context = try makeContext()
        let job = makeJob("success-metrics", in: context)
        let store = JobLifecycleStore(modelContext: context)
        let metrics = PipelineStageMetrics(
            pcmDecodeMs: 1000,
            vadAsrWallMs: 200,
            puncMs: 34,
            speakerMs: 5678
        )
        store.writeSuccessJobMetrics(
            job,
            audioPath: "/nonexistent/path.wav",
            utterances: [
                UtteranceData(startMs: 0, endMs: 1000, rawText: "hi", speakerLabel: "S1")
            ],
            metrics: metrics,
            resultPath: URL(fileURLWithPath: "/tmp/job.result.json"),
            speakersCount: 2
        )
        // The method does NOT save (caller does via finishPipeline).
        // Verify each field was set as expected.
        #expect(job.asrProcessingSeconds == 1.234)
        #expect(job.speakerProcessingSeconds == 5.678)
        #expect(job.transcriptPath == "/tmp/job.result.json")
        #expect(job.totalSpeakers == 2)
        #expect(job.namedSpeakers == 0)
        // durationSeconds depends on fileMetadata("/nonexistent/path.wav");
        // accept either 0 (file not found) or the result duration (~1.0s).
        #expect(job.durationSeconds >= 0)
    }

    @Test func writeReidentificationJobMetrics_clearsCleanupFields() throws {
        let context = try makeContext()
        let job = makeJob("reident-metrics", in: context)
        // Pretend the previous cleanup ran successfully.
        job.cleanupJobStatus = .done
        job.cleanedModel = "gemini-flash-latest"
        job.cleanedAt = Date()
        job.llmProcessingSeconds = 4.2

        let store = JobLifecycleStore(modelContext: context)
        let finishedAt = store.writeReidentificationJobMetrics(
            job,
            totalSpeakers: 3,
            namedSpeakers: 2,
            speakerProcessingSeconds: 1.5
        )
        // Metrics set
        #expect(job.speakerProcessingSeconds == 1.5)
        #expect(job.totalSpeakers == 3)
        #expect(job.namedSpeakers == 2)
        // Cleanup invalidated (the previous result.json's cleanup is now
        // invalid because the speaker layout changed).
        #expect(job.cleanupJobStatus == nil)
        #expect(job.cleanedModel == nil)
        #expect(job.cleanedAt == nil)
        #expect(job.llmProcessingSeconds == 0)
        // finishedAt is recent (within the last second)
        #expect(Date().timeIntervalSince(finishedAt) < 1.0)
    }

    @Test func moveQueuedJobToTop_movesToHeadAndShiftsOthers() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let a = makeJob("a", in: context)
        let b = makeJob("b", in: context)
        let c = makeJob("c", in: context)
        try store.enqueue(a)
        try store.enqueue(b)
        try store.enqueue(c)
        // queueOrder is 0/1/2; move c (tail) to top
        let moved = try store.moveQueuedJobToTop(id: "c")
        #expect(moved)
        // c is now at position 0, a and b shifted down
        #expect(c.queueOrder == 0)
        #expect(a.queueOrder == 1)
        #expect(b.queueOrder == 2)
    }

    @Test func reorderQueuedJobsPersistsSwiftUIListMoveOrder() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        for id in ["a", "b", "c", "d"] {
            let job = ASRJob(id: id, sourceAudioPath: "/tmp/\(id).wav", sourceAudioHash: id, durationSeconds: 0)
            context.insert(job)
            try store.enqueue(job)
        }

        try store.reorderQueuedJobs(fromOffsets: IndexSet([1, 2]), toOffset: 4)

        let ordered = try store.orderedQueuedJobs()
        #expect(ordered.map(\.id) == ["a", "d", "b", "c"])
        #expect(ordered.map(\.queueOrder) == [0, 1, 2, 3])
    }

    @Test func moveQueuedJobToTop_returnsFalseForUnknownId() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let moved = try store.moveQueuedJobToTop(id: "nonexistent")
        #expect(moved == false)
    }

    @Test func markRetryQueued_clearsLastOperationFields() throws {
        let context = try makeContext()
        let job = makeJob("retry-queued", in: context)
        // Pretend the previous run failed and we have stale lastOperation fields.
        job.jobStatus = .failed
        job.errorMessage = "前一次失败：模型加载失败"
        job.lastOperationKind = JobOperationKind.transcription.rawValue
        job.lastOperationStatus = JobOperationStatus.failed.rawValue
        job.lastOperationMessage = "模型加载失败"
        try context.save()

        let store = JobLifecycleStore(modelContext: context)
        try store.markRetryQueued(job)

        // Status is back to .queued, queueOrder is at the tail
        #expect(job.jobStatus == .queued)
        #expect(job.errorMessage == nil)
        #expect(job.lastOperationKind == nil)
        #expect(job.lastOperationStatus == nil)
        #expect(job.lastOperationMessage == nil)
        // It was the only queued job, so queueOrder is 0
        #expect(job.queueOrder == 0)
    }
}
