import SwiftUI

// MARK: - SegmentRowView（行内显示时间戳 / 当前文本）

struct SegmentRowView: View {
    let displaySpeakerName: String
    let speakerLabelSuffix: String?
    let showSpeakerLabelSuffix: Bool
    let startMs: Int
    let endMs: Int
    let displayText: String
    let showTimestamps: Bool
    /// 分拆操作层里，句子的基线归属发生变化时显示 `K → N`。Token 证据不进入 UI。
    let baselineSpeakerLabel: String?
    let onRestoreSpeaker: (() -> Void)?
    let onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(speakerTitle)
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                    if showSpeakerLabelSuffix, let suffix = speakerLabelSuffix {
                        Text(suffix)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 150, alignment: .leading)
                if showTimestamps {
                    Text("\(formatTime(ms: startMs)) - \(formatTime(ms: endMs))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let onRestoreSpeaker {
                    Button(action: onRestoreSpeaker) {
                        Label("还原说话人", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("还原此显示段落内所有手工说话人指派，不修改正文")
                }
                if let onEdit {
                    Button(action: onEdit) {
                        Label("编辑段落", systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("编辑当前段落的预览文本")
                }
            }
            Text(displayText)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }

    private func formatTime(ms: Int) -> String {
        let sec = ms / 1000
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private var speakerTitle: String {
        guard let baselineSpeakerLabel else { return displaySpeakerName }
        return "\(baselineSpeakerLabel) → \(displaySpeakerName)"
    }
}
