import Foundation
import Testing
@testable import SwiftASR

/// Locks down the post-vocab-argmax repeat filter inside `ASRDecoder`.
///
/// History: the previous contract was "drop the token if it has the same
/// vocab id as the previous frame, or if it repeats an id seen two frames
/// ago (ABA)". This worked for CJK noise ("我我" / "是是") but silently
/// truncated English abbreviations like "PPT" (subword sequence `p p t`)
/// down to "pt" (2 chars), and rejected real ABA speech patterns like
/// "是不是" / "对不对" / "好不好" because they trip the same filter.
///
/// New contract: only drop the token if it is a single CJK character.
/// ASCII letters, ASCII digits, BPE prefix tokens like `p@@`, and
/// multi-character subwords like `service` are never dropped.
@Suite("ASRDecoder repeat filter")
struct ASRDecoderRepeatFilterTests {

    @Test func minimumSixtyMillisecondFallbackIsClampedAtNextCIFBoundary() {
        let tokens = [
            ASRToken(text: "甲", startMs: 0, endMs: 60),
            ASRToken(text: "乙", startMs: 20, endMs: 80),
            ASRToken(text: "丙", startMs: 80, endMs: 140)
        ]

        let clamped = ASRDecoder.clampShortTokenOverlaps(tokens)

        #expect(clamped[0].startMs == 0)
        #expect(clamped[0].endMs == 20)
        #expect(clamped[1].startMs == 20)
        #expect(clamped[1].endMs == 80)
        #expect(clamped[2].startMs == 80)
        #expect(clamped[2].endMs == 140)
    }

    // MARK: - isCJKSingleChar

    @Test func isCJKSingleCharRecognizesCommonChineseChars() {
        #expect(ASRDecoder.isCJKSingleChar("我"))
        #expect(ASRDecoder.isCJKSingleChar("是"))
        #expect(ASRDecoder.isCJKSingleChar("不"))
        #expect(ASRDecoder.isCJKSingleChar("你"))
        #expect(ASRDecoder.isCJKSingleChar("的"))
        #expect(ASRDecoder.isCJKSingleChar("嗯"))
    }

