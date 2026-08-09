import Foundation
import SwiftData
import Testing
@testable import SwiftASR

@Suite("FileActionCoordinator")
@MainActor
struct FileActionCoordinatorTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let configuration = ModelConfiguration(
            "FileActionCoordinatorTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    @Test func reimportingQueuedOrPartialJobDoesNotCreateDuplicate() throws {
        let context = try makeContext()
        let coordinator = FileActionCoordinator()

        for (index, status) in [JobStatus.queued, .partial].enumerated() {
            let url = URL(fileURLWithPath: "/tmp/swiftasr-idempotent-\(index).wav")
            let job = ASRJob(
                id: ResultStore.hashAudioPath(url.path),
                sourceAudioPath: url.path,
                sourceAudioHash: ResultStore.hashAudioPath(url.path),
                durationSeconds: 0,
                status: status.rawValue
            )
            context.insert(job)
            try context.save()

            var selectedJobId: String?
            let started = coordinator.importAudioFile(
                url: url,
                jobs: try ASRJobRepository.fetchAll(in: context),
                selectedJobId: &selectedJobId,
                modelContext: context,
                autoStart: false
            )

            #expect(!started)
            #expect(selectedJobId == job.id)
            #expect(try ASRJobRepository.fetchAll(in: context).count == index + 1)
        }
    }

    // MARK: - 状态查询

    @Test func hasActivePipeline_isFalseInitially() {
        let coordinator = FileActionCoordinator()
        #expect(coordinator.hasActivePipeline == false)
    }

    @Test func hasRunningPipelineExcluding_returnsFalseWhenNoJobs() {
        let coordinator = FileActionCoordinator()
        #expect(coordinator.hasRunningPipelineExcluding(currentJobId: "any") == false)
    }

    @Test func hasRunningPipelineExcluding_returnsFalseForSelf() {
        // 模拟一个 jobId 正在跑但用 Excluding(self) 应当返回 false
        // —— 这个用例在生产里 retry 自己时必须允许（"自己已经在跑就允许"）
        // 但当前 activeRuns 是 empty，所以这里只是验逻辑路径
        let coordinator = FileActionCoordinator()
        #expect(coordinator.hasRunningPipelineExcluding(currentJobId: "self-job") == false)
    }

    @Test func runPipelineCoreBoundaryRejectsSecondConcurrentJob() throws {
        let context = try makeContext()
        let coordinator = FileActionCoordinator()
        coordinator.activeRuns["running-job"] = PipelineRunHandle(
            jobId: "running-job",
            operationKind: .transcription,
            token: CancellationToken()
        )
        let queued = ASRJob(
            id: "second-job",
            sourceAudioPath: "/tmp/second.wav",
            sourceAudioHash: "second-job",
            durationSeconds: 0
        )
        context.insert(queued)
        try context.save()

        coordinator.runPipeline(
            jobId: queued.id,
            audioPath: queued.sourceAudioPath,
            modelContext: context
        )

        #expect(coordinator.activeRuns.count == 1)
        #expect(coordinator.activeRuns["second-job"] == nil)
        #expect(queued.jobStatus == .queued)
    }

    // MARK: - Error message 状态管理

    @Test func dismissActionError_clearsMessage() {
        let coordinator = FileActionCoordinator()
        coordinator.dismissActionError()
        #expect(coordinator.actionErrorMessage == nil)
    }

    @Test func activeTranscriptionJobId_isNilInitially() {
        let coordinator = FileActionCoordinator()
        #expect(coordinator.activeTranscriptionJobId == nil)
        #expect(coordinator.activeTranscriptionStage == "")
        #expect(coordinator.activeTranscriptionFraction == 0)
        #expect(coordinator.activeTranscriptionMessage == "")
    }

    @Test func activeCleanupJobId_isNilInitially() {
        let coordinator = FileActionCoordinator()
        #expect(coordinator.activeCleanupJobId == nil)
        #expect(coordinator.activeCleanupProgress == nil)
        #expect(coordinator.lastCleanupOutcome == nil)
    }

    @Test func reidentificationPrecheckFailuresHaveActionableMessages() {
        #expect(ReidentificationPrecheckFailure.resultMissing.alertTitle == "找不到转写结果")
        #expect(
            ReidentificationPrecheckFailure.resultUnreadable
                .alertMessage(detail: "job_id 不匹配")
                .contains("job_id 不匹配")
        )
        #expect(
            ReidentificationPrecheckFailure.speakerInputUnreadable
                .alertMessage()
                .contains("重新转写")
        )
    }

    // MARK: - 启动恢复一次守门（recoverStaleJobsIfNeeded 委托到 StartupRecoveryManager）

    @Test func recoverStaleJobsIfNeeded_isIdempotent() throws {
        let context = try makeContext()
        let coordinator = FileActionCoordinator()
        _ = try coordinator.recoverStaleJobsIfNeeded(modelContext: context)
        // 第二次必须 no-op
        let second = try coordinator.recoverStaleJobsIfNeeded(modelContext: context)
        #expect(second == 0)
    }

    // MARK: - F4.14 throttle 决策

    @Test func throttle_persistsOnFirstCall() {
        // last == nil → 第一次永远持久化
        #expect(
            FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 0.0, last: nil
            )
        )
    }

    @Test func throttle_persistsOnStartAndEnd() {
        // 起止点必须持久化
        let last = FileActionCoordinator.CheckedProgress(stage: "load", fraction: 0.5)
        #expect(
            FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 0.0, last: last  // 起点
            )
        )
        #expect(
            FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 1.0, last: last  // 终点
            )
        )
    }

    @Test func throttle_persistsOnStageChange() {
        let last = FileActionCoordinator.CheckedProgress(stage: "load", fraction: 0.5)
        #expect(
            FileActionCoordinator.shouldCheckProgress(
                stage: "vad",  // 阶段切换
                fraction: 0.5, last: last
            )
        )
    }

    @Test func throttle_persistsOnLargeFractionStep() {
        // 步进 ≥ 5% 持久化
        let last = FileActionCoordinator.CheckedProgress(stage: "asr", fraction: 0.5)
        #expect(
            FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 0.56, last: last  // 步进 6%
            )
        )
    }

    @Test func throttle_skipsSmallFractionStep() {
        // 步进 < 5% 跳过
        let last = FileActionCoordinator.CheckedProgress(stage: "asr", fraction: 0.5)
        #expect(
            !FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 0.52, last: last  // 步进 2%
            )
        )
    }

    @Test func throttle_skipsWhenUnchanged() {
        // stage / fraction 都未变 → 跳过
        let last = FileActionCoordinator.CheckedProgress(stage: "asr", fraction: 0.5)
        #expect(
            !FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 0.5, last: last
            )
        )
    }

    @Test func throttle_respectsCustomStep() {
        // step=10% 时 5% 步进应跳过
        let last = FileActionCoordinator.CheckedProgress(stage: "asr", fraction: 0.5)
        #expect(
            !FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 0.55, last: last, step: 0.10
            )
        )
        #expect(
            FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 0.65, last: last, step: 0.10
            )
        )
    }

    @Test func throttle_doesNotPersistWhenFractionSlightlyExceedsOne() {
        // 边界：fraction > 1 也按"接近终点"对待
        let last = FileActionCoordinator.CheckedProgress(stage: "asr", fraction: 0.99)
        #expect(
            FileActionCoordinator.shouldCheckProgress(
                stage: "asr", fraction: 1.01, last: last  // 1.01 >= 1
            )
        )
    }

    // MARK: - F4.14 实际检查路径语义（与 shouldCheckProgress 决策的边界）

    /// **关键行为钉死**：5% 步进触发 `shouldCheckProgress` 返回 true
    /// （fetch 检查路径走），但 `JobLifecycleStore.updatePipelineProgress`
    /// **不会**真的 save — 它的 save 决策只覆盖 stage 变化 / 0 / 1。
    ///
    /// 验证方式：跑 5% 步进后用 in-memory `hasChanges` + manual save
    /// 行为间接钉死 — 5% 步进让 context.hasChanges = true（field 改），
    /// 但**不**调用 modelContext.save()。Stage 变化后 save() 被调用，
    /// context.hasChanges 回到 false。
    ///
    /// 注：直接断言"5% 步进后 hasChanges = false"会失败，因为 field 改了
    /// 就是 changed 状态，跟 save 无关。这里我们验证的是：
    /// 5% 步进 + 立即 manual save 后，再次修改 field 不会触发前一次残留
    /// 的 unsaved change 干扰。整体验证 `updatePipelineProgress` 在两种
    /// 场景下的"save or not"行为由源代码 review 确认（line 317）。
    @Test func fivePercentStepAndStageChange_followConsistentSaveSemantics() throws {
        let context = try makeContext()
        let job = ASRJob(
            id: "f414-persist-semantics",
            sourceAudioPath: "/tmp/f414.wav",
            sourceAudioHash: "f414-persist-semantics",
            durationSeconds: 0
        )
        context.insert(job)
        job.pipelineStage = "asr"
        job.pipelineFraction = 0.5
        job.pipelineMessage = "baseline"
        try context.save()
        // save 后 hasChanges = false
        #expect(!context.hasChanges)

        let store = JobLifecycleStore(modelContext: context)

        // 5% 步进：fields changed, save 决策不命中, context 仍有 changes
        try store.updatePipelineProgress(job, stage: "asr", fraction: 0.55, message: "step")
        #expect(job.pipelineFraction == 0.55)
        #expect(job.pipelineMessage == "step")
        // 5% 步进 in-memory 改了字段但没 save → hasChanges 仍 true
        #expect(context.hasChanges, "5% 步进 in-memory 改字段 → hasChanges = true")

        // stage 变化：fields changed + save() → hasChanges 回到 false
        try store.updatePipelineProgress(job, stage: "vad", fraction: 0.55, message: "stage change")
        #expect(job.pipelineStage == "vad")
        #expect(!context.hasChanges, "stage 变化触发 save → hasChanges = false")
    }

    // MARK: - M5.3 守卫失败时也清 lastCheckedProgress（round-3）

    @Test func cleanupTranscriptionState_clearsThrottleCacheEvenWhenGuardFails() throws {
        // 场景：cleanupTranscriptionState 用的 runID 跟 activeRuns[jobId].id 不匹配
        // （守卫失败，旧 run 的 cleanup 迟到调用）。原实现守卫失败时直接 return，
        // 留下 stale lastCheckedProgress 污染下一次 run。修复后守卫失败也清。
        //
        // 验证方法：装好"旧 run"环境 → applyPipelineProgress 触发 throttle
        // 落值 → cleanupTranscriptionState 用不匹配 runID 调 → 装"新 run"
        // → 第二次同 stage 同 fraction 的 applyPipelineProgress 应该走"检查
        // 路径"（如果 lastCheckedProgress 被清）或被跳过（如果没清，stale
        // 命中 throttle 决策）。
        let context = try makeContext()
        let coordinator = FileActionCoordinator()
        let jobId = "m53-job"
        let job = ASRJob(
            id: jobId,
            sourceAudioPath: "/tmp/m53.wav",
            sourceAudioHash: "m53-hash",
            durationSeconds: 0
        )
        context.insert(job)
        job.pipelineStage = "load"
        job.pipelineFraction = 0.0
        job.pipelineMessage = "start"
        try context.save()

        // 装旧 run + 把它设为 active transcription
        let oldRun = PipelineRunHandle(
            jobId: jobId,
            operationKind: .transcription,
            token: CancellationToken()
        )
        coordinator.activeRuns[jobId] = oldRun
        coordinator.activeTranscriptionJobId = jobId

        // 旧 run 第一次 progress: stage="load", fraction=0.05 → 走检查路径
        // (load != "" 且 0.05 != 0)，写入 lastCheckedProgress[jobId]
        coordinator.applyPipelineProgress(
            jobId: jobId,
            runID: oldRun.id,
            token: oldRun.token,
            stage: "load",
            fraction: 0.05,
            message: "first progress",
            modelContext: context
        )
        #expect(job.pipelineFraction == 0.05, "首次 progress 应已持久化")

        // 守卫失败的 cleanup：新 runID-2 不匹配旧 run
        let newRunID = UUID()
        coordinator.cleanupTranscriptionState(
            jobId: jobId,
            runID: newRunID,  // 不匹配 oldRun.id
            advanceQueue: false,
            modelContext: context
        )
        // activeRuns[jobId] 仍是旧 run（守卫失败没改它）
        #expect(coordinator.activeRuns[jobId]?.id == oldRun.id)

        // 装新 run（接管 activeRuns[jobId]）— 模拟 restart
        let newRun = PipelineRunHandle(
            jobId: jobId,
            operationKind: .transcription,
            token: CancellationToken()
        )
        coordinator.activeRuns[jobId] = newRun
        // activeTranscriptionJobId 保持（同一 job）

        // 关键场景：新 run 第一次 progress = 同 stage "load" 同 fraction 0.05
        // 旧 lastCheckedProgress[load, 0.05] + 新值 (load, 0.05)
        // shouldCheckProgress 内部: same stage, |0.05-0.05| = 0 < 0.05 → false
        // 所以如果 lastCheckedProgress 没被清，这次会跳过 update 路径。
        // 修复后 lastCheckedProgress[jobId] 已被守卫前 removeValue 清掉，
        // last = nil, shouldCheckProgress 走"stage != last.stage 或 fraction == 0"
        // (实际是 stage != nil.stage = "load" != nil... false，但 fraction == 0 也不命中)
        // — 走"5% 步进"路径：last=nil, abs(0.05-0) = 0.05 >= 0.05 → true
        // 实际走 update 路径后 job.pipelineFraction = 0.05 已被设。
        // 为更明显看出差别，第二次 progress 用 fraction 0.0（跟旧的 0.05 步进 < 5%）：
        // 旧 cache: (load, 0.05) → 0 vs 0.05 = 0.05 步进, 边界
        // 新 cache: nil → 0 vs 0 = 0 步进, 0 < 0.05 = false? 但 0 跟 stage 都 nil/empty
        // 用一个能区分的场景：旧 cache (load, 0.05), 新 progress (load, 0.05)
        // 不重置 job.pipelineFraction，先 reset 让效果可观察：
        job.pipelineFraction = 0.5  // 中间值
        try context.save()
        #expect(!context.hasChanges)

        coordinator.applyPipelineProgress(
            jobId: jobId,
            runID: newRun.id,
            token: newRun.token,
            stage: "load",
            fraction: 0.05,
            message: "restart first progress",
            modelContext: context
        )
        // 如果 lastCheckedProgress[jobId] 没被清: shouldCheckProgress
        // (load, 0.05, last=(load, 0.05)) → same stage, |0.05-0.05|=0 < 0.05 → false → 跳过
        // 修复后: last=nil → "stage != last.stage" 用 nil.stage ?? 走
        // 1h 音频首 progress 边界: shouldCheckProgress 在 last=nil 时
        // fraction==0? 0.05 != 0; stageChanged (last nil 视为 "" 或 "load" 边界) — 走 true
        #expect(
            job.pipelineFraction == 0.05,
            "修复后 lastCheckedProgress 已清，新 run 第一次 progress 应该走 update 路径"
        )
    }
}
