import Foundation

enum PunctuationRestorationError: Error, Equatable, LocalizedError, Sendable {
    case tokenizationProducedNoTokens
    case outputCountMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .tokenizationProducedNoTokens:
            return "标点阶段无法从非空 ASR 文本生成 token。"
        case let .outputCountMismatch(expected, actual):
            return "标点阶段输出数量不匹配：期望 \(expected)，实际 \(actual)。"
        }
    }
}

/// Orchestrates CT-Transformer punctuation restoration without owning model
/// inference details.
final class PunctuationRestorationPipeline: @unchecked Sendable {
    private let engine: PuncONNXEngine
    private let configuration: PunctuationRestorationConfiguration

    init(
        modelPath: String,
        vocabJsonPath: String,
        useCoreML: Bool = true,
        configuration: PunctuationRestorationConfiguration = .production
    ) throws {
        self.engine = try PuncONNXEngine(
            modelPath: modelPath,
            vocabJsonPath: vocabJsonPath,
            useCoreML: useCoreML
        )
        self.configuration = configuration
    }

    /// Restores punctuation while preserving the historical chunk/cache
    /// behavior. This remains a text-only stage; token alignment is separate.
    func restorePunctuation(text: String) throws -> String {
        if text.isEmpty { return text }

        let tokens = engine.tokenize(text: text)
        guard !tokens.isEmpty else {
            throw PunctuationRestorationError.tokenizationProducedNoTokens
        }
        let tokenIDs = engine.tokenIDs(for: tokens)

        var cacheTokens: [String] = []
        var cacheIDs: [Int32] = []
        var finalPuncIDs: [Int] = []

        let totalCount = tokens.count
        let chunkCount = (totalCount + configuration.splitSize - 1) / configuration.splitSize

        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * configuration.splitSize
            let end = min(totalCount, start + configuration.splitSize)
            let currentTokens = cacheTokens + Array(tokens[start..<end])
            let currentIDs = cacheIDs + Array(tokenIDs[start..<end])
            if currentIDs.isEmpty { continue }

            let puncIDs = try engine.infer(ids: currentIDs)
            let decision = PunctuationFlushPolicy.decide(
                puncIds: puncIDs,
                currentTokenCount: currentTokens.count,
                isLastChunk: chunkIndex == chunkCount - 1,
                configuration: configuration
            )

            switch decision {
            case .all:
                finalPuncIDs.append(contentsOf: puncIDs)
                cacheTokens = []
                cacheIDs = []

            case .none:
                cacheTokens = currentTokens
                cacheIDs = currentIDs

            case .atIndex(let sentenceEnd):
                let flushCount = min(sentenceEnd + 1, currentTokens.count, puncIDs.count)
                guard flushCount > 0 else {
                    cacheTokens = currentTokens
                    cacheIDs = currentIDs
                    continue
                }

                var flushedPuncIDs = Array(puncIDs[0..<flushCount])
                if let symbol = configuration.symbol(for: puncIDs[flushCount - 1]),
                   symbol == configuration.commaSymbol
                {
                    flushedPuncIDs[flushedPuncIDs.count - 1] = configuration.sentenceSymbolID
                }
                finalPuncIDs.append(contentsOf: flushedPuncIDs)
                cacheTokens = Array(currentTokens[flushCount...])
                cacheIDs = Array(currentIDs[flushCount...])

                if currentTokens.count > configuration.hardFlushLimit {
                    Logger.shared.warn(
                        "PunctuationRestorationPipeline: cache reached hardFlushLimit; " +
                        "mid-splitting at token \(sentenceEnd)"
                    )
                }
            }
        }

        if !finalPuncIDs.isEmpty {
            let lastIndex = finalPuncIDs.count - 1
            // Hoist the symbol lookup so both branches below share it.
            // 2026-07-26 P2 F2.9: was two separate `if let lastSymbol =
            // configuration.symbol(for: finalPuncIDs[lastIndex])` calls
            // in mutually-exclusive branches — the second call redid the
            // dictionary lookup the first had just performed.
            if let lastSymbol = configuration.symbol(for: finalPuncIDs[lastIndex]) {
                if lastSymbol == configuration.commaSymbol || lastSymbol == "、" {
                    finalPuncIDs[lastIndex] = configuration.sentenceSymbolID
                } else if !configuration.modelTerminalSymbols.contains(lastSymbol) {
                    // Preserve CT-Transformer's final-token sentence-end policy.
                    finalPuncIDs[lastIndex] = configuration.sentenceSymbolID
                }
            }
        }

        try Self.validateOutputCount(
            tokenCount: tokens.count,
            punctuationCount: finalPuncIDs.count
        )

        Self.protectRepetition(
            puncIDs: &finalPuncIDs,
            tokens: tokens,
            configuration: configuration
        )

