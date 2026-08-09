import Foundation
import SwiftUI
import SwiftData

/// UI-facing façade for file actions. Operational workflows live in dedicated
/// services; this type owns observable state, action entry points, and wiring.
@MainActor
public final class FileActionCoordinator: ObservableObject {
    typealias PipelineRunnerBuilder = @MainActor (
        _ jobId: String,
        _ modelsRoot: String,
        _ modelContext: ModelContext
    ) async throws -> PipelineRunner

    typealias SpeakerInputWriter = (_ input: SpeakerRecognitionInput, _ path: URL) throws -> Void

    struct CleanupOutcome: Equatable {
        enum Kind: Equatable { case success, cancelled, failure }
        let jobId: String
        let kind: Kind
        let message: String
    }

    struct ActiveTask: Equatable {
        enum Kind: String, Equatable {
            case transcription = "转写/说话人识别"
            case cleanup = "润色"
        }

        let kind: Kind
        let jobId: String
        let detail: String
    }

    @Published var state = CoordinatorState()

    /// Queue policy is intentionally independent from pipeline execution.
    let queueScheduler: JobQueueScheduler
    private let pipelineRunnerBuilder: PipelineRunnerBuilder?
    private let speakerInputWriter: SpeakerInputWriter
    /// F4.14 throttle: 缓存每个 jobId 上次进入"检查路径"时的 (stage, fraction)。
    /// `applyPipelineProgress` 调用 `findById + updatePipelineProgress` 之前
    /// 先查这里：只有 stage 变化 / fraction 步进 ≥ 5% / 起止点 才走检查
    /// 路径。**注意**："走检查路径" ≠ "save" — 真正的 save 仍只在
    /// `JobLifecycleStore.updatePipelineProgress` 内部 stage 变化 / 0 / 1
    private var lastCheckedProgress: [String: CheckedProgress] = [:]

    func clearCheckedProgress(for jobId: String) {
        lastCheckedProgress.removeValue(forKey: jobId)
    }
    private lazy var pipelineRuns = PipelineRunCoordinator(
        coordinator: self,
        pipelineRunnerBuilder: pipelineRunnerBuilder,
        speakerInputWriter: speakerInputWriter
    )
    private lazy var jobActions = JobActionService(coordinator: self)
    private lazy var speakerReidentification = SpeakerReidentificationCoordinator(
        fileActions: self,
        pipelineRuns: pipelineRuns
    )

    /// F4.14 throttle 用的最近检查点。`stage` + `fraction` 联合起来
    /// 决定下一次是否值得跑 findById + updatePipelineProgress（"检查路径"）。
    /// `Equatable` 方便单元测试。`internal` 暴露给 `@testable import SwiftASR` 单测
    /// `shouldCheckProgress`。
    struct CheckedProgress: Equatable {
        let stage: String
        let fraction: Double
    }

    /// F4.14 throttle 决策（pure function，单元测试直接覆盖）。
    /// 决定是否值得为这次 progress 跑 `findById` + `updatePipelineProgress`：
    /// - 起止点（fraction 0 / 1）永远要持久化
    /// - 第一次（last == nil）要持久化
    /// - stage 变化要持久化
    /// - fraction 步进 ≥ `step`（默认 5%）要持久化
    /// - 其他情况跳过持久化（UI 仍每次更新）
    ///
    /// UI state 不受 throttle 影响 — 用户看到的是实时进度条；
    /// 只跳过 SwiftData findById / PipelineSnapshot 构造 / save。
    /// F4.14 throttle 决策（pure function，单元测试直接覆盖）。
    /// 决定是否值得为这次 progress 跑 `findById` + `updatePipelineProgress`
    /// **检查路径**：
    /// - 起止点（fraction 0 / 1）触发
    /// - 第一次（last == nil）触发
    /// - stage 变化触发
    /// - fraction 步进 ≥ `step`（默认 5%）触发
    /// - 其他情况（< 5% 步进且同 stage）跳过检查路径
    ///
    /// **重要**：返回 `true` 并不意味着 SwiftData 真的 `save()` 了 — 真正的
    /// save 决策由 `JobLifecycleStore.updatePipelineProgress` 内部再次节流
    /// （`stageChanged || fraction >= 1 || fraction == 0`）。所以 5% 步进
    /// 触发的是 findById + PipelineSnapshot 构造（用来检测 job 引用是否还
    /// 有效 + 刷新 lastCheckedProgress 缓存），但不会触发实际 save。
    /// Save 仍只在 stage 变化 / 起止点发生。
    ///
    /// UI state 不受 throttle 影响 — 用户看到的是实时进度条；
    /// 检查路径只在 5% 步进及以上走，< 5% 步进完全跳过。
    /// `internal` 暴露给 `@testable import SwiftASR` 单测。
    static func shouldCheckProgress(
        stage: String,
        fraction: Double,
        last: CheckedProgress?,
        step: Double = 0.05
    ) -> Bool {
        if fraction == 0 || fraction >= 1 { return true }
        guard let last else { return true }
        if last.stage != stage { return true }
        return abs(last.fraction - fraction) >= step
    }

