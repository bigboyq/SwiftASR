import SwiftUI
import SwiftData
import AppKit

public enum CleanupStartMode: Sendable, Equatable {
    case resume
    case restart
}

/// 已持久化的润色 checkpoint。completed 只统计从第一个 chunk 起连续完整的结果，
/// 因而不会把损坏或不完整的旧数据误当作可以跳过的 chunk。
public struct CleanupCheckpoint: Equatable {
    public let completed: Int
    public let total: Int

    var isPartial: Bool { completed > 0 && completed < total }
    var isComplete: Bool { total > 0 && completed == total }

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

/// 润色启动 dialog（Phase B2）。
/// 跟 FunASR-Mac `gui/tabs/results/_cleanup_run_dialog.py` 对齐：
///   - 显示当前 CleanupSettings（model / chunk_chars / temperature / prompt）
///   - 列出所有 enabled 的 key（按 priority 升序）
///   - 让用户勾选要参与本次润色的 key 池
///   - 「开始」按钮启动 LLMCleanupService
///
/// SwiftASR 的差异（vs FunASR-Mac）：
///   - 不让用户在 dialog 内改 settings（改 settings 走 SettingsTab）
///   - 不显示 key 池以外的高级选项（chunk_chars 走 settings）
public struct CleanupRunDialog: View {
    let modelContext: ModelContext
    @Binding var isPresented: Bool
    /// 当前 job 已落盘的 checkpoint，用来决定续跑/重跑动作。
    let checkpoint: CleanupCheckpoint

    @State private var allKeys: [APIKeyConfig] = []
    @State private var selectedKeyIds: Set<String> = []
    @State private var settings: SettingsStore.CleanupSettings = SettingsStore.CleanupSettings()
    @State private var isStarting: Bool = false
    @State private var errorMessage: String?
    /// 订阅 `SettingsStore` 变化：API Key 池在 SettingsTab 改后自动刷新，
    /// cleanup 配置（在 SettingsTab 改了）也对 dialog 立刻生效。
    @StateObject private var settingsObserver = SettingsStore.shared

    var onStart: ((LLMCleanupService, CancellationToken, [APIKeyConfig], CleanupStartMode) -> Void)? = nil

    public init(
        modelContext: ModelContext,
        isPresented: Binding<Bool>,
        checkpoint: CleanupCheckpoint,
        onStart: ((LLMCleanupService, CancellationToken, [APIKeyConfig], CleanupStartMode) -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self._isPresented = isPresented
        self.checkpoint = checkpoint
        self.onStart = onStart
    }

    public var body: some View {
        VStack(spacing: 12) {
            header
            if checkpoint.completed > 0 {
                checkpointNotice
            }
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: checkpoint.completed > 0 ? 480 : 420)
        .onAppear { load() }
    }

    // 已经有润色结果时的明显提示（放在 header 下方、settings 上方）
    @ViewBuilder
    private var checkpointNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkpoint.isPartial
                     ? "已润色 \(checkpoint.completed)/\(checkpoint.total) 段，可继续润色"
                     : "已润色全部 \(checkpoint.total) 段")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(checkpoint.isPartial
                     ? "选择「继续润色」会复用已润色段，从第 \(checkpoint.completed + 1) 段接着跑；「重新润色」会清除所有已有润色结果。"
                     : "选择「重新润色」会清除所有已有润色结果；原始转写不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.errorBackgroundTint)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.errorBorderTint, lineWidth: 1)
        )
        .cornerRadius(6)
        .padding(.horizontal, 16)
    }

