import Foundation
import SwiftData

/// 队列调度：从 `FileActionCoordinator` 抽出的纯 queue 机制（2026-07-21）。
///
/// 设计：**无状态 service**，不持有 `@Published`，不调用 `runPipeline`。
/// 关心的是"队列怎么读 / 怎么改 / 暂停状态怎么持久化"。
///
/// 触发 pipeline 的决策（`shouldAutoStart`）只读取调度策略 + 外部传入的
/// `pipelineActive` 标志位，不直接发起 pipeline——避免调度器反向依赖
/// coordinator 的 `runPipeline`。
///
/// `importAudioFile` / `startQueuedJob` 这类"用户动作 → 入队 → 跑 pipeline"的
/// action handlers 留在 coordinator：它们既写队列又触发 pipeline，是
/// 跨 queue/pipeline 边界的组合，拆开反而会增加循环依赖。
@MainActor
struct JobQueueScheduler {
    let settingsStore: SettingsStore

    init(settingsStore: SettingsStore = .shared) {
        self.settingsStore = settingsStore
    }

    // MARK: - 暂停状态

    /// 当前是否暂停。读自 `SettingsStore`，持久化在 `~/Library/Application Support/` 下。
    func isPaused() -> Bool {
        settingsStore.queueSettings().isPaused
    }

    /// 写入暂停状态。coordinator 负责同步自己的 `@Published isQueuePaused` 触发 view 重渲染。
    func setPaused(_ paused: Bool) {
        var settings = settingsStore.queueSettings()
        settings.isPaused = paused
        settingsStore.setQueueSettings(settings)
    }

    // MARK: - 队列读 / 写

    /// 读下一个 ordered queued job，不发起 pipeline。
    /// 调用方负责把 jobId 喂给 `runPipeline`。
    func nextQueued(modelContext: ModelContext) throws -> ASRJob? {
        try JobLifecycleStore(modelContext: modelContext).orderedQueuedJobs().first
    }

    /// 调整队列顺序。`offset = -1` 上移一位，`+1` 下移一位。
    func moveQueuedJob(jobId: String, by offset: Int, modelContext: ModelContext) throws {
        try JobLifecycleStore(modelContext: modelContext).moveQueuedJob(id: jobId, by: offset)
    }

    func reorderQueuedJobs(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        modelContext: ModelContext
    ) throws {
        try JobLifecycleStore(modelContext: modelContext)
            .reorderQueuedJobs(fromOffsets: offsets, toOffset: destination)
    }

    // MARK: - 自动启动决策

    /// 是否应该自动启动下一个 queued job。
    /// - 依赖：用户开启了"自动开始下一个"+ 队列没暂停 + 当前没有正在跑的 pipeline
    /// - `pipelineActive` 由 coordinator 传入（`hasActivePipeline`），保持 scheduler
    ///   对 coordinator @Published 状态无依赖
    func shouldAutoStart(pipelineActive: Bool) -> Bool {
        let settings = settingsStore.queueSettings()
        return settings.automaticallyStartNext && !settings.isPaused && !pipelineActive
    }
}
