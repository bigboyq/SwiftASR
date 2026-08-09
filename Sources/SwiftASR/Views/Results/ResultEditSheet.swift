import SwiftUI

/// 对单个合并段落的人工编辑。文本和当前预览的说话人归属可以修正，
/// 原始转写、时间戳和声纹 routing label 始终保持只读。
struct ResultEditSheet: View {
    let result: MergedResult
    let speakerLabels: [String]
    let speakerNames: [String: String]
    let onSave: (String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var selectedSpeakerLabel: String
    @FocusState private var editorFocused: Bool

    init(
        result: MergedResult,
        speakerLabels: [String],
        speakerNames: [String: String],
        onSave: @escaping (String, String) -> Bool
    ) {
        self.result = result
        self.speakerNames = speakerNames
        self.onSave = onSave
        self.speakerLabels = Array(Set(speakerLabels + [
            result.speakerLabel,
            result.effectiveSpeakerLabel,
        ])).sorted {
            Self.optionTitle(label: $0, speakerNames: speakerNames)
                .localizedStandardCompare(
                    Self.optionTitle(label: $1, speakerNames: speakerNames)
                ) == .orderedAscending
        }
        _draft = State(initialValue: result.wasLLMFailure
            ? result.rawContent
            : (result.cleanedContent.isEmpty ? result.rawContent : result.cleanedContent)
        )
        _selectedSpeakerLabel = State(initialValue: result.effectiveSpeakerLabel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑段落")
                        .font(.title3.weight(.semibold))
                    Text(
                        "\(displayName(for: selectedSpeakerLabel)) · " +
                        "\(formatTime(result.startMs))–\(formatTime(result.endMs))"
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(AppLayout.pagePadding)

            Divider()

            HStack(spacing: 12) {
                Text("说话人")
                    .font(.subheadline.weight(.medium))
                Picker("说话人", selection: $selectedSpeakerLabel) {
                    ForEach(speakerLabels, id: \.self) { label in
                        Text(Self.optionTitle(label: label, speakerNames: speakerNames))
                            .tag(label)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
                Spacer()
                if selectedSpeakerLabel != result.speakerLabel {
                    Text("手工指派")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("自动识别")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, AppLayout.pagePadding)
            .padding(.vertical, AppLayout.sectionSpacing)

            Divider()

            TextEditor(text: $draft)
                .font(.body)
                .focused($editorFocused)
                .padding(AppLayout.sectionSpacing)
                .frame(minHeight: 220)

            Divider()

            HStack {
                Text("原始识别内容和声纹结果不会被修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    if onSave(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines),
                        selectedSpeakerLabel
                    ) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(AppLayout.pagePadding)
        }
        .frame(minWidth: 560, minHeight: 440)
        .onAppear {
            DispatchQueue.main.async { editorFocused = true }
        }
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        let minutes = seconds / 60
        return String(format: "%02d:%02d", minutes, seconds % 60)
    }

    private func displayName(for label: String) -> String {
        let name = speakerNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : label
    }

    private static func optionTitle(
        label: String,
        speakerNames: [String: String]
    ) -> String {
        let name = speakerNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, name != label else { return label }
        return "\(name)（\(label)）"
    }
}
