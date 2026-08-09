import Foundation

public struct DisplaySegment: Identifiable, Equatable {
    public var id: String { "\(segmentId)" }
    public var segmentId: Int
    public var startMs: Int
    public var endMs: Int
    public var displaySpeakerName: String
    public var speakerLabelSuffix: String?
    public var text: String
    public var sourceSegmentIDs: [Int]
    /// 当前段落的有效 speakerLabel（Speaker1/Speaker2...）。
    /// 跟 displaySpeakerName 区别：displaySpeakerName 是绑定 Person 后的名字，
    /// speakerLabel 仍用于筛选、跳转和展示编号后缀。
    public var speakerLabel: String
    /// 操作层分拆前的说话人编号。仅逐句原文使用：例如 `S2 → S5`。
    /// nil 表示基线结果或归属没有变化，保持原有展示。
    public var baselineSpeakerLabel: String?

    /// A display row backed by more than one persisted `MergedResult` is a
    /// presentation-only collapse. Its text cannot be edited safely because
    /// restoring speaker assignments must reveal each source's original text.
    public var hasSingleSource: Bool { sourceSegmentIDs.count == 1 }

    public init(
        segmentId: Int,
        startMs: Int,
        endMs: Int,
        displaySpeakerName: String,
        speakerLabelSuffix: String? = nil,
        text: String,
        sourceSegmentIDs: [Int]? = nil,
        speakerLabel: String,
        baselineSpeakerLabel: String? = nil
    ) {
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = endMs
        self.displaySpeakerName = displaySpeakerName
        self.speakerLabelSuffix = speakerLabelSuffix
        self.text = text
        self.sourceSegmentIDs = sourceSegmentIDs ?? [segmentId]
        self.speakerLabel = speakerLabel
        self.baselineSpeakerLabel = baselineSpeakerLabel
    }
}

public final class SegmentMerger {
    public init() {}
    
    /// 从 ResultSegment 构建展示列表。
    ///
    /// 逐句原文固定走这条路径：每个 ASR 段独立显示，不再暴露额外合并策略。
    public func buildDisplaySegments(
        segments: [ResultSegment],
        speakerNames: [String: String] = [:]
    ) -> [DisplaySegment] {
        guard !segments.isEmpty else { return [] }
        let display = segments.map { seg -> DisplaySegment in
            let name = speakerNames[seg.speakerLabel]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displaySpeakerName = (name?.isEmpty == false) ? name! : seg.speakerLabel
            let suffix: String?
            if name?.isEmpty == false && name != seg.speakerLabel {
                suffix = "(\(seg.speakerLabel))"
            } else {
                suffix = nil
            }
            return DisplaySegment(
                segmentId: seg.segmentId,
                startMs: seg.startMs,
                endMs: seg.endMs,
                displaySpeakerName: displaySpeakerName,
                speakerLabelSuffix: suffix,
                text: seg.rawText,
                speakerLabel: seg.speakerLabel
            )
        }
        return display
    }

    public func joinParagraphTexts(_ texts: [String]) -> String {
        let joinSkipTrailing: Set<Character> = ["，", "。", "、", ".", "?", "!", "？", "！", "：", ":", "；", ";", ",", " "]
        let paragraphTerminators: Set<Character> = ["。", "？", "?", "！", "!"]
        
        var parts: [String] = []
        for t in texts {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if !parts.isEmpty {
                let prev = parts.last!.trimmingCharacters(in: .whitespaces)
                if let lastChar = prev.last, !joinSkipTrailing.contains(lastChar) {
                    parts.append("，")
                }
            }
            parts.append(trimmed)
        }
        
        var joined = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty { return "" }
        if let lastChar = joined.last, !paragraphTerminators.contains(lastChar) {
            joined.append("。")
        }
        return joined
    }

    // MARK: - MergedResult 构建（持久化版）

