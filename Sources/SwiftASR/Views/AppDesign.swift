import SwiftUI

/// 应用级导航。文件是管理入口；转写和结果分别承载进行中的任务与已完成的工作台。
enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case files
    case transcription
    case results
    case speakers
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .files: return "文件"
        case .transcription: return "转写"
        case .results: return "结果"
        case .speakers: return "说话人"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .files: return "folder"
        case .transcription: return "waveform"
        case .results: return "doc.text"
        case .speakers: return "person.2.fill"
        case .settings: return "gearshape"
        }
    }
}

enum AppLayout {
    static let compactSpacing: CGFloat = 4
    static let itemSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 12
    static let pagePadding: CGFloat = 20
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 228
    static let sidebarMaxWidth: CGFloat = 280
    static let contentMinWidth: CGFloat = 680
    static let windowMinWidth: CGFloat = 1_100
    static let windowMinHeight: CGFloat = 720
    /// 结果页说话人姓名菜单比旧设计增加约 20%，足以容纳常见的五字姓名。
    static let resultsSpeakerPickerWidth: CGFloat = 204
    /// 面板只比其内容菜单宽左右各 6pt，避免与正文等宽分栏。
    static let resultsSpeakerPanelWidth: CGFloat = resultsSpeakerPickerWidth + 12
}

extension Color {
    /// 轻量错误提示背景（红 + 8% 透明），用于
    /// `MainSplitView` 启动恢复状态 / `SpeakersTab` 持久化错误 /
    /// `CleanupRunDialog` LLM 输出警告等场景。
    /// 2026-07-26 集中（原 3 处内联 `Color.red.opacity(0.08)`）。
    static let errorBackgroundTint = Color.red.opacity(0.08)

    /// 软告警背景（橙黄 + 10% 透明），用于
    /// `MainSplitView` 长音频内存预警告（2026-08-02 A2）。比 errorTint
    /// 浅一档，提示"建议但可继续"，不阻断用户操作。
    static let warningBackgroundTint = Color.orange.opacity(0.10)

    // MARK: - 2026-08-04 round-3 M1 F-NEW-1：扩 design token 收口

    /// 主色淡背景（accent + 10% 透明），用于 "active cleanup" 等中性
    /// progress 状态。比 success 冷一档，提示"操作进行中"但成功未定。
    /// `ResultsStatusBanner.swift:86`
    static let accentBackgroundTint = Color.accentColor.opacity(0.10)

    /// 成功背景（绿 + 10% 透明），用于 cleanup 成功 / 任务完成。
    /// 比 accent 暖一档，提示"已结束且成功"。
    /// `ResultsStatusBanner.swift:115`
    static let successBackgroundTint = Color.green.opacity(0.10)

    /// 信息背景（黄 + 12% 透明），用于带 LLM 注释 / partial 完成等
    /// "需用户注意但不阻断"的状态。比 warning 浅一档（不是系统级 warning）。
    /// `ResultsStatusBanner.swift:144`
    static let infoBackgroundTint = Color.yellow.opacity(0.12)

    /// 错误描边（红 + 40% 透明），用于需要突出错误但不让背景吃掉
    /// 正文的对话框边框。
    /// `CleanupRunDialog.swift:105`
    static let errorBorderTint = Color.red.opacity(0.40)
}

struct WorkspaceHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions

    init(
        _ title: String,
        subtitle: String,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppLayout.itemSpacing) {
            VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppLayout.sectionSpacing)
            actions()
        }
        .padding(.horizontal, AppLayout.pagePadding)
        .padding(.vertical, AppLayout.sectionSpacing)
    }
}

struct WorkspaceEmptyState: View {
    let title: String
    let message: String
    let icon: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: icon,
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppLayout.pagePadding)
    }
}

extension JobStatus {
    var belongsInResults: Bool {
        self == .done || self == .partial
    }

    var belongsInTranscription: Bool {
        !belongsInResults
    }
}
