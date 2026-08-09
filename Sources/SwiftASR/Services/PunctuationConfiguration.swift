import Foundation

/// Stable configuration shared by the punctuation model adapter and its
/// cache/flush orchestration. These values intentionally preserve the
/// production CT-Transformer behavior.
struct PunctuationRestorationConfiguration: Sendable, Equatable {
    let puncList: [String]
    let splitSize: Int
    let cachePopTriggerLimit: Int
    let hardFlushLimit: Int
    let modelTerminalSymbols: Set<String>
    let commaSymbol: String
    let sentenceSymbolID: Int

    static let production = PunctuationRestorationConfiguration(
        puncList: ["<unk>", "_", "，", "。", "？", "、"],
        splitSize: 20,
        cachePopTriggerLimit: 200,
        hardFlushLimit: 400,
        modelTerminalSymbols: ["。", "？"],
        commaSymbol: "，",
        sentenceSymbolID: 3
    )

    func symbol(for id: Int) -> String? {
        guard id >= 0, id < puncList.count else { return nil }
        return puncList[id]
    }
}
/// Single source of truth for the punctuation character sets used by
/// ASR's pre-punctuation sentence flush, the post-punctuation boundary
/// policy, and the alignment write-back path.
///
/// Three call sites had drifted into three near-duplicate literals
/// (ASRDecoder.sentenceEnders, SentenceBoundaryPolicy.terminalCharacters,
/// PunctuationAlignment.punctuation).  Centralising them removes the
/// risk of one call site silently changing shape while another keeps
/// the old set.
enum PunctuationVocabulary: Sendable {
    /// Terminal marks that trigger a sentence flush.
    /// Used by:
    ///   - `ASRDecoder.sentenceEnders` (pre-punctuation flush during
    ///     raw ASR token streaming).
    ///   - `SentenceBoundaryPolicy.terminalCharacters` (post-punctuation
    ///     flush inside `SentenceProjection.split`).
    static let terminal: Set<Character> = [
        "。", "！", "？", "；",
        ".", "!", "?", ";"
    ]

    /// Sub-sentence / clause marks: at the 30-char threshold these
    /// also trigger a flush.  Used only by `SentenceBoundaryPolicy`.
    static let clause: Set<Character> = [
        "，", "、", "：",
        ",", ":"
    ]

    /// Marks that `PunctuationAlignment` writes back onto the preceding
    /// ASR token.  Includes both terminal and clause marks so every
    /// output punctuation the CT-Transformer can emit has a place to
    /// land on the source token stream.
    static let alignmentWriteback: Set<Character> = [
        "，", "。", "？", "、",
        ",", ".", "?", "!", ";", "；"
    ]
}

/// Final, user-visible ASR sentence boundary policy.
///
/// This is deliberately separate from the model cache flush policy: flushing
/// the model context is an inference concern, while this policy determines
/// the sentence objects handed to the speaker pipeline.
struct SentenceBoundaryPolicy: Sendable, Equatable {
    let terminalCharacters: Set<Character>
    let clauseCharacters: Set<Character>
    let maxCharacters: Int
    let maxSilenceGapMs: Int

    static let production = SentenceBoundaryPolicy(
        terminalCharacters: PunctuationVocabulary.terminal,
        clauseCharacters: PunctuationVocabulary.clause,
        maxCharacters: 30,
        maxSilenceGapMs: 300
    )

    init(
        terminalCharacters: Set<Character> = PunctuationVocabulary.terminal,
        clauseCharacters: Set<Character> = PunctuationVocabulary.clause,
        maxCharacters: Int = 30,
        maxSilenceGapMs: Int = 300
    ) {
        self.terminalCharacters = terminalCharacters
        self.clauseCharacters = clauseCharacters
        self.maxCharacters = maxCharacters
        self.maxSilenceGapMs = maxSilenceGapMs
    }

    func shouldFlush(
        after token: ASRToken,
        characterCount: Int,
        nextToken: ASRToken?
    ) -> Bool {
        guard let lastChar = token.text.last else { return false }
        if terminalCharacters.contains(lastChar) {
            return true
        }
        if characterCount >= maxCharacters && clauseCharacters.contains(lastChar) {
            return true
        }
        if let nextToken, nextToken.startMs - token.endMs >= maxSilenceGapMs {
            return true
        }
        if characterCount >= maxCharacters * 2 {
            return true
        }
        return false
    }
}
