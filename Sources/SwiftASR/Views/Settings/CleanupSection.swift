import SwiftUI

// MARK: - 润色设置 Section

enum CleanupPromptDraftSynchronization {
    static func replacement(
        currentDraft: String,
        externalPrompt: String
    ) -> String? {
        externalPrompt == currentDraft ? nil : externalPrompt
    }
}

/// Gemini 润色设置：模型（只读）/ Chunk 大小 / Temperature / Prompt。
///
/// **Prompt 500ms debounce**（避免每打一个字触发 settings.json IO）：
/// - `onChange` 调 `scheduleSave()` 取消上一次 pending Task，启动新 Task
/// - 500ms 内连续输入只触发最后一次 save
/// - 退出页面时 `onDisappear` flush（取消 pending task + 立即 save）
public struct CleanupSection: View {
    @Binding var cleanup: SettingsStore.CleanupSettings
    /// 子 view 内部维护一个 prompt 草稿，避免每打一个字都触发 Binding 写回
    @State private var promptDraft: String = ""
    /// Last prompt value this child intentionally mirrored into the binding.
    /// If the binding differs on disappear, a parent-level reset won the race
    /// and must never be overwritten by the local draft.
    @State private var synchronizedPrompt: String = ""
    @State private var debounceTask: Task<Void, Never>?

    public init(cleanup: Binding<SettingsStore.CleanupSettings>) {
        self._cleanup = cleanup
        self._promptDraft = State(initialValue: cleanup.wrappedValue.prompt)
        self._synchronizedPrompt = State(initialValue: cleanup.wrappedValue.prompt)
    }

    public var body: some View {
        Section {
            // 模型定死，UI 只展示不暴露配置
            HStack {
                Text("模型")
                Spacer()
                Text(SettingsStore.CleanupDefaults.model)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .help("模型名固定为 \(SettingsStore.CleanupDefaults.model)，不在 UI 暴露配置。")
            }

            // Chunk 大小用 Slider：2000-12000、step 500、默认 6000
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Chunk 大小")
                    Spacer()
                    Text("\(cleanup.chunkChars) 字符")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("2000")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(cleanup.chunkChars) },
                            set: { newVal in
                                let stepped = (Int(newVal.rounded()) / 500) * 500
                                cleanup.chunkChars = max(2000, min(12000, stepped))
                                saveCleanup()
                            }
                        ),
                        in: 2000...12000,
                        step: 500
                    )
                    .accessibilityLabel("润色 Chunk 大小")
                    .accessibilityValue("\(cleanup.chunkChars) 字符")
                    Text("12000")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Temperature")
                Spacer()
                TextField("0.2", value: Binding(
                    get: { cleanup.temperature },
                    set: { cleanup.temperature = $0; saveCleanup() }
                ), formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 80)
                .accessibilityLabel("Temperature")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Prompt").font(.body)
                    Spacer()
                    // debounce 状态指示
                    if debounceTask != nil {
                        Label("编辑中…", systemImage: "ellipsis.circle")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                TextEditor(text: $promptDraft)
                    .font(.caption)
                    .frame(minHeight: 100, maxHeight: 200)
                    .border(Color.secondary.opacity(0.2))
                    .onChange(of: promptDraft) { _, newVal in
                        cleanup.prompt = newVal
                        synchronizedPrompt = newVal
                        scheduleSave()
                    }
            }

            HStack {
                Spacer()
                Button {
                    SettingsStore.shared.resetCleanupSettings()
                    cleanup = SettingsStore.shared.cleanupSettings()
                    promptDraft = cleanup.prompt
                } label: {
                    Label("恢复默认", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.small)
            }
        } header: {
            Label("润色设置", systemImage: "sparkles")
                .foregroundStyle(.tint)
        } footer: {
            Text("Chunk 切分按字符数贪心切。Temperature 0.0-1.0，越高越发散。Prompt 留空会用默认。输入后 500ms 自动保存。")
                .font(.caption)
        }
        .onChange(of: cleanup.prompt) { _, externalPrompt in
            // `SettingsTab.resetAllSettings()` replaces the parent binding
            // while this child view keeps its @State identity. Adopt that
            // external value and cancel any pending save of the old draft so
            // onDisappear cannot silently restore the pre-reset prompt.
            guard let replacement = CleanupPromptDraftSynchronization.replacement(
                currentDraft: promptDraft,
                externalPrompt: externalPrompt
            ) else { return }
            debounceTask?.cancel()
            debounceTask = nil
            promptDraft = replacement
            synchronizedPrompt = replacement
        }
        .onDisappear {
            // 离开时 flush：取消 pending + 立即保存最后一次
            debounceTask?.cancel()
            debounceTask = nil
            if cleanup.prompt != synchronizedPrompt {
                // The parent replaced the binding (for example reset all)
                // before SwiftUI delivered onChange. Preserve that external
                // value instead of flushing the stale draft.
                promptDraft = cleanup.prompt
                synchronizedPrompt = cleanup.prompt
            } else if cleanup.prompt != promptDraft {
                cleanup.prompt = promptDraft
                synchronizedPrompt = promptDraft
            }
            saveCleanup()
        }
    }

    // MARK: - Debounce

    /// 调度一次 500ms 后的保存。如果 500ms 内再次调用，
    /// 上一次 task 被 cancel，新 task 启动。
    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            saveCleanup()
            debounceTask = nil
        }
    }

    private func saveCleanup() {
        SettingsStore.shared.setCleanupSettings(cleanup)
    }
}
