import Foundation
import Testing
@testable import SwiftASR
@testable import CIFExperiments

/// Regression tests for the typed-error enums introduced / extended
/// during the codex audit P1.2 + P1 cleanup + 2026-07-26 NSError sweep.
/// Each enum (and each case) gets a test that asserts the case is
/// Error-typed + LocalizedError-typed and that errorDescription
/// matches the bit-for-bit equivalent of the prior NSError
/// userInfo[NSLocalizedDescriptionKey].  Future renames or case
/// deletions will trip these tests before they reach production.
@Suite struct TypedErrorEnumsTests {

    // MARK: - ASRInferenceError

    @Test func asrInferenceErrorShapeMismatch() {
        let e: Error = ASRInferenceError.shapeMismatch
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription == "ASR shape mismatch")
    }

    @Test func asrInferenceErrorInvalidBiasEmbeddingShape() {
        let e: Error = ASRInferenceError.invalidBiasEmbeddingShape
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription == "ASR bias embedding shape mismatch")
    }

    @Test func asrInferenceErrorMissingLogits() {
        let e: Error = ASRInferenceError.missingLogits
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription == "No output")
    }

    @Test func asrInferenceErrorEmptyLogits() {
        let e: Error = ASRInferenceError.emptyLogits
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription == "ASR logits output is empty")
    }

    @Test func asrInferenceErrorMissingHotwordEmbedding() {
        let e: Error = ASRInferenceError.missingHotwordEmbedding
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription == "SeACo embedding output hw_embed is missing")
    }

    @Test func asrInferenceErrorInvalidHotwordEmbeddingShape() {
        let e: Error = ASRInferenceError.invalidHotwordEmbeddingShape(valueCount: 0)
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription == "SeACo embedding shape is invalid: 0 values")
        let e2 = ASRInferenceError.invalidHotwordEmbeddingShape(valueCount: 13_440)
        #expect(e2.errorDescription == "SeACo embedding shape is invalid: 13440 values")
    }

    // MARK: - ASRInferenceError (round-3 M2-N1 extension)

    @Test func asrInferenceErrorInvalidCPUThreadCount() {
        let e: Error = ASRInferenceError.invalidCPUThreadCount(value: 0)
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription
                == "cpuIntraOpThreads must be positive (got 0)")
    }

    @Test func asrInferenceErrorInvalidXNNPackThreadCount() {
        let e: Error = ASRInferenceError.invalidXNNPackThreadCount(value: -1)
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription
                == "XNNPACK intra-op thread count must be positive (got -1)")
    }

    @Test func asrInferenceErrorInvalidInputContract() {
        let e: Error = ASRInferenceError.invalidInputContract(found: ["audio", "audio_lengths"])
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription
                == "ASR model input contract is invalid: [\"audio\", \"audio_lengths\"]")
    }

    @Test func asrInferenceErrorInvalidOutputContract() {
        let e: Error = ASRInferenceError.invalidOutputContract(found: ["hidden"])
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription
                == "ASR model output contract is invalid: [\"hidden\"]")
    }

    @Test func asrInferenceErrorInvalidOutputByteCount() {
        let e: Error = ASRInferenceError.invalidOutputByteCount(label: "logits", found: 13)
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription
                == "ASR logits output has invalid byte count: 13")
    }

    @Test func asrInferenceErrorInvalidTokenNumByteCount() {
        let e: Error = ASRInferenceError.invalidTokenNumByteCount(found: 5)
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription
                == "ASR token_num output has invalid byte count: 5")
    }

    @Test func asrInferenceErrorNonFiniteLogits() {
        let e: Error = ASRInferenceError.nonFiniteLogits(label: "us_cif_peak")
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription
                == "ASR us_cif_peak output contains non-finite values")
    }

    @Test func asrInferenceErrorMissingHotwordEmbeddingModel() {
        let e: Error = ASRInferenceError.missingHotwordEmbeddingModel(path: "/models/eb.onnx")
        #expect(e is ASRInferenceError)
        #expect((e as? ASRInferenceError)?.errorDescription
                == "Missing SeACo embedding model: /models/eb.onnx")
    }

    // MARK: - PuncInferenceError

    @Test func puncInferenceErrorInvalidInputContract() {
        let e: Error = PuncInferenceError.invalidInputContract(inputNames: ["speech", "text_lengths"])
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "Punc model input contract is invalid: [\"speech\", \"text_lengths\"]")
    }

    @Test func puncInferenceErrorMissingLogitsOutput() {
        let e: Error = PuncInferenceError.missingLogitsOutput(outputNames: ["hidden"])
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "Punc model is missing logits output: [\"hidden\"]")
    }

    @Test func puncInferenceErrorMissingLogits() {
        let e: Error = PuncInferenceError.missingLogits
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription == "no output")
    }

    // MARK: - PuncInferenceError (round-3 M2-N1 extension)

    @Test func puncInferenceErrorMissingUnknownToken() {
        let e: Error = PuncInferenceError.missingUnknownToken(vocabPath: "/models/punc/vocab.json")
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "Punc vocabulary is missing <unk>: /models/punc/vocab.json")
    }

    @Test func puncInferenceErrorLogitsShapeMismatch() {
        let e: Error = PuncInferenceError.logitsShapeMismatch(found: 100, expected: 105)
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "logits shape mismatch: count=100, expected 105")
    }

    @Test func puncInferenceErrorInvalidLogitsShape() {
        let e: Error = PuncInferenceError.invalidLogitsShape
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "Punc logits shape is invalid")
    }

    @Test func puncInferenceErrorNonFiniteLogits() {
        let e: Error = PuncInferenceError.nonFiniteLogits
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "Punc model returned non-finite logits")
    }

    @Test func puncInferenceErrorSessionInitFailed() {
        let e: Error = PuncInferenceError.sessionInitFailed(underlying: "ORT load failed")
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "Punc session init failed: ORT load failed")
    }

    @Test func puncInferenceErrorVocabularyLoadFailed() {
        let e: Error = PuncInferenceError.vocabularyLoadFailed(underlying: "JSON malformed")
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "Punc vocabulary load failed: JSON malformed")
    }

    @Test func puncInferenceErrorEmptyVocabulary() {
        let e: Error = PuncInferenceError.emptyVocabulary(path: "/empty/vocab.json")
        #expect(e is PuncInferenceError)
        #expect((e as? PuncInferenceError)?.errorDescription
                == "Punc vocabulary is empty: /empty/vocab.json")
    }

    // MARK: - VADInferenceError

    @Test func vadInferenceErrorMissingSpeechInput() {
        let e: Error = VADInferenceError.missingSpeechInput(inputNames: ["audio"])
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD model is missing speech input: [\"audio\"]")
    }

    @Test func vadInferenceErrorMissingLogitsOutput() {
        let e: Error = VADInferenceError.missingLogitsOutput(outputNames: ["state"])
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD model is missing logits output: [\"state\"]")
    }

    @Test func vadInferenceErrorIncompleteCacheContract() {
        let e: Error = VADInferenceError.incompleteCacheContract
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD model cache contract is incomplete")
    }

    @Test func vadInferenceErrorStreamMissingLogits() {
        let e: Error = VADInferenceError.streamMissingLogits
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD stream returned no logits")
    }

    // MARK: - VADInferenceError (round-3 M2-N1 extension)

    @Test func vadInferenceErrorStreamInputShapeMismatch() {
        let e: Error = VADInferenceError.streamInputShapeMismatch
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD stream input shape mismatch")
    }

    @Test func vadInferenceErrorLogitsShapeMismatch() {
        // VAD logits 期望宽度由 InferenceEngineConfig.VAD.expectedLogitWidth 决定 (248);
        // 2 frames × 248 = 496
        let e: Error = VADInferenceError.logitsShapeMismatch(framesCount: 2, found: 3)
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD logits shape mismatch: count=3, expected 496")
    }

    @Test func vadInferenceErrorCacheShapeMismatch() {
        let e: Error = VADInferenceError.cacheShapeMismatch(outputName: "cache_cnn_0", found: 100)
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD cache shape mismatch for cache_cnn_0: 100 bytes")
    }

    @Test func vadInferenceErrorMissingCacheOutput() {
        let e: Error = VADInferenceError.missingCacheOutput(name: "cache_lstm_1")
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD stream returned no cache: cache_lstm_1")
    }

    @Test func vadInferenceErrorNonFiniteLogits() {
        let e: Error = VADInferenceError.nonFiniteLogits
        #expect(e is VADInferenceError)
        #expect((e as? VADInferenceError)?.errorDescription
                == "VAD model returned non-finite logits")
    }

    // MARK: - AudioPipelineError (extended)

    @Test func audioPipelineErrorEnginesNotInitialized() {
        let e: Error = AudioPipelineError.enginesNotInitialized(modelsRoot: "/models/v3")
        #expect(e is AudioPipelineError)
        #expect((e as? AudioPipelineError)?.errorDescription
                == "Engine init failed. Check ONNX model paths in /models/v3.")
    }

    @Test func audioPipelineErrorSpeakerEngineNotInitialized() {
        let e1: Error = AudioPipelineError.speakerEngineNotInitialized(modelsRoot: "/models/v3")
        #expect((e1 as? AudioPipelineError)?.errorDescription
                == "Speaker engine init failed. Check ONNX model paths in /models/v3.")
        let e2: Error = AudioPipelineError.speakerEngineNotInitialized(modelsRoot: nil)
        #expect((e2 as? AudioPipelineError)?.errorDescription
                == "Speaker engine init failed.")
    }

    @Test func audioPipelineErrorFbankEmpty() {
        let e: Error = AudioPipelineError.fbankEmpty
        #expect(e is AudioPipelineError)
        #expect((e as? AudioPipelineError)?.errorDescription
                == "音频没有可提取的声学帧（需要至少 25ms 音频）。")
    }

    @Test func audioPipelineErrorFbankDimensionInvalid() {
        let e: Error = AudioPipelineError.fbankDimensionInvalid
        #expect(e is AudioPipelineError)
        #expect((e as? AudioPipelineError)?.errorDescription
                == "声学特征为空或维度损坏，无法重新识别说话人。")
    }

    // MARK: - AudioPipelineError (round-3 M2-N1 extension)

    @Test func audioPipelineErrorVadStreamingMetricsMissing() {
        let e: Error = AudioPipelineError.vadStreamingMetricsMissing
        #expect(e is AudioPipelineError)
        #expect((e as? AudioPipelineError)?.errorDescription
                == "VAD streaming producer returned no metrics")
    }

    @Test func audioPipelineErrorSpeakerFeatureWindowCountMismatch() {
        let e: Error = AudioPipelineError.speakerFeatureWindowCountMismatch(found: 8, expected: 16)
        #expect(e is AudioPipelineError)
        #expect((e as? AudioPipelineError)?.errorDescription
                == "Packed speaker feature preparation returned 8/16 windows.")
    }

    // MARK: - SpeakerCoreMLError (round-3 M2-N1 new)

    @Test func speakerCoreMLErrorModelPathMissing() {
        let e: Error = SpeakerCoreMLError.modelPathMissing(path: "/models/spk.mlmodelc")
        #expect(e is SpeakerCoreMLError)
        #expect((e as? SpeakerCoreMLError)?.errorDescription
                == "Speaker model path does not exist: /models/spk.mlmodelc")
    }

    @Test func speakerCoreMLErrorInvalidSeqLen() {
        let e: Error = SpeakerCoreMLError.invalidSeqLen(expected: 148, found: 200)
        #expect(e is SpeakerCoreMLError)
        #expect((e as? SpeakerCoreMLError)?.errorDescription
                == "Speaker model requires exactly 148 frames; got 200")
    }

    @Test func speakerCoreMLErrorInvalidFeatureSize() {
        let e: Error = SpeakerCoreMLError.invalidFeatureSize(found: 12_000, expected: 11_840)
        #expect(e is SpeakerCoreMLError)
        #expect((e as? SpeakerCoreMLError)?.errorDescription
                == "Speaker feature size mismatch: got 12000; expected 11840")
    }

    @Test func speakerCoreMLErrorInvalidBatchSize() {
        let e: Error = SpeakerCoreMLError.invalidBatchSize(expected: 16, found: 8)
        #expect(e is SpeakerCoreMLError)
        #expect((e as? SpeakerCoreMLError)?.errorDescription
                == "Expected 16 inputs, got 8")
    }

    @Test func speakerCoreMLErrorMissingEmbsOutput() {
        let e: Error = SpeakerCoreMLError.missingEmbsOutput
        #expect(e is SpeakerCoreMLError)
        #expect((e as? SpeakerCoreMLError)?.errorDescription
                == "Speaker model returned no embs output")
    }

    @Test func speakerCoreMLErrorInvalidEmbeddingCount() {
        let e: Error = SpeakerCoreMLError.invalidEmbeddingCount(found: 3_000, expected: 3_072)
        #expect(e is SpeakerCoreMLError)
        #expect((e as? SpeakerCoreMLError)?.errorDescription
                == "Speaker model returned 3000 values; expected 3072")
    }

    @Test func speakerCoreMLErrorNonFiniteEmbedding() {
        let e: Error = SpeakerCoreMLError.nonFiniteEmbedding
        #expect(e is SpeakerCoreMLError)
        #expect((e as? SpeakerCoreMLError)?.errorDescription
                == "Speaker model returned a non-finite embedding")
    }

    // MARK: - AudioConverterError (extended)

    @Test func audioConverterErrorFailedToCreateTargetFormat() {
        let e: Error = AudioConverterError.failedToCreateTargetFormat
        #expect(e is AudioConverterError)
        #expect((e as? AudioConverterError)?.errorDescription
                == "Failed to create target AVAudioFormat.")
    }

    @Test func audioConverterErrorFailedToInitializeConverter() {
        let e: Error = AudioConverterError.failedToInitializeConverter
        #expect(e is AudioConverterError)
        #expect((e as? AudioConverterError)?.errorDescription
                == "Failed to initialize AVAudioConverter.")
    }

    @Test func audioConverterErrorFailedToAllocateBuffers() {
        let e: Error = AudioConverterError.failedToAllocateBuffers
        #expect(e is AudioConverterError)
        #expect((e as? AudioConverterError)?.errorDescription
                == "Failed to allocate audio buffers.")
    }

    @Test func audioConverterErrorConversionError() {
        // R4-P2-6：conversionError 现在携带 underlying NSError?（debug metadata）。
        let e: Error = AudioConverterError.conversionError(underlying: nil)
        #expect(e is AudioConverterError)
        #expect((e as? AudioConverterError)?.errorDescription
                == "Conversion error.")
        // 带 underlying 的 round-trip。
        let nsErr = NSError(domain: "AVFoundation", code: -1)
        let e2: Error = AudioConverterError.conversionError(underlying: nsErr)
        if case let .conversionError(underlying) = e2 as? AudioConverterError {
            #expect(underlying?.code == -1)
        } else {
            Issue.record("expected .conversionError case")
        }
    }

    // MARK: - FbankExtractionError (extended)

    @Test func fbankExtractionErrorMissingAmMvnBlocks() {
        let e: Error = FbankExtractionError.missingAmMvnBlocks
        #expect(e is FbankExtractionError)
        #expect((e as? FbankExtractionError)?.errorDescription
                == "am.mvn missing <AddShift> or <Rescale> block")
    }

    // MARK: - ASRDecoderError (extended)

    @Test func asrDecoderErrorEmptyVocabulary() {
        let e: Error = ASRDecoderError.emptyVocabulary
        #expect(e is ASRDecoderError)
        #expect((e as? ASRDecoderError)?.errorDescription == "ASR vocabulary is empty")
    }

    // MARK: - ResultStoreError (extended)

    @Test func resultStoreErrorJsonRenderFailed() {
        let e: Error = ResultStoreError.jsonRenderFailed
        #expect(e is ResultStoreError)
        #expect((e as? ResultStoreError)?.errorDescription == "JSON render failed")
    }

    // MARK: - CIFPredictorWeightsError (new)

    @Test func cifPredictorWeightsErrorCifWeightsSizeMismatch() {
        let e: Error = CIFPredictorWeightsError.cifWeightsSizeMismatch(
            gotFloats: 786_000, expectedFloats: 787_457
        )
        #expect(e is CIFPredictorWeightsError)
        #expect((e as? CIFPredictorWeightsError)?.errorDescription
                == "cif_weights.bin size mismatch: got 786000 floats, expected 787457")
    }

    @Test func cifPredictorWeightsErrorAfterNormNpzTooSmall() {
        let e: Error = CIFPredictorWeightsError.afterNormNpzTooSmall
        #expect(e is CIFPredictorWeightsError)
        #expect((e as? CIFPredictorWeightsError)?.errorDescription
                == "after_norm npz too small")
    }

    // MARK: - GeminiKeyFailoverError (new)

    @Test func geminiKeyFailoverErrorNoEnabledKeys() {
        let e: Error = GeminiKeyFailoverError.noEnabledKeys
        #expect(e is GeminiKeyFailoverError)
        #expect((e as? GeminiKeyFailoverError)?.errorDescription
                == "没有启用的 Gemini Key。请到「设置」添加。")
    }

    // MARK: - GeminiProviderError (new)

    @Test func geminiProviderErrorInvalidURL() {
        let e: Error = GeminiProviderError.invalidURL
        #expect(e is GeminiProviderError)
        #expect((e as? GeminiProviderError)?.errorDescription == "Invalid URL")
    }

    @Test func geminiProviderErrorNoHTTPResponse() {
        let e: Error = GeminiProviderError.noHTTPResponse
        #expect(e is GeminiProviderError)
        #expect((e as? GeminiProviderError)?.errorDescription == "no http response")
    }

    @Test func geminiProviderErrorHttpErrorPreservesStatusWithoutBody() {
        let e: Error = GeminiProviderError.httpError(
            statusCode: 429,
            retryable: true,
            retryDelaySecs: 30.0,
            isRPD: true
        )
        #expect(e is GeminiProviderError)
        // R4-P2-3：响应体不再进入 typed error，避免 prompt 回显或敏感内容
        // 被后续日志/错误链意外保留；错误描述只保留 status code。
        #expect((e as? GeminiProviderError)?.errorDescription == "Gemini 429")
        // Round-trip the case fields used by GeminiKeyFailover cooldown
        if case let .httpError(code, retryable, delay, rpd) = e as! GeminiProviderError {
            #expect(code == 429)
            #expect(retryable == true)
            #expect(delay == 30.0)
            #expect(rpd == true)
        } else {
            Issue.record("expected .httpError case")
        }
    }

    @Test func geminiProviderErrorHttpErrorNon429HasNilDelay() {
        let e: Error = GeminiProviderError.httpError(
            statusCode: 503,
            retryable: true,
            retryDelaySecs: nil,
            isRPD: false
        )
        // R4-P2-3：errorDescription 不含响应体。
        #expect((e as? GeminiProviderError)?.errorDescription == "Gemini 503")
    }

    @Test func geminiProviderErrorParseResponseFailed() {
        let e: Error = GeminiProviderError.parseResponseFailed
        #expect(e is GeminiProviderError)
        #expect((e as? GeminiProviderError)?.errorDescription
                == "Failed to parse Gemini response")
    }

    @Test func geminiProviderErrorUnexpectedFinishReason() {
        let e: Error = GeminiProviderError.unexpectedFinishReason(reason: "MAX_TOKENS")
        #expect(e is GeminiProviderError)
        #expect((e as? GeminiProviderError)?.errorDescription
                == "Gemini response did not finish normally: MAX_TOKENS")
    }

    @Test func geminiProviderErrorMissingContentParts() {
        let e: Error = GeminiProviderError.missingContentParts
        #expect(e is GeminiProviderError)
        #expect((e as? GeminiProviderError)?.errorDescription
                == "Gemini response has no content parts")
    }

    @Test func geminiProviderErrorEmptyText() {
        let e: Error = GeminiProviderError.emptyText
        #expect(e is GeminiProviderError)
        #expect((e as? GeminiProviderError)?.errorDescription
                == "Gemini response contains no text")
    }

    @Test func geminiProviderErrorInvalidParagraphsJSON() {
        let e: Error = GeminiProviderError.invalidParagraphsJSON
        #expect(e is GeminiProviderError)
        #expect((e as? GeminiProviderError)?.errorDescription
                == "Gemini text is not valid JSON paragraphs")
    }

    // MARK: - isRateLimit / isServerOverload typed-error fast paths

    @Test func geminiProviderIsRateLimitAcceptsTypedError() {
        // 429 typed error should be rate-limited
        let e429: Error = GeminiProviderError.httpError(
            statusCode: 429, retryable: true,
            retryDelaySecs: 60.0, isRPD: false
        )
        #expect(GeminiProvider.isRateLimit(e429) == true)
        // 500 typed error should NOT be rate-limited (that's overload, not rate-limit)
        let e500: Error = GeminiProviderError.httpError(
            statusCode: 500, retryable: true,
            retryDelaySecs: nil, isRPD: false
        )
        #expect(GeminiProvider.isRateLimit(e500) == false)
        // parseResponseFailed is non-retryable; typed path returns false
        let eParse: Error = GeminiProviderError.parseResponseFailed
        #expect(GeminiProvider.isRateLimit(eParse) == false)
    }

    @Test func geminiProviderIsServerOverloadAcceptsTypedError() {
        // 5xx typed error is server overload
        let e503: Error = GeminiProviderError.httpError(
            statusCode: 503, retryable: true,
            retryDelaySecs: nil, isRPD: false
        )
        #expect(GeminiProvider.isServerOverload(e503) == true)
        // 529 typed error is server overload
        let e529: Error = GeminiProviderError.httpError(
            statusCode: 529, retryable: true,
            retryDelaySecs: nil, isRPD: false
        )
        #expect(GeminiProvider.isServerOverload(e529) == true)
        // 429 is rate-limit, NOT overload
        let e429: Error = GeminiProviderError.httpError(
            statusCode: 429, retryable: true,
            retryDelaySecs: 60.0, isRPD: false
        )
        #expect(GeminiProvider.isServerOverload(e429) == false)
        // parse failures are non-retryable
        let eParse: Error = GeminiProviderError.parseResponseFailed
        #expect(GeminiProvider.isServerOverload(eParse) == false)
    }

    @Test func geminiProviderStaticCheckersStillAcceptRawNSError() {
        // The PhaseTierFailoverTests use raw NSError objects. Make sure
        // the NSError fallback path in isRateLimit / isServerOverload
        // still works (the test suite imports GeminiProvider directly
        // and feeds NSError values, not typed errors).
        let ns429 = NSError(
            domain: "GeminiProvider", code: 429,
            userInfo: [NSLocalizedDescriptionKey: "rate limit"]
        )
        #expect(GeminiProvider.isRateLimit(ns429) == true)
        let ns503 = NSError(
            domain: "GeminiProvider", code: 503,
            userInfo: [NSLocalizedDescriptionKey: "high demand"]
        )
        #expect(GeminiProvider.isServerOverload(ns503) == true)
    }
}

// MARK: - R4-P2-6 / R4-P2-7 回归

@Test func audioConverterConversionErrorPreservesUnderlyingNSError() {
    // R4-P2-6：底层 AVAudioConverter error 作为 debug metadata 保留在 typed
    // case 里，不再裸冒泡。
    let nsErr = NSError(domain: "AVFoundationErrorDomain", code: -11800)
    let e = AudioConverterError.conversionError(underlying: nsErr)
    if case let .conversionError(underlying) = e {
        #expect(underlying?.code == -11800)
    } else {
        Issue.record("expected .conversionError case")
    }
}