    init(
        settingsStore: SettingsStore = .shared,
        pipelineRunnerBuilder: PipelineRunnerBuilder? = nil,
        speakerInputWriter: @escaping SpeakerInputWriter = ResultStore.writeSpeakerInput
    ) {
        self.queueScheduler = JobQueueScheduler(settingsStore: settingsStore)
        self.pipelineRunnerBuilder = pipelineRunnerBuilder
        self.speakerInputWriter = speakerInputWriter
        state.isQueuePaused = queueScheduler.isPaused()
    }

    // MARK: Observable state compatibility

    var showFileImporter: Bool {
        get { state.showFileImporter }
        set { state.showFileImporter = newValue }
    }
    var actionErrorMessage: String? {
        get { state.actionErrorMessage }
        set { state.actionErrorMessage = newValue }
    }
    var isQueuePaused: Bool {
        get { state.isQueuePaused }
        set { state.isQueuePaused = newValue }
    }
    var activeRuns: [String: PipelineRunHandle] {
        get { state.activeRuns }
        set { state.activeRuns = newValue }
    }
    var activeTranscriptionJobId: String? {
        get { state.activeTranscriptionJobId }
        set { state.activeTranscriptionJobId = newValue }
    }
    var activeTranscriptionStage: String {
        get { state.activeTranscriptionStage }
        set { state.activeTranscriptionStage = newValue }
    }
    var activeTranscriptionFraction: Double {
        get { state.activeTranscriptionFraction }
        set { state.activeTranscriptionFraction = newValue }
    }
    var activeTranscriptionMessage: String {
        get { state.activeTranscriptionMessage }
        set { state.activeTranscriptionMessage = newValue }
    }
    var activeStageMetrics: PipelineStageMetrics? {
        get { state.activeStageMetrics }
        set { state.activeStageMetrics = newValue }
    }
    var activeCleanupJobId: String? {
        get { state.activeCleanupJobId }
        set { state.activeCleanupJobId = newValue }
    }
    var activeCleanupToken: CancellationToken? {
        get { state.activeCleanupToken }
        set { state.activeCleanupToken = newValue }
    }
    var activeCleanupTask: Task<Void, Never>? {
        get { state.activeCleanupTask }
        set { state.activeCleanupTask = newValue }
    }
    var activeCleanupProgress: String? {
        get { state.activeCleanupProgress }
        set { state.activeCleanupProgress = newValue }
    }
    var lastCleanupOutcome: CleanupOutcome? {
        get { state.lastCleanupOutcome }
        set { state.lastCleanupOutcome = newValue }
    }

    var hasActivePipeline: Bool { !activeRuns.isEmpty }

    func activeTasksForTermination() -> [ActiveTask] {
        var tasks = activeRuns.keys.sorted().map { jobId in
            let detail: String
            if jobId == activeTranscriptionJobId {
                let percent = Int((activeTranscriptionFraction * 100).rounded())
                detail = activeTranscriptionMessage.isEmpty
                    ? "\(percent)%"
                    : "\(activeTranscriptionMessage)（\(percent)%）"
            } else {
                detail = "处理中"
            }
            return ActiveTask(kind: .transcription, jobId: jobId, detail: detail)
        }
        if let jobId = activeCleanupJobId {
            tasks.append(ActiveTask(
                kind: .cleanup,
                jobId: jobId,
                detail: activeCleanupProgress ?? "正在请求 Gemini"
            ))
        }
        return tasks
    }

    func cancelActiveTasksForTermination() {
        for run in activeRuns.values {
            run.token.cancel()
            run.task?.cancel()
        }
        activeCleanupToken?.cancel()
        activeCleanupTask?.cancel()
    }

