import SwiftData
import SwiftUI

/// Read-only preview projection and speaker-navigation behaviour for the
/// result workspace. `ResultsContent` owns state; this extension turns that
/// state into renderable rows without mixing it with editing or cleanup.
extension ResultsContent {
    func activeSegments(_ payload: ResultPayload) -> [ResultSegment] {
        ResultsPresentation.activeSegments(in: payload)
    }

    func activeMergedResults(_ payload: ResultPayload?) -> [MergedResult] {
        guard let payload else { return [] }
        return ResultsPresentation.activeMergedResults(in: payload)
    }

    func buildSegmentList(payload: ResultPayload) -> [DisplaySegment] {
        ResultsPresentation.segmentList(
            payload: payload,
            includedLabels: inScopeLabels,
            showMerged: showMerged,
            showRawText: showRawText,
            hasCompleteCleanedResults: hasCompleteCleanedResults(payload),
            speakerNames: speakerNameMap(payload)
        )
    }

    func speakerNameMap(_ payload: ResultPayload?) -> [String: String] {
        guard payload?.jobId == viewState.activeJobID else { return [:] }
        return viewState.speakerNames
    }

    func loadProfilesForPresentation() -> [SpeakerProfile] {
        do {
            let profiles = try SpeakerProfileRepository.fetchAll(in: modelContext)
            matchIndex.update(profiles: profiles)
            return profiles
        } catch {
            Logger.shared.error("无法加载说话人展示数据：\(error)")
            return []
        }
    }

    func jumpToNextSpeaker(_ label: String, in payload: ResultPayload) {
        let source: [(id: Int, label: String)]
        if showMerged, !activeMergedResults(payload).isEmpty {
            source = activeMergedResults(payload)
                .filter { inScopeLabels.contains($0.effectiveSpeakerLabel) }
                .map { ($0.mergeId, $0.effectiveSpeakerLabel) }
        } else {
            source = activeSegments(payload)
                .filter { inScopeLabels.contains($0.speakerLabel) }
                .map { ($0.segmentId, $0.speakerLabel) }
        }
        let matching = source.enumerated().compactMap { $0.element.label == label ? $0.offset : nil }
        guard !matching.isEmpty else { return }
        let cursor = speakerScrollCursors[label] ?? 0
        let sourceID = source[matching[cursor % matching.count]].id
        let displaySegments = buildSegmentList(payload: payload)
        guard let displaySegment = displaySegments.first(where: {
            $0.sourceSegmentIDs.contains(sourceID)
        }) else { return }
        scrollTargetId = displaySegment.id
        speakerScrollCursors[label] = cursor + 1
    }
}

// MARK: - SwiftUI workbench layout

