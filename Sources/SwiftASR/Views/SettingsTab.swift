import SwiftUI
import AppKit

/// 设置 tab 主壳 — 仅负责 state 装卸 + section 装配。
/// 6 个 section 拆到 `Views/Settings/` 子目录（Phase 18, 2026-07-12）：
/// - `KeySettingsSection`   — API Keys 表格 + 工具栏 + KeyEditSheet + FullKeySheet
/// - `GlossarySection`      — 优先术语表
/// - `CleanupSection`       — 润色设置（Prompt 500ms debounce）
/// - `AboutSection`         — 关于
/// - `ModelsSection`        — 模型管理（含 ModelRow）
/// - `DataLocationSection`  — 数据位置（含 DataLocationRow）
///
/// Phase 18 同时做了：
/// - API Key 工具栏的五个管理操作保持在同一行
/// - API Key 表格手搓 HStack → SwiftUI 原生 `Table`（7 列 1 选中）
/// - destructive 按钮（删除 Key / 清理日志 / 说话人页删除指纹）统一降级为普通按钮 + 红色
/// - Prompt 改 500ms debounce 保存
/// - 加"重置所有设置"按钮（保留清理日志按钮）
/// - emoji（`✨` `✏️` `➕` `✅` `❌` `🌟`）→ SF Symbol（Apple HIG 不鼓励生产 UI 堆 emoji）
public struct SettingsTab: View {
    @ObservedObject private var settingsStore = SettingsStore.shared
    // API Key section 内部维护 selection / testingKeyId / sheet state，
    // 只把数据 binding 传进去。
    @State private var apiKeys: [APIKeyConfig] = []
    @State private var glossary: [String] = []
    @State private var cleanup: SettingsStore.CleanupSettings = SettingsStore.CleanupSettings()

    // Phase 7：模型 + 数据位置（每次刷新都重读磁盘）
    @State private var models: [ModelInfo] = []
    @State private var dataLocations: [DataLocation] = []
    @State private var statusRefreshID = 0

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader("设置", subtitle: "配置 Gemini 润色、术语、模型与数据位置") {
                Button {
                    requestStatusRefresh()
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .help("重新读取模型和数据位置状态")
            }
            Divider()
            if let error = settingsStore.lastPersistenceError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            ScrollView {
                Form {
                    // API Key 表格（7 列原生 Table + 单行管理工具栏）
                    KeySettingsSection(apiKeys: $apiKeys)
                    // 术语表
                    GlossarySection(glossary: $glossary)
                    // 润色设置（Prompt 500ms debounce）
                    CleanupSection(cleanup: $cleanup)
                    // 关于 — 显示 SettingsTab 维护的 cleanup.model，响应 CleanupSection 的修改
                    AboutSection(cleanupModel: cleanup.model)
                    // 模型管理
                    ModelsSection(models: models)
                    // 数据位置（含清理日志入口，destructive 已降级）
                    DataLocationSection(
                        locations: dataLocations,
                        onRefresh: requestStatusRefresh,
                        onClearLogs: clearAllLogs
                    )

                    // 重置所有设置（页面最底部 — 远离主操作，避免误点）
                    // 跟 Phase 19 其他 destructive 一致：降级为普通 Button + 红色 text 保留警示，
                    // 不可撤销警示放 NSAlert critical 二次确认。
                    Section {
                        HStack {
                            Spacer()
                            Button {
                                confirmResetAll()
                            } label: {
                                Label("重置所有设置", systemImage: "arrow.uturn.backward.circle")
                            }
                            .controlSize(.small)
                            .foregroundStyle(.red)
                        }
                    } footer: {
                        Text("清空所有 API Key / 术语表 / 润色设置，恢复出厂状态。模型路径跟数据位置属于文件系统层，不受影响。")
                            .font(.caption)
                    }
                }
                .formStyle(.grouped)
                .padding()
            }
        }
        .task {
            load()
        }
        .task(id: statusRefreshID) {
            await refreshStatus()
        }
    }

    // MARK: - 数据装卸

    private func load() {
        apiKeys = SettingsStore.shared.apiKeys()
        // 加载时也走一次 normalize：去重 + 排序。
        glossary = SettingsStore.normalizeGlossary(SettingsStore.shared.glossary())
        cleanup = SettingsStore.shared.cleanupSettings()
    }

    // MARK: - 模型 + 数据位置刷新

    private func requestStatusRefresh() {
        statusRefreshID += 1
    }

    private func refreshStatus() async {
        let m = await Task.detached(priority: .userInitiated) {
            ModelsInspector.inspectModels()
        }.value
        guard !Task.isCancelled else { return }
        models = m

        let locs = await Task.detached(priority: .userInitiated) {
            ModelsInspector.inspectDataLocations()
        }.value
        guard !Task.isCancelled else { return }
        dataLocations = locs
    }

    private func clearAllLogs() {
        defer { requestStatusRefresh() }
        guard Logger.shared.clearAll() else {
            AlertHelper.showInfo(
                title: "日志清理未完成",
                message: "部分日志文件无法删除，请检查文件权限后重试。",
                style: .warning
            )
            return
        }
    }

    // MARK: - 重置所有设置

    private func confirmResetAll() {
        let confirmed = AlertHelper.confirm(
            title: "重置所有设置？",
            message: "将清空所有 API Key、术语表、润色设置，恢复出厂默认。\n\n该操作不可撤销。模型路径跟数据位置属于文件系统层，不受影响。",
            confirmTitle: "重置",
            style: .critical
        )
        if confirmed {
            SettingsStore.shared.resetAllSettings()
            load()
        }
    }
}
