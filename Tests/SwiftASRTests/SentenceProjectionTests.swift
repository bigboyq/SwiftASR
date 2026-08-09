import Testing
@testable import SwiftASR

@Suite("Sentence projection")
struct SentenceProjectionTests {
    @Test func terminalPunctuationSplitsSentences() {
        let tokens = [
            ASRToken(text: "甲。", startMs: 0, endMs: 100),
            ASRToken(text: "乙", startMs: 100, endMs: 200)
        ]

        let sentences = SentenceProjection.split(tokens)

        #expect(sentences.count == 2)
        #expect(sentences[0].text == "甲。")
        #expect(sentences[1].text == "乙")
    }

    @Test func clausePunctuationSplitsWhenReachingCharacterLimit() {
        let tokens = (0..<31).map { index in
            let text = (index == 29) ? "字，" : "字"
            return ASRToken(text: text, startMs: index * 10, endMs: index * 10 + 10)
        }

        let sentences = SentenceProjection.split(tokens)

        #expect(sentences.count == 2)
        #expect(sentences[0].text == String(repeating: "字", count: 29) + "字，")
        #expect(sentences[1].text == "字")
        #expect(sentences.flatMap(\.tokens).count == tokens.count)
    }

    @Test func unpunctuatedSafetyLimitSplitsWithoutDroppingTokens() {
        let tokens = (0..<61).map { index in
            ASRToken(text: "字", startMs: index * 10, endMs: index * 10 + 10)
        }

        let sentences = SentenceProjection.split(tokens)

        #expect(sentences.map(\.text.count) == [60, 1])
        #expect(sentences.flatMap(\.tokens).count == tokens.count)
    }

    @Test func longAcousticGapSplitsBeforeNextToken() {
        let tokens = [
            ASRToken(text: "甲", startMs: 0, endMs: 100),
            ASRToken(text: "乙", startMs: 400, endMs: 500)
        ]

        let sentences = SentenceProjection.split(tokens)

        #expect(sentences.count == 2)
        #expect(sentences[0].text == "甲")
        #expect(sentences[1].text == "乙")
    }
}