extension ResultsContent {
    @ViewBuilder
    func contentView(payload: ResultPayload) -> some View {
        // One projection feeds the header, speaker panel, export button and
        // list. This prevents repeated full-array mapping/merging during one
        // SwiftUI body evaluation.
        let projection = ResultsPresentation.projection(
            payload: payload,
            includedLabels: inScopeLabels,
            showMerged: showMerged,
            showRawText: showRawText,
            speakerNames: speakerNameMap(payload)
        )
        let allPersonNames = allPersons.map { $0.name }.sorted()
        VStack(spacing: 0) {
            // 顶部：文件名 + JobInfoCard + reidentify error banner
            // 拆到 `ResultsContentHeader` sub-view（2026-07-22）
            ResultsContentHeader(
                payload: payload,
                currentJob: currentJob,
                uniqueNamedSpeakers: projection.uniqueNamedSpeakerCount
            )

            Divider()

            ResultsContentToolbar(
                isCleanupRunning: coordinator.activeCleanupJobId != nil,
                hasCleanedResults: hasCleanedResults(payload),
                canStartCleanup: !projection.activeSegments.isEmpty && hasUsableApiKey,
                cleanupButtonTooltip: cleanupButtonTooltip,
                previewMode: previewMode,
                showSpeakerIDs: showSpeakerIDsBinding,
                showTimestamps: showTimestampsBinding,
                isCleanupDialogPresented: showCleanupDialogBinding,
                hasExportableContent: !projection.activeSegments.isEmpty
                    && !projection.displaySegments.isEmpty,
                onPreviewModeChange: applyPreviewMode,
                onExport: { exportText(payload: payload, displaySegments: projection.displaySegments) }
            )

            Divider()

            ResultsContentSpeakerArea(
                payload: payload,
                projection: projection,
                allPersonNames: allPersonNames,
                inScopeLabels: inScopeLabelsBinding,
                suggestions: suggestions,
                splitProfileLabels: Set(payload.speakerSplitOperation?.splitProfileLabels ?? []),
                splittableProfileLabels: splitCoordinator.splittableProfileLabels,
                profileCohesions: profileCohesions,
                splitPreviewTooltips: splitPreviewTooltips,
                showSpeakerIDs: showSpeakerIDs,
                showTimestamps: showTimestamps,
                showMerged: showMerged,
                previewContentVersion: previewContentVersion,
                scrollTargetId: Binding(
                    get: { scrollTargetId },
                    set: { scrollTargetId = $0 }
                ),
                onToggleIncluded: { label, included in
                    toggleIncluded(label: label, included: included)
                },
                onSetAllIncluded: { included in
                    setAllIncluded(included)
                },
                onAttemptToggleSplitProfileIncluded: { label in
                    splitProfileSelectionAlertLabel = label
                },
                onToggleSplitProfile: { label in
                    toggleSplitProfile(label: label)
                },
                onSelectPerson: { label, personName in
                    selectPerson(label: label, personName: personName)
                },
                onRequestCreatePerson: { label in
                    createPersonTargetLabel = label
                },
                onJumpToNext: { label in
                    jumpToNextSpeaker(label, in: payload)
                },
                onRestoreSpeaker: { ids in
                    _ = restoreManualSpeakerAssignments(mergeIDs: ids)
                },
                onEdit: { beginManualEdit(mergeId: $0) }
            )
        }
        // R4-P2-10：原来用 `.onAppear` + `DispatchQueue.main.async`，快速切换
        // job 时旧 hop 仍会执行并覆盖新 job 的状态。改用 `.task(id:)` 绑定到
        // 当前 payload 的 jobId，切换时 SwiftUI 自动取消旧的 task。
        .task(id: payload.jobId) {
            applyInitialPresentationState(payload: payload, projection: projection)
        }
    }

    /// Applies compatibility defaults after the layout is installed. Keeping
    /// this callback out of the view tree prevents the main body from mixing
    /// one-time state migration with its rendering branches.
    private func applyInitialPresentationState(
        payload: ResultPayload,
        projection: ResultsProjection
    ) {
        // 兼容旧 result.json：没有勾选状态时默认 in-scope = 全部
        if inScopeLabels.isEmpty {
            inScopeLabels = defaultInScopeLabels(for: payload)
            if inScopeLabels.isEmpty { inScopeLabels = Set(projection.speakerPanelLabels) }
        }
        // 未润色时只允许原始显示，避免一进页就出现错误状态。
        if !hasCompleteCleanedResults(payload) {
            showRawText = true
        }
    }

}

