import Foundation
import SwiftData
import Testing
@testable import SwiftASR

/// `JobQueueScheduler` 单元测试（2026-07-22）。
///
/// 关注纯函数 `shouldAutoStart(pipelineActive:)` 的三条件全矩阵，
/// 以及 settings / SwiftData 往返行为。`SettingsStore` 走
/// `createTestInstance()`（指向 `~/Library/...` 但串行测试隔离）。
@Suite(.serialized)
@MainActor
struct JobQueueSchedulerTests {
    // MARK: - Fixtures

    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let config = ModelConfiguration(
            "JobQueueSchedulerTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func makeJob(_ id: String, in context: ModelContext) -> ASRJob {
        let job = ASRJob(
            id: id,
            sourceAudioPath: "/tmp/\(id).wav",
            sourceAudioHash: id,
            durationSeconds: 0
        )
        context.insert(job)
        return job
    }

    // MARK: - shouldAutoStart 三条件矩阵

    @Test func shouldAutoStart_allConditionsMet_returnsTrue() {
        let settings = SettingsStore.createTestInstance()
        settings.setQueueSettings(SettingsStore.QueueSettings(isPaused: false, automaticallyStartNext: true))
        let scheduler = JobQueueScheduler(settingsStore: settings)
        #expect(scheduler.shouldAutoStart(pipelineActive: false) == true)
    }

    @Test func shouldAutoStart_paused_returnsFalse() {
        let settings = SettingsStore.createTestInstance()
        settings.setQueueSettings(SettingsStore.QueueSettings(isPaused: true, automaticallyStartNext: true))
        let scheduler = JobQueueScheduler(settingsStore: settings)
        #expect(scheduler.shouldAutoStart(pipelineActive: false) == false)
    }

    @Test func shouldAutoStart_autoStartDisabled_returnsFalse() {
        let settings = SettingsStore.createTestInstance()
        settings.setQueueSettings(SettingsStore.QueueSettings(isPaused: false, automaticallyStartNext: false))
        let scheduler = JobQueueScheduler(settingsStore: settings)
        #expect(scheduler.shouldAutoStart(pipelineActive: false) == false)
    }

    @Test func shouldAutoStart_pipelineActive_returnsFalse() {
        let settings = SettingsStore.createTestInstance()
        settings.setQueueSettings(SettingsStore.QueueSettings(isPaused: false, automaticallyStartNext: true))
        let scheduler = JobQueueScheduler(settingsStore: settings)
        #expect(scheduler.shouldAutoStart(pipelineActive: true) == false)
    }

    @Test func shouldAutoStart_allOff_returnsFalse() {
        let settings = SettingsStore.createTestInstance()
        settings.setQueueSettings(SettingsStore.QueueSettings(isPaused: true, automaticallyStartNext: false))
        let scheduler = JobQueueScheduler(settingsStore: settings)
        #expect(scheduler.shouldAutoStart(pipelineActive: true) == false)
    }

    // MARK: - 暂停状态持久化

    @Test func pausedRoundTripsThroughSettingsStore() {
        let settings = SettingsStore.createTestInstance()
        let scheduler = JobQueueScheduler(settingsStore: settings)
        // 干净起点
        scheduler.setPaused(false)
        #expect(scheduler.isPaused() == false)
        // 翻转
        scheduler.setPaused(true)
        #expect(scheduler.isPaused() == true)
        // 重建 scheduler 验证持久化
        let other = JobQueueScheduler(settingsStore: settings)
        #expect(other.isPaused() == true)
        // 还原
        scheduler.setPaused(false)
    }

    // MARK: - nextQueued / moveQueuedJob SwiftData 集成

    @Test func nextQueued_returnsFirstInOrder() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let a = makeJob("a", in: context)
        try store.enqueue(a)
        let b = makeJob("b", in: context)
        try store.enqueue(b)
        let c = makeJob("c", in: context)
        try store.enqueue(c)

        let settings = SettingsStore.createTestInstance()
        let scheduler = JobQueueScheduler(settingsStore: settings)
        let next = try scheduler.nextQueued(modelContext: context)
        #expect(next?.id == "a")
    }

    @Test func nextQueued_emptyQueueReturnsNil() throws {
        let context = try makeContext()
        let settings = SettingsStore.createTestInstance()
        let scheduler = JobQueueScheduler(settingsStore: settings)
        let next = try scheduler.nextQueued(modelContext: context)
        #expect(next == nil)
    }

    @Test func moveQueuedJob_reordersViaLifecycleStore() throws {
        let context = try makeContext()
        let store = JobLifecycleStore(modelContext: context)
        let a = makeJob("a", in: context)
        try store.enqueue(a)
        let b = makeJob("b", in: context)
        try store.enqueue(b)
        let c = makeJob("c", in: context)
        try store.enqueue(c)

        let settings = SettingsStore.createTestInstance()
        let scheduler = JobQueueScheduler(settingsStore: settings)

        // 把 c 下移 1 位（→ 末尾不变；上移 1 位 → 跟 b 交换）
        try scheduler.moveQueuedJob(jobId: "c", by: -1, modelContext: context)
        let next = try scheduler.nextQueued(modelContext: context)
        #expect(next?.id == "a")  // a 仍然是头
        let second = try JobLifecycleStore(modelContext: context).orderedQueuedJobs()[1]
        #expect(second.id == "c")
    }
}
