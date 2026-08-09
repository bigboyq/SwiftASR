import Testing
import Foundation
@testable import SwiftASR

// MARK: - Data Model 全面测试

@Test func asrJobDefaultValues() {
    let job = ASRJob(
        sourceAudioPath: "/x.wav",
        sourceAudioHash: "h",
        durationSeconds: 30.0
    )
    #expect(job.status == "queued")
    #expect(job.mode == "turbo")
    #expect(job.asrBackend == "paraformer")
    #expect(job.speakerBackend == "eres2netv2")
    #expect(job.device == "auto")
    #expect(job.speakerOccurrences.isEmpty)
    #expect(job.errorMessage == nil)
}

@Test func asrSentenceSendableAcrossActor() async {
    let sentence = ASRSentence(text: "hello", startMs: 0, endMs: 1000)
    // ASRSentence 是 Sendable，可以跨 actor 传递
    let sentToTask = await Task.detached { sentence }.value
    #expect(sentToTask.text == "hello")
}

@Test func utteranceDataDefaults() {
    let u = UtteranceData(startMs: 0, endMs: 1000, rawText: "x", speakerLabel: "S1")
    #expect(u.startMs == 0)
    #expect(u.endMs == 1000)
    #expect(u.rawText == "x")
    #expect(u.speakerLabel == "S1")
}

@Test func asrResultEmptyValid() {
    let r = ASRResult(sentences: [], rawText: "")
    #expect(r.sentences.isEmpty)
}

@Test func resultSegmentDefaultsForOptionals() {
    let s = ResultSegment(segmentId: 1, startMs: 0, endMs: 1000, speakerLabel: "S1", rawText: "hi")
    #expect(s.includedInPreview == true)
}
