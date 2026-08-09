import SwiftUI

// MARK: - 术语表 Section

/// 优先术语列表：LLM 看到原文出现相近发音时按这里的标准写法收口。
/// 接 `@Binding` 让父 view 拿到 store 同步状态。
public struct GlossarySection: View {
    @Binding var glossary: [String]
    @State private var newGlossary: String = ""

    public init(glossary: Binding<[String]>) {
        self._glossary = glossary
    }

    public var body: some View {
        Section {
            HStack(spacing: 8) {
                TextField("输入术语", text: $newGlossary)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addGlossary() }
                Button {
                    addGlossary()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(newGlossary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if glossary.isEmpty {
                Label("还没有优先术语", systemImage: "text.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else if glossary.count > 48 {
                ScrollView {
                    termGrid
                        .padding(.vertical, 2)
                }
                .frame(height: 256)
            } else {
                termGrid
                    .padding(.vertical, 2)
            }
        } header: {
            Label("优先术语 \(glossary.count)", systemImage: "list.bullet.rectangle")
        } footer: {
            Text("Gemini 润色时会优先采用这些写法；重复项会自动忽略。")
                .font(.caption)
        }
    }

    private var termGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(glossary, id: \.self) { term in
                HStack(spacing: 6) {
                    Text(term)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        removeGlossary(term)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("删除 \(term)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.10), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addGlossary() {
        let term = newGlossary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            newGlossary = ""
            return
        }
        // 走 normalize：去重 + 排序后整体覆盖 UI state。
        // 旧实现只 append + contains 检查，留下了"用户编辑 JSON 后乱序"
        // 或"两个 term 仅大小写不同"会同时存在的边角问题。
        let next = SettingsStore.normalizeGlossary(glossary + [term])
        glossary = next
        SettingsStore.shared.setGlossary(next)
        newGlossary = ""
    }

    private func removeGlossary(_ term: String) {
        glossary.removeAll { $0 == term }
        SettingsStore.shared.setGlossary(glossary)
    }
}
