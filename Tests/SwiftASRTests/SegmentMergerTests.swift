import Testing
@testable import SwiftASR

@Suite("SegmentMerger Tests")
struct SegmentMergerTests {
    
    @Test func joinParagraphTextsCombinesWithCommas() {
        let merger = SegmentMerger()
        let texts = [
            "不从业务模式上当然也有",
            "区别那法律关系上也有区别",
            "呃，你sars服的话，"
        ]
        
        let joined = merger.joinParagraphTexts(texts)
        #expect(joined == "不从业务模式上当然也有，区别那法律关系上也有区别，呃，你sars服的话，。")
    }
    
    @Test func buildDisplaySegmentsWithoutMergeKeepsAll() {
        let merger = SegmentMerger()
        let segments = [
            ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "Speaker1", rawText: "你好"),
            ResultSegment(segmentId: 2, startMs: 1000, endMs: 2000, speakerLabel: "Speaker1", rawText: "世界")
        ]

        // 逐句原文固定保持 ASR 段颗粒度。
        let display = merger.buildDisplaySegments(segments: segments, speakerNames: ["Speaker1": "雅冬"])
        #expect(display.count == 2)
        #expect(display[0].displaySpeakerName == "雅冬")
        #expect(display[0].speakerLabelSuffix == "(Speaker1)")
        #expect(display[0].text == "你好")
        #expect(display[0].hasSingleSource)
    }

    @Test func mergedResultsKeepSpeakerLabelsWhileDisplayCanMergeNames() {
        let merger = SegmentMerger()
        let source = [
            ResultSegment(segmentId: 1, startMs: 0, endMs: 1_000, speakerLabel: "Speaker1", rawText: "你好"),
            ResultSegment(segmentId: 2, startMs: 1_000, endMs: 2_000, speakerLabel: "Speaker2", rawText: "世界")
        ]
        let merged = merger.buildMergedResults(segments: source)
        #expect(merged.map(\.speakerLabel) == ["Speaker1", "Speaker2"])

        let display = merger.buildDisplaySegments(
            mergedResults: merged,
            speakerNames: ["Speaker1": "雅冬", "Speaker2": "雅冬"]
        )
        #expect(display.count == 1)
        #expect(display[0].displaySpeakerName == "雅冬")
        #expect(display[0].speakerLabelSuffix == "(Speaker1, Speaker2)")
    }

    @Test func mergedDisplayCanExplicitlyUseRawContent() {
        let display = SegmentMerger().buildDisplaySegments(
            mergedResults: [MergedResult(
                mergeId: 1, startMs: 0, endMs: 1_000,
                speakerLabel: "Speaker1", rawContent: "原始内容", cleanedContent: "润色内容"
            )],
            showRawText: true
        )
        #expect(display[0].text == "原始内容。")
    }
}
