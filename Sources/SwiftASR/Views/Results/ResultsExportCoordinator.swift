import AppKit
import Foundation

/// Builds and writes the exact projection currently shown by the result page.
/// The view supplies presentation choices; save-panel lifetime and disk errors
/// stay outside `ResultsContent`.
@MainActor
enum ResultsExportCoordinator {
    static func export(
        payload: ResultPayload,
        displaySegments: [DisplaySegment],
        showSpeakerIDs: Bool,
        showTimestamps: Bool,
        reportError: @escaping (String) -> Void
    ) {
        let utterances = displaySegments.map { segment in
            UtteranceData(
                startMs: segment.startMs,
                endMs: segment.endMs,
                rawText: segment.text,
                speakerLabel: segment.displaySpeakerName + (
                    showSpeakerIDs ? (segment.speakerLabelSuffix.map { " \($0)" } ?? "") : ""
                )
            )
        }
        guard !utterances.isEmpty else {
            reportError("当前筛选范围没有可导出的内容。请至少选择一个说话人。")
            return
        }

        let text = Exporter().exportParagraphs(utterances: utterances, includeTimestamps: showTimestamps)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: payload.audioPath)
            .deletingPathExtension().lastPathComponent + ".txt"
        panel.allowedContentTypes = [.plainText]

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                reportError("导出文本失败：\(error.localizedDescription)")
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}
