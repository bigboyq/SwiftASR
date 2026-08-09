import Foundation
import Accelerate
import OnnxRuntimeBindings

/// CT-Transformer punctuation model adapter.
///
/// This type owns ONNX session execution and vocabulary encoding only. Cache
/// management, flush decisions, and punctuation rendering live in
/// `PunctuationRestorationPipeline`.
///
/// `@unchecked Sendable` is required because ONNX Runtime's session types do
/// not declare `Sendable`; the session and vocabulary are initialized once and
/// are read-only during inference.
public enum PuncInferenceError: Error, LocalizedError, Sendable {
    case invalidInputContract(inputNames: [String])
    case missingLogitsOutput(outputNames: [String])
    case missingLogits
    /// 词汇表缺 <unk> token
    case missingUnknownToken(vocabPath: String)
    /// logits shape 不匹配 (count != ids.count * numClasses)
    case logitsShapeMismatch(found: Int, expected: Int)
    /// numClasses <= 0 或 logits.count 不是 numClasses 倍数
    case invalidLogitsShape
    /// logits 含 NaN / ±Inf
    case nonFiniteLogits
    /// ORT session 初始化失败
    case sessionInitFailed(underlying: String)
    /// 词表 JSON decode 失败
    ///
    /// **MIGRATION NOTE (round-3 M2-N1)**：原 NSError 文本是
    /// `"Unable to read Punc vocabulary: \(path)"` (read 失败) 或
    /// `"Unable to decode Punc vocabulary: \(path)"` (JSON decode 失败)，
    /// 原 error 通过 `userInfo[NSUnderlyingErrorKey]` 单独携带。
    /// enum 改用 `underlying: String` 把 underlying 拼到 errorDescription
    /// (`"Punc vocabulary load failed: ... (underlying)"`)，跟原 NSError
    /// 文本不等价。
    /// 这是 enum migration 必然损失：enum case 不能携带任意 `Error` 类型
    /// (会牺牲 Sendable)。如果未来 caller 需要原始 `Error` 类型（比如
    /// 区分 NSPOSIXErrorCode），改 `underlying: any Error` + 加 `Sendable`
    /// 包装，但要先确认所有 throws 路径都 Sendable。
    /// `EnumMigrationGoldenTextTests` 钉死这个行为。
    case vocabularyLoadFailed(underlying: String)
    /// 词表为空
    case emptyVocabulary(path: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInputContract(inputNames):
            return "Punc model input contract is invalid: \(inputNames)"
        case let .missingLogitsOutput(outputNames):
            return "Punc model is missing logits output: \(outputNames)"
        case .missingLogits:
            return "no output"
        case let .missingUnknownToken(vocabPath):
            return "Punc vocabulary is missing <unk>: \(vocabPath)"
        case let .logitsShapeMismatch(found, expected):
            return "logits shape mismatch: count=\(found), expected \(expected)"
        case .invalidLogitsShape:
            return "Punc logits shape is invalid"
        case .nonFiniteLogits:
            return "Punc model returned non-finite logits"
        case let .sessionInitFailed(underlying):
            return "Punc session init failed: \(underlying)"
        case let .vocabularyLoadFailed(underlying):
            return "Punc vocabulary load failed: \(underlying)"
        case let .emptyVocabulary(path):
            return "Punc vocabulary is empty: \(path)"
        }
    }
}

