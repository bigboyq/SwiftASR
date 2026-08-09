import Foundation

/// Validation failures are part of the persisted result boundary. Keeping the
/// error taxonomy beside the validation implementation makes schema changes
/// discoverable without inflating the result envelope type file.
public enum ResultPayloadValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyJobID
    case jobIDMismatch(expected: String, actual: String)
    case duplicateSegmentID(Int)
    case invalidSegmentTime(segmentID: Int, startMs: Int, endMs: Int)
    case emptySpeakerLabel(segmentID: Int)
    case duplicateSpeakerLabel(String)
    case duplicateMergeID(Int)
    case invalidMergedResultTime(mergeID: Int, startMs: Int, endMs: Int)
    case invalidMergedResultSpeakerLabel(mergeID: Int, label: String)
    case invalidManualSpeakerLabel(mergeID: Int, label: String?)
    case unsupportedSplitOperationVersion(Int)
    case invalidSplitProfileLabel
    case duplicateSplitProfileLabel(String)
    case splitProfileLabelNotInBaseline(String)
    case invalidRoutingSnapshot(version: Int, identity: String)
    case emptyDerivedSegments
    case duplicateDerivedSegmentID(Int)
    case invalidDerivedSegmentTime(segmentID: Int, startMs: Int, endMs: Int)
    case emptyDerivedSpeakerLabel(segmentID: Int)
    case overlappingDerivedSegments(previousSegmentID: Int, segmentID: Int)
    case derivedSegmentBaselineMismatch(segmentID: Int)
    case incompleteDerivedBaselineSegment(segmentID: Int)
    case derivedSegmentRawTextMismatch(segmentID: Int)
    case changedFrozenDerivedSpeakerLabel(segmentID: Int)
    case duplicateDerivedMergeID(Int)
    case invalidDerivedMergeTime(mergeID: Int, startMs: Int, endMs: Int)
    case invalidDerivedMergedStructure
    case invalidBaselineCleanupSeconds(Double)

    public var errorDescription: String? {
        switch self {
        case .emptyJobID:
            return "result.json 缺少 job_id。"
        case let .jobIDMismatch(expected, actual):
            return "result.json 的 job_id 不匹配：期望 \(expected)，实际 \(actual)。"
        case let .duplicateSegmentID(id):
            return "result.json 包含重复的 segment_id：\(id)。"
        case let .invalidSegmentTime(id, start, end):
            return "segment \(id) 的时间范围无效：\(start)-\(end)ms。"
        case let .emptySpeakerLabel(id):
            return "segment \(id) 缺少 speaker_label。"
        case let .duplicateSpeakerLabel(label):
            return "result.json 包含重复的 speaker_label：\(label)。"
        case let .duplicateMergeID(id):
            return "result.json 包含重复的 merge_id：\(id)。"
        case let .invalidMergedResultTime(id, start, end):
            return "merged result \(id) 的时间范围无效：\(start)-\(end)ms。"
        case let .invalidMergedResultSpeakerLabel(id, label):
            return "merged result \(id) 的 speaker_label 无效或不属于当前任务：\(label)。"
        case let .invalidManualSpeakerLabel(id, label):
            return "merged result \(id) 的 manual_speaker_label 无效或不属于当前任务：\(label ?? "nil")。"
        case let .unsupportedSplitOperationVersion(version):
            return "不支持的 speaker split operation 版本：\(version)。"
        case .invalidSplitProfileLabel:
            return "speaker split operation 包含空的 profile label。"
        case let .duplicateSplitProfileLabel(label):
            return "speaker split operation 包含重复 profile label：\(label)。"
        case let .splitProfileLabelNotInBaseline(label):
            return "speaker split operation 的 profile label 不在基线结果中：\(label)。"
        case let .invalidRoutingSnapshot(version, identity):
            return "speaker split routing snapshot 无效：v\(version)，identity=\(identity)。"
        case .emptyDerivedSegments:
            return "启用 speaker split operation 时派生句段不能为空。"
        case let .duplicateDerivedSegmentID(id):
            return "speaker split operation 包含重复 derived segment_id：\(id)。"
        case let .invalidDerivedSegmentTime(id, start, end):
            return "derived segment \(id) 的时间范围无效：\(start)-\(end)ms。"
        case let .emptyDerivedSpeakerLabel(id):
            return "derived segment \(id) 缺少说话人标签。"
        case let .overlappingDerivedSegments(previousID, id):
            return "derived segment \(previousID) 与 \(id) 的时间范围重叠或顺序错误。"
        case let .derivedSegmentBaselineMismatch(id):
            return "derived segment \(id) 无法唯一对应到基线句段。"
        case let .incompleteDerivedBaselineSegment(id):
            return "基线 segment \(id) 未被派生句段完整覆盖。"
        case let .derivedSegmentRawTextMismatch(id):
            return "基线 segment \(id) 的派生 raw_text 与原文不一致。"
        case let .changedFrozenDerivedSpeakerLabel(id):
            return "derived segment \(id) 改写了 Split Set 外的说话人归属。"
        case let .duplicateDerivedMergeID(id):
            return "speaker split operation 包含重复 derived merge_id：\(id)。"
        case let .invalidDerivedMergeTime(id, start, end):
            return "derived merged result \(id) 的时间范围无效：\(start)-\(end)ms。"
        case .invalidDerivedMergedStructure:
            return "speaker split operation 的派生合并段与派生句段不一致。"
        case let .invalidBaselineCleanupSeconds(seconds):
            return "speaker split baseline cleanup 时长无效：\(seconds)。"
        }
    }
}

