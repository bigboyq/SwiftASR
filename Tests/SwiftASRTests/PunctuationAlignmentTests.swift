import Testing
@testable import SwiftASR

@Suite("Punctuation token alignment")
struct PunctuationAlignmentTests {
    private let tokens = [
        ASRToken(text: "甲", startMs: 0, endMs: 100),
        ASRToken(text: "乙", startMs: 100, endMs: 200)
    ]

    @Test func insertsPunctuationWithoutChangingTokenCount() {
        let result = PunctuationAlignment.align(puncText: "甲，乙。", into: tokens)

        #expect(result.isAligned)
        #expect(result.tokens.count == tokens.count)
        #expect(result.tokens.map(\.text) == ["甲，", "乙。"])
    }

    @Test func alignmentFailureReturnsOriginalTokensAndReason() {
        let result = PunctuationAlignment.align(puncText: "甲，丙。", into: tokens)

        #expect(!result.isAligned)
        #expect(result.tokens.map(\.text) == tokens.map(\.text))
        #expect(result.failure != nil)
    }

    @Test func alignmentFailureCanBePromotedToAStageError() {
        let result = PunctuationAlignment.align(puncText: "甲，丙。", into: tokens)

        #expect(throws: PunctuationAlignment.Failure.unexpectedCharacter(
            index: 2, character: "丙", sourceIndex: 1
        )) {
            try PunctuationAlignment.requireAligned(result)
        }
    }

    @Test func spacesAreIgnoredForAlignment() {
        let result = PunctuationAlignment.align(puncText: "甲， 乙。", into: tokens)

        #expect(result.isAligned)
        #expect(result.tokens.map(\.text) == ["甲，", "乙。"])
    }
}