        return Self.render(tokens: tokens, puncIDs: finalPuncIDs, configuration: configuration)
    }

    /// Removes punctuation that would break an obvious repeated phrase.
    ///
    /// CT-Transformer is a per-token model — it does not see the cross-token
    /// repeated structure. When a speaker repeats a character or short word,
    /// the model can confidently insert a sentence break between the two
    /// occurrences, producing output like "见。过" instead of "见过". Real
    /// examples from 6月4日ADHD2 5min 精修:
    ///
    /// - L20: `见过都知道，见。过都知道` — "。" inserted between the second
    ///   "见" and "过" of the repeated "见过".
    /// - L51: `大一点大一。点` — "。" inserted between the second "一" and
    ///   "点" of the repeated "大一点".
    ///
    /// The guard fires when *all five* of the following hold:
    ///   (a) the punctuation is a terminal mark (`。` / `？`); commas and
    ///       enumeration marks are weaker and are intentionally left alone.
    ///   (b) the candidate is *not* the last token (句末标点保留).
    ///   (c) `tokens[index]` is **not** itself a terminal mark. In production
    ///       the input text comes from ASR (no punctuation) so the model
    ///       only sees plain CJK tokens. But when a 5min 精修 fixture feeds
    ///       punctuation *into* the pipeline for diagnostic, `tokens[i]` can
    ///       be a `。` itself; such positions are normal sentence ends, not
    ///       broken repetitions.
    ///   (d) the two tokens straddling the punctuation differ (`X != Y`).
    ///       A repeated `X。X` like "哈。哈" reads as intentional emphasis and
    ///       must be left intact.
    ///   (e) the 3-token context is reproducible from an earlier occurrence
    ///       in **either** of two directions:
    ///         - `(X_prev, X, Y)` matches an earlier 3-token window, **or**
    ///         - `(X, Y, Y_next)` matches an earlier 3-token window.
    ///       Both directions require the earlier window's trailing puncID
    ///       to be 0 (i.e. it was inside a complete unit). The 3-token
    ///       check is the key guard against false positives: a 2-token
    ///       `(X, Y)` pair that happened to appear earlier (e.g. "饶了" +
    ///       "我" → "好了" + "我") is NOT a repetition, because neither the
    ///       preceding nor the following context matches. Only when at
    ///       least one of the two 3-token windows reproduces from earlier
    ///       is the candidate a real broken repetition.
    ///
    /// Direction coverage is important: L20 satisfies the *forward*
    /// direction (`(见, 过, 都)` recurs), L51 satisfies the *backward*
    /// direction (`(大, 一, 点)` recurs). Either alone is sufficient.
    ///
    /// L41-style "真的" being broken by "，" inside a single occurrence is
    /// *not* handled here — that requires a common-word list and is a
    /// separate word-boundary problem.
    static func protectRepetition(
        puncIDs: inout [Int],
        tokens: [String],
        configuration: PunctuationRestorationConfiguration
    ) {
        guard puncIDs.count == tokens.count, !tokens.isEmpty else { return }

        for index in 0..<puncIDs.count where puncIDs[index] >= 2 {
            // (b) sentence-final punc is not "in the middle" of anything.
            guard index + 1 < puncIDs.count else { continue }
            // (a) only act on terminal marks; comma / enumeration stay.
            guard let symbol = configuration.symbol(for: puncIDs[index]),
                  configuration.modelTerminalSymbols.contains(symbol) else { continue }
            // (c) the token at the candidate position must be a real CJK
            //     character, not a terminal mark. A terminal mark as `X`
            //     means the model already had the punc on the *previous*
            //     token; there is no second punc to clear here.
            guard !configuration.modelTerminalSymbols.contains(tokens[index]) else { continue }

            let x = tokens[index]
            let y = tokens[index + 1]
            // (d) X == Y reads as intentional emphasis (e.g. "哈。哈") and
            //     must be kept.
            guard x != y else { continue }

            // (e) at least one 3-token context window matches an earlier
            //     occurrence whose trailing puncID is 0.
            guard index >= 1 else { continue }
            let canCheckForward = index + 2 < tokens.count
            var foundEarlierPattern = false
            for j in 0..<index {
                guard j + 1 < tokens.count else { continue }
                let trailingPuncIsZero = puncIDs[j + 1] == 0
                guard trailingPuncIsZero else { continue }
                // Backward direction: (X_prev, X, Y) == (tokens[j-1], tokens[j], tokens[j+1])
                let backwardMatches = j >= 1
                    && tokens[j - 1] == tokens[index - 1]
                    && tokens[j] == x
                    && tokens[j + 1] == y
                // Forward direction: (X, Y, Y_next) == (tokens[j], tokens[j+1], tokens[j+2])
                let forwardMatches = canCheckForward
                    && j + 2 < tokens.count
                    && tokens[j] == x
                    && tokens[j + 1] == y
                    && tokens[j + 2] == tokens[index + 2]
                if backwardMatches || forwardMatches {
                    foundEarlierPattern = true
                    break
                }
            }
            if foundEarlierPattern {
                puncIDs[index] = 0
            }
        }
    }

    static func validateOutputCount(tokenCount: Int, punctuationCount: Int) throws {
        guard tokenCount == punctuationCount else {
            throw PunctuationRestorationError.outputCountMismatch(
                expected: tokenCount,
                actual: punctuationCount
            )
        }
    }

    static func render(
        tokens: [String],
        puncIDs: [Int],
        configuration: PunctuationRestorationConfiguration
    ) -> String {
        var output = ""
        for index in tokens.indices {
            let token = tokens[index]
            if index > 0 {
                let previous = tokens[index - 1]
                // 2026-07-26 P2 F2.10: `previous.utf8.count == previous.count` is
                // an indirect "is this ASCII" check (UTF-8 packs non-ASCII
                // into multi-byte sequences). Direct isASCII is O(n) on
                // Characters with the same semantics and clearer intent.
                if previous.allSatisfy(\.isASCII) && token.allSatisfy(\.isASCII) {
                    output.append(" ")
                }
            }
            output.append(token)
            guard index < puncIDs.count else { continue }
            if let symbol = configuration.symbol(for: puncIDs[index]), puncIDs[index] >= 2 {
                output.append(symbol)
            }
        }
        return output
    }
}
