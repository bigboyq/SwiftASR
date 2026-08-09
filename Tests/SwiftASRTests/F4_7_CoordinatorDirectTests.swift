import Foundation
import SwiftData
import Testing
@testable import SwiftASR

/// F4.7 后续：3 个拆出的 coordinator（PipelineRunCoordinator /
/// JobActionService / SpeakerReidentificationCoordinator）的失败 /
/// 取消 / 恢复直接单测。已有 `PipelinePersistenceIntegrationTests`
/// 集成覆盖，这层只补白盒单元测试，验证关键边界行为不退化。
///
/// 所有测试用 `pipelineRunnerBuilder` DI seam 注入 mock runner，
/// 不依赖真实 ONNX / VAD / Speaker 模型。
@Suite("F4.7 — coordinator direct failure / cancel / recover paths", .serialized)
@MainActor
struct F4_7_CoordinatorDirectTests {

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let config = ModelConfiguration("F4_7_CoordinatorDirectTests", schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func makeJob(_ id: String, in context: ModelContext) -> ASRJob {
        let job = ASRJob(
            id: id, sourceAudioPath: "/tmp/\(id).wav", sourceAudioHash: id, durationSeconds: 0
        )
        context.insert(job)
        return job
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - PipelineRunCoordinator — 3 terminal paths

    @Test func runPipeline_marksJobDoneWhenRunnerCompletes() async throws {
        let context = try makeContext()
        let job = makeJob("prc-done", in: context)
        let coordinator = FileActionCoordinator(
            settingsStore: SettingsStore.createTestInstance(),
            pipelineRunnerBuilder: { _, _, _ in
                PipelineRunner { _, onProgress, _, _, _ in
                    onProgress("load", 1.0, "load")
                    onProgress("vad", 1.0, "vad")
                    onProgress("asr", 1.0, "asr")
                    return PipelineRunnerOutput(
                        utterances: [], speakerProfiles: [], metrics: PipelineStageMetrics()
                    )
                }
            }
        )
        coordinator.runPipeline(
            jobId: job.id, audioPath: job.sourceAudioPath, modelContext: context
        )
        let settled = await waitUntil {
            !coordinator.hasActivePipeline
        }
        #expect(settled, "runPipeline did not finish within timeout")
        let refreshed = try #require(try ASRJobRepository.findById(job.id, in: context))
        #expect(refreshed.jobStatus == .done)
        #expect(refreshed.errorMessage == nil)
    }

    @Test func runPipeline_marksJobCancelledWhenRunnerEmitsCancelled() async throws {
        let context = try makeContext()
        let job = makeJob("prc-cancel", in: context)
        let coordinator = FileActionCoordinator(
            settingsStore: SettingsStore.createTestInstance(),
            pipelineRunnerBuilder: { _, _, _ in
                PipelineRunner { _, _, _, _, _ in
                    throw PipelineCancelled(stage: "asr")
                }
            }
        )
        coordinator.runPipeline(
            jobId: job.id, audioPath: job.sourceAudioPath, modelContext: context
        )
        let settled = await waitUntil {
            !coordinator.hasActivePipeline
        }
        #expect(settled, "runPipeline did not settle within timeout")
        let refreshed = try #require(try ASRJobRepository.findById(job.id, in: context))
        #expect(refreshed.jobStatus == .cancelled)
    }

    @Test func runPipeline_marksJobFailedWhenRunnerThrows() async throws {
        struct TestError: Error {}
        let context = try makeContext()
        let job = makeJob("prc-fail", in: context)
        let coordinator = FileActionCoordinator(
            settingsStore: SettingsStore.createTestInstance(),
            pipelineRunnerBuilder: { _, _, _ in
                PipelineRunner { _, _, _, _, _ in
                    throw TestError()
                }
            }
        )
        coordinator.runPipeline(
            jobId: job.id, audioPath: job.sourceAudioPath, modelContext: context
        )
        let settled = await waitUntil {
            !coordinator.hasActivePipeline
        }
        #expect(settled, "runPipeline did not settle within timeout")
        let refreshed = try #require(try ASRJobRepository.findById(job.id, in: context))
        #expect(refreshed.jobStatus == .failed)
    }

    @Test func runPipeline_rejectsSecondConcurrentRun() throws {
        // runPipeline 在 activeRuns 非空时必须拒绝新的 run，不污染 activeRuns。
        // 之前做法是 mock runner 一直 hold 主 actor，会跟 @MainActor 测试死锁；
        // 改为手动构造一个 stub PipelineRunHandle 塞进 activeRuns，直接验证
        // 拒绝逻辑。
        let context = try makeContext()
        let job1 = makeJob("prc-conc-1", in: context)
        let coordinator = FileActionCoordinator(settingsStore: SettingsStore.createTestInstance())
        // 手动塞一个 stub run handle 模拟"已有 run 在跑"
        let stub = PipelineRunHandle(
            jobId: job1.id,
            operationKind: .transcription,
            token: CancellationToken()
        )
        try stub.start()
        coordinator.activeRuns[job1.id] = stub
        // 现在 activeRuns 非空，runPipeline 必须被拒绝
        coordinator.runPipeline(
            jobId: "prc-conc-2", audioPath: "/tmp/prc-conc-2.wav", modelContext: context
        )
        // activeRuns 仍然只有 job1（stub），没有 prc-conc-2
        #expect(coordinator.activeRuns.keys.sorted() == [job1.id])
        #expect(coordinator.actionErrorMessage != nil, "应给出 user-facing 错误提示")
    }

    // MARK: - JobActionService — import / delete

    @Test func importAudioFile_insertsNewJobOnFreshPath() throws {
        let context = try makeContext()
        let coordinator = FileActionCoordinator(settingsStore: SettingsStore.createTestInstance())
        let url = URL(fileURLWithPath: "/tmp/jas-fresh-\(UUID().uuidString).wav")
        var selectedJobId: String?
        // `autoStart: false` 时 importAudioFile 仍成功入队（selectedJobId
        // 写入），但 return false 表示"未启动 pipeline"。
        let didAutoStart = coordinator.importAudioFile(
            url: url, jobs: [], selectedJobId: &selectedJobId,
            modelContext: context, autoStart: false
        )
        #expect(!didAutoStart, "autoStart=false 时不应自动启动")
        #expect(selectedJobId != nil, "selectedJobId 必须被设置")
        let inserted = try #require(try ASRJobRepository.findById(selectedJobId!, in: context))
        #expect(inserted.sourceAudioPath == url.path)
    }

    @Test func importAudioFile_reusesJobAtSameCanonicalPath() throws {
        // F4.10 兼容性：大小写敏感 volume 之前用小写化路径 hash，现在统一
        // canonical path。两次 import 同路径必须返回同一个 jobId。
        let context = try makeContext()
        let coordinator = FileActionCoordinator(settingsStore: SettingsStore.createTestInstance())
        let url = URL(fileURLWithPath: "/tmp/jas-reuse-\(UUID().uuidString).wav")
        var firstSelected: String?
        _ = coordinator.importAudioFile(
            url: url, jobs: [], selectedJobId: &firstSelected,
            modelContext: context, autoStart: false
        )
        let firstId = try #require(firstSelected)
        let existing = try ASRJobRepository.findById(firstId, in: context)
        // 第二次 import：jobs 参数传入已有 job 列表，必须复用 firstId
        var secondSelected: String?
        let didAutoStart = coordinator.importAudioFile(
            url: url, jobs: existing.map { [$0] } ?? [],
            selectedJobId: &secondSelected, modelContext: context, autoStart: false
        )
        #expect(!didAutoStart)
        #expect(secondSelected == firstId, "应该复用已有 jobId，不创建新的")
    }

    @Test func deleteJob_removesJobAndSidecar() throws {
        // 删除 job 时 sidecar artifact 应该跟着清掉（E-1 修复）
        let context = try makeContext()
        let coordinator = FileActionCoordinator(settingsStore: SettingsStore.createTestInstance())
        let url = URL(fileURLWithPath: "/tmp/jas-delete-\(UUID().uuidString).wav")
        var selectedJobId: String?
        _ = coordinator.importAudioFile(
            url: url, jobs: [], selectedJobId: &selectedJobId,
            modelContext: context, autoStart: false
        )
        let jobId = try #require(selectedJobId)
        let job = try #require(try ASRJobRepository.findById(jobId, in: context))
        let transcriptPath = ResultStore.stageResultPath(jobId: jobId)
        try FileManager.default.createDirectory(
            at: transcriptPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 写一个空 result.json 模拟 sidecar
        try Data("{}".utf8).write(to: transcriptPath)
        #expect(FileManager.default.fileExists(atPath: transcriptPath.path))

        var selected = selectedJobId
        coordinator.deleteJob(
            job: job, selectedJobId: &selected, modelContext: context, confirm: false
        )
        // job 应从 context 中移除
        let after = try ASRJobRepository.findById(jobId, in: context)
        #expect(after == nil)
        // transcript sidecar 应清理
        #expect(!FileManager.default.fileExists(atPath: transcriptPath.path))
    }

    // MARK: - SpeakerReidentificationCoordinator — recovery

    // 备注：交互式 `reidentifySpeakers` 路径在 precheck 失败时会调
    // `AlertHelper.showInfo(...).runModal()`，会阻塞主线程等用户点
    // "知道了"。在测试环境无 UI 循环，单元测试会 hang。
    // 所以这里只覆盖 `startQueuedReidentification` 的失败恢复路径
    // （precheck 失败时不弹 alert，直接 restore job）。

    @Test func startQueuedReidentification_restoresJobOnPrecheckFailure() throws {
        // 排队的 speaker reidentification 在数据缺失时必须还原到原状态
        // （不要留在 queued），并记录失败原因。
        let context = try makeContext()
        let job = makeJob("src-queued-fail", in: context)
        let originalStatus: JobStatus = .done
        let originalFinishedAt = Date(timeIntervalSince1970: 1_000_000)
        job.jobStatus = .queued
        job.queuedOperationKind = QueuedJobOperationKind.speakerReidentification.rawValue
        job.queuedRestoreStatus = originalStatus.rawValue
        job.queuedRestoreFinishedAt = originalFinishedAt
        try context.save()

        let coordinator = FileActionCoordinator(settingsStore: SettingsStore.createTestInstance())
        // 没有 result.json，precheck 必然失败
        coordinator.startQueuedReidentification(job: job, modelContext: context)

        // 应该被还原到 originalStatus，不留在 .queued
        #expect(job.jobStatus == originalStatus)
        #expect(job.finishedAt == originalFinishedAt)
        #expect(job.errorMessage != nil)
    }
}
