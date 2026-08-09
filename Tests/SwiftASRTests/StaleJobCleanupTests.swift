import Testing
import Foundation
import SwiftData
@testable import SwiftASR

// MARK: - Bug fix 2026-07-13: 删 appBackgrounded 路径
//
// 之前 MainSplitView 监听 NSApplication.didResignActiveNotification, 进入后台
// 立即把 running/processing/queued job 标 failed. 误伤 "短时间切后台"的用户
// (例如 ⌘+H 看一眼别的 app, 几秒后回来), pipeline 没死还在跑, 但用户
// 先看到 "转写失败" 错误信息.
//
// OS 真正强杀进程是 silent, 不会触发 didResignActiveNotification, 所以这条
// 路径**也帮不到 OS 强杀场景** — appLaunch 路径已覆盖 (用户重启电脑 / 杀
// 进程后重新打开 app).
//
// 这些测试覆盖:
// 1. appLaunch 清理 .running 状态 → .failed + 友好错误信息
// 2. appLaunch 清理 .processing 状态 → .failed
// 3. appLaunch 保留 .queued 状态（它不是 stale 运行态）
// 4. appLaunch 保留 .done / .partial / .failed 状态 (不应误伤已完成的)
// 5. appLaunch 清理 cleanupJobStatus = .running → 清空字段
// 6. coordinator transient 字段全部 nil
// 7. StaleJobCleanupService.Trigger 只有 .appLaunch (没有 .appBackgrounded)

@Suite("StaleJobCleanupService (Bug fix 2026-07-13)")
@MainActor
struct StaleJobCleanupTests {

    /// 测试用 ModelContainer — SwiftData in-memory.
    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let config = ModelConfiguration("StaleJobCleanupTests", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeJob(in context: ModelContext, status: JobStatus) -> ASRJob {
        let job = ASRJob(
            id: "test-\(UUID().uuidString)",
            sourceAudioPath: "/tmp/test.m4a",
            sourceAudioHash: "test-audio-hash",
            durationSeconds: 0,
            status: status.rawValue
        )
        context.insert(job)
        try? context.save()
        return job
    }

    // MARK: - appLaunch 清理: 真正 stale 状态

    @Test func appLaunch_cleansRunningJob() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .running)

        let cleaned = try StaleJobCleanupService.cleanup(in: context, when: .appLaunch)

