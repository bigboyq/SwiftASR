import Foundation
import Testing
@testable import SwiftASR

/// CT-Transformer is a per-token punctuation model: it sees a token sequence
/// and outputs a puncID at every position without any cross-token structural
/// knowledge. When a speaker repeats a character or short word, the model
/// can confidently insert a sentence break between the two occurrences, which
/// destroys the repeated structure. We see this in 6月4日ADHD2 5min 精修:
///
/// - L20:  `见过都知道，见。过都知道，没必要。`
///   The repeated "见过" had a "。" inserted between the second "见" and "过".
/// - L51:  `大一点大一。点，哎呀，。`
///   The repeated "大一点" had a "。" inserted between the second "一" and "点".
///
/// `PunctuationRestorationPipeline.protectRepetition` is the post-render
/// guard: it scans the rendered puncID stream and removes punctuation that
/// would otherwise break an obvious repeated phrase. The rule is
/// deliberately conservative — it only fires when both the token *before* and
/// the 1–2 token window *after* the candidate punc have an earlier identical
/// occurrence, and that earlier occurrence ended without a punc.
@Suite("Punc repetition protection")
struct PuncRepetitionProtectionTests {
    private let configuration = PunctuationRestorationConfiguration.production

    // MARK: 5min ADHD2 精修里真实出现的吞字 case

    /// L20: 重复 "见过" 里的 "。" (在第 2 个 "见" 之后, 打断 "见" / "过") 必须移除。
    @Test func secondSeenKnownRepetitionLosesItsPeriod() {
        let tokens = ["对", "见", "过", "都", "知", "道", "见", "过", "都", "知", "道"]
        var puncIDs = [2, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        let text = PunctuationRestorationPipeline.render(
            tokens: tokens, puncIDs: puncIDs, configuration: configuration
        )
        #expect(puncIDs[6] == 0)
        #expect(puncIDs[5] == 3) // 第 1 句末的 "。" 保留
        #expect(text == "对，见过都知道。见过都知道")
    }

    /// L51: 重复 "大一点" 里的 "。" (在第 2 个 "一" 之后, 打断 "一" / "点") 必须移除。
    @Test func daYiDianRepetitionLosesItsPeriod() {
        let tokens = ["大", "一", "点", "大", "一", "点"]
        var puncIDs = [0, 0, 0, 0, 3, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        let text = PunctuationRestorationPipeline.render(
            tokens: tokens, puncIDs: puncIDs, configuration: configuration
        )
        #expect(puncIDs[4] == 0)
        #expect(text == "大一点大一点")
    }

    // MARK: 已知的 false negative — 这类不在 v1 范围

    /// L41: "他讲的我真，的会信" 里的 "，" 打断 "真的" 这个词。
    /// 1-token "真" 在前文没出现过, 规则不会触发 — 已知 false negative,
    /// 留给后续 word-boundary 修复 (需要 common 词表, 暂不做)。
    @Test func genuineWordBoundaryInsideOneOccurrenceIsNotRepaired() {
        let tokens = ["他", "讲", "的", "我", "真", "的", "会", "信"]
        var puncIDs = [0, 0, 0, 0, 2, 0, 0, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        #expect(puncIDs[4] == 2)
        let text = PunctuationRestorationPipeline.render(
            tokens: tokens, puncIDs: puncIDs, configuration: configuration
        )
        #expect(text == "他讲的我真，的会信")
    }

    // MARK: 对称 negative case — 规则不该误伤

    /// "我。我喜欢" — 用户 主动 在 2 个 "我" 之间用 "。" 强调。规则不触发。
    @Test func intentionalPeriodAfterFirstOfTwoIdenticalCharsIsKept() {
        let tokens = ["我", "我", "喜欢"]
        var puncIDs = [3, 0, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        #expect(puncIDs[0] == 3)
    }

    /// 3 个 "有" "有有有" 无标点 — 跟 精修 L13 一样完整保留。
    @Test func threeIdenticalCharsWithoutPunctuationIsUnchanged() {
        let tokens = ["有", "有", "有"]
        var puncIDs = [0, 0, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        #expect(puncIDs == [0, 0, 0])
    }

    /// 4 个 "好" 跟标点 "哈哈。哈哈" — 句号 在词末而非词中, 不应被移除。
    @Test func periodAtTheEndOfRepeatedTwoCharWordIsKept() {
        let tokens = ["哈", "哈", "哈", "哈"]
        var puncIDs = [0, 0, 3, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        #expect(puncIDs[2] == 3)
    }

    /// 完全不同的词加句号 — 标点保留。
    @Test func periodBetweenUnrelatedTokensIsKept() {
        let tokens = ["您", "好", "世", "界"]
        var puncIDs = [0, 3, 0, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        #expect(puncIDs[1] == 3)
    }

    /// 4-char 短语重复 "不错的吗。不错的吗" — 句号 在词末, 不动。
    @Test func periodAtEndOfRepeatedFourCharPhraseIsKept() {
        let tokens = ["不", "错", "的", "吗", "不", "错", "的", "吗"]
        var puncIDs = [0, 0, 0, 3, 0, 0, 0, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        #expect(puncIDs[3] == 3)
    }

    /// 句号前是首次出现的 token, 即使 1-token 窗口之前出现也不该被吞。
    /// 例: "我讲。你听我讲你" — "讲。你" 不是重复, 句号保留。
    @Test func periodAfterFirstOccurrenceIsKeptEvenIfWindowMatchesLater() {
        let tokens = ["我", "讲", "你", "听", "我", "讲", "你"]
        var puncIDs = [0, 3, 0, 0, 0, 0, 0]
        Self.protect(puncIDs: &puncIDs, tokens: tokens)
        #expect(puncIDs[1] == 3)
    }

    // MARK: helper

    private static func protect(puncIDs: inout [Int], tokens: [String]) {
        PunctuationRestorationPipeline.protectRepetition(
            puncIDs: &puncIDs,
            tokens: tokens,
            configuration: PunctuationRestorationConfiguration.production
        )
    }
}
