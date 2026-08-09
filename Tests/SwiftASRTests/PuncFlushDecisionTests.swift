// MARK: - PunctuationFlushPolicy.decide() 纯函数

import Foundation
import Testing
@testable import SwiftASR

@Suite("Punc 流式断句兜底策略")
struct PuncFlushDecisionTests {

    private static let configuration = PunctuationRestorationConfiguration.production

    private static func ids(_ symbols: [String]) -> [Int] {
        symbols.compactMap { s in configuration.puncList.firstIndex(of: s) }
    }

    @Test func lastChunkAlwaysFlushesAll() {
        // 最后一个 chunk 无条件 flush
        let d = PunctuationFlushPolicy.decide(
            puncIds: Self.ids(["_", "_", "_"]),
            currentTokenCount: 50,
            isLastChunk: true,
            configuration: Self.configuration
        )
        #expect(d == .all)
    }

    @Test func sentenceEndTriggersFlush() {
        // 找到 。 → 在该位置切
        // puncIds: [_ _ 。 _ _]，找到 last 句尾 = index 2
        let d = PunctuationFlushPolicy.decide(
            puncIds: Self.ids(["_", "_", "。", "_", "_"]),
            currentTokenCount: 50,
            isLastChunk: false,
            configuration: Self.configuration
        )
        #expect(d == .atIndex(2))
    }

    @Test func questionMarkTriggersFlush() {
        // 找到 ？ → 在该位置切
        let d = PunctuationFlushPolicy.decide(
            puncIds: Self.ids(["_", "？", "_"]),
            currentTokenCount: 50,
            isLastChunk: false,
            configuration: Self.configuration
        )
        #expect(d == .atIndex(1))
    }

    @Test func cacheOverPopTriggerWithCommaForcesFlush() {
        // 超过 cachePopTriggerLimit(200) + 有逗号 → 强制在最后逗号切
        let d = PunctuationFlushPolicy.decide(
            puncIds: Self.ids(Array(repeating: "_", count: 250) + ["，"] + Array(repeating: "_", count: 50)),
            currentTokenCount: 301,
            isLastChunk: false,
            configuration: Self.configuration
        )
        // 最后逗号 index = 250
        #expect(d == .atIndex(250))
    }

    @Test func hardFlushLimitNoPunctuationSplitsAtMid() {
        // cache 超 hardFlushLimit(400)，全程无标点 → 中位切
        let puncIds = Self.ids(Array(repeating: "_", count: 500))
        let d = PunctuationFlushPolicy.decide(
            puncIds: puncIds,
            currentTokenCount: 500,
            isLastChunk: false,
            configuration: Self.configuration
        )
        // 兜底：currentTokenCount / 2 = 250
        #expect(d == .atIndex(250))
    }

    @Test func cacheUnderLimitsKeepsAccumulating() {
        // 都没超 → .none
        let d = PunctuationFlushPolicy.decide(
            puncIds: Self.ids(Array(repeating: "_", count: 50)),
            currentTokenCount: 50,
            isLastChunk: false,
            configuration: Self.configuration
        )
        #expect(d == .none)
    }

    @Test func hardFlushDoesNotTriggerWhenUnderLimit() {
        // currentTokenCount 超过 popTrigger 但没超过 hardFlush 且无逗号 → .none
        let d = PunctuationFlushPolicy.decide(
            puncIds: Self.ids(Array(repeating: "_", count: 300)),
            currentTokenCount: 300,
            isLastChunk: false,
            configuration: Self.configuration
        )
        #expect(d == .none)
    }

    @Test func invalidPunctuationIDsAreIgnored() {
        let d = PunctuationFlushPolicy.decide(
            puncIds: [99, 1, 3],
            currentTokenCount: 50,
            isLastChunk: false,
            configuration: Self.configuration
        )
        #expect(d == .none)
    }

    @Test func hardFlushIndexIsClampedToAvailablePredictions() {
        let d = PunctuationFlushPolicy.decide(
            puncIds: Array(repeating: 1, count: 3),
            currentTokenCount: 500,
            isLastChunk: false,
            configuration: Self.configuration
        )
        #expect(d == .atIndex(2))
    }
}
