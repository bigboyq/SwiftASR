import Foundation
import SwiftData
import AppKit

/// 启动时清理"上次未完成"的转写/润色状态。
///
/// **触发场景**：
/// - 用户 kill -9 / 系统重启 / app 崩溃 → pipeline 跑到一半死掉
/// - Gemini cleanup 跑到一半掉线 → cleanupStatus 卡在 "running"
/// - coordinator 是 `@StateObject` 持有，进程退出全丢，static 字段 + SwiftData
///   里残留的 job.status 没人清 → 下次启动 UI 上看到"转写中 50%"，但点取消没反应
///
/// **清理策略**（Phase 19 抽出，2026-07-12）：
/// - 转写/说话人：`.running` / `.processing` → `.failed` + 友好错误信息
/// - `.queued` 不是运行态；它代表用户明确保留的待处理队列，启动后必须原样保留
///   保留 failed 状态而不是直接重置为 queued：让用户**看到**上次没完成，可以主动重试
/// - 润色：cleanupStatus == .running → 清空 cleanupStatus/cleanedAt/cleanedModel
///   不改 job.status（转写可能 done 了，润色失败不该拖累转写状态）
/// - coordinator transient 字段全部 nil（activeCleanupJobId / activeTranscriptionJobId 等）
/// - 失败信息：`"任务在 <时机> 处于未完成状态，已自动重置。您可以重新发起转写。"`
///
/// **调用时机**（仅 `appLaunch`）：
/// - `MainSplitView.onAppear` 启动时（迁移自内联代码）
///
/// **历史**：
/// - Phase 19 (2026-07-12) 曾加 `.appBackgrounded` 路径监听
///   `NSApplication.didResignActiveNotification`，进入后台立即标 failed。
///   Bug fix 2026-07-13: 删此路径 — 误伤"短时间切后台"用户
///   (例如 ⌘+H 看一眼别的 app, 几秒后回来), pipeline 没死还在跑,
///   但用户先看到"转写失败"错误信息. OS 真正强杀进程是 silent,
///   不会触发 didResignActiveNotification, 所以这条路径**也帮不到
///   OS 强杀场景** — appLaunch 路径已覆盖.
///
/// **不调用**的时机：
/// - `NSApplication.willTerminateNotification` — 用户主动退出时不该清，coordinator
///   自己会在退出前 cancel 任务（参见 `configureTerminationConfirmation`）
/// - `NSApplication.didResignActiveNotification` — 进入后台不应清理 (见上)
/// - `NSApplication.didBecomeActiveNotification` — 切回前台时无 stale 风险
public enum StaleJobCleanupService {
    /// 清理 SwiftData 里的"上次未完成"job，返回清理数量。
    /// 转写/说话人运行中 → 标 failed + 友好错误信息 + 清 pipeline 进度
    /// 润色运行中 → 清空 cleanupStatus 字段（不动 job.status）
    @discardableResult
    public static func cleanup(
        in modelContext: ModelContext,
        when trigger: Trigger
    ) throws -> Int {
        let jobs = try ASRJobRepository.fetchAll(in: modelContext)
        var cleanedCount = 0
        for job in jobs {
            if [.running, .processing].contains(job.jobStatus) {
                job.status = JobStatus.failed.rawValue
                job.errorMessage = "任务在 \(trigger.userFacingLabel) 处于未完成状态，已自动重置。您可以重新发起转写。"
                job.pipelineFraction = 0.0
                job.pipelineStage = ""
                job.pipelineMessage = ""
                cleanedCount += 1
            }
            if job.cleanupJobStatus == .running {
                job.cleanupJobStatus = nil
                job.cleanedAt = nil
                job.cleanedModel = nil
            }
        }
        try modelContext.save()
        return cleanedCount
    }

    /// 清空 coordinator 的 transient 状态。
    /// active* 字段是 @Published，进程退出就丢；运行中崩溃或被 OS 强杀后
    /// 这些字段也会跟进程一起死，但 SwiftData 里的 job.status 还在 — 所以
    /// 启动 / 后台时**只**清 SwiftData 跟 coordinator，不需要清其他 view @State。
    @MainActor
    public static func clearCoordinatorTransients(_ coordinator: FileActionCoordinator) {
        coordinator.activeCleanupJobId = nil
        coordinator.activeCleanupToken = nil
        coordinator.activeCleanupTask = nil
        coordinator.activeCleanupProgress = nil
        coordinator.clearActivePipelineTransients()
    }

    /// 触发场景
    public enum Trigger {
        case appLaunch         // MainSplitView.onAppear

        var userFacingLabel: String {
            switch self {
            case .appLaunch: return "应用启动"
            }
        }
    }
}
