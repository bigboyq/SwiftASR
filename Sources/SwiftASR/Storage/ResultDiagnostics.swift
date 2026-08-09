import Foundation

// 2026-07-26 P2 F5.3: speaker-only diagnostics 块从 ResultData.swift
// 抽出。3 个 struct（SpeakerDiarizationDiagnostics /
// SpeakerTemporalWaterfallDiagnostic / SpeakerTokenEvidenceDiagnostic）
// 都跟 result.json 主 schema 无关，是独立 sidecar 文件
// (`.speaker-diagnostics.json`) 的 schema，IO 路径在
// ResultStore.writeSpeakerDiagnostics / readSpeakerDiagnostics。
// 抽出来 result.json 主 schema 文件能少 100 行，也更明确
// "这是 sidecar schema" 的边界。

/// Persisted speaker-only diagnostics for the L1+L2+UtteranceBuilder
/// pipeline.  2026-07-26: Viterbi / DecisionTree removed; the per-token
/// Viterbi score fields were dropped in the 2026-07-26 P1.3 cleanup.
public struct SpeakerDiarizationDiagnostics: Codable, Sendable {
    public let version: Int
    public let temporalWaterfall: SpeakerTemporalWaterfallDiagnostic

    public init(
        version: Int = 7,
        temporalWaterfall: SpeakerTemporalWaterfallDiagnostic
    ) {
        self.version = version
        self.temporalWaterfall = temporalWaterfall
    }
}

/// Compact temporal summary for replay and regression reports. Full score vectors
/// remain in the speaker sidecar/experiment output rather than result.json.
///
/// 2026-07-26 audit: `temporalCount` is now optional and always nil.  The
/// Viterbi / DecisionTree path that populated it is gone; the field is
/// kept (Optional, default nil) so old diagnostics JSON files still
/// decode via the explicit `init(from:)` below.
public struct SpeakerTemporalWaterfallDiagnostic: Codable, Sendable {
    public let windowCount: Int
    public let profileCount: Int
    public let directCount: Int
    /// Always nil after 2026-07-26.  Kept for backward-compat decoding of
    /// pre-removal diagnostics files.
    public let temporalCount: Int?
    public let otherCount: Int
    public let unresolvedCount: Int
    public let tokenEvidence: [SpeakerTokenEvidenceDiagnostic]

    enum CodingKeys: String, CodingKey {
        case windowCount, profileCount, directCount, temporalCount
        case otherCount, unresolvedCount, tokenEvidence
    }

    public init(
        windowCount: Int, profileCount: Int, directCount: Int,
        otherCount: Int, unresolvedCount: Int,
        tokenEvidence: [SpeakerTokenEvidenceDiagnostic] = []
    ) {
        self.windowCount = windowCount
        self.profileCount = profileCount
        self.directCount = directCount
        self.temporalCount = nil
        self.otherCount = otherCount
        self.unresolvedCount = unresolvedCount
        self.tokenEvidence = tokenEvidence
    }

    /// Backward-compat decoder: tolerates old diagnostics files that
    /// include a `temporalCount` integer (the field is ignored but
    /// decoding must not fail).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.windowCount = try c.decode(Int.self, forKey: .windowCount)
        self.profileCount = try c.decode(Int.self, forKey: .profileCount)
        self.directCount = try c.decode(Int.self, forKey: .directCount)
        self.temporalCount = try c.decodeIfPresent(Int.self, forKey: .temporalCount)
        self.otherCount = try c.decode(Int.self, forKey: .otherCount)
        self.unresolvedCount = try c.decode(Int.self, forKey: .unresolvedCount)
        self.tokenEvidence = try c.decodeIfPresent(
            [SpeakerTokenEvidenceDiagnostic].self, forKey: .tokenEvidence
        ) ?? []
    }
}

public struct SpeakerTokenEvidenceDiagnostic: Codable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let scores: [Int: Float]
    public let decisionLabel: Int?
    public let decisionSource: String?
    /// L1 per-token label (the sentence-level router's per-token
    /// projection, before L2 rescue).  Used for diff-comparing the
    /// current L1+L2 pipeline against earlier per-token-only snapshots.
    public let baselineLabel: Int?
    /// L1 per-token disposition (`direct`, `deferred`, `other`, …).
    public let baselineRoute: String?

    public init(
        startMs: Int,
        endMs: Int,
        scores: [Int: Float],
        decisionLabel: Int?,
        decisionSource: String?,
        baselineLabel: Int? = nil,
        baselineRoute: String? = nil
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.scores = scores
        self.decisionLabel = decisionLabel
        self.decisionSource = decisionSource
        self.baselineLabel = baselineLabel
        self.baselineRoute = baselineRoute
    }
}