    // MARK: - 区域

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.title2)
            Text("启动 Gemini 润色")
                .font(.title2.bold())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsCard
                keyPickerCard
            }
            .padding(16)
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                Text("润色设置").font(.subheadline.weight(.semibold))
                Spacer()
                Text("在「设置」tab 修改")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 16) {
                Text("模型：\(settings.model)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Chunk：\(settings.chunkChars) 字符")
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: "Temperature：%.2f", settings.temperature))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var keyPickerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                Text("Gemini Keys（先按 tier、再按 priority 升序）")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(selectedKeyIds.count) / \(allKeys.count) 选中")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if allKeys.isEmpty {
                Text("没有可用的 Gemini Key。请到「设置 → API Keys」添加。")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                VStack(spacing: 4) {
                    ForEach(allKeys) { key in
                        KeyRow(
                            key: key,
                            isSelected: selectedKeyIds.contains(key.id),
                            onToggle: { toggleKey(key) }
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var footer: some View {
        HStack {
            if let err = errorMessage {
                Text(err)
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("取消") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            if checkpoint.isPartial {
                Button("重新润色") { startCleanup(mode: .restart) }
                    .disabled(selectedKeyIds.isEmpty || isStarting)
                Button { startCleanup(mode: .resume) } label: {
                    if isStarting { ProgressView().controlSize(.small) }
                    else { Text("继续润色（\(checkpoint.completed)/\(checkpoint.total)）") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedKeyIds.isEmpty || isStarting)
            } else {
                Button {
                    startCleanup(mode: .restart)
                } label: {
                    if isStarting { ProgressView().controlSize(.small) }
                    else { Text(checkpoint.isComplete ? "重新润色" : "开始润色") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedKeyIds.isEmpty || isStarting)
            }
        }
        .padding(16)
    }

    // MARK: - 数据

    private func load() {
        allKeys = SettingsStore.shared.apiKeys()
            .filter(\.isUsableGeminiKey)
            // v10 tier 升级：先 tier 升序、再 priority 升序。跨 tier 允许
            // 同 priority（因为 unique 约束只在 (tier, priority) 复合里）。
            // 跟 SettingsStore.upsertApiKeys + GeminiKeyFailover 池序一致。
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return lhs.priority < rhs.priority
            }
        // 默认全选
        if selectedKeyIds.isEmpty {
            selectedKeyIds = Set(allKeys.map { $0.id })
        }
        settings = SettingsStore.shared.cleanupSettings()
    }

    private func toggleKey(_ key: APIKeyConfig) {
        if selectedKeyIds.contains(key.id) {
            selectedKeyIds.remove(key.id)
        } else {
            selectedKeyIds.insert(key.id)
        }
    }

    private func startCleanup(mode: CleanupStartMode) {
        let selected = allKeys.filter { selectedKeyIds.contains($0.id) }
        guard !selected.isEmpty else { return }
        isStarting = true
        let service = LLMCleanupService(settings: settings, keys: selected)
        let token = CancellationToken()
        onStart?(service, token, selected, mode)
        isPresented = false
    }
}

struct KeyRow: View {
    let key: APIKeyConfig
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(key.label)
                            .font(.body)
                        // tier 0 = 免费（次要色），1+ = 付费（橙色）
                        // 颜色让用户一眼看出"同一 tier 内的 key 在轮询，
                        // 不同 tier 之间会升 / 降级"。
                        tierBadge(key.tier)
                        Text("p=\(key.priority)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(3)
                    }
                    Text(maskedKey(key.keyValue))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(4)
    }

    private func maskedKey(_ key: String) -> String {
        if key.count <= 8 { return key }
        return String(key.prefix(4)) + "••••" + String(key.suffix(4))
    }

    /// Tier 升级：tier 数字渲染成 `T0` / `T1` / ... 标签。0 = 免费
    /// （次要色），1+ = 付费（橙色）。返回 some View 让 KeyRow 行紧凑。
    @ViewBuilder
    private func tierBadge(_ tier: Int) -> some View {
        let label = "T" + String(tier)
        Text(label)
            .font(.caption.monospaced())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundColor(tier == 0 ? .secondary : .orange)
            .background(
                (tier == 0 ? Color.secondary : Color.orange)
                    .opacity(0.15)
            )
            .cornerRadius(3)
    }
}
