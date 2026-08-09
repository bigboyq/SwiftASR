import Foundation
import SwiftData

/// Sendable startup data returned by the background SwiftData context. SwiftData
/// model objects must not cross the context/actor boundary, so the shell uses
/// these immutable values for its initial selection and match-index warm-up.
struct StartupJobSnapshot: Sendable, Equatable {
    let id: String
    let status: JobStatus
    let createdAt: Date
    let finishedAt: Date?
    let cleanedAt: Date?
    let lastOperationAt: Date?

    var mostRecentActivity: Date {
        var latest = createdAt
        if let finishedAt, finishedAt > latest { latest = finishedAt }
        if let cleanedAt, cleanedAt > latest { latest = cleanedAt }
        if let lastOperationAt, lastOperationAt > latest { latest = lastOperationAt }
        return latest
    }
}

struct StartupRecoverySnapshot: Sendable, Equatable {
    let cleanedJobCount: Int
    let jobs: [StartupJobSnapshot]
    let profiles: [SpeakerMatchProfileSnapshot]

    static let empty = StartupRecoverySnapshot(
        cleanedJobCount: 0, jobs: [], profiles: []
    )
}

/// Owns all startup work that can be performed with a background SwiftData
/// context. It deliberately returns values, never `@Model` instances.
private enum StartupRecoveryWorker {
    static func run(container: ModelContainer) throws -> StartupRecoverySnapshot {
        let context = ModelContext(container)
        let cleaned = try StaleJobCleanupService.cleanup(in: context, when: .appLaunch)
        let reconciled = try ResultArtifactReconciliationService.reconcile(in: context)
        if reconciled > 0 {
            Logger.shared.warn("启动时修复 \(reconciled) 个结果 artifact/job 状态不一致")
        }
        let migrated = try SpeakerProfileOccurrenceMigrator.migrateIfNeeded(in: context)
        if migrated > 0 {
            Logger.shared.info("已迁移 \(migrated) 条 job/profile occurrence")
        }
        try normalizeQueue(in: context)

        let jobs = try ASRJobRepository.fetchAll(in: context).map {
            StartupJobSnapshot(
                id: $0.id,
                status: $0.jobStatus,
                createdAt: $0.createdAt,
                finishedAt: $0.finishedAt,
                cleanedAt: $0.cleanedAt,
                lastOperationAt: $0.lastOperationAt
            )
        }
        let profiles = try SpeakerProfileRepository.fetchAll(in: context).map {
            SpeakerMatchProfileSnapshot(
                profileId: $0.id,
                fingerprintId: $0.fingerprintId,
                personId: $0.person?.id,
                personName: $0.person?.name,
                embedding: $0.embedding ?? []
            )
        }
        return StartupRecoverySnapshot(
            cleanedJobCount: cleaned,
            jobs: jobs,
            profiles: profiles
        )
    }

    private static func normalizeQueue(in context: ModelContext) throws {
        let queuedStatus = JobStatus.queued.rawValue
        let descriptor = FetchDescriptor<ASRJob>(
            predicate: #Predicate { $0.status == queuedStatus },
            sortBy: [
                SortDescriptor(\.queueOrder),
                SortDescriptor(\.createdAt),
                SortDescriptor(\.id)
            ]
        )
        for (position, job) in try context.fetch(descriptor).enumerated() {
            job.queueOrder = position
        }
        try context.save()
    }
}

/// 启动期模型预热 + stale 状态恢复。从 `FileActionCoordinator` 抽出（2026-07-21）：
///
/// 职责单一：负责进程重启后让用户看不到"上次崩了"的残留状态，
/// 跟 coordinator 日常的 queue / pipeline / 进度分发职责完全正交。
///
/// 持有 `prewarmedPipelines`（常驻模型 session）和 `didRunStartupRecovery`
/// 一次执行守门。`recoverStaleJobsIfNeeded` 仍需 `coordinator` 引用，
/// 因为 `StaleJobCleanupService.clearCoordinatorTransients` 直接写 coordinator
/// 上的 `@Published` transient 字段，view 端才能立刻看到。
@MainActor
final class StartupRecoveryManager {
    /// 常驻的只有模型 session；每个 pipeline run 的 PCM / fbank 仍是局部变量，完成后释放。
    let prewarmedPipelines = PrewarmedAudioPipelineStore()
    /// 只允许执行一次启动恢复。SwiftUI 的 onAppear 可能重复触发，但重复触发
    /// 不应把正在运行的 job 再次当作 stale 清理。
    private var didRunStartupRecovery = false
    private var backgroundRecoveryStarted = false
    /// Coalesces repeated SwiftUI `onAppear` calls while the background pass
    /// is still running. A second caller observes the same result instead of
    /// opening a second context and replaying migrations concurrently.
    private var backgroundRecoveryTask: Task<StartupRecoverySnapshot, Error>?

