import Testing
@testable import SwiftASR

@Test func exportParagraphsCanOmitTimestamps() {
    let utterances = [
        UtteranceData(startMs: 1_000, endMs: 3_000, rawText: "你好", speakerLabel: "歪歪")
    ]

    let text = Exporter().exportParagraphs(utterances: utterances, includeTimestamps: false)

    #expect(text == "歪歪: 你好\n")
}

@Test func exportParagraphsKeepsTimestampsByDefault() {
    let utterances = [
        UtteranceData(startMs: 1_000, endMs: 3_000, rawText: "你好", speakerLabel: "歪歪")
    ]

    let text = Exporter().exportParagraphs(utterances: utterances)

    #expect(text == "[00:01-00:03] 歪歪: 你好\n")
}

@Test func exportSameNamedConsecutiveSpeakersAsOneParagraph() {
    // 导出层可以按最终人名合并，但原始 SpeakerN 仍只存在于 result.json 的
    // MergedResult 中，不会被这一步改写。
    let source = [
        MergedResult(
            mergeId: 1, startMs: 0, endMs: 1_000,
            speakerLabel: "Speaker1", rawContent: "你好"
        ),
        MergedResult(
            mergeId: 2, startMs: 1_000, endMs: 2_000,
            speakerLabel: "Speaker2", rawContent: "世界"
        ),
    ]
    let display = SegmentMerger().buildDisplaySegments(
        mergedResults: source,
        speakerNames: ["Speaker1": "雅冬", "Speaker2": "雅冬"],
        showRawText: true
    )
    let utterances = display.map {
        UtteranceData(
            startMs: $0.startMs,
            endMs: $0.endMs,
            rawText: $0.text,
            speakerLabel: $0.displaySpeakerName + " " + ($0.speakerLabelSuffix ?? "")
        )
    }

    let text = Exporter().exportParagraphs(utterances: utterances)

    #expect(text == "[00:00-00:02] 雅冬 (Speaker1, Speaker2): 你好，世界。\n")
}