    func prewarmModelsIfNeeded() {
        pipelineRuns.prewarmModelsIfNeeded()
    }

    func releasePrewarmedModels() {
        pipelineRuns.releasePrewarmedModels()
    }

    @discardableResult
    func recoverStaleJobsIfNeeded(modelContext: ModelContext) throws -> Int {
        try pipelineRuns.recoverStaleJobsIfNeeded(modelContext: modelContext)
    }

    func recoverStaleJobsInBackground(
        modelContext: ModelContext
    ) async throws -> StartupRecoverySnapshot {
        try await pipelineRuns.recoverStaleJobsInBackground(modelContext: modelContext)
    }

    /// Startup recovery is the only caller; normal runs clean themselves up.
    func clearActivePipelineTransients() {
        activeRuns.removeAll()
        activeTranscriptionJobId = nil
        activeTranscriptionStage = ""
        activeTranscriptionFraction = 0
        activeTranscriptionMessage = ""
    }

    func hasRunningPipelineExcluding(currentJobId: String) -> Bool {
        activeRuns.contains { $0.key != currentJobId }
    }

    @discardableResult
    func startCleanupIfIdle(jobId: String) -> Bool {
        if activeCleanupJobId != nil && activeCleanupJobId != jobId { return false }
        activeCleanupJobId = jobId
        if lastCleanupOutcome?.jobId == jobId { lastCleanupOutcome = nil }
        return true
    }

    func recordCleanupOutcome(jobId: String, kind: CleanupOutcome.Kind, message: String) {
        lastCleanupOutcome = CleanupOutcome(jobId: jobId, kind: kind, message: message)
    }

    func finishCleanup(jobId: String) {
        guard activeCleanupJobId == jobId else { return }
        activeCleanupJobId = nil
        activeCleanupToken = nil
        activeCleanupTask = nil
        activeCleanupProgress = nil
    }

    func alertOtherPipelineRunning() {
        AlertHelper.showInfo(
            title: "已有任务在跑",
            message: "全局同时只能跑一个转写/说话人识别。请先等当前任务完成后再试。"
        )
    }

    func alertOtherCleanupRunning() {
        AlertHelper.showInfo(
            title: "已有润色在跑",
            message: "全局同时只能跑一个润色。请先等当前润色完成后再试。"
        )
    }

