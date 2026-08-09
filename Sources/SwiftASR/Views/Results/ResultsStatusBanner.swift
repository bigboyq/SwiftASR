import SwiftUI
import SwiftData

/// 结果页顶部状态条。从 `ResultsContent` 抽出（2026-07-21）：
/// 90 行 @ViewBuilder if-else 链 + 4 个 banner 状态 binding + 文件名裁剪
/// helper，把"提示什么 + 怎么排版"从 ResultsContent 主 view 拆出来。
///
/// **优先级顺序**（保留历史行为）：
/// 1. 当前正在跑的 LLM 润色（active cleanup）— 跨 ResultsContent 实例共享，
///    切到其他文件仍显示**正在跑**那个 cleanup 的文件
/// 2. cleanup 错误（红）
/// 3. 持久化错误（红，外置硬盘图标）
/// 4. 同步成功 banner（绿）
/// 5. 当前 job 的 cleanup 终态结果（红 / 绿，依赖 jobId 匹配）
/// 6. info banner（黄，温和提示）
struct ResultsStatusBanner: View {
    let jobId: String
    /// MainSplitView @StateObject 持有，跨 ResultsContent 实例共享 cleanup state
    @ObservedObject var coordinator: FileActionCoordinator
    /// 当前正在跑 cleanup 的 job。`ResultsContent.fetchJob(byId:)` 解析后传入，
    /// banner 不直接访问 ModelContext 也不重新查 SwiftData
    let activeCleanupJob: ASRJob?
    @Binding var cleanupError: String?
    @Binding var persistenceError: String?
    @Binding var syncBanner: String?
    @Binding var infoBanner: String?
    /// 取消 cleanup 按钮回调；具体实现由 ResultsContent 持有 coordinator 引用
    let onCancelCleanup: () -> Void

    var body: some View {
        if let activeJobId = coordinator.activeCleanupJobId {
            activeCleanupBanner(jobId: activeJobId)
        } else if let err = cleanupError {
            errorBanner(message: err, icon: "exclamationmark.triangle.fill") {
                cleanupError = nil
            }
        } else if let err = persistenceError {
            errorBanner(message: err, icon: "externaldrive.badge.exclamationmark") {
                persistenceError = nil
            }
        } else if let msg = syncBanner {
            successBanner(message: msg) {
                syncBanner = nil
            }
        } else if let outcome = coordinator.lastCleanupOutcome, outcome.jobId == jobId {
            terminalOutcomeBanner(outcome: outcome)
        } else if let msg = infoBanner {
            infoBanner(message: msg) {
                infoBanner = nil
            }
        }
    }

    // MARK: - Banner types

    @ViewBuilder
    private func activeCleanupBanner(jobId activeJobId: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            // 文件名自带日期信息（用户命名约定：6月2日.....wav 之类），
            // 直接拼在状态前面方便在多任务并行时一眼认出是哪个文件。
            // 中间用 ··· 把文件名和状态隔开，视觉上比 [文件名][状态] 更松弛。
            if let fileName = activeCleanupJob.map({ Self.cleanupFileName($0.sourceAudioPath) }) {
                Text("\(fileName) ··· LLM 润色进行中…")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("LLM 润色进行中…")
                    .font(.subheadline)
            }
            if let progress = coordinator.activeCleanupProgress {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onCancelCleanup()
            } label: {
                Label("取消", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.accentBackgroundTint)
    }

    private func errorBanner(
        message: String,
        icon: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.red)
            Text(message).font(.subheadline).lineLimit(2)
            Spacer()
            Button("关闭", action: onDismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.errorBackgroundTint)
    }

    private func successBanner(
        message: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.subheadline)
            Spacer()
            Button("关闭", action: onDismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.successBackgroundTint)
    }

    @ViewBuilder
    private func terminalOutcomeBanner(outcome: FileActionCoordinator.CleanupOutcome) -> some View {
        let isFailure = outcome.kind == .failure
        HStack(spacing: 8) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isFailure ? .red : .green)
            Text(outcome.message).font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(isFailure ? Color.errorBackgroundTint : Color.successBackgroundTint)
    }

    private func infoBanner(
        message: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        // 黄色温和提示：自动帮用户做了一件事（不是错误）。
        // 例：取消"显示原始"时自动勾"合并说话内容"。
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.yellow)
            Text(message).font(.subheadline)
            Spacer()
            Button("关闭", action: onDismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.infoBackgroundTint)
    }

    // MARK: - Helpers

    /// 状态栏用的文件名：去扩展名、保留目录最后一段的 basename。
    /// 例子：`/Users/me/recs/6月2日....wav` → `6月2日....`
    /// ——用户文件名已经带日期，不需要再解析或格式化。
    fileprivate static func cleanupFileName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? url.lastPathComponent : stem
    }
}