public final class PuncONNXEngine: @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession
    private let requestedOutputNames: Set<String>
    private let charToId: [String: Int]
    private let unknownTokenID: Int32

    public init(modelPath: String, vocabJsonPath: String, useCoreML: Bool = true) throws {
        self.env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()

        if useCoreML {
            do {
                let cmleOptions = ORTCoreMLExecutionProviderOptions()
                cmleOptions.useCPUOnly = false
                try options.appendCoreMLExecutionProvider(with: cmleOptions)
                Logger.shared.info("PuncONNXEngine: CoreML EP appended")
            } catch {
                Logger.shared.warn("PuncONNXEngine: CoreML EP not available: \(error)")
            }
        } else {
            Logger.shared.info("PuncONNXEngine: CPU provider")
        }

        let session = try ORTSessionInitializationGate.create(
            env: env, modelPath: modelPath, options: options
        )
        self.session = session
        let inputNames = try session.inputNames()
        guard inputNames.contains("inputs"), inputNames.contains("text_lengths") else {
            throw PuncInferenceError.invalidInputContract(inputNames: inputNames)
        }
        let outputNames = try session.outputNames()
        guard outputNames.contains("logits") else {
            throw PuncInferenceError.missingLogitsOutput(outputNames: outputNames)
        }
        self.requestedOutputNames = Set(outputNames)
        let vocabulary = try Self.loadVocabulary(path: vocabJsonPath)
        guard let unknownID = vocabulary["<unk>"] else {
            throw PuncInferenceError.missingUnknownToken(vocabPath: vocabJsonPath)
        }
        self.charToId = vocabulary
        self.unknownTokenID = Int32(unknownID)
        Logger.shared.info("PuncONNXEngine: vocabulary loaded (\(charToId.count) entries)")
    }

    func tokenize(text: String) -> [String] {
        var words: [String] = []
        let segments = text.components(separatedBy: .whitespacesAndNewlines)
        for segment in segments where !segment.isEmpty {
            var currentWord = ""
            for character in segment {
                let value = String(character)
                if value.utf8.count == 1 {
                    currentWord.append(value)
                } else {
                    if !currentWord.isEmpty {
                        words.append(currentWord)
                        currentWord = ""
                    }
                    words.append(value)
                }
            }
            if !currentWord.isEmpty {
                words.append(currentWord)
            }
        }
        return words
    }

    func tokenIDs(for tokens: [String]) -> [Int32] {
        tokens.map { Int32(charToId[$0] ?? Int(unknownTokenID)) }
    }

    func infer(ids: [Int32]) throws -> [Int] {
        guard !ids.isEmpty else { return [] }

        var idsCopy = ids
        let idsData = Data(bytes: &idsCopy, count: idsCopy.count * MemoryLayout<Int32>.size)
        let inputTensor = try ORTValue(
            tensorData: NSMutableData(data: idsData),
            elementType: .int32,
            shape: [1, NSNumber(value: ids.count)]
        )
        var lengths: [Int32] = [Int32(ids.count)]
        let lengthsData = Data(bytes: &lengths, count: lengths.count * MemoryLayout<Int32>.size)
        let lengthsTensor = try ORTValue(
            tensorData: NSMutableData(data: lengthsData),
            elementType: .int32,
            shape: [1]
        )

        let outputs: [String: ORTValue] = try session.run(
            withInputs: ["inputs": inputTensor, "text_lengths": lengthsTensor],
            outputNames: requestedOutputNames,
            runOptions: nil
        )
        guard let logitsTensor = outputs["logits"] else {
            throw PuncInferenceError.missingLogits
        }
        let logitsData = try logitsTensor.tensorData() as Data
        let logits = logitsData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        let numClasses = PunctuationRestorationConfiguration.production.puncList.count
        guard logits.count == ids.count * numClasses else {
            throw PuncInferenceError.logitsShapeMismatch(
                found: logits.count, expected: ids.count * numClasses
            )
        }
        return try Self.argmaxPerFrame(logits: logits, numClasses: numClasses)
    }

    static func argmaxPerFrame(logits: [Float], numClasses: Int) throws -> [Int] {
        guard numClasses > 0, logits.count.isMultiple(of: numClasses) else {
            throw PuncInferenceError.invalidLogitsShape
        }
        // vDSP_sve 一次性求和再判 finite (Punc logits 跟 VAD 一样有界,sum 不会溢出)
        var logitsSum: Float = 0
        logits.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_sve(base, 1, &logitsSum, vDSP_Length(ptr.count))
        }
        guard logitsSum.isFinite else {
            throw PuncInferenceError.nonFiniteLogits
        }
        let count = logits.count / numClasses
        var output: [Int] = []
        output.reserveCapacity(count)
        let classLen = vDSP_Length(numClasses)
        logits.withUnsafeBufferPointer { logitsBuf in
            guard let logitsBase = logitsBuf.baseAddress else { return }
            for frame in 0..<count {
                let framePtr = logitsBase.advanced(by: frame * numClasses)
                // vDSP_maxvi 跟 ASRDecoder 写法同源,bit-exact 跟标量 for-if 选最大一致。
                // 注意:在并列最大值时,标量 `value > bestValue` 取第一个,argmax 也类似
                // (vDSP_maxvi 在并列时取最小 idx,标量也是 — `if value > bestValue` 不更新,所以是第一个)。
                var maxVal: Float = 0
                var maxIdx: vDSP_Length = 0
                vDSP_maxvi(framePtr, 1, &maxVal, &maxIdx, classLen)
                output.append(Int(maxIdx))
            }
        }
        return output
    }

    static func loadVocabulary(path: String) throws -> [String: Int] {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw PuncInferenceError.vocabularyLoadFailed(
                underlying: "Unable to read Punc vocabulary: \(path) (\(error))"
            )
        }

        let tokens: [String]
        do {
            tokens = try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw PuncInferenceError.vocabularyLoadFailed(
                underlying: "Unable to decode Punc vocabulary: \(path) (\(error))"
            )
        }
        guard !tokens.isEmpty else {
            throw PuncInferenceError.emptyVocabulary(path: path)
        }
        var vocabulary: [String: Int] = [:]
        var duplicates: [(token: String, first: Int, duplicate: Int)] = []
        for (index, token) in tokens.enumerated() {
            if let first = vocabulary[token] {
                duplicates.append((token: token, first: first, duplicate: index))
            } else {
                vocabulary[token] = index
            }
        }
        if !duplicates.isEmpty {
            let details = duplicates.prefix(8).map {
                "\($0.token) [\($0.first),\($0.duplicate)]"
            }.joined(separator: ", ")
            Logger.shared.warn(
                "Punc vocabulary duplicate tokens repaired in memory (index-preserving): \(details)"
            )
        }
        return vocabulary
    }
}
