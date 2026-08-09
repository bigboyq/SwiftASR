import Testing
@testable import SwiftASR

@Test func tokenTimelineClipsOverlapWithoutChangingRawTime() {
    let timeline = TokenTimeline(
        sentences: [ASRSentence(text: "甲乙", startMs: 0, endMs: 300, tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 200),
            ASRToken(text: "乙", startMs: 100, endMs: 300),
        ])],
        totalFrames: 30
    )

    #expect(timeline.tokens.count == 2)
    #expect(timeline.tokens[0].rawRangeMs == 0..<200)
    #expect(timeline.tokens[1].rawRangeMs == 100..<300)
    #expect(timeline.tokens[0].effectiveRangeMs == 0..<150)
    #expect(timeline.tokens[1].effectiveRangeMs == 150..<300)
    #expect(timeline.tokens.allSatisfy { $0.quality.contains(.overlapClipped) })
}

@Test func tokenTimelineClipsNestedOverlapsAcrossNonAdjacentTokens() {
    let timeline = TokenTimeline(
        sentences: [ASRSentence(text: "甲乙丙", startMs: 0, endMs: 1_000, tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 1_000),
            ASRToken(text: "乙", startMs: 100, endMs: 900),
            ASRToken(text: "丙", startMs: 200, endMs: 300),
        ])],
        totalFrames: 100
    )

    let ranges = timeline.tokens.map(\.effectiveRangeMs)
    for left in ranges.indices {
        for right in ranges.indices where right > left {
            #expect(ranges[left].upperBound <= ranges[right].lowerBound)
        }
    }
    #expect(timeline.tokens[0].effectiveRangeMs == 0..<250)
    #expect(timeline.tokens[1].effectiveRangeMs.isEmpty)
    #expect(timeline.tokens[2].effectiveRangeMs == 250..<300)
}

@Test func tokenPackedPlannerKeepsNormalTokensAtomicAndSplitsOverlongLocally() {
    let timeline = TokenTimeline(
        sentences: [ASRSentence(text: "甲乙丙", startMs: 0, endMs: 4_100, tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 700),
            ASRToken(text: "乙", startMs: 700, endMs: 1_400),
            ASRToken(text: "丙", startMs: 1_400, endMs: 4_100),
        ])],
        totalFrames: 410
    )
    let windows = TokenPackedWindowPlanner().makeWindows(timeline: timeline)

    let normal = windows.filter { !$0.isOverlongTokenSubwindow }
    let overlong = windows.filter(\.isOverlongTokenSubwindow)
    #expect(normal.count == 1)
    #expect(normal[0].tokenIDs.count == 2)
    #expect(normal[0].packedFrameCount == 140)
    #expect(overlong.count == 3)
    #expect(overlong.allSatisfy { $0.tokenIDs == [timeline.tokens[2].id] && $0.packedFrameCount <= 148 })
}

@Test func tokenPackedMaterializationFailsOnOutOfRangeSourceSpan() {
    let window = TokenPackedWindowPlanner.Window(
        islandID: 0,
        tokenIDs: [],
        spans: [TokenPackedWindowPlanner.FbankSpan(
            sourceFrames: 8..<12,
            packedFrames: 0..<4
        )],
        packedFrameCount: 4,
        isOverlongTokenSubwindow: false
    )

    do {
        _ = try TokenPackedWindowPlanner.materialize(
            window: window,
            from: [Float](repeating: 0, count: 10 * 80)
        )
        Issue.record("out-of-range speaker span should fail loudly")
    } catch is TokenPackedWindowPlanner.MaterializationError {
        // expected
    } catch {
        Issue.record("unexpected speaker materialization error: \(error)")
    }
}

