import SwiftUI
import AppKit

/// 添加 / 编辑 Gemini API Key 的 sheet。
/// 标题用 SF Symbol 不用 emoji（Apple HIG 不鼓励生产 UI 堆 emoji）。
/// 父 view 通过 `@Binding` 控制 sheet 状态，按"保存"调 `onSave` 回调。
struct KeyEditSheet: View {
    @Binding var isPresented: Bool
    let isEditing: Bool
    @Binding var label: String
    @Binding var keyValue: String
    @Binding var priority: Int
    @Binding var tier: Int
    @Binding var notes: String
    let onSave: (String, String, Int, Int, String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isEditing ? "pencil.circle.fill" : "plus.circle.fill")
                    .font(.title2)
                Text(isEditing ? "编辑 Gemini API Key" : "添加 Gemini API Key")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(16)
            Divider()
            Form {
                LabeledContent("Provider", value: "gemini")
                    .foregroundStyle(.secondary)
                TextField("标签", text: $label, prompt: Text("我的工作号"))
                SecureField("Key Value", text: $keyValue, prompt: Text(isEditing ? "留空表示不修改" : "AIzaSy..."))
                HStack {
                    Text("Priority:")
                    Spacer()
                    Text("\(priority)")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 30, alignment: .trailing)
                    Stepper("", value: $priority, in: 0...99)
                        .labelsHidden()
                }
                HStack {
                    Text("Tier:")
                    Spacer()
                    Text("\(tier)")
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 30, alignment: .trailing)
                    Stepper("", value: $tier, in: 0...9)
                        .labelsHidden()
                }
                Text("Priority 0 = 最优先；数字越大越靠后。Tier 0 = 免费；1+ = 付费。\n同一 (tier, priority) 内只能放一个 key。润色时 429 在同 tier 内轮询，5xx / 529 会升 tier。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("备注", text: $notes, prompt: Text("公司 / 自用 / 备用..."))
            }
            .formStyle(.grouped)
            .padding(16)
            Divider()
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(label, keyValue, priority, tier, notes.isEmpty ? nil : notes)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isEditing && keyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 410)
    }
}