    @Test func isCJKSingleCharRejectsAsciiLettersAndDigits() {
        // Single ASCII letters — must NOT be classified as CJK so the
        // English-abbreviation path can pass through.
        for ch in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            #expect(!ASRDecoder.isCJKSingleChar(String(ch)), "letter \(ch) wrongly flagged as CJK")
        }
        for ch in "0123456789" {
            #expect(!ASRDecoder.isCJKSingleChar(String(ch)), "digit \(ch) wrongly flagged as CJK")
        }
    }

    @Test func isCJKSingleCharRejectsBpePrefixAndMultiCharSubwords() {
        // BPE prefix (vocab uses "@@" suffix, not SentencePiece "▁")
        #expect(!ASRDecoder.isCJKSingleChar("p@@"))
        // Multi-character subwords
        #expect(!ASRDecoder.isCJKSingleChar("service"))
        #expect(!ASRDecoder.isCJKSingleChar("the"))
        #expect(!ASRDecoder.isCJKSingleChar("PPT"))
    }

    @Test func isCJKSingleCharRejectsEmptyAndNonAsciiNonCjk() {
        #expect(!ASRDecoder.isCJKSingleChar(""))
        // Fullwidth punctuation: not ASCII but also not CJK.
        // Must NOT be classified as CJK so the noise filter doesn't
        // accidentally drop it.
        #expect(!ASRDecoder.isCJKSingleChar("，"))
        #expect(!ASRDecoder.isCJKSingleChar("。"))
        #expect(!ASRDecoder.isCJKSingleChar("？"))
        // Latin-1 supplement (e.g. é) is not ASCII, but also not CJK.
        #expect(!ASRDecoder.isCJKSingleChar("é"))
        // Half-width katakana / hangul / other non-CJK non-ASCII.
        #expect(!ASRDecoder.isCJKSingleChar("é"))
        // Half-width katakana (U+FF66) — fullwidth Japanese, not CJK.
        #expect(!ASRDecoder.isCJKSingleChar("ｦ"))
    }

    // MARK: - shouldSkipForRepeat (consecutive)

    @Test func consecutiveCJKSingleCharIsSkipped() {
        let current = (id: 100, text: "我")
        let prev = (id: 100, text: "我")
        #expect(ASRDecoder.shouldSkipForRepeat(prev: prev, prevPrev: nil, current: current))
    }

    @Test func consecutiveASCIILetterIsRetained_PPT() {
        // The real failure case: "PPT" subword sequence `p` `p` `t`.
        // Second `p` must NOT be filtered, otherwise `ppt` → `pt`.
        let pPrev = (id: 5625, text: "p")
        let pCurr = (id: 5625, text: "p")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: pPrev, prevPrev: nil, current: pCurr))

        // Same for any English double-letter "pp" / "tt" / "ee" cases.
        let tPrev = (id: 1473, text: "t")
        let tCurr = (id: 1473, text: "t")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: tPrev, prevPrev: nil, current: tCurr))
    }

    @Test func consecutiveMultiCharSubwordIsRetained() {
        // BPE keeps `service` as a single vocab token, but if the model
        // emits it twice in a row, the second is a real (low-probability)
        // emission, not a duplicate we want to drop.
        let prev = (id: 7933, text: "service")
        let current = (id: 7933, text: "service")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: prev, prevPrev: nil, current: current))
    }

    @Test func consecutiveBpePrefixIsRetained() {
        // `p@@` followed by `p@@` would mean "we're predicting a long
        // p-prefix" — keep both frames, the model will figure it out.
        let prev = (id: 8284, text: "p@@")
        let current = (id: 8284, text: "p@@")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: prev, prevPrev: nil, current: current))
    }

    // MARK: - shouldSkipForRepeat (ABA)

    @Test func abaCJKSingleCharIsSkipped() {
        // "是 不 是" → third 是 dropped, but the ABA pattern
        // could also be "是不是" which is real speech, so this filter is
        // risky for CJK; we keep it for now because Paraformer model
        // tends to hallucinate ABA on CJK frames.
        let prev = (id: 6426, text: "是")
        let prevPrev = (id: 1004, text: "不")
        let current = (id: 6426, text: "是")
        #expect(ASRDecoder.shouldSkipForRepeat(prev: prev, prevPrev: prevPrev, current: current))
    }

    @Test func abaASCIILetterIsRetained_CEO() {
        // "CEO" / "USA" / "OK" subword sequences can land as c,e,c or
        // u,s,u in the argmax. Even if the model emits `c, e, c` in
        // 3 separate frames, the third `c` is the legitimate closing
        // letter of the abbreviation. Filter must NOT drop it.
        let c1 = (id: 4377, text: "c")
        let e = (id: 5965, text: "e")
        let c2 = (id: 4377, text: "c")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: c2, prevPrev: c1, current: e))
        // Strictly the ABA test: prevPrev id == current id
        let cAgain = (id: 4377, text: "c")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: e, prevPrev: c1, current: cAgain))
    }

    @Test func abaASCIINaturalSpeechIsRetained() {
        // Real speech patterns:
        //   "是不是"   → 是 / 不 / 是  (CJK, kept by previous test)
        //   "对不对"   → 对 / 不 / 对
        //   "好不好"   → 好 / 不 / 好
        //   "PPT 啊"   → p / p / t / 啊
        // All real-speech ABA cases where the third token is an ASCII
        // letter must be retained.
        let first = (id: 100, text: "p")
        let middle = (id: 1473, text: "t")
        let third = (id: 100, text: "p")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: middle, prevPrev: first, current: third))
    }

    // MARK: - shouldSkipForRepeat (negative cases)

    @Test func differentVocabIdsAlwaysRetained() {
        // prev id != current id → never skip, regardless of text.
        let prev = (id: 100, text: "我")
        let current = (id: 200, text: "是")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: prev, prevPrev: nil, current: current))
    }

    @Test func abaWithoutPrevIsRetained() {
        // First frame after a gap: prev is nil, ABA can't fire.
        let current = (id: 100, text: "我")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: nil, prevPrev: nil, current: current))
    }

    @Test func abaWithConsecutiveButDifferentIdIsRetained() {
        // prevPrev matches but prev id differs from current id.
        // This is not strictly ABA; the filter should NOT fire.
        let prev = (id: 200, text: "不")
        let prevPrev = (id: 100, text: "我")
        let current = (id: 300, text: "他")
        #expect(!ASRDecoder.shouldSkipForRepeat(prev: prev, prevPrev: prevPrev, current: current))
    }
}