private struct ResultsContentToolbar: View {
    let isCleanupRunning: Bool
    let hasCleanedResults: Bool
    let canStartCleanup: Bool
    let cleanupButtonTooltip: String
    let previewMode: ResultsPreviewMode
    @Binding var showSpeakerIDs: Bool
    @Binding var showTimestamps: Bool
    @Binding var isCleanupDialogPresented: Bool
    let hasExportableContent: Bool
    let onPreviewModeChange: (ResultsPreviewMode) -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: AppLayout.itemSpacing) {
            Button {
                isCleanupDialogPresented = true
            } label: {
                if isCleanupRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("润色", systemImage: "sparkles")
                }
            }
            .modifier(CleanupButtonStyle(hasCleanedResults: hasCleanedResults))
            .disabled(isCleanupRunning || !canStartCleanup)
            .help(cleanupButtonTooltip)

            Picker("内容模式", selection: Binding(
                get: { previewMode },
                set: { mode in onPreviewModeChange(mode) }
            )) {
                ForEach(ResultsPreviewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Menu {
                Toggle("显示说话人 ID", isOn: $showSpeakerIDs)
                Toggle("显示时间戳", isOn: $showTimestamps)
            } label: {
                Label("显示", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)

            Spacer(minLength: AppLayout.itemSpacing)

            Button(action: onExport) {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(!hasExportableContent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct ResultsContentSpeakerArea: View {
    let payload: ResultPayload
    let projection: ResultsProjection
    let allPersonNames: [String]
    @Binding var inScopeLabels: Set<String>
    let suggestions: [String: SpeakerSuggestion]
    let splitProfileLabels: Set<String>
    let splittableProfileLabels: Set<String>
    let profileCohesions: [String: Float]
    let splitPreviewTooltips: [String: String]
    let showSpeakerIDs: Bool
    let showTimestamps: Bool
    let showMerged: Bool
    let previewContentVersion: Int
    @Binding var scrollTargetId: String?
    let onToggleIncluded: (String, Bool) -> Void
    let onSetAllIncluded: (Bool) -> Void
    let onAttemptToggleSplitProfileIncluded: (String) -> Void
    let onToggleSplitProfile: (String) -> Void
    let onSelectPerson: (String, String?) -> Void
    let onRequestCreatePerson: (String) -> Void
    let onJumpToNext: (String) -> Void
    let onRestoreSpeaker: ([Int]) -> Void
    let onEdit: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            SpeakerPanel(
                distinctSpeakers: projection.speakerPanelLabels,
                inScopeLabels: $inScopeLabels,
                speakerNames: projection.speakerNames,
                suggestions: suggestions,
                allPersonNames: allPersonNames,
                speakerDurations: projection.speakerDurations,
                splitProfileLabels: splitProfileLabels,
                splittableProfileLabels: splittableProfileLabels,
                profileCohesions: profileCohesions,
                splitPreviewTooltips: splitPreviewTooltips,
                onToggleIncluded: onToggleIncluded,
                onSetAllIncluded: onSetAllIncluded,
                onAttemptToggleSplitProfileIncluded: onAttemptToggleSplitProfileIncluded,
                onToggleSplitProfile: onToggleSplitProfile,
                onSelectPerson: onSelectPerson,
                onRequestCreatePerson: onRequestCreatePerson,
                onJumpToNext: onJumpToNext
            )
            .frame(width: AppLayout.resultsSpeakerPanelWidth)

            Divider()

            ResultsSegmentList(
                displaySegments: projection.displaySegments,
                manuallyAssignedMergeIDs: Set(
                    ResultsPresentation.activeMergedResults(in: payload).compactMap {
                        $0.manualSpeakerLabel == nil ? nil : $0.mergeId
                    }
                ),
                showSpeakerIDs: showSpeakerIDs,
                showTimestamps: showTimestamps,
                showMerged: showMerged,
                scrollTargetId: $scrollTargetId,
                onRestoreSpeaker: onRestoreSpeaker,
                onEdit: onEdit
            )
            .id(previewContentVersion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ResultsSegmentList: View {
    let displaySegments: [DisplaySegment]
    let manuallyAssignedMergeIDs: Set<Int>
    let showSpeakerIDs: Bool
    let showTimestamps: Bool
    let showMerged: Bool
    @Binding var scrollTargetId: String?
    let onRestoreSpeaker: ([Int]) -> Void
    let onEdit: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(displaySegments) { dSeg in
                        SegmentRowView(
                            displaySpeakerName: dSeg.displaySpeakerName,
                            speakerLabelSuffix: dSeg.speakerLabelSuffix,
                            showSpeakerLabelSuffix: showSpeakerIDs,
                            startMs: dSeg.startMs,
                            endMs: dSeg.endMs,
                            displayText: dSeg.text,
                            showTimestamps: showTimestamps,
                            baselineSpeakerLabel: dSeg.baselineSpeakerLabel,
                            onRestoreSpeaker: showMerged
                                && dSeg.sourceSegmentIDs.contains(where: manuallyAssignedMergeIDs.contains)
                                ? { onRestoreSpeaker(dSeg.sourceSegmentIDs) }
                                : nil,
                            // A collapsed row can contain multiple persisted merge units.
                            // Editing it directly would lose the text boundary, so require
                            // restoration before editing such rows.
                            onEdit: showMerged && dSeg.hasSingleSource
                                ? { onEdit(dSeg.sourceSegmentIDs[0]) }
                                : nil
                        )
                        .id(dSeg.id)
                        Divider()
                    }
                }
                .padding(.horizontal, 16)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: scrollTargetId) { _, newId in
                guard let id = newId else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .top)
                }
                DispatchQueue.main.async { scrollTargetId = nil }
            }
        }
    }
}