public extension ResultPayload {
    /// Validates the persisted result boundary without mutating it.
    ///
    /// The phases deliberately follow the JSON dependency order: identity,
    /// baseline timeline, baseline merges, then the optional split projection.
    func validate(expectedJobID: String? = nil) throws {
        try validateIdentity(expectedJobID: expectedJobID)
        let availableLabels = try validateBaseline()
        try validateBaselineMergedResults(availableLabels: availableLabels)
        if let split = speakerSplitOperation {
            try validateSplitOperation(split, baselineAvailableLabels: availableLabels)
        }
    }
}

private extension ResultPayload {
    func validateIdentity(expectedJobID: String?) throws {
        guard !jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResultPayloadValidationError.emptyJobID
        }
        if let expectedJobID, expectedJobID != jobId {
            throw ResultPayloadValidationError.jobIDMismatch(expected: expectedJobID, actual: jobId)
        }
    }

    func validateBaseline() throws -> Set<String> {
        var segmentIDs = Set<Int>()
        for segment in segments {
            guard segmentIDs.insert(segment.segmentId).inserted else {
                throw ResultPayloadValidationError.duplicateSegmentID(segment.segmentId)
            }
            guard segment.startMs >= 0, segment.endMs >= segment.startMs else {
                throw ResultPayloadValidationError.invalidSegmentTime(
                    segmentID: segment.segmentId,
                    startMs: segment.startMs,
                    endMs: segment.endMs
                )
            }
            guard !segment.speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ResultPayloadValidationError.emptySpeakerLabel(segmentID: segment.segmentId)
            }
        }

        var speakerLabels = Set<String>()
        for speaker in speakers {
            guard speakerLabels.insert(speaker.speakerLabel).inserted else {
                throw ResultPayloadValidationError.duplicateSpeakerLabel(speaker.speakerLabel)
            }
        }
        return speakerLabels.union(Set(segments.map(\.speakerLabel)))
    }

    func validateBaselineMergedResults(availableLabels: Set<String>) throws {
        var mergeIDs = Set<Int>()
        for merged in mergedResults {
            guard mergeIDs.insert(merged.mergeId).inserted else {
                throw ResultPayloadValidationError.duplicateMergeID(merged.mergeId)
            }
            guard merged.startMs >= 0, merged.endMs >= merged.startMs else {
                throw ResultPayloadValidationError.invalidMergedResultTime(
                    mergeID: merged.mergeId,
                    startMs: merged.startMs,
                    endMs: merged.endMs
                )
            }
            try validateSpeakerLabels(for: merged, availableLabels: availableLabels)
        }
    }

    func validateSplitOperation(
        _ split: SpeakerSplitOperation,
        baselineAvailableLabels: Set<String>
    ) throws {
        let splitLabels = try validateSplitMetadata(split)
        let derivedByBaselineID = try validateDerivedSegments(
            split,
            splitLabels: splitLabels
        )
        try validateDerivedCoverage(split, derivedByBaselineID: derivedByBaselineID)
        try validateDerivedMergedResults(
            split,
            baselineAvailableLabels: baselineAvailableLabels
        )
        try validateBaselineCleanup(split.baselineCleanup)
    }

    func validateSplitMetadata(_ split: SpeakerSplitOperation) throws -> Set<String> {
        guard split.version == 1 else {
            throw ResultPayloadValidationError.unsupportedSplitOperationVersion(split.version)
        }

        var splitLabels = Set<String>()
        let baselineSegmentLabels = Set(segments.map(\.speakerLabel))
        for label in split.splitProfileLabels {
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw ResultPayloadValidationError.invalidSplitProfileLabel
            }
            guard splitLabels.insert(label).inserted else {
                throw ResultPayloadValidationError.duplicateSplitProfileLabel(label)
            }
            guard baselineSegmentLabels.contains(label) else {
                throw ResultPayloadValidationError.splitProfileLabelNotInBaseline(label)
            }
        }
        guard split.routingSnapshotVersion > 0,
              !split.routingSnapshotIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ResultPayloadValidationError.invalidRoutingSnapshot(
                version: split.routingSnapshotVersion,
                identity: split.routingSnapshotIdentity
            )
        }
        if split.hasActiveSplit, split.derivedSegments.isEmpty {
            throw ResultPayloadValidationError.emptyDerivedSegments
        }
        return splitLabels
    }

    func validateDerivedSegments(
        _ split: SpeakerSplitOperation,
        splitLabels: Set<String>
    ) throws -> [Int: [SpeakerSplitDerivedSegment]] {
        var derivedSegmentIDs = Set<Int>()
        var previousDerivedSegment: SpeakerSplitDerivedSegment?
        var derivedSegmentsByBaselineID: [Int: [SpeakerSplitDerivedSegment]] = [:]

        // One monotonic cursor per label preserves the original
        // O(baseline + derived) matching behavior.
        let baselineSegmentsByLabel = Dictionary(grouping: segments, by: \.speakerLabel)
        var baselineCursorByLabel: [String: Int] = [:]
        for segment in split.derivedSegments {
            guard derivedSegmentIDs.insert(segment.segmentId).inserted else {
                throw ResultPayloadValidationError.duplicateDerivedSegmentID(segment.segmentId)
            }
            guard segment.startMs >= 0, segment.endMs >= segment.startMs else {
                throw ResultPayloadValidationError.invalidDerivedSegmentTime(
                    segmentID: segment.segmentId,
                    startMs: segment.startMs,
                    endMs: segment.endMs
                )
            }
            guard !segment.speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !segment.baselineSpeakerLabel
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ResultPayloadValidationError.emptyDerivedSpeakerLabel(
                    segmentID: segment.segmentId
                )
            }
            if let previousDerivedSegment, segment.startMs < previousDerivedSegment.endMs {
                throw ResultPayloadValidationError.overlappingDerivedSegments(
                    previousSegmentID: previousDerivedSegment.segmentId,
                    segmentID: segment.segmentId
                )
            }
            previousDerivedSegment = segment

            guard let matchingBaselines = baselineSegmentsByLabel[segment.baselineSpeakerLabel]
            else {
                throw ResultPayloadValidationError.derivedSegmentBaselineMismatch(
                    segmentID: segment.segmentId
                )
            }
            var baselineCursor = baselineCursorByLabel[segment.baselineSpeakerLabel, default: 0]
            while baselineCursor < matchingBaselines.count,
                  matchingBaselines[baselineCursor].endMs < segment.endMs {
                baselineCursor += 1
            }
            guard baselineCursor < matchingBaselines.count else {
                throw ResultPayloadValidationError.derivedSegmentBaselineMismatch(
                    segmentID: segment.segmentId
                )
            }
            let baseline = matchingBaselines[baselineCursor]
            guard baseline.startMs <= segment.startMs, segment.endMs <= baseline.endMs else {
                throw ResultPayloadValidationError.derivedSegmentBaselineMismatch(
                    segmentID: segment.segmentId
                )
            }
            if matchingBaselines.indices.contains(baselineCursor + 1) {
                let next = matchingBaselines[baselineCursor + 1]
                guard next.startMs > segment.startMs || next.endMs < segment.endMs else {
                    throw ResultPayloadValidationError.derivedSegmentBaselineMismatch(
                        segmentID: segment.segmentId
                    )
                }
            }
            baselineCursorByLabel[segment.baselineSpeakerLabel] =
                segment.endMs == baseline.endMs ? baselineCursor + 1 : baselineCursor
            if !splitLabels.contains(segment.baselineSpeakerLabel),
               segment.speakerLabel != segment.baselineSpeakerLabel {
                throw ResultPayloadValidationError.changedFrozenDerivedSpeakerLabel(
                    segmentID: segment.segmentId
                )
            }
            derivedSegmentsByBaselineID[baseline.segmentId, default: []].append(segment)
        }
        return derivedSegmentsByBaselineID
    }

    func validateDerivedCoverage(
        _ split: SpeakerSplitOperation,
        derivedByBaselineID: [Int: [SpeakerSplitDerivedSegment]]
    ) throws {
        guard split.hasActiveSplit else { return }
        for baseline in segments {
            guard let partition = derivedByBaselineID[baseline.segmentId],
                  partition.first?.startMs == baseline.startMs,
                  partition.last?.endMs == baseline.endMs
            else {
                throw ResultPayloadValidationError.incompleteDerivedBaselineSegment(
                    segmentID: baseline.segmentId
                )
            }
            guard partition.map(\.rawText).joined() == baseline.rawText else {
                throw ResultPayloadValidationError.derivedSegmentRawTextMismatch(
                    segmentID: baseline.segmentId
                )
            }
        }
    }

    func validateDerivedMergedResults(
        _ split: SpeakerSplitOperation,
        baselineAvailableLabels: Set<String>
    ) throws {
        var mergeIDs = Set<Int>()
        let availableLabels = baselineAvailableLabels.union(
            Set(split.derivedSegments.map(\.speakerLabel))
        )
        for merged in split.derivedMergedResults {
            guard mergeIDs.insert(merged.mergeId).inserted else {
                throw ResultPayloadValidationError.duplicateDerivedMergeID(merged.mergeId)
            }
            guard merged.startMs >= 0, merged.endMs >= merged.startMs else {
                throw ResultPayloadValidationError.invalidDerivedMergeTime(
                    mergeID: merged.mergeId,
                    startMs: merged.startMs,
                    endMs: merged.endMs
                )
            }
            try validateSpeakerLabels(for: merged, availableLabels: availableLabels)
        }
        guard split.hasActiveSplit else { return }

        let expected = SegmentMerger().buildMergedResults(
            segments: split.derivedSegments.map(\.effectiveSegment)
        )
        guard expected.count == split.derivedMergedResults.count else {
            throw ResultPayloadValidationError.invalidDerivedMergedStructure
        }
        for (expected, actual) in zip(expected, split.derivedMergedResults) {
            guard expected.mergeId == actual.mergeId,
                  expected.startMs == actual.startMs,
                  expected.endMs == actual.endMs,
                  expected.speakerLabel == actual.speakerLabel,
                  expected.rawContent == actual.rawContent
            else {
                throw ResultPayloadValidationError.invalidDerivedMergedStructure
            }
        }
    }

    func validateBaselineCleanup(_ cleanup: SpeakerSplitBaselineCleanup?) throws {
        guard let cleanup else { return }
        guard cleanup.processingSeconds.isFinite, cleanup.processingSeconds >= 0 else {
            throw ResultPayloadValidationError.invalidBaselineCleanupSeconds(
                cleanup.processingSeconds
            )
        }
    }

    func validateSpeakerLabels(
        for merged: MergedResult,
        availableLabels: Set<String>
    ) throws {
        guard !merged.speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              availableLabels.contains(merged.speakerLabel)
        else {
            throw ResultPayloadValidationError.invalidMergedResultSpeakerLabel(
                mergeID: merged.mergeId,
                label: merged.speakerLabel
            )
        }
        if let manualSpeakerLabel = merged.manualSpeakerLabel {
            let normalized = manualSpeakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized == manualSpeakerLabel,
                  availableLabels.contains(normalized)
            else {
                throw ResultPayloadValidationError.invalidManualSpeakerLabel(
                    mergeID: merged.mergeId,
                    label: manualSpeakerLabel
                )
            }
        }
    }
}
