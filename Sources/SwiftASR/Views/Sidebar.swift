import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 2026-07-26: 集中 sidebar drop + fileImporter + isAudioURL 三处都引用的音频 UTI 列表。
/// 之前 5 个 audio/mp3/wav/mpeg4Audio/aiff 在两处独立写死（.fileImporter
/// 允许列表 + isAudioURL 的 conforms 链），加新格式得改两处。
let swiftASRAudioContentTypes: [UTType] = [.audio, .mp3, .wav, .mpeg4Audio, .aiff]

private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        values.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// 应用主侧栏：一级导航始终可见，最近项目只承担快捷入口，不再兼任完整文件页。
struct Sidebar: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ASRJob.createdAt, order: .reverse) private var jobs: [ASRJob]
    @Binding var section: AppSection
    @Binding var selectedJobId: String?
    @ObservedObject var coordinator: FileActionCoordinator
    @StateObject private var settings = SettingsStore.shared
    @State private var isDropTargeted = false

    /// 按"最近一次活动"倒序：重新转写/重新识别说话人/LLM 润色都会让对应 job 冒到顶。
    /// 用 ASRJob.mostRecentActivity（max of lastOperationAt/cleanedAt/finishedAt/createdAt），
    /// 而非 createdAt（添加时间，重跑后不更新 → 旧 bug）。
    private var recentJobs: [ASRJob] {
        jobs.sorted { $0.mostRecentActivity > $1.mostRecentActivity }
    }

    var body: some View {
        VStack(spacing: 0) {
            addAudioButton

            List {
                Section("工作区") {
                    ForEach(AppSection.allCases) { item in
                        navigationRow(for: item)
                    }
                }

                Section("最近项目") {
                    if recentJobs.isEmpty {
                        Label("还没有导入文件", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentJobs.prefix(12), id: \.id) { job in
                            recentJobRow(job)
                                .contextMenu {
                                    JobActionMenu(
                                        job: job,
                                        selectedJobId: $selectedJobId,
                                        coordinator: coordinator,
                                        open: { section = $0 }
                                    )
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $coordinator.showFileImporter,
            allowedContentTypes: swiftASRAudioContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                importURLs(urls)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftASRShowFileImporter)) { _ in
            coordinator.showFileImporter = true
        }
        .alert(
            "文件操作失败",
            isPresented: Binding(
                get: { coordinator.actionErrorMessage != nil },
                set: { if !$0 { coordinator.dismissActionError() } }
            )
        ) {
            Button("好") { coordinator.dismissActionError() }
        } message: {
            Text(coordinator.actionErrorMessage ?? "未知错误")
        }
    }

    private var addAudioButton: some View {
        Button {
            coordinator.showFileImporter = true
        } label: {
            Label("添加音频", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(AppLayout.sectionSpacing)
        .help("添加音频（⌘O）")
    }

    @ViewBuilder
    private func navigationRow(for item: AppSection) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: AppLayout.itemSpacing) {
                Label(item.title, systemImage: item.icon)
                Spacer()
                if item == .settings && needsApiKeyBadge {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("尚未配置 API Key")
                }
            }
            .padding(.horizontal, AppLayout.itemSpacing)
            .padding(.vertical, AppLayout.compactSpacing)
            .background(
                section == item ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(section == item ? .isSelected : [])
    }

    @ViewBuilder
    private func recentJobRow(_ job: ASRJob) -> some View {
        Button {
            selectedJobId = job.id
            section = job.jobStatus.belongsInResults ? .results : .transcription
        } label: {
            HStack(spacing: AppLayout.itemSpacing) {
                Image(systemName: JobStatusDisplay(job.jobStatus).icon)
                    .foregroundStyle(JobStatusDisplay(job.jobStatus).color)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var hasRunningJob: Bool {
        coordinator.hasActivePipeline
    }

    /// 单文件且空闲时立即转写；其他导入进入队列，并统一带用户前往转写工作区。
    private func importURLs(_ urls: [URL]) {
        var seenJobIDs = Set<String>()
        let audio = urls
            .filter(isAudioURL)
            .filter { seenJobIDs.insert(ResultStore.hashAudioPath($0.path)).inserted }
        guard !audio.isEmpty else { return }

        var selected = selectedJobId
        let shouldAutoStartFirst = !hasRunningJob
        for (index, url) in audio.enumerated() {
            coordinator.importAudioFile(
                url: url,
                jobs: jobs,
                selectedJobId: &selected,
                modelContext: modelContext,
                autoStart: shouldAutoStartFirst && index == 0
            )
        }
        selectedJobId = selected
        section = .transcription
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let collector = DroppedURLCollector()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                collector.append(url)
            }
        }
        group.notify(queue: .main) {
            importURLs(collector.snapshot())
        }
        return true
    }

    private func isAudioURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return swiftASRAudioContentTypes.contains { type.conforms(to: $0) }
    }

    private var needsApiKeyBadge: Bool {
        !settings.hasUsableGeminiKey()
    }
}
