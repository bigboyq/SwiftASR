import SwiftUI
import AppKit

/// Person 增/改共用 sheet。
///
/// 用法：
/// - 新建：`PersonEditSheet(isPresented: $s, mode: .creating) { name in ... }`
/// - 改名：`PersonEditSheet(isPresented: $s, mode: .renaming(person)) { name in ... }`
///
/// Person.name 是 `@Attribute(.unique)`，重名时由父 View 弹 NSAlert 拒绝
/// （跟 SettingsTab.addKey 风格一致）。
public struct PersonEditSheet: View {
    @Binding var isPresented: Bool
    let mode: Mode
    /// 用户确认后回调，参数是 trim 后的非空 name
    let onSave: (String) -> Void

    @State private var nameDraft: String = ""
    @FocusState private var nameFocused: Bool

    public enum Mode: Equatable, Identifiable {
        case creating
        case renaming(Person)

        public var id: String {
            switch self {
            case .creating: return "create"
            case .renaming(let p): return "rename-\(p.id)"
            }
        }
    }

    public init(
        isPresented: Binding<Bool>,
        mode: Mode,
        onSave: @escaping (String) -> Void
    ) {
        self._isPresented = isPresented
        self.mode = mode
        self.onSave = onSave
    }

    private var title: String {
        switch mode {
        case .creating: return "新增说话人"
        case .renaming: return "重命名说话人"
        }
    }

    private var existingName: String? {
        if case .renaming(let p) = mode { return p.name }
        return nil
    }

    private var trimmed: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmed.isEmpty }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.title2.bold())
                Spacer()
            }
            .padding(16)
            Divider()
            Form {
                TextField("名字", text: $nameDraft, prompt: Text(existingName ?? "新名字"))
                    .focused($nameFocused)
                    .onSubmit { commit() }
                if let existing = existingName {
                    HStack {
                        Text("当前").foregroundStyle(.secondary)
                        Text(existing)
                    }
                    .font(.caption)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider()
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 420, height: existingName == nil ? 200 : 240)
        .onAppear {
            if case .renaming(let p) = mode {
                nameDraft = p.name
            }
            // 等 sheet 动画完成再 focus（macOS sheet 动画期间 focus 会丢）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                nameFocused = true
            }
        }
    }

    private func commit() {
        guard canSave else { return }
        onSave(trimmed)
        isPresented = false
    }
}
