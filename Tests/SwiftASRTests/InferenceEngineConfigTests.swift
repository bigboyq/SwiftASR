import Testing
import Foundation
@testable import SwiftASR

/// Regression tests for `InferenceEngineConfig` (F6.7 central tunables index).
///
/// These tests lock the centralised values so a future "let me change this
/// constant" edit can't silently drift a knob.  Each engine class also keeps
/// a `static let` re-export pointing at the same values, so the
/// `Self.X == InferenceEngineConfig.Y.X` invariants are tested here too.
@Suite struct InferenceEngineConfigTests {

    @Test func asrNoBiasTokenMatchesSeACoConvention() {
        // Sentinel token id for "no bias" first entry in the hotword
        // embedding table.  Matches the SeACo-Paraformer ONNX model's
        // bias-token convention.
        #expect(InferenceEngineConfig.ASR.noBiasToken == 8377)
    }

    @Test func asrHotwordTokenLimitMatchesONNXSession() {
        // Drives the [1, hotwordTokenLimit] tensor shape sent to the
        // hotword-embedding ONNX session.
        #expect(InferenceEngineConfig.ASR.hotwordTokenLimit == 10)
    }

    @Test func vadExpectedFeatureDimMatchesFbankStack() {
        // 80-dim fbank stacked 5x = 400.
        #expect(InferenceEngineConfig.VAD.expectedFeatureDim == 400)
    }

    @Test func vadExpectedLogitWidthMatchesFSMNBlock() {
        #expect(InferenceEngineConfig.VAD.expectedLogitWidth == 248)
    }

    @Test func vadCacheShapeMatchesFSMNLorder() {
        // 19 = lorder=20 minus 1 (model uses 19 frames of history).
        let shape = InferenceEngineConfig.VAD.cacheShape.map { $0.intValue }
        #expect(shape == [1, 128, 19, 1])
    }

    @Test func vadCacheCountMatchesInOutCachePairCount() {
        #expect(InferenceEngineConfig.VAD.cacheCount == 4)
    }

    @Test func speakerPreferredBatchSizeMatchesModelExport() {
        // Tied to Models/speaker/model_batch16.mlmodelc.
        #expect(InferenceEngineConfig.Speaker.preferredBatchSize == 16)
    }

    // Re-export invariants: each engine's static let must equal the
    // central config, so existing tests (e.g. OfficialVADParityTests
    // asserting VADONNXEngine.cacheCount == 4) keep passing AND the
    // central config is the single source of truth.
    //
    // Note: `ASRONNXEngine.noBiasToken` / `.hotwordTokenLimit` are
    // `private static let`; VADONNXEngine.expectedFeatureDim /
    // expectedLogitWidth are `fileprivate static let` — none are
    // re-export-testable from this module.  Only the internal / public
    // constants can be tested directly here:
    //   - VADONNXEngine.cacheCount, .cacheShape (`static let`, internal)
    //   - SpeakerNativeCoreMLEngine.preferredBatchSize (`public static let`)
    @Test func vadEngineReExportsMatchConfig() {
        #expect(VADONNXEngine.cacheCount == InferenceEngineConfig.VAD.cacheCount)
        #expect(VADONNXEngine.cacheShape.count == InferenceEngineConfig.VAD.cacheShape.count)
    }

    @Test func speakerEngineReExportsMatchConfig() {
        #expect(SpeakerNativeCoreMLEngine.preferredBatchSize
                == InferenceEngineConfig.Speaker.preferredBatchSize)
    }
}
