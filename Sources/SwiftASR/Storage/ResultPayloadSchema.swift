import Foundation

// MARK: - Result JSON schema

/// Job-local mapping from a diarization label to a speaker profile.
public struct ResultSpeaker: Codable, Sendable, Equatable, Identifiable {
    public var speakerLabel: String
    public var speakerProfileId: String?
    /// Pipeline-owned identifier; it is not proof of a library identity.
    public var fingerprintId: String?

    public var id: String { speakerLabel }

    enum CodingKeys: String, CodingKey {
        case speakerLabel = "speaker_label"
        case speakerProfileId = "speaker_profile_id"
        case fingerprintId = "fingerprint_id"
    }

    public init(speakerLabel: String, speakerProfileId: String? = nil, fingerprintId: String? = nil) {
        self.speakerLabel = speakerLabel
        self.speakerProfileId = speakerProfileId
        self.fingerprintId = fingerprintId
    }
}

/// A contiguous, same-speaker group used by cleanup and export.
public struct MergedResult: Codable, Sendable, Identifiable, Equatable {
    public static let llmFailurePrefix = "⚠️"

    public static func llmFailureFallbackContent(rawContent: String) -> String {
        llmFailurePrefix + rawContent
    }

    public var mergeId: Int
    public var startMs: Int
    public var endMs: Int
    public var speakerLabel: String
    public var manualSpeakerLabel: String?
    public var rawContent: String
    public var cleanedContent: String
    public var wasLLMFailure: Bool

    public var id: Int { mergeId }
    public var effectiveSpeakerLabel: String {
        let manual = manualSpeakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return manual?.isEmpty == false ? manual! : speakerLabel
    }

    enum CodingKeys: String, CodingKey {
        case mergeId = "merge_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case speakerLabel = "speaker_label"
        case manualSpeakerLabel = "manual_speaker_label"
        case rawContent = "raw_content"
        case cleanedContent = "cleaned_content"
        case wasLLMFailure = "was_llm_failure"
    }

    public init(
        mergeId: Int,
        startMs: Int,
        endMs: Int,
        speakerLabel: String,
        manualSpeakerLabel: String? = nil,
        rawContent: String,
        cleanedContent: String = "",
        wasLLMFailure: Bool = false
    ) {
        self.mergeId = mergeId
        self.startMs = startMs
        self.endMs = endMs
        self.speakerLabel = speakerLabel
        self.manualSpeakerLabel = manualSpeakerLabel
        self.rawContent = rawContent
        self.cleanedContent = cleanedContent
        self.wasLLMFailure = wasLLMFailure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mergeId = try c.decode(Int.self, forKey: .mergeId)
        self.startMs = try c.decode(Int.self, forKey: .startMs)
        self.endMs = try c.decode(Int.self, forKey: .endMs)
        self.speakerLabel = try c.decode(String.self, forKey: .speakerLabel)
        self.manualSpeakerLabel = try c.decodeIfPresent(String.self, forKey: .manualSpeakerLabel)
        self.rawContent = try c.decode(String.self, forKey: .rawContent)
        self.cleanedContent = try c.decodeIfPresent(String.self, forKey: .cleanedContent) ?? ""
        self.wasLLMFailure = try c.decodeIfPresent(Bool.self, forKey: .wasLLMFailure) ?? false
    }
}

/// One atomic transcript turn. Raw fields are immutable from the result UI.
public struct ResultSegment: Codable, Sendable, Equatable {
    public var segmentId: Int
    public var startMs: Int
    public var endMs: Int
    public var speakerLabel: String
    public var includedInPreview: Bool
    public var rawText: String

    enum CodingKeys: String, CodingKey {
        case segmentId = "segment_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case speakerLabel = "speaker_label"
        case includedInPreview = "included_in_preview"
        case rawText = "raw_text"
    }

