import Foundation

struct ResultsProjection {
    let activeSegments: [ResultSegment]
    let speakerPanelLabels: [String]
    let speakerDurations: [String: Int]
    let speakerNames: [String: String]
    let uniqueNamedSpeakerCount: Int
    let displaySegments: [DisplaySegment]
}

/// 结果页的纯展示/派生计算。
///
/// 不读取 SwiftUI state、不写 SwiftData 或 result.json，因此列表、导出和信息卡可复用
/// 同一套过滤和合并规则。
enum ResultsPresentation {
    static func projection(
        payload: ResultPayload,
        includedLabels: Set<String>,
        showMerged: Bool,
        showRawText: Bool,
        speakerNames: [String: String]
    ) -> ResultsProjection {
        let segments = activeSegments(in: payload)
        let panelLabels = Array(Set(
            payload.segments.map(\.speakerLabel)
                + payload.speakers.map(\.speakerLabel)
                + segments.map(\.speakerLabel)
        )).sorted()
        var durations: [String: Int] = [:]
        for segment in segments {
            durations[segment.speakerLabel, default: 0] += max(segment.endMs - segment.startMs, 0)
        }
        let uniqueCount = Set(Array(Set(segments.map(\.speakerLabel))).map { label in
            if let name = speakerNames[label], !name.isEmpty { return name }
            return "__unbound__:\(label)"
        }).count
        let complete = hasCompleteCleanedResults(in: payload)
        let display = segmentList(
            payload: payload,
            includedLabels: includedLabels,
            showMerged: showMerged,
            showRawText: showRawText,
            hasCompleteCleanedResults: complete,
            speakerNames: speakerNames
        )
        return ResultsProjection(
            activeSegments: segments,
            speakerPanelLabels: panelLabels,
            speakerDurations: durations,
            speakerNames: speakerNames,
            uniqueNamedSpeakerCount: uniqueCount,
            displaySegments: display
        )
    }

    /// 操作层存在时，结果页所有“当前结果”都以派生句为准；基线 `segments`
    /// 永远不改写，供取消分拆和重新计算使用。
    static func activeSegments(in payload: ResultPayload) -> [ResultSegment] {
        guard let operation = payload.speakerSplitOperation else { return payload.segments }
        return operation.derivedSegments.map {
            ResultSegment(
                segmentId: $0.segmentId,
                startMs: $0.startMs,
                endMs: $0.endMs,
                speakerLabel: $0.speakerLabel,
                includedInPreview: $0.includedInPreview,
                rawText: $0.rawText
            )
        }
    }

    static func activeMergedResults(in payload: ResultPayload) -> [MergedResult] {
        payload.speakerSplitOperation?.derivedMergedResults ?? payload.mergedResults
    }

    static func hasCompleteCleanedResults(in payload: ResultPayload) -> Bool {
        let mergedResults = activeMergedResults(in: payload)
        guard !mergedResults.isEmpty else { return false }
        return mergedResults.allSatisfy {
            !$0.cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func baselineSpeakerLabelBySegmentID(in payload: ResultPayload) -> [Int: String] {
        guard let operation = payload.speakerSplitOperation else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: operation.derivedSegments.compactMap { segment in
                segment.baselineSpeakerLabel == segment.speakerLabel
                    ? nil
                    : (segment.segmentId, segment.baselineSpeakerLabel)
            }
        )
    }

    static func distinctSpeakerLabels(in payload: ResultPayload) -> [String] {
        Array(Set(activeSegments(in: payload).map(\.speakerLabel))).sorted()
    }

    /// 左侧 Profile 面板必须保留基线 Profile：当一个被分拆的 Profile 的所有
    /// 句子都已转给其他人时，它仍需可见，用户才能单击取消分拆。
    static func speakerPanelLabels(in payload: ResultPayload) -> [String] {
        let baseline = payload.segments.map(\.speakerLabel)
        let mapped = payload.speakers.map(\.speakerLabel)
        let effective = activeSegments(in: payload).map(\.speakerLabel)
        return Array(Set(baseline + mapped + effective)).sorted()
    }

    static func speakerDurations(in payload: ResultPayload) -> [String: Int] {
        var durations: [String: Int] = [:]
        for segment in activeSegments(in: payload) {
            durations[segment.speakerLabel, default: 0] += max(segment.endMs - segment.startMs, 0)
        }
        return durations
    }

    static func effectiveAudioSeconds(in payload: ResultPayload) -> Int {
        activeSegments(in: payload).reduce(0) { $0 + max($1.endMs - $1.startMs, 0) } / 1_000
    }

    static func uniqueNamedSpeakerCount(
        payload: ResultPayload,
        nameByLabel: [String: String]
    ) -> Int {
        Set(distinctSpeakerLabels(in: payload).map { label in
            if let name = nameByLabel[label], !name.isEmpty { return name }
            return "__unbound__:\(label)"
        }).count
    }

    static func segmentList(
        payload: ResultPayload,
        includedLabels: Set<String>,
        showMerged: Bool,
        showRawText: Bool,
        hasCompleteCleanedResults: Bool,
        speakerNames: [String: String]
    ) -> [DisplaySegment] {
        let segments = activeSegments(in: payload)
        let mergedResults = activeMergedResults(in: payload)
        guard showMerged else {
            // 逐句原文：按自动识别的说话人编号展示，每个 ASR 段保持独立。
            var display = SegmentMerger().buildDisplaySegments(
                segments: segments.filter { includedLabels.contains($0.speakerLabel) },
                speakerNames: speakerNames
            )
            let baselineByID = baselineSpeakerLabelBySegmentID(in: payload)
            for index in display.indices {
                display[index].baselineSpeakerLabel = baselineByID[display[index].segmentId]
            }
            return display
        }
        guard showRawText || hasCompleteCleanedResults else { return [] }
        return SegmentMerger().buildDisplaySegments(
            mergedResults: mergedResults.filter {
                includedLabels.contains($0.effectiveSpeakerLabel)
            },
            speakerNames: speakerNames,
            showRawText: showRawText
        )
    }

    static func speakerNameMap(
        payload: ResultPayload?,
        profiles: [SpeakerProfile]
    ) -> [String: String] {
        guard let payload else { return [:] }
        let ids = Set(payload.speakers.compactMap(\.speakerProfileId))
        var namesByID: [String: String] = [:]
        for profile in profiles where ids.contains(profile.id) {
            guard let name = profile.person?.name, !name.isEmpty else { continue }
            namesByID[profile.id] = name
        }
        var result: [String: String] = [:]
        for speaker in payload.speakers {
            guard let id = speaker.speakerProfileId, let name = namesByID[id] else { continue }
            result[speaker.speakerLabel] = name
        }
        return result
    }
}

/// Disk/JSON portion of result loading. It is deliberately value-only and
/// `Sendable`, allowing `ResultsContent` to keep large file reads and decoding
/// away from the main actor. SwiftData hydration remains on the main actor.
enum ResultsPayloadLoader {
    enum Outcome: Sendable {
        case success(ResultPayload)
        case failure(message: String, diagnostic: String)
    }

    nonisolated static func load(jobID: String, storedPath: String?) -> Outcome {
        do {
            let path = try ResultStore.readPath(jobId: jobID, storedPath: storedPath)
            let payload = try ResultStore.read(from: path)
            try payload.validate(expectedJobID: jobID)
            return .success(payload)
        } catch {
            return .failure(
                message: "无法加载结果：\(error.localizedDescription)",
                diagnostic: String(describing: error)
            )
        }
    }
}
