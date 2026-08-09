import Foundation

/// 用户人工编辑 result.json 中可变的 `merged_results.cleaned_content` 和
/// `manual_speaker_label`。原始 ASR 字段始终保持只读，保证重跑、
/// 说话人识别和诊断数据仍可复用。
enum ResultEditingService {
    /// 清除一个展示段落所包含的全部手工说话人 override。
    ///
    /// 展示层可能把多个相邻的 MergedResult 按有效人名合成一行，因此这里接受
    /// 一组 merge id，并恢复每个单元各自保留的自动 `speakerLabel`。正文和
    /// `cleanedContent` 不参与还原。
    static func clearingManualSpeakerAssignments(
        from source: ResultPayload,
        mergeIDs: [Int]
    ) -> ResultPayload? {
        let targetIDs = Set(mergeIDs)
        guard !targetIDs.isEmpty else { return nil }

        var payload = source
        if payload.speakerSplitOperation != nil {
            let matching = payload.speakerSplitOperation!.derivedMergedResults.indices.filter {
                targetIDs.contains(
                    payload.speakerSplitOperation!.derivedMergedResults[$0].mergeId
                ) && payload.speakerSplitOperation!.derivedMergedResults[$0].manualSpeakerLabel != nil
            }
            guard !matching.isEmpty else { return nil }
            for index in matching {
                payload.speakerSplitOperation!.derivedMergedResults[index].manualSpeakerLabel = nil
            }
            return payload
        }

        let matching = payload.mergedResults.indices.filter {
            targetIDs.contains(payload.mergedResults[$0].mergeId)
                && payload.mergedResults[$0].manualSpeakerLabel != nil
        }
        guard !matching.isEmpty else { return nil }
        for index in matching {
            payload.mergedResults[index].manualSpeakerLabel = nil
        }
        return payload
    }

    /// 返回更新后的 payload；merge id 不存在或文本为空时返回 nil，不写入半成品。
    static func applyingManualEdit(
        to source: ResultPayload,
        mergeId: Int,
        text: String,
        speakerLabel: String? = nil
    ) -> ResultPayload? {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return nil }
        let normalizedSpeakerLabel = speakerLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedSpeakerLabel {
            guard !normalizedSpeakerLabel.isEmpty else { return nil }
            let availableLabels = Set(
                source.speakers.map(\.speakerLabel)
                    + source.segments.map(\.speakerLabel)
                    + (source.speakerSplitOperation?.derivedSegments.map(\.speakerLabel) ?? [])
            )
            guard availableLabels.contains(normalizedSpeakerLabel) else { return nil }
        }

        var payload = source
        if payload.speakerSplitOperation != nil {
            // 人工编辑是当前操作层的润色数据，不得写回基线 merged_results。
            if payload.speakerSplitOperation!.derivedMergedResults.isEmpty {
                payload.speakerSplitOperation!.derivedMergedResults = SegmentMerger().buildMergedResults(
                    segments: ResultsPresentation.activeSegments(in: payload)
                )
            }
            guard let index = payload.speakerSplitOperation!.derivedMergedResults.firstIndex(where: {
                $0.mergeId == mergeId
            }) else { return nil }
            let target = payload.speakerSplitOperation!.derivedMergedResults[index]
            let shouldWriteText = normalizedSpeakerLabel == nil
                || target.wasLLMFailure
                || !target.cleanedContent.isEmpty
                || cleanedText != target.rawContent
            if shouldWriteText {
                for offset in payload.speakerSplitOperation!.derivedMergedResults.indices
                where payload.speakerSplitOperation!.derivedMergedResults[offset].cleanedContent.isEmpty {
                    payload.speakerSplitOperation!.derivedMergedResults[offset].cleanedContent =
                        payload.speakerSplitOperation!.derivedMergedResults[offset].rawContent
                }
                payload.speakerSplitOperation!.derivedMergedResults[index].cleanedContent = cleanedText
                payload.speakerSplitOperation!.derivedMergedResults[index].wasLLMFailure = false
            }
            if let normalizedSpeakerLabel {
                let automatic = payload.speakerSplitOperation!.derivedMergedResults[index].speakerLabel
                payload.speakerSplitOperation!.derivedMergedResults[index].manualSpeakerLabel =
                    normalizedSpeakerLabel == automatic ? nil : normalizedSpeakerLabel
            }
            return payload
        }
        if payload.mergedResults.isEmpty {
            payload.buildMergedResults()
        }
        guard let index = payload.mergedResults.firstIndex(where: { $0.mergeId == mergeId }) else {
            return nil
        }

        let target = payload.mergedResults[index]
        let shouldWriteText = normalizedSpeakerLabel == nil
            || target.wasLLMFailure
            || !target.cleanedContent.isEmpty
            || cleanedText != target.rawContent
        if shouldWriteText {
            // 编辑的是“当前预览”的一部分。未由 LLM 或用户改过的段落以原文作为
            // cleaned_content 的初始值，使导出永远完整且可继续逐段修改。
            for offset in payload.mergedResults.indices
            where payload.mergedResults[offset].cleanedContent.isEmpty {
                payload.mergedResults[offset].cleanedContent =
                    payload.mergedResults[offset].rawContent
            }
            payload.mergedResults[index].cleanedContent = cleanedText
            payload.mergedResults[index].wasLLMFailure = false
        }
        if let normalizedSpeakerLabel {
            let automatic = payload.mergedResults[index].speakerLabel
            payload.mergedResults[index].manualSpeakerLabel =
                normalizedSpeakerLabel == automatic ? nil : normalizedSpeakerLabel
        }
        return payload
    }
}
