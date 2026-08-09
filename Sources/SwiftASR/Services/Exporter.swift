import Foundation

public final class Exporter {
    public init() {}

    /// 导出为段落格式 TXT
    public func exportParagraphs(utterances: [UtteranceData], includeTimestamps: Bool = true) -> String {
        guard !utterances.isEmpty else { return "" }
        let lines = utterances.map { u in
            if includeTimestamps {
                let start = formatTime(ms: u.startMs)
                let end = formatTime(ms: u.endMs)
                return "[\(start)-\(end)] \(u.speakerLabel): \(u.rawText)"
            } else {
                return "\(u.speakerLabel): \(u.rawText)"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func formatTime(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
