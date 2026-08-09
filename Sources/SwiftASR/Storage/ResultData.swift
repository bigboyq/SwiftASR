import Foundation

/// The persisted result.json envelope. Schema leaf types live in
/// `ResultPayloadSchema.swift`; validation lives in `ResultPayloadValidation.swift`.
/// Keeping this facade type in its historical file preserves all public symbols
/// and keeps result assembly separate from the wire schema definitions.
public struct ResultPayload: Codable, Sendable {
    public var jobId: String
    public var audioPath: String
    public var segments: [ResultSegment]
    public var speakers: [ResultSpeaker]
    public var finishedAt: String?
    public var cleanedModel: String?
    public var mergedResults: [MergedResult]
    public var speakerSplitOperation: SpeakerSplitOperation?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case audioPath = "audio_path"
        case segments
        case speakers
        case finishedAt = "finished_at"
        case cleanedModel = "cleaned_model"
        case mergedResults = "merged_results"
        case speakerSplitOperation = "speaker_split_operation"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        audioPath = try c.decode(String.self, forKey: .audioPath)
        segments = try c.decode([ResultSegment].self, forKey: .segments)
        speakers = try c.decodeIfPresent([ResultSpeaker].self, forKey: .speakers) ?? []
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        cleanedModel = try c.decodeIfPresent(String.self, forKey: .cleanedModel)
        mergedResults = try c.decodeIfPresent([MergedResult].self, forKey: .mergedResults) ?? []
        speakerSplitOperation = try c.decodeIfPresent(
            SpeakerSplitOperation.self,
            forKey: .speakerSplitOperation
        )
    }

    public init(
        jobId: String,
        audioPath: String,
        segments: [ResultSegment],
        speakers: [ResultSpeaker] = [],
        finishedAt: String? = nil,
        cleanedModel: String? = nil,
        mergedResults: [MergedResult] = [],
        speakerSplitOperation: SpeakerSplitOperation? = nil
    ) {
        self.jobId = jobId
        self.audioPath = audioPath
        self.segments = segments
        self.speakers = speakers
        self.finishedAt = finishedAt
        self.cleanedModel = cleanedModel
        self.mergedResults = mergedResults
        self.speakerSplitOperation = speakerSplitOperation
    }

    /// Rebuild merged results from the current atomic segments.
    public mutating func buildMergedResults() {
        mergedResults = SegmentMerger().buildMergedResults(segments: segments)
    }

    public func speakerProfileId(for label: String) -> String? {
        speakers.first(where: { $0.speakerLabel == label })?.speakerProfileId
    }

    public func fingerprintId(for label: String) -> String? {
        speakers.first(where: { $0.speakerLabel == label })?.fingerprintId
    }

    public mutating func setSpeakerProfileId(_ profileId: String?, for label: String) {
        if let index = speakers.firstIndex(where: { $0.speakerLabel == label }) {
            speakers[index].speakerProfileId = profileId
        } else {
            speakers.append(ResultSpeaker(speakerLabel: label, speakerProfileId: profileId))
        }
    }

    public static func from(utterances: [UtteranceData], audioPath: String, jobId: String) -> ResultPayload {
        // Persist atomic turns so the true time boundaries remain available to
        // the result editor and are not hidden by display-time merging.
        var segments: [ResultSegment] = []
        var nextId = 1
        for utterance in utterances {
            let text = utterance.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            segments.append(ResultSegment(
                segmentId: nextId,
                startMs: utterance.startMs,
                endMs: utterance.endMs,
                speakerLabel: utterance.speakerLabel,
                rawText: text
            ))
            nextId += 1
        }
        let speakers = Array(Set(segments.map(\.speakerLabel))).sorted().map {
            ResultSpeaker(speakerLabel: $0)
        }
        return ResultPayload(
            jobId: jobId,
            audioPath: audioPath,
            segments: segments,
            speakers: speakers,
            finishedAt: ResultStore.nowIso()
        )
    }

    /// Build a partial result when ASR + punctuation completed but speaker
    /// recognition failed. The schema remains identical to a successful result.
    public static func partialFromSpeakerInput(
        _ input: SpeakerRecognitionInput,
        jobId: String
    ) -> ResultPayload {
        var segments: [ResultSegment] = []
        var nextId = 1
        for sentence in input.sentences {
            let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            segments.append(ResultSegment(
                segmentId: nextId,
                startMs: sentence.startMs,
                endMs: sentence.endMs,
                speakerLabel: "Speaker1",
                rawText: text
            ))
            nextId += 1
        }
        return ResultPayload(
            jobId: jobId,
            audioPath: input.audioPath,
            segments: segments,
            speakers: [ResultSpeaker(speakerLabel: "Speaker1", speakerProfileId: nil)],
            finishedAt: ResultStore.nowIso()
        )
    }

    /// Replace raw turns after speaker-only reidentification. Downstream
    /// cleanup and split state is invalidated because the source turns changed.
    public mutating func replaceSegmentsWithSpeakerTurns(
        from utterances: [UtteranceData]
    ) -> Bool {
        guard !utterances.isEmpty,
              segments.map(\.rawText).joined() == utterances.map(\.rawText).joined()
        else { return false }

        segments = ResultPayload.from(
            utterances: utterances,
            audioPath: audioPath,
            jobId: jobId
        ).segments
        speakers = Array(Set(segments.map(\.speakerLabel))).sorted().map {
            ResultSpeaker(speakerLabel: $0)
        }
        cleanedModel = nil
        mergedResults = []
        speakerSplitOperation = nil
        finishedAt = ResultStore.nowIso()
        return true
    }
}

// ResultStore and the file-side transaction types intentionally remain in
// their dedicated Storage files. This file is the small schema facade.