@Test func speakerEvidenceWeightsMultipleSourceSpansPerTokenByTokenTotal() {
    let timeline = TokenTimeline(
        sentences: [ASRSentence(text: "甲乙", startMs: 0, endMs: 100, tokens: [
            ASRToken(text: "甲", startMs: 0, endMs: 60),
            ASRToken(text: "乙", startMs: 60, endMs: 100)
        ])],
        totalFrames: 10
    )
    let tokens = timeline.tokens
    let window = TokenPackedWindowPlanner.Window(
        islandID: tokens[0].islandID,
        tokenIDs: [tokens[0].id, tokens[1].id],
        spans: [
            .init(sourceFrames: 0..<3, packedFrames: 0..<3),
            .init(sourceFrames: 3..<6, packedFrames: 3..<6),
            .init(sourceFrames: 6..<10, packedFrames: 6..<10)
        ],
        tokenFrameCounts: [6, 4],
        packedFrameCount: 10,
        isOverlongTokenSubwindow: false
    )
    var embedding = [Float](repeating: 0, count: 192)
    embedding[0] = 1
    let evidence = SpeakerEvidenceTimeline(
        timeline: timeline,
        windows: [window],
        embeddings: embedding,
        profileCentroids: [0: embedding]
    )

    #expect(evidence.tokenEvidence[tokens[0].id]?.supportFrames == 6)
    #expect(evidence.tokenEvidence[tokens[1].id]?.supportFrames == 4)
}

// MARK: - 2026-07-26 tokenIndicesBySentence() extension tests
//
// The shared sentenceID → token-indices map lets L1 / L2 routing
// stages avoid rescanning `timeline.tokens` per sentence.  These
// tests pin the extension's contract so the L1 / L2 sharing has a
// regression test.
@Suite(.serialized)
struct TokenTimelineIndicesTests {

    @Test func tokenIndicesBySentenceGroupsBySentenceID() {
        let s0 = ASRSentence(
            text: "甲乙",
            startMs: 0,
            endMs: 200,
            tokens: [
                ASRToken(text: "甲", startMs: 0, endMs: 100),
                ASRToken(text: "乙", startMs: 100, endMs: 200),
            ]
        )
        let s1 = ASRSentence(
            text: "丙丁戊",
            startMs: 200,
            endMs: 500,
            tokens: [
                ASRToken(text: "丙", startMs: 200, endMs: 300),
                ASRToken(text: "丁", startMs: 300, endMs: 400),
                ASRToken(text: "戊", startMs: 400, endMs: 500),
            ]
        )
        let timeline = TokenTimeline(sentences: [s0, s1], totalFrames: 50)
        let map = timeline.tokenIndicesBySentence()
        #expect(map.keys.sorted() == [0, 1])
        #expect(map[0]?.count == 2)
        #expect(map[1]?.count == 3)
    }

    @Test func tokenIndicesBySentenceReordersByStartMsWithinSentence() {
        // ASR gives intra-sentence tokens out of rawStartMs order.  The
        // TokenTimeline init reorders by (rawStartMs, rawEndMs, id),
        // so the returned indices must point to tokens in **time**
        // order, not source order.
        let sentence = ASRSentence(
            text: "甲乙丙",
            startMs: 0,
            endMs: 300,
            tokens: [
                ASRToken(text: "甲", startMs: 0, endMs: 100),
                ASRToken(text: "乙", startMs: 200, endMs: 300),
                ASRToken(text: "丙", startMs: 100, endMs: 200),
            ]
        )
        let timeline = TokenTimeline(sentences: [sentence], totalFrames: 30)
        let map = timeline.tokenIndicesBySentence()
        let indices = map[0] ?? []
        #expect(indices.count == 3)
        // The tokens must be in time order: 甲 (startMs=0) → 丙 (100) → 乙 (200).
        let orderedText = indices.map { timeline.tokens[$0].text }.joined()
        #expect(orderedText == "甲丙乙")
    }

    @Test func tokenIndicesBySentenceIsStable() {
        let sentence = ASRSentence(
            text: "甲乙",
            startMs: 0,
            endMs: 200,
            tokens: [
                ASRToken(text: "甲", startMs: 0, endMs: 100),
                ASRToken(text: "乙", startMs: 100, endMs: 200),
            ]
        )
        let timeline = TokenTimeline(sentences: [sentence], totalFrames: 20)
        let a = timeline.tokenIndicesBySentence()
        let b = timeline.tokenIndicesBySentence()
        #expect(a == b)
    }
}