    public init(
        segmentId: Int,
        startMs: Int,
        endMs: Int,
        speakerLabel: String,
        includedInPreview: Bool = true,
        rawText: String
    ) {
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = endMs
        self.speakerLabel = speakerLabel
        self.includedInPreview = includedInPreview
        self.rawText = rawText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segmentId = try c.decode(Int.self, forKey: .segmentId)
        startMs = try c.decode(Int.self, forKey: .startMs)
        endMs = try c.decode(Int.self, forKey: .endMs)
        speakerLabel = try c.decode(String.self, forKey: .speakerLabel)
        includedInPreview = try c.decodeIfPresent(Bool.self, forKey: .includedInPreview) ?? true
        rawText = try c.decode(String.self, forKey: .rawText)
    }
}

// MARK: - Job-local speaker split schema

public struct SpeakerSplitDerivedSegment: Codable, Sendable, Equatable {
    public var segmentId: Int
    public var startMs: Int
    public var endMs: Int
    public var baselineSpeakerLabel: String
    public var speakerLabel: String
    public var includedInPreview: Bool
    public var rawText: String

    enum CodingKeys: String, CodingKey {
        case segmentId = "segment_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case baselineSpeakerLabel = "baseline_speaker_label"
        case speakerLabel = "speaker_label"
        case includedInPreview = "included_in_preview"
        case rawText = "raw_text"
    }

    public init(
        segmentId: Int,
        startMs: Int,
        endMs: Int,
        baselineSpeakerLabel: String,
        speakerLabel: String,
        includedInPreview: Bool = true,
        rawText: String
    ) {
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = endMs
        self.baselineSpeakerLabel = baselineSpeakerLabel
        self.speakerLabel = speakerLabel
        self.includedInPreview = includedInPreview
        self.rawText = rawText
    }

    public var effectiveSegment: ResultSegment {
        ResultSegment(
            segmentId: segmentId,
            startMs: startMs,
            endMs: endMs,
            speakerLabel: speakerLabel,
            includedInPreview: includedInPreview,
            rawText: rawText
        )
    }
}

public struct SpeakerSplitBaselineCleanup: Codable, Sendable, Equatable {
    public var status: String?
    public var completedAt: Date?
    public var model: String?
    public var processingSeconds: Double

    public init(status: String?, completedAt: Date?, model: String?, processingSeconds: Double) {
        self.status = status
        self.completedAt = completedAt
        self.model = model
        self.processingSeconds = processingSeconds
    }
}

public struct SpeakerSplitOperation: Codable, Sendable, Equatable {
    public var version: Int
    public var splitProfileLabels: [String]
    public var routingSnapshotVersion: Int
    public var routingSnapshotIdentity: String
    public var derivedAt: String
    public var derivedSegments: [SpeakerSplitDerivedSegment]
    public var derivedMergedResults: [MergedResult]
    public var baselineCleanup: SpeakerSplitBaselineCleanup?

    enum CodingKeys: String, CodingKey {
        case version
        case splitProfileLabels = "split_profile_labels"
        case routingSnapshotVersion = "routing_snapshot_version"
        case routingSnapshotIdentity = "routing_snapshot_identity"
        case derivedAt = "derived_at"
        case derivedSegments = "derived_segments"
        case derivedMergedResults = "derived_merged_results"
        case baselineCleanup = "baseline_cleanup"
    }

    public init(
        version: Int = 1,
        splitProfileLabels: [String],
        routingSnapshotVersion: Int,
        routingSnapshotIdentity: String,
        derivedAt: String,
        derivedSegments: [SpeakerSplitDerivedSegment],
        derivedMergedResults: [MergedResult],
        baselineCleanup: SpeakerSplitBaselineCleanup? = nil
    ) {
        self.version = version
        self.splitProfileLabels = Array(Set(splitProfileLabels)).sorted()
        self.routingSnapshotVersion = routingSnapshotVersion
        self.routingSnapshotIdentity = routingSnapshotIdentity
        self.derivedAt = derivedAt
        self.derivedSegments = derivedSegments
        self.derivedMergedResults = derivedMergedResults
        self.baselineCleanup = baselineCleanup
    }

    public var hasActiveSplit: Bool { !splitProfileLabels.isEmpty }
}
