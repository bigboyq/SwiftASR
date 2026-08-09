import Foundation

// MARK: - SwiftASR 通用数据类型
//
// 这些是 ASR pipeline 输出和持久化的最小数据单位。原本在 `AudioPipeline.swift`
// 末尾嵌套，文件 2079 行。P1-3 拆分：把 6 个数据结构独立出来，让 AudioPipeline
// 只装 actor + 算法。

/// 一段 ASR 句子的最小化结构（text + 绝对毫秒时间戳）。
public struct ASRSentence: Codable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var tokens: [ASRToken]
    public init(text: String, startMs: Int, endMs: Int, tokens: [ASRToken] = []) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.tokens = tokens
    }
}

/// Paraformer CIF 解码出的最小文本单元及其绝对毫秒时间戳。
public struct ASRToken: Codable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// ASR 推理结果
public struct ASRResult: Sendable {
    public var sentences: [ASRSentence]
    public var rawText: String
    public init(sentences: [ASRSentence], rawText: String) {
        self.sentences = sentences
        self.rawText = rawText
    }
}

/// Persisted input for speaker-only re-identification. It captures the
/// punctuated ASR sentence/token timeline before any speaker labels are
/// assigned, which result.json intentionally does not retain.
public struct SpeakerRecognitionInput: Codable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let audioPath: String
    public let sentences: [ASRSentence]

    public init(
        version: Int = SpeakerRecognitionInput.currentVersion,
        audioPath: String,
        sentences: [ASRSentence]
    ) {
        self.version = version
        self.audioPath = audioPath
        self.sentences = sentences
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw SpeakerRecognitionInputValidationError.unsupportedVersion(version)
        }
        guard !audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeakerRecognitionInputValidationError.emptyAudioPath
        }
        for (sentenceIndex, sentence) in sentences.enumerated() {
            guard sentence.startMs >= 0, sentence.endMs >= sentence.startMs else {
                throw SpeakerRecognitionInputValidationError.invalidSentenceTime(
                    index: sentenceIndex,
                    startMs: sentence.startMs,
                    endMs: sentence.endMs
                )
            }
            for (tokenIndex, token) in sentence.tokens.enumerated() {
                guard token.startMs >= sentence.startMs,
                      token.endMs >= token.startMs,
                      token.endMs <= sentence.endMs
                else {
                    throw SpeakerRecognitionInputValidationError.invalidTokenTime(
                        sentenceIndex: sentenceIndex,
                        tokenIndex: tokenIndex
                    )
                }
            }
        }
    }
}

public enum SpeakerRecognitionInputValidationError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case emptyAudioPath
    case invalidSentenceTime(index: Int, startMs: Int, endMs: Int)
    case invalidTokenTime(sentenceIndex: Int, tokenIndex: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "不支持的 speaker-input 版本：\(version)。"
        case .emptyAudioPath:
            return "speaker-input 缺少音频路径。"
        case let .invalidSentenceTime(index, start, end):
            return "speaker-input sentence \(index) 时间范围无效：\(start)-\(end)ms。"
        case let .invalidTokenTime(sentenceIndex, tokenIndex):
            return "speaker-input token \(sentenceIndex):\(tokenIndex) 时间范围无效。"
        }
    }
}

public struct UtteranceData: Sendable {
    public var startMs: Int
    public var endMs: Int
    public var rawText: String
    public var speakerLabel: String
}

/// 一个 speaker 在该 job 里的统计 + centroid embedding
public struct SpeakerProfileData: Sendable {
    public var speakerLabel: String        // 内部 label "说话人 1"
    /// Stable acoustic-cluster identity carried alongside the display label.
    /// It is not persisted into result.json.
    public var acousticLabel: Int?
    public var fingerprintId: String       // SHA256(embedding)[:12] = "fp_xxxxxxxxxxxx"
    public var totalDurationMs: Int
    public var chunkCount: Int
    public var centroidEmbedding: [Float]  // 192 维
    public var embeddingData: Data         // centroidEmbedding 的二进制（写入 SwiftData 用）
    /// Real acoustic profiles use `eres2netv2`. The fixed `Speaker` sentinel
    /// is not emitted as a profile; an explicit user action may later create a
    /// separate user-managed mapping for it.
    public var backend: String

    public init(speakerLabel: String, fingerprintId: String, totalDurationMs: Int, chunkCount: Int, centroidEmbedding: [Float], embeddingData: Data, backend: String = "eres2netv2", acousticLabel: Int? = nil) {
        self.speakerLabel = speakerLabel
        self.acousticLabel = acousticLabel
        self.fingerprintId = fingerprintId
        self.totalDurationMs = totalDurationMs
        self.chunkCount = chunkCount
        self.centroidEmbedding = centroidEmbedding
        self.embeddingData = embeddingData
        self.backend = backend
    }
}