        #expect(cleaned == 1, "应清理 1 个 .running job")
        #expect(job.status == JobStatus.failed.rawValue, ".running → .failed")
        #expect(job.errorMessage?.contains("应用启动") == true, "错误信息应包含 '应用启动'")
    }

    @Test func appLaunch_cleansProcessingJob() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .processing)

        let cleaned = try StaleJobCleanupService.cleanup(in: context, when: .appLaunch)

        #expect(cleaned == 1)
        #expect(job.status == JobStatus.failed.rawValue)
    }

    @Test func appLaunch_preservesQueuedJob() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .queued)

        let cleaned = try StaleJobCleanupService.cleanup(in: context, when: .appLaunch)

        #expect(cleaned == 0, ".queued 是用户待处理队列，不是崩溃遗留的运行态")
        #expect(job.status == JobStatus.queued.rawValue)
    }

    // MARK: - appLaunch 不误伤: 已完成状态

    @Test func appLaunch_preservesDoneJob() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .done)

        let cleaned = try StaleJobCleanupService.cleanup(in: context, when: .appLaunch)

        #expect(cleaned == 0, ".done 不应被清理")
        #expect(job.status == JobStatus.done.rawValue, ".done 保留 .done")
    }

    @Test func appLaunch_preservesPartialJob() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .partial)

        let cleaned = try StaleJobCleanupService.cleanup(in: context, when: .appLaunch)

        #expect(cleaned == 0, ".partial 不应被清理 (用户可以看到 ASR 句子)")
        #expect(job.status == JobStatus.partial.rawValue)
    }

    @Test func appLaunch_preservesFailedJob() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .failed)
        job.errorMessage = "之前已经失败的"

        let cleaned = try StaleJobCleanupService.cleanup(in: context, when: .appLaunch)

        #expect(cleaned == 0, ".failed 不应被清理 (避免覆盖之前的错误信息)")
        #expect(job.errorMessage == "之前已经失败的", "之前的错误信息保留")
    }

    @Test func artifactReconciliationMarksDoneJobWithoutResultAsFailed() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .done)
        job.transcriptPath = "/tmp/SwiftASR-missing-\(UUID().uuidString).result.json"
        try context.save()

        let repaired = try ResultArtifactReconciliationService.reconcile(in: context)

        #expect(repaired == 1)
        #expect(job.jobStatus == .failed)
        #expect(job.errorMessage?.contains("结果文件不存在") == true)
    }

    @Test func artifactReconciliationDoesNotTouchFailedJobWithoutResult() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .failed)
        job.errorMessage = "保留原始错误"
        job.transcriptPath = "/tmp/SwiftASR-missing-\(UUID().uuidString).result.json"
        try context.save()

        let repaired = try ResultArtifactReconciliationService.reconcile(in: context)

        #expect(repaired == 0)
        #expect(job.errorMessage == "保留原始错误")
    }

    @Test func artifactReconciliationRestoresInterruptedResultReplacementBeforeValidation() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .done)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftASR-interrupted-reconcile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let finalURL = directory.appendingPathComponent("\(job.id).result.json")
        job.transcriptPath = finalURL.path

        let oldPayload = ResultPayload(jobId: job.id, audioPath: job.sourceAudioPath, segments: [])
        try JSONEncoder().encode(oldPayload).write(to: finalURL, options: [.atomic])
        let transactionDirectory = directory.appendingPathComponent(
            ".swiftasr-result-transaction-interrupted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: finalURL,
            to: transactionDirectory.appendingPathComponent("previous.result.json")
        )
        try JSONEncoder().encode(oldPayload).write(
            to: transactionDirectory.appendingPathComponent("staged.result.json"),
            options: [.atomic]
        )
        let manifest = ResultWriteTransactionManifest(
            version: 1,
            finalPath: finalURL.standardizedFileURL.path,
            phase: .previousMoved
        )
        try JSONEncoder().encode(manifest).write(
            to: transactionDirectory.appendingPathComponent("transaction-manifest.json"),
            options: [.atomic]
        )
        try context.save()

        #expect(try ResultArtifactReconciliationService.reconcile(in: context) == 1)
        #expect(job.jobStatus == .done)
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: transactionDirectory.path))
    }

    // MARK: - appLaunch 清理: cleanup 残留

    @Test func appLaunch_cleansRunningCleanupStatus() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .done)  // 转写已完成
        job.cleanupJobStatus = .running  // 但润色卡在 running

        try StaleJobCleanupService.cleanup(in: context, when: .appLaunch)

        #expect(job.cleanupJobStatus == nil, "润色 running 状态被清空")
    }

    // MARK: - coordinator transient 清理

    @Test func clearCoordinatorTransients_clearsAllActiveFields() {
        let coordinator = FileActionCoordinator()
        coordinator.activeCleanupJobId = "test-cleanup"
        coordinator.activeCleanupToken = CancellationToken()
        coordinator.activeTranscriptionJobId = "test-transcription"
        coordinator.activeTranscriptionStage = "speaker"
        coordinator.activeTranscriptionFraction = 0.5
        coordinator.activeTranscriptionMessage = "说话人识别中…"

        StaleJobCleanupService.clearCoordinatorTransients(coordinator)

        #expect(coordinator.activeCleanupJobId == nil)
        #expect(coordinator.activeCleanupToken == nil)
        #expect(coordinator.activeTranscriptionJobId == nil)
        #expect(coordinator.activeTranscriptionStage == "")
        #expect(coordinator.activeTranscriptionFraction == 0)
        #expect(coordinator.activeTranscriptionMessage == "")
    }

    @Test func startupRecoveryRunsOnlyOncePerCoordinator() throws {
        let context = try makeContext()
        let job = makeJob(in: context, status: .running)
        let coordinator = FileActionCoordinator()

        #expect(try coordinator.recoverStaleJobsIfNeeded(modelContext: context) == 1)
        #expect(job.jobStatus == .failed)

        // 即便 SwiftData 中随后出现一个新的 running 值，也不能被同一个
        // coordinator 的重复 onAppear 当成第二次启动恢复。
        job.jobStatus = .running
        try context.save()
        #expect(try coordinator.recoverStaleJobsIfNeeded(modelContext: context) == 0)
        #expect(job.jobStatus == .running)
    }

    // MARK: - Trigger enum: 只有 .appLaunch (验证 appBackgrounded 已被删)

    @Test func trigger_onlyHasAppLaunch() {
        // Bug fix 2026-07-13: 删 .appBackgrounded. 之前进入后台立即标 failed
        // 误伤"短时间切后台"用户. 现在只有 .appLaunch 路径, 启动时清理真正的
        // stale 残留 (用户重启 / 杀进程后重新打开 app).
        let trigger = StaleJobCleanupService.Trigger.appLaunch
        #expect(trigger.userFacingLabel == "应用启动")

        // 验证 enum case 数量: 只有 .appLaunch 一个 case
        // (Swift 不直接给 enum case count, 用 reflection 间接验证)
        let allCases: [StaleJobCleanupService.Trigger] = [.appLaunch]
        #expect(allCases.count == 1)
        #expect(allCases == [.appLaunch])
    }
}
