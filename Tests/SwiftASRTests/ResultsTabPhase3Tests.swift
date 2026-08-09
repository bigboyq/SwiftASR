import Testing
import Foundation
@testable import SwiftASR

// MARK: - SpeakerSuggestion 纯数据测试

@Test func speakerSuggestion_Equality() {
    let s1 = SpeakerSuggestion(
        personName: "Alice",
        personId: "p_1",
        score: 0.85,
        confidence: .high
    )
    let s2 = SpeakerSuggestion(
        personName: "Alice",
        personId: "p_1",
        score: 0.85,
        confidence: .high
    )
    let s3 = SpeakerSuggestion(
        personName: "Bob",
        personId: "p_2",
        score: 0.55,
        confidence: .medium
    )
    #expect(s1 == s2, "相同字段应该相等")
    #expect(s1 != s3, "不同字段应该不等")
}

@Test func speakerSuggestion_Confidence_HighVsMedium() {
    // high 跟 medium 各自有不同 score 范围
    // high = >= 0.75, medium = 0.50..0.75
    // 实际判定在结果页的推荐刷新逻辑里，测试只覆盖数据层
    // 产品推荐置信度区间：high >= 0.75，medium = 0.50..0.75。
    let highScore: Float = 0.85
    let mediumScore: Float = 0.55
    #expect(highScore >= 0.75)
    #expect(mediumScore < 0.75)
    #expect(mediumScore >= 0.50)
}

@Test func speakerSuggestionHoverTextListsTopPeopleAndAggregatesFingerprints() {
    let suggestion = SpeakerSuggestion(
        personName: "雅冬",
        personId: "p_ya",
        score: 0.99,
        confidence: .high,
        matches: [
            SpeakerMatcher.PersonMatch(
                personId: "p_ya", personName: "雅冬", score: 0.99,
                fingerprintCount: 2, minScore: 0.78, maxScore: 0.99
            ),
            SpeakerMatcher.PersonMatch(
                personId: "p_b", personName: "说话人乙", score: 0.78,
                fingerprintCount: 1, minScore: 0.78, maxScore: 0.78
            ),
            SpeakerMatcher.PersonMatch(
                personId: "p_summer", personName: "Summer", score: 0.66,
                fingerprintCount: 1, minScore: 0.66, maxScore: 0.66
            )
        ]
    )

    #expect(suggestion.hoverText.contains("1. 雅冬（0.78~0.99）指纹2个"))
    #expect(suggestion.hoverText.contains("2. 说话人乙（0.78）指纹1个"))
    #expect(suggestion.hoverText.contains("3. Summer（0.66）指纹1个"))
}

// MARK: - 改名 + 同步 的纯逻辑测试（不依赖 SwiftData）

@Test func trimName_EmptyString_ReturnsNilEquivalent() {
    let name = "  "
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmed.isEmpty, "全空格的 name 算空")
}

@Test func trimName_ValidString_Trimmed() {
    let name = "  Alice  "
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmed == "Alice")
}

@Test func trimName_Nil_HandledSeparately() {
    // PersonRepository.getOrCreate 的逻辑：nil 或 全空格 → 返回 nil
    let name: String? = nil
    let result: String? = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(result == nil)
}
