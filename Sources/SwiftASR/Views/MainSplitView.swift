import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// SwiftASR 主壳：HSplit 左导航 + 右工作区。
///
/// 左侧始终提供文件、转写、结果、说话人、设置五个入口，以及最近项目快捷入口；
/// 右侧保留同一个 selectedJobId，在文件管理、任务队列和结果工作台之间连续切换。
public struct MainSplitView: View {
    @Environment(\.modelContext) private var modelContext
    @SceneStorage("swiftasr.main.section") private var storedSection = AppSection.files.rawValue
    @SceneStorage("swiftasr.main.selectedJobId") private var storedSelectedJobId = ""
    @State private var section: AppSection = .files
    @State private var selectedJobId: String?
    @State private var startupRecoveryError: String?
    @State private var startupRecoveryStarted = false
    @State private var memoryWarning: MemoryWarning?
    @StateObject private var coordinator = FileActionCoordinator()
    // F-NEW-3 (round-3): cleanup cache 上提到 MainSplitView 常驻，避免
    // 「文件 ↔ 结果」切换时 cache 跟着 workspace 销毁重建。 FilesWorkspace /
    // ResultsWorkspace 改 @ObservedObject 接收实例。
    @StateObject private var cleanupCache = CleanupCompletionCache()
    @ObservedObject private var matchIndex = SpeakerMatchIndex.shared

    /// 长音频 preflight 告警。来源：`Notification.Name.audioPipelineMemoryWarning`，
    /// pipeline 在长音频 + 低内存机器 / 超长音频时发出。软告警不阻断，用户可关闭
    /// banner 继续转写。
    struct MemoryWarning: Equatable {
        let durationSec: Double
        let estimatedMB: Int
        let machineGB: Int
    }

    public init() {}

