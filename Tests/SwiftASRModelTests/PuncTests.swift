import Testing
import Foundation
@testable import SwiftASR

// MARK: - Punctuation configuration tests

@Test func puncStaticConfig() {
    // punc_list 6 类，按 funasr yaml 的 punc_list 顺序
    // 0=<unk> 1=_ 2=， 3=。 4=？ 5=、
    let config = PunctuationRestorationConfiguration.production
    #expect(config.puncList == ["<unk>", "_", "，", "。", "？", "、"])
    #expect(config.symbol(for: 0) == "<unk>")
    #expect(config.symbol(for: 5) == "、")
    #expect(config.symbol(for: 6) == nil)
}

@Test func puncSentenceEndIs3() {
    // funasr sentence_end_id = 3 对应 "。" (句号)
    let config = PunctuationRestorationConfiguration.production
    #expect(config.sentenceSymbolID == 3)
    #expect(config.symbol(for: config.sentenceSymbolID) == "。")
}

@Test func puncVocabularyRequiresReadableNonEmptyJSONWithUnknownToken() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("punc_vocab_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("not-json".utf8).write(to: root)
    #expect(throws: Error.self) {
        try PuncONNXEngine.loadVocabulary(path: root.path)
    }

    try JSONEncoder().encode([String]()).write(to: root)
    #expect(throws: Error.self) {
        try PuncONNXEngine.loadVocabulary(path: root.path)
    }

    try JSONEncoder().encode(["<blank>", "<unk>", "我"]).write(to: root)
    let vocabulary = try PuncONNXEngine.loadVocabulary(path: root.path)
    #expect(vocabulary["<blank>"] == 0)
    #expect(vocabulary["<unk>"] == 1)
    #expect(vocabulary["我"] == 2)
}

@Test func puncVocabularyRepairsDuplicatesWithoutChangingFirstTokenID() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("punc_duplicate_vocab_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: root) }
    let tokens = ["<unk>", "甲", "甲", "乙"]
    try JSONEncoder().encode(tokens).write(to: root)

    let vocabulary = try PuncONNXEngine.loadVocabulary(path: root.path)
    #expect(vocabulary["<unk>"] == 0)
    #expect(vocabulary["甲"] == 1)
    #expect(vocabulary["乙"] == 3)
}

@Test func puncRenderPreservesTokensWhenPunctuationOutputIsShort() {
    let configuration = PunctuationRestorationConfiguration.production
    let text = PunctuationRestorationPipeline.render(
        tokens: ["你好", "世界"],
        puncIDs: [],
        configuration: configuration
    )
    #expect(text == "你好世界")
}

@Test func puncOutputCountMismatchIsAStageFailure() {
    #expect(throws: PunctuationRestorationError.outputCountMismatch(expected: 2, actual: 0)) {
        try PunctuationRestorationPipeline.validateOutputCount(tokenCount: 2, punctuationCount: 0)
    }
}
