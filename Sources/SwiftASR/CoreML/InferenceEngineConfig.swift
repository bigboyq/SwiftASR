import Foundation

/// Centralised tunables for ASR / VAD / Speaker inference engines.
///
/// Before 2026-07-26 each engine exposed its own `static let` for tunable
/// constants (`ASRONNXEngine.noBiasToken`, `VADONNXEngine.cacheCount`, etc.).
/// These were not duplicated, but the lack of a single index made it hard
/// to find every "how is this knob set" site.  F6.7 groups them here.
///
/// Each engine class also keeps a `static let` re-export pointing at this
/// config (e.g. `VADONNXEngine.cacheCount == InferenceEngineConfig.VAD.cacheCount`),
/// so existing callers — including regression tests like
/// `OfficialVADParityTests.cacheCount` — keep working.  New code should
/// read from `InferenceEngineConfig` directly.
///
/// `nonisolated(unsafe)` not needed: this is an immutable, frozen value
/// table (all `static let` in an `enum` are inherently thread-safe).
public enum InferenceEngineConfig {

    /// ASR (SeACo-Paraformer) hotword / bias token layout.
    public enum ASR {
        /// Sentinel token id used as the no-bias first entry in the
        /// hotword embedding table.  Matches the SeACo-Paraformer ONNX
        /// model's bias-token convention.
        public static let noBiasToken: Int32 = 8377

        /// Maximum number of hotword tokens in a single batch.
        /// Drives the [1, hotwordTokenLimit] tensor shape sent to the
        /// hotword-embedding ONNX session.
        public static let hotwordTokenLimit: Int = 10
    }

    /// VAD (FSMN-VAD) input contract and cache layout.
    public enum VAD {
        /// Expected fbank feature dim for the FSMN-VAD input.  80-dim
        /// fbank stacked 5x = 400.
        public static let expectedFeatureDim: Int = 400

        /// Expected per-frame logit width (number of context frames the
        /// FSMN block aggregates).
        public static let expectedLogitWidth: Int = 248

        /// FSMN-VAD cache tensor shape: [batch, channels, history_frames, 1].
        /// 19 = `lorder=20` minus 1 (the model uses 19 frames of history).
        public static let cacheShape: [NSNumber] = [1, 128, 19, 1]

        /// Number of in/out cache pairs the FSMN-VAD ONNX session
        /// consumes / produces.  Drives the dynamic `in_cacheN` /
        /// `out_cacheN` input / output name generation.
        public static let cacheCount: Int = 4
    }

    /// Speaker (ERes2NetV2 batch-16 CoreML) inference batch size.
    public enum Speaker {
        /// Preferred inference batch size.  Matches
        /// `Models/speaker/model_batch16.mlmodelc` and the production
        /// pipeline's window planner.  Tied to the MLModel's fixed
        /// batch=16 input shape; changing this requires re-exporting
        /// the .mlmodelc with the new batch size.
        public static let preferredBatchSize: Int = 16
    }
}
