import SwiftUI

struct ResultHistorySheet: View {
    let jobs: [ASRJob]
    @Binding var selectedJobId: String?
    @ObservedObject var cleanupCache: CleanupCompletionCache

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var filter: ResultHistoryFilter = .all
    @State private var requestedPage = 0

    private var entries: [ResultHistoryEntry] {
        ResultHistoryQuery.entries(from: jobs, cleanupStates: cleanupCache.states)
    }

    private var resultPage: ResultHistoryPage {
        ResultHistoryQuery.page(
            entries: entries,
            searchText: searchText,
            filter: filter,
            requestedPage: requestedPage
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("筛选结果", selection: $filter) {
                    ForEach(ResultHistoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                if resultPage.entries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(resultPage.entries) { entry in
                        ResultHistoryRow(entry: entry, isSelected: selectedJobId == entry.id) {
                            selectedJobId = entry.id
                            dismiss()
                        }
                    }
                    .listStyle(.inset)
                }

                Divider()
                paginationBar
            }
            .navigationTitle("历史结果")
            .searchable(text: $searchText, prompt: "搜索文件名或路径")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("关闭")
                    .accessibilityLabel("关闭历史结果")
                }
            }
            .onChange(of: searchText) { _, _ in requestedPage = 0 }
            .onChange(of: filter) { _, _ in requestedPage = 0 }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { cleanupCache.refresh(jobs: jobs) }
    }

    @ViewBuilder
    private var paginationBar: some View {
        if resultPage.totalCount > 0 {
            HStack(spacing: AppLayout.itemSpacing) {
                Text("共 \(resultPage.totalCount) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { requestedPage = resultPage.pageIndex - 1 }
                    .disabled(resultPage.pageIndex == 0)
                Text("第 \(resultPage.pageNumber) / \(resultPage.pageCount) 页")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("下一页") { requestedPage = resultPage.pageIndex + 1 }
                    .disabled(resultPage.pageIndex + 1 >= resultPage.pageCount)
            }
            .padding(.horizontal)
            .padding(.vertical, AppLayout.itemSpacing)
        }
    }
}

private struct ResultHistoryRow: View {
    let entry: ResultHistoryEntry
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: AppLayout.itemSpacing) {
                Image(systemName: JobStatusDisplay(entry.jobStatus).icon)
                    .foregroundStyle(JobStatusDisplay(entry.jobStatus).color)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
                    Text(entry.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(entry.completedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatDuration(entry.durationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        historyBadge(entry.isCleaned ? "已润色" : "未润色", tint: entry.isCleaned ? .green : .secondary)
                        if entry.jobStatus == .partial {
                            historyBadge("部分结果", tint: .orange)
                        }
                        if entry.totalSpeakers > 0 {
                            Text("\(entry.namedSpeakers)/\(entry.totalSpeakers) 位已命名")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: AppLayout.itemSpacing)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("当前结果")
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func historyBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
