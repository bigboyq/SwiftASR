import SwiftUI
import SwiftData
import AppKit

/// 右侧工作区：根据一级导航切换，job 选择在各工作区间保持一致。
struct DetailPane: View {
    @Binding var section: AppSection
    @Binding var selectedJobId: String?
    @ObservedObject var coordinator: FileActionCoordinator
    // F-NEW-3 (round-3): MainSplitView 上提的共享 cache，传给需要它的
    // workspace。TranscriptionWorkspace / SpeakersTab / SettingsTab 不需要。
    @ObservedObject var cleanupCache: CleanupCompletionCache

    var body: some View {
        Group {
            switch section {
            case .files:
                FilesWorkspace(
                    selectedJobId: $selectedJobId,
                    section: $section,
                    coordinator: coordinator,
                    cleanupCache: cleanupCache
                )
            case .transcription:
                TranscriptionWorkspace(selectedJobId: $selectedJobId, coordinator: coordinator)
            case .results:
                ResultsWorkspace(
                    selectedJobId: $selectedJobId,
                    coordinator: coordinator,
                    cleanupCache: cleanupCache
                )
            case .speakers:
                SpeakersTab()
            case .settings:
                SettingsTab()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 文件详情：
/// - header：name / path / size / duration / status
/// - body：根据 status 切换
///   - processing/running：5 步进度 + 取消
///   - failed：错误信息 + 重试
///   - done：当前结果工作区内容（HSplit SpeakerPanel + segments + toolbar）
///   - queued：等待中
///   - 其他（cancelled/未开始）：可能因为 pipeline 跑过被卡住；显示错误或重试
struct FileDetailView: View {
    let jobId: String
    @ObservedObject var coordinator: FileActionCoordinator
    let showsHeader: Bool

    init(jobId: String, coordinator: FileActionCoordinator, showsHeader: Bool = true) {
        self.jobId = jobId
        self.coordinator = coordinator
        self.showsHeader = showsHeader
        // R4-P2-8：只查当前 job，避免每次变更都重新 fetch 整张任务表。
        let targetId = jobId
        let filter = #Predicate<ASRJob> { $0.id == targetId }
        _jobs = Query(filter: filter)
    }

    @Environment(\.modelContext) private var modelContext
    @Query private var jobs: [ASRJob]

    /// "查看 ASR 结果"无法完成时展示具体原因（sidecar 不存在或持久化失败）。
    @State private var partialResultAlertMessage: String?

    private var job: ASRJob? { jobs.first }

    var body: some View {
        Group {
            if let job = job {
                VStack(spacing: 0) {
                    if showsHeader {
                        FileHeader(job: job)
                        Divider()
                    }
                    body(for: job)
                }
            } else {
                ContentUnavailableView(
                    "文件不存在",
                    systemImage: "questionmark.folder",
                    description: Text("该 job 已被删除或数据库不可用。")
                )
            }
        }
        .alert("无法显示 ASR 结果", isPresented: Binding(
            get: { partialResultAlertMessage != nil },
            set: { if !$0 { partialResultAlertMessage = nil } }
        )) {
            Button("好") {}
        } message: {
            Text(partialResultAlertMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private func body(for job: ASRJob) -> some View {
        switch job.jobStatus {
        case .done:
            // 转写完成：结果工作区内容
            ResultsContent(jobId: job.id)
                .id(job.id)
        case .partial:
            // 部分完成：ASR + 标点已保存（result.json 派生），speaker 失败
            // 仍展示 ResultsContent（让用户看 ASR 句子），status icon 显示 ⚠️
            ResultsContent(jobId: job.id)
                .id(job.id)
        case .running, .processing:
            processingView(job: job)
        case .failed:
            failedView(job: job)
        case .queued:
            queuedView(job: job)
        case .cancelled:
            cancelledView(job: job)
        }
    }

    // MARK: - 各状态视图

    @ViewBuilder
    private func queuedView(job: ASRJob) -> some View {
        VStack(spacing: AppLayout.sectionSpacing) {
            Image(systemName: "clock").font(.system(size: 40)).foregroundStyle(.yellow)
            Text("等待转写").font(.title3)
            Text(queueDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                coordinator.startQueuedJob(
                    jobId: job.id,
                    audioPath: job.sourceAudioPath,
                    modelContext: modelContext
                )
            } label: {
                Label("开始转写", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.hasRunningPipelineExcluding(currentJobId: job.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueDescription: String {
        coordinator.hasActivePipeline
            ? "当前有其他转写任务正在运行；完成后可在此启动本任务。"
            : "任务已准备就绪，可以开始转写。"
    }

    @ViewBuilder
    private func processingView(job: ASRJob) -> some View {
        VStack(spacing: 16) {
            // 当前选中的 job **正好是**正在转写那个 job → 用 coordinator 的
            // 实时 progress（切到其他文件后切回仍能正确显示，因为 onProgress
            // 持续在写 coordinator）。否则（一般情况：当前 selection 的 job
            // 不在转写、显示的是历史的 job.pipelineStage）→ 用 SwiftData 字段。
            // 两路读到的字段**对正在转写的 job 一定一致**（onProgress 同步写两边）。
            let isActive = (coordinator.activeTranscriptionJobId == job.id)
            let stage = isActive ? coordinator.activeTranscriptionStage : job.pipelineStage
            let fraction = isActive ? coordinator.activeTranscriptionFraction : job.pipelineFraction
            let message = isActive ? coordinator.activeTranscriptionMessage : job.pipelineMessage
            ProgressView(value: fraction) {
                HStack {
                    Text(PipelineSteps.stageLabel(stage)).font(.headline)
                    Spacer()
                    Text("\(Int(fraction * 100))%").font(.subheadline.monospacedDigit())
                }
            }
            .progressViewStyle(.linear)
            .accessibilityLabel("转写进度")
            .accessibilityValue(
                "\(PipelineSteps.stageLabel(stage))，\(Int((fraction * 100).rounded()))%，\(message)"
            )
            // D-3: 单一总进度条 + 合成 banner message "(vad: X/Y 帧, asr: A/B batches)"
            // VAD/ASR sub-stage 进度条已删（用户诉求：vad+asr 只要一个进度条）
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            PipelineChecklist(currentStage: stage, metrics: coordinator.activeStageMetrics)
            // 取消按钮：去掉 Button(role: .destructive)（macOS 渲染成 filled red 矩形过大），
            // 改普通 Button + .foregroundStyle(.red)，跟说话人页/设置页降级一致。
            Button {
                coordinator.cancelPipeline(jobId: job.id)
            } label: {
                Label("取消", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
            .accessibilityLabel("取消当前转写任务")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func failedView(job: ASRJob) -> some View {
        let display = JobStatusDisplay(job.jobStatus)
        VStack(spacing: 12) {
            Image(systemName: display.icon).font(.system(size: 40)).foregroundStyle(display.color)
            Text(display.label).font(.title2)
            if let err = job.errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            partialResultActions(
                job: job,
                retryTitle: "重试",
                retryIcon: "arrow.clockwise",
                unavailableHint: "这条任务的 ASR 还没跑完（speaker-input.json 不存在），没法看 ASR 结果。点“重试”重新跑完整 pipeline。"
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func cancelledView(job: ASRJob) -> some View {
        let display = JobStatusDisplay(job.jobStatus)
        VStack(spacing: 12) {
            Image(systemName: display.icon).font(.system(size: 40)).foregroundStyle(display.color)
            Text(display.label).font(.title2)
            if let err = job.errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            partialResultActions(
                job: job,
                retryTitle: "重新转写",
                retryIcon: "arrow.triangle.2.circlepath",
                unavailableHint: "这条任务的 ASR 还没跑完（speaker-input.json 不存在），没法看 ASR 结果。点“重新转写”重新跑完整 pipeline。"
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func partialResultActions(
        job: ASRJob,
        retryTitle: String,
        retryIcon: String,
        unavailableHint: String
    ) -> some View {
        let hasSpeakerInput = ResultStore.locateSpeakerInputPath(
            jobId: job.id,
            storedPath: job.transcriptPath
        ) != nil

        VStack(spacing: 12) {
            if hasSpeakerInput {
                Button {
                    let outcome = coordinator.persistPartialResultIfAvailable(
                        job: job, modelContext: modelContext
                    )
                    switch outcome {
                    case .persisted:
                        break
                    case .unavailable:
                        partialResultAlertMessage = unavailableHint
                    case .failed(let message):
                        partialResultAlertMessage = message
                    }
                } label: {
                    Label("查看 ASR 结果", systemImage: "doc.text")
                }
                .buttonStyle(.borderedProminent)
                .help("查看崩溃/取消前已保存的 ASR 标点结果")

                Button {
                    coordinator.retranscribe(job: job, modelContext: modelContext)
                } label: {
                    Label(retryTitle, systemImage: retryIcon)
                }
                .buttonStyle(.bordered)
            } else {
                Text(unavailableHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button {
                    coordinator.retranscribe(job: job, modelContext: modelContext)
                } label: {
                    Label(retryTitle, systemImage: retryIcon)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - File Header（name / path / size / duration / status）

struct FileHeader: View {
    let job: ASRJob

    @State private var fileSize: Int64 = 0
    @State private var durationSeconds: Double = 0
    @State private var loadedAudioPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                Text(URL(fileURLWithPath: job.sourceAudioPath).lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                StatusPill(status: job.status)
            }
            HStack(spacing: 16) {
                metaItem(icon: "folder", label: "路径", value: shortenPath(job.sourceAudioPath))
                metaItem(icon: "scalemass", label: "大小", value: formatBytes(fileSize))
                metaItem(icon: "clock", label: "时长", value: formatRawDuration())
            }
            .font(.caption)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .task(id: job.sourceAudioPath) {
            let path = job.sourceAudioPath
            let meta = await Task.detached(priority: .userInitiated) {
                fileMetadata(at: path)
            }.value
            if Task.isCancelled || job.sourceAudioPath != path { return }
            self.fileSize = meta.fileSize
            self.durationSeconds = meta.durationSeconds
        }
    }

    /// 渲染用的原始时长字符串：优先 job.durationSeconds，
    /// 兜底用磁盘 metadata 算出来的 durationSeconds。
    private func formatRawDuration() -> String {
        if job.durationSeconds > 0 {
            return formatDuration(job.durationSeconds)
        }
        return formatDuration(durationSeconds)
    }

    @ViewBuilder
    private func metaItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    private func shortenPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return url.deletingLastPathComponent().path
    }
}

struct StatusPill: View {
    let status: String

    /// Phase 19 (2026-07-12)：统一 delegate 到 JobStatusDisplay enum。
    /// 删 emoji 拼接 + 6 行 switch 重复代码，跟说话人页 ProfileHealth 风格一致。
    private var display: JobStatusDisplay {
        JobStatusDisplay(JobStatus(rawValue: status) ?? .failed)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: display.icon)
                .imageScale(.small)
            Text(display.label)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(display.pillBackground)
        .foregroundStyle(display.color)
        .cornerRadius(8)
    }
}

// MARK: - 4 步 checklist（VStack，每行独立，避开漏斗视觉）
// 4 阶段：预处理 / 文字识别 / 标点 / 说话人
// - 完成（cur > order）: ✅ 绿色勾 + 关键信息（"PCM 8.0s · fbank 2.9s · 5284 帧"）
// - 进行中（cur == order）: 🔄 转圈动画
// - 未开始（cur < order）: ⏸ 漏斗

struct PipelineChecklist: View {
    let currentStage: String
    /// 4 阶段关键 timing + 数量指标. pipeline 跑完后 coordinator 写入, ✅ 后显示.
    let metrics: PipelineStageMetrics?

    private var stages: [(stage: String, label: String)] { PipelineSteps.all }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(stages, id: \.stage) { s in
                HStack(spacing: 8) {
                    statusIcon(for: s.stage)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(s.label)
                                .font(.callout)
                                .foregroundStyle(isActive(s.stage) ? .primary : .secondary)
                            // 完成后显示关键信息 (一行小字, 灰色)
                            if let summary = completedSummary(for: s.stage) {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isActive(s.stage) ? Color.accentColor.opacity(0.10) : Color.clear)
                .cornerRadius(4)
            }
        }
    }

    private func isActive(_ stage: String) -> Bool {
        // "isActive" = 当前 stage 进度 >= 这个 stage 索引（即已完成或正在进行）。
        let mappedCur = PipelineSteps.mapToBroadStage(currentStage)
        let order = stages.firstIndex(where: { $0.stage == stage }) ?? -1
        let cur = stages.firstIndex(where: { $0.stage == mappedCur }) ?? -1
        return cur >= order
    }

    private func statusIcon(for stage: String) -> some View {
        let mappedCur = PipelineSteps.mapToBroadStage(currentStage)
        let order = stages.firstIndex(where: { $0.stage == stage }) ?? -1
        let cur = stages.firstIndex(where: { $0.stage == mappedCur }) ?? -1
        if order < cur {
            // ✅ 完成
            return AnyView(
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            )
        } else if order == cur {
            // 🔄 进行中
            return AnyView(
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            )
        } else {
            // ⏸ 未开始（漏斗）
            return AnyView(
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
            )
        }
    }

    /// 该 stage 完成后, 显示一行小字关键信息 (e.g. "PCM 8.0s · fbank 2.9s · 5284 帧").
    /// 仅当 stage 已完成 (order < cur) 且 metrics 里有数据时返回.
    private func completedSummary(for stage: String) -> String? {
        let mappedCur = PipelineSteps.mapToBroadStage(currentStage)
        let order = stages.firstIndex(where: { $0.stage == stage }) ?? -1
        let cur = stages.firstIndex(where: { $0.stage == mappedCur }) ?? -1
        guard order < cur, let metrics else { return nil }
        return metrics.summary(for: stage)
    }
}
