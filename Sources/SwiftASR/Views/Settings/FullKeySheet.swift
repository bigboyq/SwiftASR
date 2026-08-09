import SwiftUI

/// 显示完整 Gemini API Key 明文的 sheet。父 view 控制 `isPresented`。
/// Key 内容用 `textSelection(.enabled)` 让用户双击或拖拽选中复制。
struct FullKeySheet: View {
    let keyId: String
    let keyValue: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.title2)
                Text("API Key 明文")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Key ID: \(keyId)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("完整 API Key:")
                    .font(.subheadline.weight(.semibold))
                Text(keyValue)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                    .textSelection(.enabled)
                Text("可在上方双击或拖拽选择并复制该 Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            HStack {
                Spacer()
                Button("关闭") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 400, height: 240)
    }
}
