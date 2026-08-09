import SwiftUI
import SwiftData

/// 文件管理页：展示全量任务，并让用户直接进入转写或结果工作台。
struct FilesWorkspace: View {
    @Query(sort: \ASRJob.createdAt, order: .reverse) private var jobs: [ASRJob]
    @Binding var selectedJobId: String?
    @Binding var section: AppSection
    @ObservedObject var coordinator: FileActionCoordinator
    // F-NEW-3 (round-3): cache 由 MainSplitView 持有，两个 workspace 共享同一实例。
    // 切到 ResultsWorkspace 再切回不会重读 result.json。
    @ObservedObject var cleanupCache: CleanupCompletionCache

    /// 按"最近一次活动"倒序（max of lastOperationAt/cleanedAt/finishedAt/createdAt）。
    /// 文件管理页用户预期是"按最近改动排序"——重新转写 / 重新识别说话人 / 润色后应该
    /// 立即冒到顶。@Query 的 createdAt 排序只反映"添加时间",无法满足此需求。
    private var sortedJobs: [ASRJob] {
        jobs.sorted { $0.mostRecentActivity > $1.mostRecentActivity }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader("文件", subtitle: "管理导入的音频、任务历史和文件操作")
            Divider()
            if jobs.isEmpty {
                WorkspaceEmptyState(
                    title: "还没有文件",
                    message: "从左侧“添加音频”导入文件，或直接把音频拖到窗口中。",
                    icon: "tray"
                )
            } else {
                List {
                    Section {
                        ForEach(sortedJobs, id: \.id) { job in
                            JobTableRow(job: job, cleanupCache: cleanupCache) {
                                selectedJobId = job.id
                                section = job.jobStatus.belongsInResults ? .results : .transcription
                            }
                            .contextMenu {
                                JobActionMenu(
                                    job: job,
                                    selectedJobId: $selectedJobId,
                                    coordinator: coordinator,
                                    open: { section = $0 }
                                )
                            }
                        }
                    } header: {
                        HStack {
                            Text("文件")
                            Spacer()
                            Text("创建时间").frame(width: 150, alignment: .leading)
                            Text("状态").frame(width: 88, alignment: .leading)
                            Text("时长").frame(width: 72, alignment: .leading)
                            Text("润色").frame(width: 72, alignment: .leading)
                            Text("最近更新").frame(width: 150, alignment: .leading)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { cleanupCache.refresh(jobs: jobs) }
        .onChange(of: cleanupCacheKey) { _, _ in cleanupCache.refresh(jobs: jobs) }
    }

    private var cleanupCacheKey: [String] {
        jobs.map {
            "\($0.id)|\($0.transcriptPath ?? "")|\($0.mostRecentActivity.timeIntervalSinceReferenceDate)"
        }
    }
}

private struct JobTableRow: View {
    let job: ASRJob
    @ObservedObject var cleanupCache: CleanupCompletionCache
    let open: () -> Void

    var body: some View {
        HStack(spacing: AppLayout.itemSpacing) {
            Image(systemName: JobStatusDisplay(job.jobStatus).icon)
                .foregroundStyle(JobStatusDisplay(job.jobStatus).color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Button(action: open) {
                VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
                    Text(URL(fileURLWithPath: job.sourceAudioPath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityValue(JobStatusDisplay(job.jobStatus).shortMessage(job: job) ?? JobStatusDisplay(job.jobStatus).label)

            Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                .frame(width: 150, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(JobStatusDisplay(job.jobStatus).label)
                .frame(width: 88, alignment: .leading)
                .foregroundStyle(JobStatusDisplay(job.jobStatus).color)
            Text(formatDuration(job.durationSeconds))
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(cleanupLabel)
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(cleanupLabel == "已润色" ? .green : .secondary)
            Text(job.mostRecentActivity.formatted(date: .abbreviated, time: .shortened))
                .frame(width: 150, alignment: .leading)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.vertical, AppLayout.compactSpacing)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }

    private var cleanupLabel: String {
        if cleanupCache.state(for: job.id) == true { return "已润色" }
        guard let cleanup = job.cleanupJobStatus else { return "未润色" }
        return cleanup == .done ? "已润色" : JobStatusDisplay(cleanup).label
    }
}

/// 转写页只聚焦尚未得到可编辑结果的任务，避免完成历史和进行中状态混在一起。
struct TranscriptionWorkspace: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ASRJob.createdAt, order: .reverse) private var jobs: [ASRJob]
    @Binding var selectedJobId: String?
    @ObservedObject var coordinator: FileActionCoordinator

    private var transcriptionJobs: [ASRJob] {
        jobs.filter { $0.jobStatus.belongsInTranscription }
            .sorted {
                if $0.jobStatus == .queued, $1.jobStatus == .queued {
                    if $0.queueOrder != $1.queueOrder { return $0.queueOrder < $1.queueOrder }
                }
                return $0.createdAt > $1.createdAt
            }
    }

    private var queuedJobs: [ASRJob] {
        transcriptionJobs.filter { $0.jobStatus == .queued }
    }

    private var nonQueuedTranscriptionJobs: [ASRJob] {
        transcriptionJobs.filter { $0.jobStatus != .queued }
    }

    private var displayedJob: ASRJob? {
        if let selectedJobId,
           let selected = transcriptionJobs.first(where: { $0.id == selectedJobId }) {
            return selected
        }
        return transcriptionJobs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader("转写", subtitle: "查看队列、当前进度和可恢复的失败任务") {
                Button {
                    coordinator.setQueuePaused(!coordinator.isQueuePaused, modelContext: modelContext)
                } label: {
                    Label(
                        coordinator.isQueuePaused ? "继续队列" : "暂停队列",
                        systemImage: coordinator.isQueuePaused ? "play.fill" : "pause.fill"
                    )
                }
            }
            Divider()
            if transcriptionJobs.isEmpty {
                WorkspaceEmptyState(
                    title: "没有待处理任务",
                    message: "导入音频后，转写进度和失败恢复会显示在这里。",
                    icon: "waveform"
                )
            } else {
                HSplitView {
                    List(selection: $selectedJobId) {
                        if !queuedJobs.isEmpty {
                            Section("队列") {
                                ForEach(queuedJobs, id: \.id) { job in
                                    transcriptionRow(job)
                                }
                                .onMove { offsets, destination in
                                    coordinator.reorderQueuedJobs(
                                        fromOffsets: offsets,
                                        toOffset: destination,
                                        modelContext: modelContext
                                    )
                                }
                            }
                        }
                        if !nonQueuedTranscriptionJobs.isEmpty {
                            Section("处理中与失败任务") {
                                ForEach(nonQueuedTranscriptionJobs, id: \.id) { job in
                                    transcriptionRow(job)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 340)

                    if let job = displayedJob {
                        FileDetailView(jobId: job.id, coordinator: coordinator, showsHeader: true)
                    }
                }
                .onAppear {
                    coordinator.startNextQueuedJobIfPossible(modelContext: modelContext)
                    if selectedJobId == nil || !transcriptionJobs.contains(where: { $0.id == selectedJobId }) {
                        selectedJobId = transcriptionJobs.first?.id
                    }
                }
                .onChange(of: transcriptionJobs.map(\.id)) { _, ids in
                    if selectedJobId.map({ !ids.contains($0) }) == true {
                        selectedJobId = ids.first
                    }
                }
            }
        }
    }

    private func transcriptionRow(_ job: ASRJob) -> some View {
        TranscriptionJobRow(job: job)
            .tag(Optional(job.id))
            .contextMenu {
                JobActionMenu(
                    job: job,
                    selectedJobId: $selectedJobId,
                    coordinator: coordinator,
                    open: { _ in }
                )
            }
    }
}

private struct TranscriptionJobRow: View {
    let job: ASRJob

    var body: some View {
        HStack(spacing: AppLayout.itemSpacing) {
            Image(systemName: JobStatusDisplay(job.jobStatus).icon)
                .foregroundStyle(JobStatusDisplay(job.jobStatus).color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
                Text(URL(fileURLWithPath: job.sourceAudioPath).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let message = JobStatusDisplay(job.jobStatus).shortMessage(job: job) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if job.jobStatus == .queued {
                Spacer(minLength: AppLayout.compactSpacing)
                Text("#\(job.queueOrder + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("队列位置 \(job.queueOrder + 1)")
            }
        }
        .padding(.vertical, AppLayout.compactSpacing)
        .accessibilityLabel(URL(fileURLWithPath: job.sourceAudioPath).lastPathComponent)
        .accessibilityValue(JobStatusDisplay(job.jobStatus).shortMessage(job: job) ?? JobStatusDisplay(job.jobStatus).label)
    }
}

/// 结果页是独立工作台，默认显示最近一次已完成任务，并允许在完成历史间切换。
struct ResultsWorkspace: View {
    @Query(sort: \ASRJob.createdAt, order: .reverse) private var jobs: [ASRJob]
    @Binding var selectedJobId: String?
    @ObservedObject var coordinator: FileActionCoordinator
    // F-NEW-3 (round-3): 同 FilesWorkspace，由 MainSplitView 传入。
    @ObservedObject var cleanupCache: CleanupCompletionCache
    @State private var showsResultHistory = false

    private var resultJobs: [ASRJob] {
        ResultHistoryQuery.orderedJobs(from: jobs)
    }

    private var displayedJob: ASRJob? {
        if let selectedJobId,
           let selected = resultJobs.first(where: { $0.id == selectedJobId }) {
            return selected
        }
        return resultJobs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader("结果", subtitle: "编辑转写、命名说话人、润色并按当前预览导出") {
                if !resultJobs.isEmpty {
                    Button {
                        showsResultHistory = true
                    } label: {
                        Label("历史结果", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            Divider()
            if let job = displayedJob {
                FileDetailView(jobId: job.id, coordinator: coordinator, showsHeader: false)
            } else {
                WorkspaceEmptyState(
                    title: "还没有可查看的结果",
                    message: "完成一次转写后，结果会自动出现在这里。",
                    icon: "doc.text"
                )
            }
        }
        .onAppear {
            cleanupCache.refresh(jobs: jobs)
            if selectedJobId == nil || !resultJobs.contains(where: { $0.id == selectedJobId }) {
                selectedJobId = resultJobs.first?.id
            }
        }
        .onChange(of: resultJobs.map(\.id)) { _, ids in
            if selectedJobId.map({ !ids.contains($0) }) == true {
                selectedJobId = ids.first
            }
        }
        .sheet(isPresented: $showsResultHistory) {
            ResultHistorySheet(
                jobs: jobs,
                selectedJobId: $selectedJobId,
                cleanupCache: cleanupCache
            )
        }
    }
}
