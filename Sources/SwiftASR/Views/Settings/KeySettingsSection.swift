import SwiftUI
import AppKit

// MARK: - API Key 设置 Section

/// Gemini API Key 管理。子 view 接 `@Binding` 让父 view 控制 sheet 状态。
///
/// 表格用 SwiftUI 原生 `Table`（macOS 12+）：
/// - 7 列：`TableColumn` 各自指定宽度 / 对齐 / 排序
/// - 单选：`selection: $selectedKeyId`
/// - 测试消息在行下方 inline 展示（用 `Table` 之外的 VStack 包裹，不进 cell）
///
/// 跟旧版手搓 HStack 对比：列宽自适应 + 选中态系统默认 + 双击 gesture 由 `Table` 自己处理。
public struct KeySettingsSection: View {
    @Binding var apiKeys: [APIKeyConfig]
    @State private var selectedKeyId: String?
    @State private var testingKeyId: String?
    @State private var testMessages: [String: String] = [:]

    // Sheet state
    @State private var showAddSheet = false
    @State private var showEditSheet = false
    @State private var showFullKey = false

    // Sheet input buffers
    @State private var keyLabel: String = ""
    @State private var keyValue: String = ""
    @State private var keyPriority: Int = 0
    @State private var keyTier: Int = 0
    @State private var keyNotes: String = ""