    @discardableResult
    func importAudioFile(
        url: URL,
        jobs: [ASRJob],
        selectedJobId: inout String?,
        modelContext: ModelContext,
        autoStart: Bool
    ) -> Bool {
        jobActions.importAudioFile(
            url: url,
            jobs: jobs,
            selectedJobId: &selectedJobId,
            modelContext: modelContext,
            autoStart: autoStart
        )
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    func reportActionError(_ message: String) {
        actionErrorMessage = message
        Logger.shared.error(message)
    }

    func retranscribe(job: ASRJob, modelContext: ModelContext) {
        jobActions.retranscribe(job: job, modelContext: modelContext)
    }

    func reidentifySpeakers(job: ASRJob, modelContext: ModelContext) {
        speakerReidentification.reidentifySpeakers(job: job, modelContext: modelContext)
    }

    func startQueuedRetranscription(job: ASRJob, modelContext: ModelContext) {
        jobActions.startQueuedRetranscription(job: job, modelContext: modelContext)
    }

    func startQueuedReidentification(job: ASRJob, modelContext: ModelContext) {
        speakerReidentification.startQueuedReidentification(job: job, modelContext: modelContext)
    }

    /// Releases only the run that owns this token. This prevents a stale task
    /// from erasing state after the same job has been restarted.
    func cleanupTranscriptionState(
        jobId: String,
        runID: UUID,
        advanceQueue: Bool,
        modelContext: ModelContext
    ) {
        // M5.3 (round-3): 即使守卫失败也要清掉 throttle 缓存。
        // 守卫失败意味着这个 run 已经不是 activeRuns[jobId] 的 owner（旧
        // run 已被新 run 接管，或 id 不匹配）。如果不清 stale 缓存，
        // 新 run 第一次 progress 若 stage 跟旧值相同且 fraction 步进 < 5%，
        // 会被错误跳过（典型 case：旧值 stage="load" 0.0，新值
        // stage="load" 0.0，abs(0-0) = 0 < 0.05 → 跳 persist）。
        lastCheckedProgress.removeValue(forKey: jobId)
        guard activeRuns[jobId]?.id == runID else { return }
        activeRuns[jobId] = nil
        // F4.14: 清掉 throttle 缓存，否则同 jobId 重启新 run 后第一次
        // progress 会误判为"无显著变化"被跳过。
        // (重复清理一次无害，map.removeValue 对 missing key 是 no-op)
        if activeTranscriptionJobId == jobId {
            activeTranscriptionJobId = nil
            activeTranscriptionStage = ""
            activeTranscriptionFraction = 0
            activeTranscriptionMessage = ""
        }
        if advanceQueue { startNextQueuedJobIfPossible(modelContext: modelContext) }
    }

    func applyPipelineProgress(
        jobId: String,
        runID: UUID,
        token: CancellationToken,
        stage: String,
        fraction: Double,
        message: String,
        modelContext: ModelContext
    ) {
        guard activeRuns[jobId]?.id == runID,
              activeRuns[jobId]?.token === token,
              activeTranscriptionJobId == jobId else { return }
        // UI state 每次都更新（用户看到的是实时进度条）
        activeTranscriptionStage = stage
        activeTranscriptionFraction = fraction
        activeTranscriptionMessage = message
        // F4.14: 节流 SwiftData 检查路径。1h 音频 ~200-500 次 progress
        // 回调，原来每次都 findById + PipelineSnapshot (24 字段) +
        // 可能的 save。现在按 stage 变化 / 5% 步进 / 起止点 触发"检查
        // 路径"（findById + snapshot 构造 + 缓存更新）；< 5% 步进同
        // stage 完全跳过。**注意**：触发检查路径 ≠ 触发 save — 真正的
        // save 决策由 `JobLifecycleStore.updatePipelineProgress` 内部
        // 做（stage 变化 / 0 / 1 才 save）。1h 音频实际 save 数仍为
        // stage 切换 + 起止点，跟修复前一致；节省的是中间步进的
        // findById + snapshot。UI 仍每次更新。
        let last = lastCheckedProgress[jobId]
        guard Self.shouldCheckProgress(stage: stage, fraction: fraction, last: last) else {
            return
        }
        do {
            if let job = try ASRJobRepository.findById(jobId, in: modelContext) {
                try JobLifecycleStore(modelContext: modelContext).updatePipelineProgress(
                    job, stage: stage, fraction: fraction, message: message
                )
                lastCheckedProgress[jobId] = CheckedProgress(stage: stage, fraction: fraction)
            }
        } catch {
            Logger.shared.error("无法持久化任务进度：\(error)")
        }
    }

    func applyStageMetrics(
        jobId: String,
        runID: UUID,
        token: CancellationToken,
        stage: String,
        metrics: PipelineStageMetrics,
        modelContext: ModelContext
    ) {
        guard activeRuns[jobId]?.id == runID,
              activeRuns[jobId]?.token === token,
              activeTranscriptionJobId == jobId else { return }
        activeStageMetrics = metrics
        do {
            if let job = try ASRJobRepository.findById(jobId, in: modelContext) {
                try JobLifecycleStore(modelContext: modelContext)
                    .updateStageMetrics(job, stage: stage, metrics: metrics)
            }
        } catch {
            Logger.shared.error("无法持久化阶段指标：\(error)")
        }
    }

    func deleteJob(
        job: ASRJob,
        selectedJobId: inout String?,
        modelContext: ModelContext,
        confirm: Bool = true
    ) {
        jobActions.deleteJob(
            job: job,
            selectedJobId: &selectedJobId,
            modelContext: modelContext,
            confirm: confirm
        )
    }

    func cancelPipeline(jobId: String) {
        activeRuns[jobId]?.token.cancel()
        activeRuns[jobId]?.task?.cancel()
    }

    @discardableResult
    func persistPartialResultIfAvailable(
        job: ASRJob,
        modelContext: ModelContext
    ) -> PartialResultPersistenceOutcome {
        pipelineRuns.persistPartialResultIfAvailable(job: job, modelContext: modelContext)
    }

    func runPipeline(jobId: String, audioPath: String, modelContext: ModelContext) {
        pipelineRuns.runPipeline(jobId: jobId, audioPath: audioPath, modelContext: modelContext)
    }
}
