/// Pure streaming-cache policy for CT-Transformer punctuation.
///
/// This is a structural extraction only. The production thresholds and
/// priority order are intentionally unchanged: terminal punctuation, comma
/// pressure after 200 tokens, hard midpoint split after 400 tokens, otherwise
/// continue accumulating.
enum PunctuationFlushPolicy {
    enum Decision: Equatable {
        case none
        case atIndex(Int)
        case all
    }

    static func decide(
        puncIds: [Int],
        currentTokenCount: Int,
        isLastChunk: Bool,
        configuration: PunctuationRestorationConfiguration = .production
    ) -> Decision {
        if isLastChunk { return .all }
        guard !puncIds.isEmpty else { return .none }

        var sentenceEnd = -1
        var lastCommaIndex = -1
        // 2026-07-26 P2 F2.11: 之前是 `if lastSearchIndex >= 0 { stride(..., -1) }`
        // 守空集合。改成 0..<max(0, count - 1) 然后 .reversed() —— 空 range
        // 本身就跳过循环，不需要外层 if 守。
        for i in (0..<max(0, puncIds.count - 1)).reversed() {
            guard let symbol = configuration.symbol(for: puncIds[i]) else { continue }
            if configuration.modelTerminalSymbols.contains(symbol) {
                sentenceEnd = i
                break
            }
            if lastCommaIndex < 0 && symbol == configuration.commaSymbol {
                lastCommaIndex = i
            }
        }
        if sentenceEnd >= 0 { return .atIndex(sentenceEnd) }
        if currentTokenCount > configuration.cachePopTriggerLimit && lastCommaIndex >= 0 {
            return .atIndex(lastCommaIndex)
        }
        if currentTokenCount > configuration.hardFlushLimit {
            return .atIndex(min(currentTokenCount / 2, puncIds.count - 1))
        }
        return .none
    }
}
