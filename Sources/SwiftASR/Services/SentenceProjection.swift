/// Projects aligned punctuation tokens into utterance-sized sentences.
enum SentenceProjection {
    static func split(
        _ tokens: [ASRToken],
        policy: SentenceBoundaryPolicy = .production
    ) -> [ASRSentence] {
        var out: [ASRSentence] = []
        var current: [ASRToken] = []
        var currentCharacterCount = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            out.append(ASRSentence(text: text, startMs: first.startMs, endMs: last.endMs, tokens: current))
            current = []
            currentCharacterCount = 0
        }

        for (index, token) in tokens.enumerated() {
            current.append(token)
            currentCharacterCount += token.text.count
            let nextToken = index + 1 < tokens.count ? tokens[index + 1] : nil
            if policy.shouldFlush(
                after: token,
                characterCount: currentCharacterCount,
                nextToken: nextToken
            ) {
                flush()
            }
        }
        flush()
        return out
    }
}
