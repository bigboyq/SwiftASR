import Foundation
import Accelerate

enum ASRDecoderError: Error, LocalizedError {
    case invalidOutput(String)
    case emptyVocabulary

    var errorDescription: String? {
        switch self {
        case .invalidOutput(let message): return "ASR decoder output contract invalid: \(message)"
        case .emptyVocabulary: return "ASR vocabulary is empty"
        }
    }
}

/// Converts raw Paraformer evidence into timestamped ASR sentences.
///
/// This type intentionally has no ONNX state.  It owns only vocabulary and
/// deterministic post-processing, so the same decoder contract is used by all
/// concurrent inference workers.
struct ASRDecoder: Sendable {
    private let vocabulary: [String]

    init(vocabJsonPath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: vocabJsonPath))
        let tokens = try JSONDecoder().decode([String].self, from: data)
        guard !tokens.isEmpty else {
            throw ASRDecoderError.emptyVocabulary
        }
        vocabulary = tokens
    }

    func decode(output: ASRInferenceOutput, seqLen: Int) throws -> ASRResult {
        let vocabSize = vocabulary.count
        guard vocabSize > 0, seqLen > 0, output.logits.count > 0 else {
            throw ASRDecoderError.invalidOutput("empty logits or sequence length")
        }
        // Opt-in diagnostic hook: see `ASRDecoderDiagnostics.swift`. When
        // Release builds use an optimizable no-op stub. Debug builds consult
        // the diagnostic environment variables documented in that file.
        Self.beginDecodeSegment()
        guard output.logits.count.isMultiple(of: vocabSize) else {
            throw ASRDecoderError.invalidOutput(
                "logits count \(output.logits.count) is not divisible by vocabulary size \(vocabSize)"
            )
        }
        let actualT = output.logits.count / vocabSize
        guard output.tokenNum >= 0, output.tokenNum <= actualT else {
            throw ASRDecoderError.invalidOutput(
                "token_num \(output.tokenNum) exceeds logits capacity \(actualT)"
            )
        }
        let validT = Self.effectiveTokenCount(
            logitsCount: output.logits.count,
            vocabSize: vocabSize,
            tokenNum: output.tokenNum
        )
        let totalSeqLen = min(validT, actualT)
        guard totalSeqLen > 0 else {
            throw ASRDecoderError.invalidOutput("effective token capacity is zero")
        }

        // 1. 拿 token 序列：每 t 对应 1 个 token，vDSP_maxvi 取 argmax。
        // 保留当前生产规则：特殊 token、低概率 token、连续重复和 ABA 重复过滤。
        var decodedTokens: [(id: Int, text: String)] = []
        var prevTokenId: Int?
        var prevPrevTokenId: Int?
        let minProbability: Float = 0.2
        var softmaxScratch = [Float](repeating: 0, count: vocabSize)
        let vLen = vDSP_Length(vocabSize)

        try output.logits.withUnsafeBufferPointer { logitsBuf in
            guard let logitsBase = logitsBuf.baseAddress else { return }
            for t in 0..<totalSeqLen {
                let offset = t * vocabSize
                let framePtr = logitsBase.advanced(by: offset)
                var maxVal: Float = 0
                var maxIdx: vDSP_Length = 0
                vDSP_maxvi(framePtr, 1, &maxVal, &maxIdx, vLen)
                let maxIndex = Int(maxIdx)
                guard maxVal.isFinite else {
                    throw ASRDecoderError.invalidOutput("non-finite logit at frame \(t)")
                }
                let token = vocabulary[maxIndex]
                if token == "<blank>" || token == "<s>" || token == "</s>" { continue }
                guard Self.clearsProbabilityThresholdPointer(
                    logitsPtr: framePtr,
                    vocabularySize: vocabSize,
                    maxLogit: maxVal,
                    minimumProbability: minProbability,
                    scratch: &softmaxScratch
                ) else { continue }
                // Skip only CJK single-character repeats. CJK speakers don't
                // actually emit "我我" or "是是" back-to-back, so a 2-3 frame
                // stretch of the same CJK char is essentially always model
                // noise. ASCII letter repeats (e.g. "PPT" / "CEO" / "USA"
                // collapsed to "p p t" subword sequence, or English double
                // letters "pp" / "tt") and multi-character subword repeats
                // (e.g. "service service") are NOT noise, so we must NOT
                // drop them. ABA patterns follow the same rule: "是不是"
                // / "对不对" / "好不好" are real speech, not noise.
                let current = (id: maxIndex, text: token)
                let prev = prevTokenId.map { (id: $0, text: vocabulary[$0]) }
                let prevPrev = prevPrevTokenId.map { (id: $0, text: vocabulary[$0]) }
                let newSkip = Self.shouldSkipForRepeat(prev: prev, prevPrev: prevPrev, current: current)
                // Opt-in diagnostic: when `SWIFTASR_FILTER_COMPARE=1`,
                // logs every position where the pre-`ae440e8` and current
                // filters disagree.  See `ASRDecoderDiagnostics.swift`.
                Self.recordFilterDecision(
                    t: t, logitsBase: logitsBase, offset: offset,
                    vocabSize: vocabSize, vLen: vLen,
                    usAlphas: output.usAlphas,
                    token: token, current: current,
                    prev: prev, prevPrev: prevPrev,
                    newSkip: newSkip
                )
                if newSkip {
                    continue
                }
                prevPrevTokenId = prevTokenId
                prevTokenId = maxIndex
                var display = token
                if display.hasSuffix("@@") { display = String(display.dropLast(2)) }
                decodedTokens.append((maxIndex, display))
                // Opt-in diagnostic: when `SWIFTASR_EMIT_TRACE_FILE` is
                // set, append one TSV row per emit.  See
                // `ASRDecoderDiagnostics.swift`.
                Self.recordEmit(
                    t: t, id: maxIndex, text: display,
                    logitsBase: logitsBase, offset: offset,
                    vocabSize: vocabSize, vLen: vLen,
                    usAlphas: output.usAlphas
                )
            }
        }

        let frameMs = 60
        let maxDurationMs = seqLen * frameMs
        let tokenTimesMs = Self.officialCIFTokenTimestampsMs(
            usAlphas: output.usAlphas,
            usCifPeak: output.usCifPeak,
            tokenCount: decodedTokens.count,
            maxDurationMs: maxDurationMs
        )
        var pieces: [ASRToken] = []
        for (index, token) in decodedTokens.enumerated() {
            let startMs = Self.tokenTimeMs(index: index, tokenTimesMs: tokenTimesMs, frameMs: frameMs)
            let nextMs = Self.tokenTimeMs(index: index + 1, tokenTimesMs: tokenTimesMs, frameMs: frameMs)
            let endMs = min(maxDurationMs, max(startMs + frameMs, nextMs))
            pieces.append(contentsOf: Self.characterTokens(
                text: token.text,
                startMs: min(startMs, maxDurationMs),
                endMs: max(min(startMs + frameMs, maxDurationMs), endMs)
            ))
        }
        pieces = Self.clampShortTokenOverlaps(pieces)

        // 当前断句规则不变：30 字或句末标点 flush。
        let maxChars = 30
        let sentenceEnders = PunctuationVocabulary.terminal
        var sentences: [ASRSentence] = []
        var current: [ASRToken] = []
        func flush() {
            let tokens = current.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let text = tokens.map(\.text).joined()
            if !text.isEmpty {
                sentences.append(ASRSentence(
                    text: text,
                    startMs: tokens.first?.startMs ?? 0,
                    endMs: tokens.last?.endMs ?? tokens.first?.startMs ?? 0,
                    tokens: tokens
                ))
            }
            current = []
        }
        for piece in pieces {
            current.append(piece)
            let text = current.map(\.text).joined()
            let isEnder = piece.text.last.map { sentenceEnders.contains($0) } ?? false
            if text.count >= maxChars || isEnder { flush() }
        }
        flush()
        return ASRResult(sentences: sentences, rawText: sentences.map(\.text).joined(separator: ""))
    }

    /// CIF fire points are authoritative token boundaries. The historical
    /// 60ms minimum-duration fallback may extend one token past the next fire
    /// point; cap that fallback at the following token's start so a single
    /// decoder invocation never emits overlapping token ranges.
    static func clampShortTokenOverlaps(_ tokens: [ASRToken]) -> [ASRToken] {
        guard tokens.count > 1 else { return tokens }
        var output = tokens
        for index in output.indices.dropLast() {
            let nextStart = output[index + 1].startMs
            if output[index].endMs > nextStart {
                output[index].endMs = max(output[index].startMs, nextStart)
            }
        }
        return output
    }

    /// True if the given vocab token is a single CJK Unified Ideograph
    /// (covering the common Chinese characters in Paraformer's vocab).
    /// Used to gate the consecutive/ABA repeat filter on the decode loop:
    /// a CJK single char appearing in 2-3 consecutive argmax frames is
    /// essentially always model noise, but an ASCII letter (or multi-char
    /// subword) repeat is the legitimate subword-level spelling of an
    /// English abbreviation like "PPT" / "CEO", or a doubled letter
    /// like "pp" / "tt". Fullwidth punctuation (`，`) and Latin-1
    /// letters (`é`) are intentionally NOT classified as CJK so the
    /// noise filter doesn't accidentally drop them.
    static func isCJKSingleChar(_ token: String) -> Bool {
        guard token.count == 1,
              let scalar = token.unicodeScalars.first else { return false }
        let value = scalar.value
        // CJK Unified Ideographs (U+4E00–U+9FFF) plus the most common
        // CJK Extension A range (U+3400–U+4DBF). Paraformer's Chinese
        // vocabulary lives almost entirely in U+4E00–U+9FFF; the
        // Extension A range is included as a defensive bound for less
        // common characters.
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
    }

    /// Returns true if `current` should be filtered as a "repeating model
    /// noise" given `prev` and `prevPrev` from earlier frames in the same
    /// decode pass. Only CJK single-character tokens are filtered; ASCII
    /// letters (English abbreviations / doubled letters) and
    /// multi-character subwords (e.g. "service") are always retained.
    /// - "PPT" subword sequence `p` `p` `t` → second `p` retained.
    /// - "我我" CJK noise → second `我` dropped.
    /// - "service service" multi-char subword → retained.
    /// - "是不是" / "对不对" / "好不好" ABA patterns → all retained.
    static func shouldSkipForRepeat(
        prev: (id: Int, text: String)?,
        prevPrev: (id: Int, text: String)?,
        current: (id: Int, text: String)
    ) -> Bool {
        // Consecutive: same vocab id as prev
        if let prev, prev.id == current.id {
            return isCJKSingleChar(current.text)
        }
        // ABA: same vocab id as prevPrev (and prev exists)
        if let prevPrev, prevPrev.id == current.id, prev != nil {
            return isCJKSingleChar(current.text)
        }
        return false
    }

    // NOTE: opt-in diagnostic hooks (`oldShouldSkipForRepeat`,
    // `filterCompareEnabled`, `emitTraceFilePath`, `maxProb`,
    // `openEmitTrace` / `appendEmitTrace` / `flushEmitTrace`,
    // `recordFilterDecision`, `recordEmit`, `beginDecodeSegment`)
    // live in `ASRDecoderDiagnostics.swift`. Debug builds gate them on
    // environment variables; Release builds compile signature-compatible
    // no-op stubs so the optimizer removes the hooks.

    static func effectiveTokenCount(logitsCount: Int, vocabSize: Int, tokenNum: Int) -> Int {
        guard logitsCount > 0, vocabSize > 0 else { return 0 }
        let logitsT = logitsCount / vocabSize
        guard tokenNum > 0 else { return logitsT }
        return min(tokenNum, logitsT)
    }

    /// Computes the production softmax confidence gate with Accelerate.  The
    /// caller owns `scratch`, so decoding many frames does not allocate one
    /// temporary vector per vocabulary row.
    static func clearsProbabilityThresholdPointer(
        logitsPtr: UnsafePointer<Float>,
        vocabularySize: Int,
        maxLogit: Float,
        minimumProbability: Float,
        scratch: inout [Float]
    ) -> Bool {
        guard vocabularySize > 0, minimumProbability > 0, scratch.count == vocabularySize else {
            return false
        }
        var denominator: Float = 0
        var negativeMax = -maxLogit
        scratch.withUnsafeMutableBufferPointer { destination in
            guard let destinationBase = destination.baseAddress else { return }
            vDSP_vsadd(
                logitsPtr, 1,
                &negativeMax,
                destinationBase, 1,
                vDSP_Length(vocabularySize)
            )
            var count = Int32(vocabularySize)
            vvexpf(destinationBase, destinationBase, &count)
            vDSP_sve(destinationBase, 1, &denominator, vDSP_Length(vocabularySize))
        }
        return denominator.isFinite && denominator > 0 && (1 / denominator) >= minimumProbability
    }

    static func clearsProbabilityThreshold(
        logits: [Float],
        offset: Int,
        vocabularySize: Int,
        maxLogit: Float,
        minimumProbability: Float,
        scratch: inout [Float]
    ) -> Bool {
        guard vocabularySize > 0,
              minimumProbability > 0,
              offset >= 0,
              offset + vocabularySize <= logits.count,
              scratch.count == vocabularySize else {
            return false
        }
        return logits.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return false }
            return clearsProbabilityThresholdPointer(
                logitsPtr: base.advanced(by: offset),
                vocabularySize: vocabularySize,
                maxLogit: maxLogit,
                minimumProbability: minimumProbability,
                scratch: &scratch
            )
        }
    }

    static func officialCIFTokenTimestampsMs(
        usAlphas: [Float],
        usCifPeak: [Float],
        tokenCount: Int,
        maxDurationMs: Int,
        peakThreshold: Float = 1.0 - 1e-4,
        forceTimeShift: Float = -1.5,
        upsampleRate: Float = 3.0
    ) -> [Int] {
        guard tokenCount > 0, maxDurationMs > 0 else { return [] }
        let expectedFireCount = tokenCount + 1
        let timeRateMs = 10.0 * 6.0 / upsampleRate
        var firePlaces = cifFirePlaces(peaks: usCifPeak, threshold: peakThreshold, forceTimeShift: forceTimeShift)
        if firePlaces.count != expectedFireCount, !usAlphas.isEmpty {
            firePlaces = recomputedCIFFirePlaces(
                alphas: usAlphas, expectedFireCount: expectedFireCount,
                threshold: peakThreshold, forceTimeShift: forceTimeShift
            )
        }
        guard firePlaces.count >= 2 else {
            return (0...tokenCount).map { min(maxDurationMs, max(0, $0 * 60)) }
        }
        var out: [Int] = []
        out.reserveCapacity(min(expectedFireCount, firePlaces.count))
        for firePlace in firePlaces.prefix(expectedFireCount) {
            let ms = Int((firePlace * timeRateMs).rounded())
            out.append(min(maxDurationMs, max(0, ms)))
        }
        if out.count < expectedFireCount {
            let last = out.last ?? 0
            while out.count < expectedFireCount {
                out.append(min(maxDurationMs, last + (out.count - (firePlaces.count - 1)) * 60))
            }
        }
        return out
    }

    static func cifFirePlaces(
        peaks: [Float], threshold: Float = 1.0 - 1e-4, forceTimeShift: Float = -1.5
    ) -> [Float] {
        peaks.enumerated().compactMap { index, value in
            value >= threshold ? Float(index) + forceTimeShift : nil
        }
    }

    static func recomputedCIFFirePlaces(
        alphas: [Float], expectedFireCount: Int,
        threshold: Float = 1.0 - 1e-4, forceTimeShift: Float = -1.5
    ) -> [Float] {
        guard expectedFireCount > 0 else { return [] }
        let sum = alphas.reduce(Float(0), +)
        guard sum > 1e-6 else { return [] }
        let scale = Float(expectedFireCount) / sum
        var integrate: Float = 0
        var fires: [Float] = []
        fires.reserveCapacity(expectedFireCount)
        for (index, alpha) in alphas.enumerated() {
            integrate += alpha * scale
            if integrate >= threshold {
                fires.append(Float(index) + forceTimeShift)
                integrate -= threshold
            }
        }
        return fires
    }

    private static func tokenTimeMs(index: Int, tokenTimesMs: [Int], frameMs: Int) -> Int {
        if index >= 0, index < tokenTimesMs.count { return tokenTimesMs[index] }
        if let last = tokenTimesMs.last, index >= tokenTimesMs.count {
            return last + (index - tokenTimesMs.count + 1) * frameMs
        }
        return max(0, index * frameMs)
    }

    private static func characterTokens(text: String, startMs: Int, endMs: Int) -> [ASRToken] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        let duration = max(0, endMs - startMs)
        return characters.enumerated().map { index, character in
            let tokenStart = startMs + Int((Double(index) / Double(characters.count) * Double(duration)).rounded())
            let tokenEnd = startMs + Int((Double(index + 1) / Double(characters.count) * Double(duration)).rounded())
            return ASRToken(text: String(character), startMs: tokenStart, endMs: max(tokenStart, tokenEnd))
        }
    }
}