    init() {}

    /// 应用启动后后台创建 ONNX / CoreML session；不阻塞主界面。
    /// Returns the scheduled task so tests and orderly shutdown paths can
    /// await it; normal UI callers intentionally ignore the result and stay
    /// non-blocking.
    @discardableResult
    func prewarmModelsIfNeeded() -> Task<Void, Never> {
        let modelsRoot = SettingsStore.modelsRoot
        return Task { [prewarmedPipelines] in
            do {
                try await prewarmedPipelines.prewarm(modelsRoot: modelsRoot)
            } catch {
                Logger.shared.error("转写模型预热失败：\(error.localizedDescription)")
            }
        }
    }

    /// AppDelegate 在确认退出后调用；显式释放预热模型，而不是让它们一直留到进程回收。
    func releasePrewarmedModels() {
        prewarmedPipelines.release()
    }

    /// 启动恢复：清 coordinator transient + 清理 SwiftData stale job +
    /// 修复 result.json artifact 跟 job 状态不一致 + 迁移旧 occurrence +
    /// 归一化队列顺序。失败时允许下次 onAppear 重试。
    @discardableResult
    func recoverStaleJobsIfNeeded(
        coordinator: FileActionCoordinator,
        modelContext: ModelContext
    ) throws -> Int {
        guard !didRunStartupRecovery else { return 0 }
        StaleJobCleanupService.clearCoordinatorTransients(coordinator)
        do {
            let cleaned = try StaleJobCleanupService.cleanup(
                in: modelContext, when: .appLaunch
            )
            let reconciled = try ResultArtifactReconciliationService.reconcile(in: modelContext)
            if reconciled > 0 {
                Logger.shared.warn("启动时修复 \(reconciled) 个结果 artifact/job 状态不一致")
            }
            let migrated = try SpeakerProfileOccurrenceMigrator.migrateIfNeeded(in: modelContext)
            if migrated > 0 {
                Logger.shared.info("已迁移 \(migrated) 条 job/profile occurrence")
            }
            try JobLifecycleStore(modelContext: modelContext).normalizeQueue()
            didRunStartupRecovery = true
            return cleaned
        } catch {
            // 只有持久化和队列恢复都成功后才标记完成，失败时允许下次 onAppear 重试。
            throw error
        }
    }

    /// Runs startup recovery on a dedicated SwiftData context. The caller's
    /// main-actor context is used only to obtain the shared container; no
    /// model object crosses into the detached task.
    func recoverStaleJobsInBackground(
        coordinator: FileActionCoordinator,
        modelContext: ModelContext
    ) async throws -> StartupRecoverySnapshot {
        guard !didRunStartupRecovery else { return .empty }
        if backgroundRecoveryStarted {
            // The flag is set before the first suspension below, so a second
            // onAppear cannot start another recovery pass. The task normally
            // exists here; the empty fallback only covers a completed pass
            // between the flag check and this read.
            if let backgroundRecoveryTask {
                return try await backgroundRecoveryTask.value
            }
            return .empty
        }
        backgroundRecoveryStarted = true
        StaleJobCleanupService.clearCoordinatorTransients(coordinator)
        let container = modelContext.container
        let task = Task.detached(priority: .utility) {
            try StartupRecoveryWorker.run(container: container)
        }
        backgroundRecoveryTask = task
        do {
            let snapshot = try await task.value
            backgroundRecoveryTask = nil
            didRunStartupRecovery = true
            return snapshot
        } catch {
            // Keep the gate closed so the visible retry action can run the
            // complete recovery again after a transient store/file failure.
            backgroundRecoveryTask = nil
            backgroundRecoveryStarted = false
            throw error
        }
    }
}