    public var body: some View {
        HSplitView {
            Sidebar(section: $section, selectedJobId: $selectedJobId, coordinator: coordinator)
                .frame(
                    minWidth: AppLayout.sidebarMinWidth,
                    idealWidth: AppLayout.sidebarIdealWidth,
                    maxWidth: AppLayout.sidebarMaxWidth
                )

            DetailPane(section: $section, selectedJobId: $selectedJobId, coordinator: coordinator, cleanupCache: cleanupCache)
                .frame(minWidth: AppLayout.contentMinWidth, minHeight: 500)
        }
        .environmentObject(coordinator)
        .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if let startupRecoveryError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("启动恢复未完成：\(startupRecoveryError)")
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("重试") {
                            self.startupRecoveryError = nil
                            startStartupRecovery()
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.errorBackgroundTint)
                }
                if let memoryWarning {
                    memoryWarningBanner(memoryWarning)
                }
            }
        }
        .onAppear {
            configureTerminationConfirmation()
            coordinator.prewarmModelsIfNeeded()
            startStartupRecovery()
        }
        .onChange(of: section) { _, newSection in
            storedSection = newSection.rawValue
        }
        .onChange(of: selectedJobId) { _, newJobId in
            storedSelectedJobId = newJobId ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftASRNavigate)) { notification in
            guard let raw = notification.object as? String,
                  let destination = AppSection(rawValue: raw) else { return }
            section = destination
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioPipelineMemoryWarning)) { notification in
            // userInfo 解析可在任意线程（NotificationCenter 不保证 sink 线程）
            let info = notification.userInfo ?? [:]
            guard let duration = info["duration"] as? Double,
                  let estimatedMB = info["estimatedMB"] as? Int,
                  let machineGB = info["machineGB"] as? Int else {
                Logger.shared.warn("AudioPipeline memory warning 缺字段：count=\(info.count)")
                return
            }
            // @State 修改必须在 MainActor。AudioPipeline 是 actor，notification
            // 可能从 actor 自己的 executor（后台）发出；直接赋值会触发 SwiftUI
            // "Modifying state during view update" 运行时警告。显式 hop 到 main。
            Task { @MainActor in
                memoryWarning = MemoryWarning(
                    durationSec: duration,
                    estimatedMB: estimatedMB,
                    machineGB: machineGB
                )
            }
        }
        // Bug fix 2026-07-13: 删 didResignActiveNotification listener. 之前
        // 进入后台立即把 running/processing/queued job 标 failed, 误伤
        // "短时间切后台"的用户 (例如 ⌘+H 看一眼别的 app, 几秒后回来),
        // 实际 pipeline 没死还在跑, 但用户先看到 "转写失败" 错误信息.
        // OS 真正强杀进程是 silent, 不会触发 didResignActiveNotification,
        // 所以这条路径**也帮不到 OS 强杀场景** — appLaunch 路径已经
        // 覆盖所有真正的 stale 清理 (用户重启电脑 / 杀进程后重新打开 app).
        // 现在进入后台: pipeline 继续跑, 用户切回看到正常 .done 状态.
    }

    private func isSectionCompatible(_ section: AppSection, with status: JobStatus) -> Bool {
        switch section {
        case .transcription:
            return status.belongsInTranscription
        case .results:
            return status.belongsInResults
        case .files, .speakers, .settings:
            return true
        }
    }

    /// Starts recovery once per view lifetime. The actual SwiftData work runs
    /// on a dedicated context; this main-actor continuation only applies the
    /// immutable startup snapshot to observable UI state.
    private func startStartupRecovery() {
        guard !startupRecoveryStarted else { return }
        startupRecoveryStarted = true
        let coordinator = coordinator
        let modelContext = modelContext
        Task { @MainActor in
            do {
                let snapshot = try await coordinator.recoverStaleJobsInBackground(
                    modelContext: modelContext
                )
                applyStartupSnapshot(snapshot)
            } catch {
                startupRecoveryStarted = false
                // R4-P1-6：不向用户暴露 Foundation._GenericObjCError 之类的原始
                // localizedDescription，统一走稳定中文文案；原始 error 只进日志。
                startupRecoveryError = UserFacingErrorMapper.message(
                    for: error, context: .startupRecovery
                )
                Logger.shared.error("无法持久化启动恢复状态：\(error)")
            }
        }
    }

    private func applyStartupSnapshot(_ snapshot: StartupRecoverySnapshot) {
        if snapshot.cleanedJobCount > 0 {
            Logger.shared.info(
                "启动恢复清理了 \(snapshot.cleanedJobCount) 个 stale job（标 .failed）"
            )
        }
        matchIndex.update(snapshots: snapshot.profiles)

        // 默认 selection：优先恢复用户上次位置；否则打开最近完成的结果。
        let jobs = snapshot.jobs
        let restoredSection = AppSection(rawValue: storedSection)
        if let restored = jobs.first(where: { $0.id == storedSelectedJobId }),
           let restoredSection,
           isSectionCompatible(restoredSection, with: restored.status) {
            selectedJobId = restored.id
            section = restoredSection
        } else if let first = ResultHistoryQuery.orderedJobSnapshots(from: jobs).first {
            // Match ResultsWorkspace: the default result is the most recently
            // finished one, not merely the newest imported job.
            selectedJobId = first.id
            section = .results
        } else if let first = jobs.first {
            selectedJobId = first.id
            section = first.status.belongsInResults ? .results : .files
        }
    }

    /// 将运行时任务快照交给 AppDelegate：点关闭窗口或 Cmd+Q 时可先确认。
    /// 文件名在此处通过 MainSplitView 持有的 SwiftData context 查询，coordinator
    /// 仍只负责调度，不耦合存储层。
    private func configureTerminationConfirmation() {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.releasePrewarmedModels = { [coordinator] in
            coordinator.releasePrewarmedModels()
        }
        appDelegate.activeTerminationRequest = { [coordinator, modelContext] in
            let tasks = coordinator.activeTasksForTermination()
            guard !tasks.isEmpty else { return nil }

            let details = tasks.map { task in
                let fileName: String
                do {
                    if let job = try ASRJobRepository.findById(task.jobId, in: modelContext) {
                        fileName = URL(fileURLWithPath: job.sourceAudioPath).lastPathComponent
                    } else {
                        // R4-P1-6：找不到任务行时不要向用户展示裸 UUID。
                        // 已有任务但 SwiftData 查不到意味着任务已不在列表，
                        // 用稳定文案让用户知道哪个任务还在跑。
                        fileName = task.kind.rawValue
                    }
                } catch {
                    Logger.shared.error("无法读取退出确认任务：\(error)")
                    fileName = task.kind.rawValue
                }
                return "• \(task.kind.rawValue)：\(fileName)\n  \(task.detail)"
            }.joined(separator: "\n")

            return ActiveTerminationRequest(
                details: details,
                cancelTasks: { coordinator.cancelActiveTasksForTermination() }
            )
        }
    }

    /// 长音频 preflight 软告警 banner。展示"建议关闭其他大型应用后重试"，
    /// 行为可继续（pipeline 不会被中断），用户可主动关闭 banner。
    /// 显示时长（X 小时 Y 分 / X 分钟）+ 估算内存（GB/MB）+ 机器 RAM（GB）。
    @ViewBuilder
    private func memoryWarningBanner(_ warning: MemoryWarning) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(
                "音频时长 \(formatChineseDuration(warning.durationSec))，" +
                "预估占用 \(formatBytes(Int64(warning.estimatedMB) * 1024 * 1024))，" +
                "当前机器 \(warning.machineGB)GB。" +
                "建议关闭其他大型应用后重试。"
            )
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                memoryWarning = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("关闭此提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.warningBackgroundTint)
    }
}
