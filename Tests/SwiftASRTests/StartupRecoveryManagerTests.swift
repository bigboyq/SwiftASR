import Foundation
import SwiftData
import Testing
@testable import SwiftASR

/// `StartupRecoveryManager` 单元测试（2026-07-22）。
///
/// 关注：
/// 1. 启动恢复**一次守门**（`didRunStartupRecovery`）—— 同一 manager 第二次调用
///    `recoverStaleJobsIfNeeded` 必须 no-op
/// 2. stale `.running` / `.processing` job 在恢复后变 `.failed` + 友好错误信息
/// 3. cleanup 终态（cleanupJobStatus == .running）被清空
/// 4. `prewarmModelsIfNeeded` / `releasePrewarmedModels` 不 crash
@Suite(.serialized)
@MainActor
struct StartupRecoveryManagerTests {
    // MARK: - Fixtures

    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let config = ModelConfiguration(
            "StartupRecoveryManagerTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func makeJob(_ id: String, status: JobStatus, in context: ModelContext) -> ASRJob {
        let job = ASRJob(
            id: id,
            sourceAudioPath: "/tmp/\(id).wav",
            sourceAudioHash: id,
            durationSeconds: 0
        )
        job.jobStatus = status
        context.insert(job)
        return job
    }

    private func makeCoordinator() -> FileActionCoordinator {
        FileActionCoordinator(settingsStore: SettingsStore.createTestInstance())
    }

    // MARK: - 一次守门

    @Test func recover_secondCallIsNoop() throws {
        let context = try makeContext()
        let manager = StartupRecoveryManager()
        let coordinator = makeCoordinator()

        _ = try manager.recoverStaleJobsIfNeeded(
            coordinator: coordinator, modelContext: context
        )
        // 第二次必须返回 0 且不抛
        let second = try manager.recoverStaleJobsIfNeeded(
            coordinator: coordinator, modelContext: context
        )
        #expect(second == 0)
    }

    // MARK: - Stale job 状态转换

    @Test func recover_marksRunningJobAsFailed() throws {
        let context = try makeContext()
        let job = makeJob("a", status: .running, in: context)
        try context.save()

        let manager = StartupRecoveryManager()
        let coordinator = makeCoordinator()
        let cleaned = try manager.recoverStaleJobsIfNeeded(
            coordinator: coordinator, modelContext: context
        )
        #expect(cleaned == 1)
        #expect(job.jobStatus == .failed)
        #expect(job.errorMessage?.contains("未完成状态") == true)
        #expect(job.pipelineFraction == 0.0)
    }

    @Test func recover_marksProcessingJobAsFailed() throws {
        let context = try makeContext()
        let job = makeJob("a", status: .processing, in: context)
        try context.save()

        let manager = StartupRecoveryManager()
        let coordinator = makeCoordinator()
        let cleaned = try manager.recoverStaleJobsIfNeeded(
            coordinator: coordinator, modelContext: context
        )
        #expect(cleaned == 1)
        #expect(job.jobStatus == .failed)
    }

    @Test func recover_keepsQueuedJobUntouched() throws {
        let context = try makeContext()
        let job = makeJob("a", status: .queued, in: context)
        try context.save()

        let manager = StartupRecoveryManager()
        let coordinator = makeCoordinator()
        let cleaned = try manager.recoverStaleJobsIfNeeded(
            coordinator: coordinator, modelContext: context
        )
        // queued 不算 stale，不应该被清
        #expect(cleaned == 0)
        #expect(job.jobStatus == .queued)
    }

    @Test func recover_clearsRunningCleanupStatus() throws {
        // 用 .queued 状态（不会被 stale 逻辑改、也不会被 reconcile 改），
        // 单独验证 cleanupJobStatus == .running 的清空路径。
        let context = try makeContext()
        let job = makeJob("a", status: .queued, in: context)
        job.cleanupJobStatus = .running
        try context.save()

        let manager = StartupRecoveryManager()
        let coordinator = makeCoordinator()
        _ = try manager.recoverStaleJobsIfNeeded(
            coordinator: coordinator, modelContext: context
        )
        // job.status 保留 .queued（cleanup 失败不该拖累转写）
        #expect(job.jobStatus == .queued)
        // 但 cleanup 状态被清
        #expect(job.cleanupJobStatus == nil)
    }

    @Test func backgroundRecoveryReturnsSendableSnapshotAndPersistsChanges() async throws {
        let context = try makeContext()
        let job = makeJob("background", status: .running, in: context)
        try context.save()

        let manager = StartupRecoveryManager()
        let coordinator = makeCoordinator()
        let snapshot = try await manager.recoverStaleJobsInBackground(
            coordinator: coordinator, modelContext: context
        )

        #expect(snapshot.cleanedJobCount == 1)
        #expect(snapshot.jobs.contains { $0.id == job.id && $0.status == .failed })
        // Re-fetch through the caller's context: the detached worker must have
        // persisted the mutation to the shared store, not just its own model.
        let reloaded = try #require(try ASRJobRepository.findById(job.id, in: context))
        #expect(reloaded.jobStatus == .failed)
        #expect(try await manager.recoverStaleJobsInBackground(
            coordinator: coordinator, modelContext: context
        ).jobs.isEmpty)
    }

    @Test func backgroundRecoveryCoalescesConcurrentCallers() async throws {
        let context = try makeContext()
        let job = makeJob("coalesced", status: .processing, in: context)
        try context.save()

        let manager = StartupRecoveryManager()
        let coordinator = makeCoordinator()
        let first = Task { @MainActor in
            try await manager.recoverStaleJobsInBackground(
                coordinator: coordinator, modelContext: context
            )
        }
        let second = Task { @MainActor in
            try await manager.recoverStaleJobsInBackground(
                coordinator: coordinator, modelContext: context
            )
        }
        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value

        #expect(firstSnapshot == secondSnapshot)
        #expect(firstSnapshot.cleanedJobCount == 1)
        #expect(try #require(try ASRJobRepository.findById(job.id, in: context)).jobStatus == .failed)
    }

    // MARK: - 协程操作

    @Test func prewarm_doesNotCrash() async {
        let manager = StartupRecoveryManager()
        // Wait for the task this test starts. Leaving ORT session construction
        // detached while the test host exits can race process teardown.
        await manager.prewarmModelsIfNeeded().value
        #expect(
            manager.prewarmedPipelines.readiness(for: SettingsStore.modelsRoot) != .warming
        )
        manager.releasePrewarmedModels()
    }

    @Test func release_isIdempotent() {
        let manager = StartupRecoveryManager()
        manager.releasePrewarmedModels()
        manager.releasePrewarmedModels()  // 不应崩
    }
}