    /// 列表展示用的排序：先 Tier 升序，同 Tier 内 priority 升序。
    /// 跟 ``SettingsStore.upsertApiKeys`` 和 ``GeminiKeyFailover`` 的池序
    /// 完全一致——UI 看到的顺序就是 failover 实际跑过的顺序。
    private var sortedApiKeys: [APIKeyConfig] {
        apiKeys.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.priority < rhs.priority
        }
    }

    private var selectedKey: APIKeyConfig? {
        apiKeys.first { $0.id == selectedKeyId }
    }

    private var apiKeyTierCount: Int {
        Set(apiKeys.map(\.tier)).count
    }

    public init(apiKeys: Binding<[APIKeyConfig]>) {
        self._apiKeys = apiKeys
    }

    public var body: some View {
        Section {
            // 顶部说明（不用 emoji，统一 SF Symbol + text）
            Label {
                Text("当前只支持 Gemini API Key。key 明文存储在本地（默认不依赖 Keychain）。key 列表只显示前/后缀；要看完整 key 点「显示完整」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            // 五个操作在同一行，便于在 API Key 表格上方连续完成管理动作。
            toolbar
                .padding(.vertical, 2)

            // 表格 + 选中消息
            keyTable
        } header: {
            HStack {
                Label("Gemini API Keys", systemImage: "key.horizontal")
                Spacer()
                Text("共 \(apiKeys.count) 个 Key · 分 \(apiKeyTierCount) 个 Tier")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            KeyEditSheet(
                isPresented: $showAddSheet,
                isEditing: false,
                label: $keyLabel,
                keyValue: $keyValue,
                priority: $keyPriority,
                tier: $keyTier,
                notes: $keyNotes,
                onSave: { lbl, val, pri, tier, nts in
                    addKey(label: lbl, value: val, priority: pri, tier: tier, notes: nts)
                }
            )
        }
        .sheet(isPresented: $showEditSheet) {
            KeyEditSheet(
                isPresented: $showEditSheet,
                isEditing: true,
                label: $keyLabel,
                keyValue: $keyValue,
                priority: $keyPriority,
                tier: $keyTier,
                notes: $keyNotes,
                onSave: { lbl, val, pri, tier, nts in
                    if let selectedKeyId = selectedKeyId {
                        editKey(keyId: selectedKeyId, label: lbl, value: val, priority: pri, tier: tier, notes: nts)
                    }
                }
            )
        }
        .sheet(isPresented: $showFullKey) {
            if let selectedKey = selectedKey {
                FullKeySheet(
                    keyId: selectedKey.id,
                    keyValue: selectedKey.keyValue,
                    isPresented: $showFullKey
                )
            }
        }
    }

    // MARK: - 工具栏

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                keyLabel = ""
                keyValue = ""
                keyPriority = 0
                keyTier = 0
                keyNotes = ""
                showAddSheet = true
            } label: {
                Label("添加 Key", systemImage: "plus")
            }
            .controlSize(.small)

            Button {
                openEditSheet()
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .controlSize(.small)
            .disabled(selectedKeyId == nil)

            Button {
                if selectedKey != nil { showFullKey = true }
            } label: {
                Label("显示完整", systemImage: "eye")
            }
            .controlSize(.small)
            .disabled(selectedKeyId == nil)

            Button {
                if let selectedKey = selectedKey {
                    testKeyConnection(selectedKey)
                }
            } label: {
                if let selectedKey = selectedKey, testingKeyId == selectedKey.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label("测试连接", systemImage: "bolt.horizontal")
                }
            }
            .controlSize(.small)
            .disabled(selectedKeyId == nil || testingKeyId != nil)

            Button {
                if let selectedKey = selectedKey {
                    confirmDeleteKey(selectedKey)
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(selectedKeyId == nil)
            .foregroundStyle(.red)

            Spacer()
        }
    }

    // MARK: - 表格

    @ViewBuilder
    private var keyTable: some View {
        VStack(spacing: 0) {
            if apiKeys.isEmpty {
                Text("无 Key，请点击上方「添加 Key」添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Table(sortedApiKeys, selection: $selectedKeyId) {
                    TableColumn("") { key in
                        Toggle("", isOn: Binding(
                            get: { key.isEnabled },
                            set: { _ in toggleKey(key) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    }
                    .width(40)

                    TableColumn("标签") { key in
                        Text(key.label)
                            .lineLimit(1)
                    }
                    .width(min: 80, ideal: 110)

                    TableColumn("Key") { key in
                        Text(key.keyPrefix)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("优先级") { key in
                        Text(String(format: "%3d", key.priority))
                            .font(.body.monospacedDigit())
                    }
                    .width(60)

                    TableColumn("Tier") { key in
                        Text("T\(key.tier)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(key.tier == 0 ? Color.secondary : Color.orange)
                    }
                    .width(50)

                    TableColumn("上次使用") { key in
                        Text(formatLastUsed(key.lastUsedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("成功") { key in
                        if key.successCount > 0 {
                            Text("\(key.successCount)")
                                .font(.caption.monospacedDigit())
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(50)

                    TableColumn("备注") { key in
                        Text(key.notes ?? "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 160)
                }
                .frame(minHeight: 200, idealHeight: 240)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let key = apiKeys.first(where: { $0.id == id }) {
                        Button("编辑", systemImage: "pencil") {
                            selectedKeyId = key.id
                            openEditSheet()
                        }
                        Button("显示完整 Key", systemImage: "eye") {
                            selectedKeyId = key.id
                            showFullKey = true
                        }
                        Button("测试连接", systemImage: "bolt.horizontal") {
                            selectedKeyId = key.id
                            testKeyConnection(key)
                        }
                        Divider()
                        Button("删除", systemImage: "trash", role: .destructive) {
                            selectedKeyId = key.id
                            confirmDeleteKey(key)
                        }
                    }
                }
                .onTapGesture(count: 2) {
                    if selectedKeyId != nil { openEditSheet() }
                }

                // 选中行对应的测试消息（放在 Table 下方）
                if let id = selectedKeyId, let testMsg = testMessages[id] {
                    HStack {
                        Image(systemName: testMsg.contains("✅") ? "checkmark.circle.fill"
                              : testMsg.contains("❌") ? "xmark.octagon.fill"
                              : "info.circle")
                            .foregroundStyle(testMsg.contains("✅") ? .green
                                           : testMsg.contains("❌") ? .red
                                           : .secondary)
                        Text(testMsg)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.05))
                }

                // 状态栏
                HStack {
                    let inPool = apiKeys.filter { $0.isEnabled }.count
                    Text("共 \(apiKeys.count) 个 key；其中 \(inPool) 个在润色池里（已设 priority）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .border(Color.secondary.opacity(0.2))
        .cornerRadius(4)
    }

    // MARK: - 操作

    private func openEditSheet() {
        guard let key = selectedKey else { return }
        keyLabel = key.label
        keyValue = ""
        keyPriority = key.priority
        keyTier = key.tier
        keyNotes = key.notes ?? ""
        showEditSheet = true
    }

    private func addKey(label: String, value: String, priority: Int, tier: Int, notes: String?) {
        let normalizedPriority = max(0, min(99, priority))
        let normalizedTier = max(0, min(9, tier))
        if apiKeys.contains(where: { $0.tier == normalizedTier && $0.priority == normalizedPriority }) {
            reportTierPriorityConflict(tier: normalizedTier, priority: normalizedPriority)
            return
        }
        apiKeys.append(APIKeyConfig(
            label: label, keyValue: value,
            isEnabled: true, priority: normalizedPriority, tier: normalizedTier,
            notes: notes
        ))
        SettingsStore.shared.setApiKeys(apiKeys)
        clearKeyBuffers()
        showAddSheet = false
    }

    private func editKey(keyId: String, label: String, value: String, priority: Int, tier: Int, notes: String?) {
        let normalizedPriority = max(0, min(99, priority))
        let normalizedTier = max(0, min(9, tier))
        if apiKeys.contains(where: { $0.id != keyId && $0.tier == normalizedTier && $0.priority == normalizedPriority }) {
            reportTierPriorityConflict(tier: normalizedTier, priority: normalizedPriority)
            return
        }
        if let idx = apiKeys.firstIndex(where: { $0.id == keyId }) {
            apiKeys[idx].label = label
            let trimmedVal = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedVal.isEmpty {
                apiKeys[idx].keyValue = trimmedVal
                apiKeys[idx].keyPrefix = APIKeyConfig.deriveKeyPrefix(from: trimmedVal)
            }
            apiKeys[idx].priority = normalizedPriority
            apiKeys[idx].tier = normalizedTier
            apiKeys[idx].notes = notes?.isEmpty == true ? nil : notes
            SettingsStore.shared.setApiKeys(apiKeys)
        }
        clearKeyBuffers()
        showEditSheet = false
    }

    private func removeKey(_ key: APIKeyConfig) {
        apiKeys.removeAll { $0.id == key.id }
        SettingsStore.shared.setApiKeys(apiKeys)
    }

    private func confirmDeleteKey(_ key: APIKeyConfig) {
        let confirmed = AlertHelper.confirm(
            title: "确认删除",
            message: "确认要删除 API Key「\(key.label)」吗？",
            confirmTitle: "删除"
        )
        if confirmed {
            removeKey(key)
            if selectedKeyId == key.id {
                selectedKeyId = nil
            }
        }
    }

    private func toggleKey(_ key: APIKeyConfig) {
        if let idx = apiKeys.firstIndex(where: { $0.id == key.id }) {
            apiKeys[idx].isEnabled.toggle()
            SettingsStore.shared.setApiKeys(apiKeys)
        }
    }

    private func testKeyConnection(_ key: APIKeyConfig) {
        testingKeyId = key.id
        testMessages[key.id] = "测试中…"
        Task {
            let result = await GeminiProvider.testConnection(
                apiKey: key.keyValue,
                modelName: SettingsStore.CleanupDefaults.model
            )
            await MainActor.run {
                testingKeyId = nil
                testMessages[key.id] = result.message
                if result.ok {
                    SettingsStore.shared.updateLastUsedAt(keyId: key.id)
                    apiKeys = SettingsStore.shared.apiKeys()
                }
            }
        }
    }

    private func clearKeyBuffers() {
        keyLabel = ""
        keyValue = ""
        keyPriority = 0
        keyTier = 0
        keyNotes = ""
    }

    /// addKey / editKey 共用 alert：相同 (tier, priority) 在同 provider 内已占用。
    /// 之前 2 处 6 行 alert 配置完全重复，合并到这里。
    private func reportTierPriorityConflict(tier: Int, priority: Int) {
        AlertHelper.showInfo(
            title: "tier=\(tier) priority=\(priority) 已被占用",
            message: "请换一个 priority 数字，或者换一个 tier。每个 (tier, priority) 在同一 provider 内只能用一个 key。",
            buttonTitle: "好",
            style: .warning
        )
    }

    private func formatLastUsed(_ date: Date?) -> String {
        guard let date = date else { return "从未使用" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
