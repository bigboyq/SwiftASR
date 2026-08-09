import Foundation

/// Maps punctuation-model output back onto the original ASR token timeline.
enum PunctuationAlignment {
    enum Failure: Error, Equatable, LocalizedError, Sendable {
        case unexpectedCharacter(index: Int, character: Character, sourceIndex: Int)
        case unconsumedTokens(expected: Int, matched: Int)

        var errorDescription: String? {
            switch self {
            case let .unexpectedCharacter(index, character, sourceIndex):
                return "标点 token 对齐失败：第 \(index) 个字符“\(character)”无法映射到 source token \(sourceIndex)。"
            case let .unconsumedTokens(expected, matched):
                return "标点 token 对齐失败：期望消费 \(expected) 个 token，实际消费 \(matched) 个。"
            }
        }
    }

    struct Result: Sendable {
        let tokens: [ASRToken]
        let failure: Failure?

        var isAligned: Bool { failure == nil }
    }

    static func align(
        puncText: String,
        into tokens: [ASRToken]
    ) -> Result {
        let punctuation = PunctuationVocabulary.alignmentWriteback
        var outputTokens = tokens
        var sourceIndex = 0

        for (index, character) in puncText.enumerated() {
            if character == " " { continue }
            if sourceIndex < outputTokens.count,
               let sourceCharacter = outputTokens[sourceIndex].text.first,
               character == sourceCharacter
            {
                sourceIndex += 1
            } else if punctuation.contains(character), sourceIndex > 0 {
                outputTokens[sourceIndex - 1].text.append(character)
            } else {
                let failure = Failure.unexpectedCharacter(
                    index: index,
                    character: character,
                    sourceIndex: sourceIndex
                )
                Logger.shared.info(
                    "AudioPipeline: punc/token alignment failed at character " +
                    String(index) + " " +
                    "(sourceIndex=\(sourceIndex)/\(outputTokens.count), character='\(character)')"
                )
                return Result(tokens: tokens, failure: failure)
            }
        }

        guard sourceIndex == outputTokens.count else {
            let failure = Failure.unconsumedTokens(expected: outputTokens.count, matched: sourceIndex)
            Logger.shared.info(
                "AudioPipeline: punc/token alignment failed " +
                "(sourceIndex=\(sourceIndex)/\(outputTokens.count)); fallback to unpunctuated tokens"
            )
            return Result(tokens: tokens, failure: failure)
        }
        return Result(tokens: outputTokens, failure: nil)
    }

    static func requireAligned(_ result: Result) throws -> [ASRToken] {
        guard let failure = result.failure else { return result.tokens }
        throw failure
    }
}