    /// 从 segments 构建 MergedResult 列表（rawContent only，cleanedContent = ""）。
    /// 合并规则：连续相同 speakerLabel 的 segment 为一组。显示名称绝不能参与
    /// LLM 单位的划分，否则两个 SpeakerN 被命名为同一人时会意外混入同一段。
    public func buildMergedResults(segments: [ResultSegment]) -> [MergedResult] {
        guard !segments.isEmpty else { return [] }
        var results: [MergedResult] = []
        var currentGroup: [ResultSegment] = []
        var currentSpeaker = ""
        var mergeId = 1

        func flush() {
            guard !currentGroup.isEmpty else { return }
            let first = currentGroup.first!
            let last  = currentGroup.last!
            let raw = joinParagraphTexts(currentGroup.map { $0.rawText })
            results.append(MergedResult(
                mergeId: mergeId,
                startMs: first.startMs,
                endMs:   last.endMs,
                speakerLabel: currentSpeaker,
                rawContent:  raw
            ))
            mergeId += 1
            currentGroup = []
        }

        for seg in segments {
            let speaker = seg.speakerLabel
            if currentGroup.isEmpty {
                currentGroup.append(seg); currentSpeaker = speaker
            } else if speaker == currentSpeaker {
                currentGroup.append(seg)
            } else {
                flush()
                currentGroup = [seg]; currentSpeaker = speaker
            }
        }
        flush()
        return results
    }

    /// Rebuilding cleanup units intentionally clears old cleaned text, but a
    /// paragraph-level speaker correction is separate user-authored metadata
    /// and must survive a Gemini restart when the automatic merge structure
    /// is unchanged.
    public func buildMergedResults(
        segments: [ResultSegment],
        preservingManualAssignmentsFrom existing: [MergedResult]
    ) -> [MergedResult] {
        var rebuilt = buildMergedResults(segments: segments)
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.mergeId, $0) })
        for index in rebuilt.indices {
            guard let previous = existingByID[rebuilt[index].mergeId],
                  previous.startMs == rebuilt[index].startMs,
                  previous.endMs == rebuilt[index].endMs,
                  previous.speakerLabel == rebuilt[index].speakerLabel,
                  previous.rawContent == rebuilt[index].rawContent
            else { continue }
            rebuilt[index].manualSpeakerLabel = previous.manualSpeakerLabel
        }
        return rebuilt
    }

    // MARK: - MergedResult → DisplaySegment（展示层）

    /// 从 MergedResult 构建展示列表。
    /// 有 cleanedContent 则显示 cleanedContent，否则显示 rawContent。
    ///
    /// 合并原文和润色稿固定按 `displaySpeakerName` 合并：跨 MergedResult
    /// 边界只要当前有效人名相同，就显示为一个连续段落。
    public func buildDisplaySegments(
        mergedResults: [MergedResult],
        speakerNames: [String: String] = [:],
        showRawText: Bool = false
    ) -> [DisplaySegment] {
        let display = mergedResults.map { mr in
            let text = showRawText ? mr.rawContent : mr.cleanedContent
            let effectiveLabel = mr.effectiveSpeakerLabel
            let name = speakerNames[effectiveLabel]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (name?.isEmpty == false) ? name! : effectiveLabel
            return DisplaySegment(
                segmentId: mr.mergeId,
                startMs:   mr.startMs,
                endMs:     mr.endMs,
                displaySpeakerName: displayName,
                speakerLabelSuffix: displayName == effectiveLabel ? nil : "(\(effectiveLabel))",
                text: text,
                sourceSegmentIDs: [mr.mergeId],
                speakerLabel: effectiveLabel
            )
        }
        return mergeDisplaySegmentsByName(display)
    }

    private func mergeDisplaySegmentsByName(_ segments: [DisplaySegment]) -> [DisplaySegment] {
        guard !segments.isEmpty else { return [] }
        var result: [DisplaySegment] = []
        var group: [DisplaySegment] = []
        func flush() {
            guard let first = group.first else { return }
            let labels = group.map(\.speakerLabel).uniqueElements()
            result.append(DisplaySegment(
                segmentId: first.segmentId,
                startMs: first.startMs,
                endMs: group.last!.endMs,
                displaySpeakerName: first.displaySpeakerName,
                speakerLabelSuffix: labels.count == 1 && labels[0] == first.displaySpeakerName
                    ? nil
                    : "(\(labels.joined(separator: ", ")))",
                text: joinParagraphTexts(group.map(\.text)),
                sourceSegmentIDs: group.flatMap(\.sourceSegmentIDs).uniqueElements(),
                speakerLabel: first.speakerLabel
            ))
            group = []
        }
        for segment in segments {
            // group.isEmpty 时 short-circuit 避免 group[0] 越界
            if group.isEmpty || group[0].displaySpeakerName == segment.displaySpeakerName {
                group.append(segment)
            } else {
                flush(); group = [segment]
            }
        }
        flush()
        return result
    }
}

extension Array where Element: Hashable {
    func uniqueElements() -> [Element] {
        var seen = Set<Element>()
        var result: [Element] = []
        result.reserveCapacity(count)
        for element in self where seen.insert(element).inserted {
                result.append(element)
        }
        return result
    }
}
