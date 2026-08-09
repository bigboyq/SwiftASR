import SwiftUI
import SwiftData
import AppKit

enum ResultsPreviewMode: String, CaseIterable, Identifiable {
    case segments
    case mergedOriginal
    case cleaned

    var id: Self { self }

    var title: String {
        switch self {
        case .segments: return "逐句原文"
        case .mergedOriginal: return "合并原文"
        case .cleaned: return "润色稿"
        }
    }
}

// `PendingProfileSplit` moved to `ResultsViewState.swift` (F1.13
// view-model refactor) so the view model and the view can both
// reference the type.  See that file for the struct definition.

/// 结果内容：给定 jobId 显示 result.json 内容 + LLM 润色 +
/// 左侧 Speaker 面板直接把当前 profile 绑定到 Person。
///
/// 由 FileDetailView 在 status == "done" 时调用；非 done 状态由 FileDetailView 自己处理
public struct ResultsContent: View {
    let jobId: String

    @Environment(\.modelContext) var modelContext
    /// 全局 coordinator（MainSplitView @StateObject 持有）。
    /// activeCleanupJobId / activeCleanupProgress 来自 coordinator（不是 @State），
    /// 让切到其他文件时 banner 仍显示**正在跑**那个 cleanup 的文件。
    @EnvironmentObject var coordinator: FileActionCoordinator
    /// All `@State` is now grouped in `ResultsViewState` (audit F1.13,
    /// 2026-07-26).  The view holds this `@StateObject` plus 21
    /// computed-property re-exports (`payload`, `cleanupError`, etc.);
    /// split-preview calculation has its own coordinator because it owns a
    /// cancellable background task and cache.
    /// so existing view-body code that reads / writes these fields
    /// directly keeps working without changes.  Sub-views that take a
    /// `Binding<T>` use the corresponding `payloadBinding`,
    /// `cleanupErrorBinding`, ... re-exports (SwiftUI's auto-derived
    /// `$<state>` only works on `@State` / `@StateObject` wrappers,
    /// not on computed properties).
    @StateObject var viewState = ResultsViewState()
    @StateObject var splitCoordinator = ResultsSplitCoordinator()
    @ObservedObject var matchIndex = SpeakerMatchIndex.shared

    // MARK: - Re-exports (audit F1.13 backward-compat)
    //
    // These mirror `ResultsViewState`'s 21 fields so the existing
    // view body code (which references `payload`, `cleanupError`, etc.
    // as if they were local state) keeps compiling.  Reads / writes
    // go through `viewState.<field>` — SwiftUI's `@StateObject`
    // property wrapper fires the view's `objectWillChange` on every
    // nested `@Published` mutation, so view body re-renders work
    // identically to the previous @State pattern.
    //
    // The `var XBinding: Binding<T>` re-exports are needed because
    // SwiftUI's `$<name>` syntax only works on @State / @StateObject
    // wrappers; passing a binding to a sub-view (`.sheet(isPresented:
    // showCleanupDialogBinding)`, `TextField(text: $X)`, etc.) requires an
    // explicit `Binding(get:set:)` for the re-exported computed
    // property.

    var payload: ResultPayload? {
        get { viewState.payload }
        nonmutating set { viewState.payload = newValue }
    }
    var payloadBinding: Binding<ResultPayload?> {
        Binding(get: { viewState.payload }, set: { viewState.payload = $0 })
    }
    var cleanupError: String? {
        get { viewState.cleanupError }
        nonmutating set { viewState.cleanupError = newValue }
    }
    var cleanupErrorBinding: Binding<String?> {
        Binding(get: { viewState.cleanupError }, set: { viewState.cleanupError = $0 })
    }
    var persistenceError: String? {
        get { viewState.persistenceError }
        nonmutating set { viewState.persistenceError = newValue }
    }
    var persistenceErrorBinding: Binding<String?> {
        Binding(get: { viewState.persistenceError }, set: { viewState.persistenceError = $0 })
    }
    var showSpeakerIDs: Bool {
        get { viewState.showSpeakerIDs }
        nonmutating set { viewState.showSpeakerIDs = newValue }
    }
    var showSpeakerIDsBinding: Binding<Bool> {
        Binding(get: { viewState.showSpeakerIDs }, set: { viewState.showSpeakerIDs = $0 })
    }
    var showTimestamps: Bool {
        get { viewState.showTimestamps }
        nonmutating set { viewState.showTimestamps = newValue }
    }
    var showTimestampsBinding: Binding<Bool> {
        Binding(get: { viewState.showTimestamps }, set: { viewState.showTimestamps = $0 })
    }
    var showMerged: Bool {
        get { viewState.showMerged }
        nonmutating set { viewState.showMerged = newValue }
    }
    var showRawText: Bool {
        get { viewState.showRawText }
        nonmutating set { viewState.showRawText = newValue }
    }
    var previewContentVersion: Int {
        get { viewState.previewContentVersion }
        nonmutating set { viewState.previewContentVersion = newValue }
    }
    var scrollTargetId: String? {
        get { viewState.scrollTargetId }
        nonmutating set { viewState.scrollTargetId = newValue }
    }
    var speakerScrollCursors: [String: Int] {
        get { viewState.speakerScrollCursors }
        nonmutating set { viewState.speakerScrollCursors = newValue }
    }
    var inScopeLabels: Set<String> {
        get { viewState.inScopeLabels }
        nonmutating set { viewState.inScopeLabels = newValue }
    }
    var inScopeLabelsBinding: Binding<Set<String>> {
        Binding(get: { viewState.inScopeLabels }, set: { viewState.inScopeLabels = $0 })
    }
    var suggestions: [String: SpeakerSuggestion] {
        get { viewState.suggestions }
        nonmutating set { viewState.suggestions = newValue }
    }
    var syncBanner: String? {
        get { viewState.syncBanner }
        nonmutating set { viewState.syncBanner = newValue }
    }
    var syncBannerBinding: Binding<String?> {
        Binding(get: { viewState.syncBanner }, set: { viewState.syncBanner = $0 })
    }
    var infoBanner: String? {
        get { viewState.infoBanner }
        nonmutating set { viewState.infoBanner = newValue }
    }
    var infoBannerBinding: Binding<String?> {
        Binding(get: { viewState.infoBanner }, set: { viewState.infoBanner = $0 })
    }
    var showCleanupDialog: Bool {
        get { viewState.showCleanupDialog }
        nonmutating set { viewState.showCleanupDialog = newValue }
    }
    var showCleanupDialogBinding: Binding<Bool> {
        Binding(get: { viewState.showCleanupDialog }, set: { viewState.showCleanupDialog = $0 })
    }
    var editingMergedResult: MergedResult? {
        get { viewState.editingMergedResult }
        nonmutating set { viewState.editingMergedResult = newValue }
    }
    var editingMergedResultBinding: Binding<MergedResult?> {
        Binding(get: { viewState.editingMergedResult }, set: { viewState.editingMergedResult = $0 })
    }
    var createPersonTargetLabel: String? {
        get { viewState.createPersonTargetLabel }
        nonmutating set { viewState.createPersonTargetLabel = newValue }
    }
    var splitProfileSelectionAlertLabel: String? {
        get { viewState.splitProfileSelectionAlertLabel }
        nonmutating set { viewState.splitProfileSelectionAlertLabel = newValue }
    }
    var profileCohesions: [String: Float] {
        get { viewState.profileCohesions }
        nonmutating set { viewState.profileCohesions = newValue }
    }
    var splitPreviewTooltips: [String: String] {
        splitCoordinator.previewTooltips
    }
    var pendingProfileSplit: PendingProfileSplit? {
        get { viewState.pendingProfileSplit }
        nonmutating set { viewState.pendingProfileSplit = newValue }
    }
    var completedSplitNotice: ProfileSplitReassignmentService.SplitPreview? {
        get { viewState.completedSplitNotice }
        nonmutating set { viewState.completedSplitNotice = newValue }
    }

    // 用 @Query 拿到当前 job 的实时状态（pipeline 进度 / 失败原因）
    // R4-P2-8：只查当前 job，避免每次变更都重新 fetch 整张任务表。
    @Query private var jobs: [ASRJob]
    // 候选名字列表：所有已命名的 Person
    @Query(sort: \Person.name) var allPersons: [Person]

    public init(jobId: String) {
        self.jobId = jobId
        let targetId = jobId
        let filter = #Predicate<ASRJob> { $0.id == targetId }
        _jobs = Query(filter: filter)
    }

    var currentJob: ASRJob? {
        jobs.first
    }

    /// 跨 ResultsContent 实例查找任意 jobId 对应的 ASRJob。
    /// cleanup banner 用这个查**正在跑**那个 cleanup 的 job（可能不是当前 selection 的 job）。
    private func fetchJob(byId jobId: String) -> ASRJob? {
        // R4-P2-8：jobs 现在只含当前 selection 的 job。若查的是当前 job，
        // 直接命中；否则走 repository fetch（cleanup banner 常见情况）。
        if jobs.first?.id == jobId { return jobs.first }
        do {
            return try ASRJobRepository.findById(jobId, in: modelContext)
        } catch {
            Logger.shared.error("无法读取任务 \(jobId)：\(error)")
            return nil
        }
    }

    private func resetPreviewOptions() {
        showSpeakerIDs = true
        showTimestamps = true
        showMerged = false
        showRawText = true
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部状态条 — 抽到 `ResultsStatusBanner`（2026-07-21），这里是包装
            ResultsStatusBanner(
                jobId: jobId,
                coordinator: coordinator,
                activeCleanupJob: coordinator.activeCleanupJobId.flatMap { fetchJob(byId: $0) },
                cleanupError: cleanupErrorBinding,
                persistenceError: persistenceErrorBinding,
                syncBanner: syncBannerBinding,
                infoBanner: infoBannerBinding,
                onCancelCleanup: cancelCleanup
            )
            Group {
                if let payload = payload {
                    contentView(payload: payload)
                } else if let persistenceError {
                    ContentUnavailableView(
                        "无法加载结果",
                        systemImage: "exclamationmark.triangle",
                        description: Text(persistenceError)
                    )
                } else {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .alert(
            "该说话人已分拆",
            isPresented: Binding(
                get: { splitProfileSelectionAlertLabel != nil },
                set: { if !$0 { splitProfileSelectionAlertLabel = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { splitProfileSelectionAlertLabel = nil }
        } message: {
            Text("需先取消混合标记。")
        }
        .alert(
            "分拆前请确认",
            isPresented: Binding(
                get: { pendingProfileSplit != nil },
                set: { if !$0 { pendingProfileSplit = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingProfileSplit = nil }
            Button("仍然分拆") {
                guard let pending = pendingProfileSplit else { return }
                pendingProfileSplit = nil
                commitPendingSplit(pending)
            }
        } message: {
            Text(ResultsSplitCoordinator.message(pendingProfileSplit?.preview, includesCaution: true))
        }
        .alert(
            "已完成分拆",
            isPresented: Binding(
                get: { completedSplitNotice != nil },
                set: { if !$0 { completedSplitNotice = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { completedSplitNotice = nil }
        } message: {
            Text(ResultsSplitCoordinator.message(completedSplitNotice, includesCaution: false))
        }
        .modifier(LifecycleModifiers(
            jobId: jobId,
            payloadJobId: payload?.jobId ?? "",
            currentJobStatus: currentJob?.status ?? "",
            currentJobStage: currentJob?.pipelineStage ?? "",
            allPersonIds: allPersons.map { $0.id },
            onLifecycle: LifecycleActions(
                onAppear: { handleAppear() },
                onJobIdChange: { handleJobIdChange() },
                onPayloadChange: { handlePayloadChange() },
                onStatusChange: { reload() },
                onStageChange: { reload() },
                onPersonsChange: { refreshSuggestions() }
            )
        ))
        .onChange(of: matchIndex.generation) { _, _ in
            refreshSuggestions()
        }
        .sheet(isPresented: showCleanupDialogBinding) {
            cleanupDialogContent
        }
        .sheet(item: editingMergedResultBinding) { result in
            let names = speakerNameMap(payload)
            ResultEditSheet(
                result: result,
                speakerLabels: payload.map {
                    ResultsPresentation.speakerPanelLabels(in: $0)
                } ?? [],
                speakerNames: names,
                onSave: {
                    saveManualEdit(
                        resultId: result.mergeId,
                        text: $0,
                        speakerLabel: $1
                    )
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { createPersonTargetLabel != nil },
            set: { if !$0 { createPersonTargetLabel = nil } }
        )) {
            PersonEditSheet(
                isPresented: Binding(
                    get: { createPersonTargetLabel != nil },
                    set: { if !$0 { createPersonTargetLabel = nil } }
                ),
                mode: .creating,
                onSave: { name in
                    if let label = createPersonTargetLabel {
                        createPersonAndSelect(label: label, name: name)
                    }
                    createPersonTargetLabel = nil
                }
            )
        }
    }

    private func handleAppear() {
        viewState.activate(jobID: jobId)
        resetPreviewOptions()
        reload()
    }

    private func handleJobIdChange() {
        viewState.activate(jobID: jobId)
        resetPreviewOptions()
        reload()
    }

    /// 空白页防御：job 切换后 payload 加载完，如果当前 toggle 状态会导致
    /// buildSegmentList 返回空（showMerged && !showRawText && 没润色结果），
    /// 自动回退 4 个 toggle 到默认，再触发 buildSegmentList 重新计算。
    private func handlePayloadChange() {
        guard let p = payload, !activeSegments(p).isEmpty else { return }
        if showMerged && !showRawText && !hasCompleteCleanedResults(p) {
            resetPreviewOptions()
        }
    }

    /// 拆出来避免 .sheet 内表达式太复杂导致 type-check timeout
    @ViewBuilder
    private var cleanupDialogContent: some View {
        CleanupRunDialog(
            modelContext: modelContext,
            isPresented: showCleanupDialogBinding,
            checkpoint: cleanupCheckpoint(payload: payload)
        ) { service, token, _, mode in
            startCleanupWithSelectedKeys(service: service, token: token, mode: mode)
        }
    }

    // MARK: - 顶部 banner（已抽到 `ResultsStatusBanner`，2026-07-21）

    private func cancelCleanup() {
        // 从 coordinator 取 token/task，因为切到其他文件时本 ResultsContent
        // 实例的 @State 已经没了。被 `ResultsStatusBanner` 通过 `onCancelCleanup`
        // 闭包调用。
        coordinator.activeCleanupToken?.cancel()
        coordinator.activeCleanupTask?.cancel()
    }

    // MARK: - 主内容（HSplit：左侧 SpeakerPanel + 右侧 segment 预览）

    // MARK: - 数据操作

    private func distinctSpeakerLabels(payload: ResultPayload) -> [String] {
        ResultsPresentation.distinctSpeakerLabels(in: payload)
    }

    /// Returns the job's initial visible speaker scope. Persisted preview
    /// flags win when present; legacy payloads with no included segments fall
    /// back to all distinct labels. All load, split and first-appearance paths
    /// use this one rule so the result panel cannot drift between entry points.
    func defaultInScopeLabels(for payload: ResultPayload) -> Set<String> {
        let included = Set(
            activeSegments(payload)
                .filter(\.includedInPreview)
                .map(\.speakerLabel)
        )
        return included.isEmpty
            ? Set(distinctSpeakerLabels(payload: payload))
            : included
    }

    func toggleIncluded(label: String, included: Bool) {
        var nextScope = inScopeLabels
        if included { nextScope.insert(label) } else { nextScope.remove(label) }
        guard var p = payload else { return }
        if p.speakerSplitOperation != nil {
            for i in p.speakerSplitOperation!.derivedSegments.indices
            where p.speakerSplitOperation!.derivedSegments[i].speakerLabel == label {
                p.speakerSplitOperation!.derivedSegments[i].includedInPreview = included
            }
        } else {
            for i in p.segments.indices where p.segments[i].speakerLabel == label {
                p.segments[i].includedInPreview = included
            }
        }
        guard persist(p, action: "保存说话人预览范围") else { return }
        inScopeLabels = nextScope
        payload = p
        refreshSuggestions()
    }

    /// Batch equivalent of toggling every speaker's preview scope. Mutates the
    /// payload once and persists once instead of N separate full-JSON writes
    /// (one per speaker), which previously stalled the main thread for large
    /// results with many speakers.
    func setAllIncluded(_ included: Bool) {
        guard var p = payload else { return }
        let labels = distinctSpeakerLabels(payload: p)
        if p.speakerSplitOperation != nil {
            for i in p.speakerSplitOperation!.derivedSegments.indices {
                p.speakerSplitOperation!.derivedSegments[i].includedInPreview = included
            }
        } else {
            for i in p.segments.indices {
                p.segments[i].includedInPreview = included
            }
        }
        guard persist(p, action: "保存说话人预览范围") else { return }
        inScopeLabels = included ? Set(labels) : []
        payload = p
        refreshSuggestions()
    }

    func toggleSplitProfile(label: String) {
        do {
            guard let payload else { return }
            switch try splitCoordinator.toggle(
                label: label,
                payload: payload,
                jobID: jobId,
                storedPath: currentJob?.transcriptPath,
                currentJob: currentJob,
                modelContext: modelContext
            ) {
            case .confirmation(let pending):
                pendingProfileSplit = pending
            case .committed(let change, let completionNotice):
                applySplitChange(change)
                completedSplitNotice = completionNotice
            }
        } catch {
            persistenceError = "混合 Profile 分拆失败：\(error.localizedDescription)"
            Logger.shared.error("混合 Profile 分拆失败（\(label)）：\(error)")
        }
    }

    private func commitPendingSplit(_ pending: PendingProfileSplit) {
        do {
            let change = try splitCoordinator.commitConfirmation(
                pending,
                jobID: jobId,
                storedPath: currentJob?.transcriptPath,
                currentJob: currentJob,
                modelContext: modelContext
            )
            applySplitChange(change)
            completedSplitNotice = pending.preview
        } catch {
            persistenceError = "混合 Profile 分拆失败：\(error.localizedDescription)"
            Logger.shared.error("混合 Profile 分拆确认失败（\(pending.sourceProfileLabel)）：\(error)")
        }
    }

    private func applySplitChange(_ change: ResultsSplitCoordinator.CommittedChange) {
        payload = change.payload
        inScopeLabels = defaultInScopeLabels(for: change.payload)
        if !change.splitSet.isEmpty {
            showRawText = true
        } else if showMerged, !hasCompleteCleanedResults(change.payload) {
            showRawText = true
        }
        previewContentVersion &+= 1
        cleanupError = nil
        if change.wasMarked && change.splitSet.isEmpty {
            infoBanner = "已取消 \(change.changedLabel) 的混合标记，结果已恢复到基线。"
        } else if change.wasMarked {
            infoBanner = "已取消 \(change.changedLabel) 的混合标记，剩余集合已从基线重新计算；请重新润色。"
        } else {
            infoBanner = "已标记 \(change.changedLabel) 为混合 Profile，结果已从基线重新计算；请重新润色。"
        }
        refreshSuggestions()
    }

    private func setShowMerged(_ enabled: Bool) {
        guard enabled else {
            showMerged = false
            previewContentVersion &+= 1
            return
        }
        guard var p = payload else { return }
        var didBuildMergedResults = false
        if p.speakerSplitOperation != nil {
            if p.speakerSplitOperation!.derivedMergedResults.isEmpty {
                p.speakerSplitOperation!.derivedMergedResults = SegmentMerger().buildMergedResults(
                    segments: activeSegments(p)
                )
                didBuildMergedResults = true
            }
        } else if p.mergedResults.isEmpty {
            p.buildMergedResults()
            didBuildMergedResults = true
        }
        if didBuildMergedResults {
            guard persist(p, action: "创建合并段落") else { return }
            payload = p
        }
        if !hasCompleteCleanedResults(p) {
            showRawText = true
        }
        showMerged = true
        previewContentVersion &+= 1
    }

    private func setShowRawText(_ enabled: Bool) {
        guard !enabled else {
            // 用户主动开"显示原始"：无前置条件，直接开。
            showRawText = true
            previewContentVersion &+= 1
            return
        }
        // 用户关"显示原始" = 想看润色。润色只在合并模式可见。
        // 1) 没勾合并 → 自动勾（不报错，黄色温和提示"已帮你切"）。
        //    这是 UX 优化：用户的目标很明确（看润色），少一次手动勾选。
        if !showMerged {
            // setShowMerged(true) 内部会 buildMergedResults + 写盘
            setShowMerged(true)
            infoBanner = "查看润色需要在合并状态下，已自动切换合并状态"
        }
        // 2) 合并已勾但没润色结果 → 真的没法看，原报错。
        //    这条不能自动 fix（没润色就是没润色），给红 banner 提示用户去点"润色"。
        if let p = payload, !hasCompleteCleanedResults(p) {
            let checkpoint = cleanupCheckpoint(payload: p)
            cleanupError = checkpoint.isPartial
                ? "润色仅完成 \(checkpoint.completed)/\(checkpoint.total) 个 chunk；请继续润色后再查看完整润色稿。"
                : "切换失败：没有润色结果"
            showRawText = true  // 强制保持开
            previewContentVersion &+= 1
            return
        }
        // 3) 一切就绪：关掉 showRawText。
        showRawText = false
        previewContentVersion &+= 1
    }

    var previewMode: ResultsPreviewMode {
        if !showMerged { return .segments }
        return showRawText ? .mergedOriginal : .cleaned
    }

    func applyPreviewMode(_ mode: ResultsPreviewMode) {
        switch mode {
        case .segments:
            showMerged = false
            showRawText = true
            previewContentVersion &+= 1
        case .mergedOriginal:
            setShowMerged(true)
            showRawText = true
            previewContentVersion &+= 1
        case .cleaned:
            setShowMerged(true)
            setShowRawText(false)
        }
    }

    func hasCleanedResults(_ payload: ResultPayload) -> Bool {
        activeMergedResults(payload).contains {
            !$0.cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 只有完整 checkpoint 才能作为"润色稿"展示. 部分 checkpoint 是续跑资产,
    /// 不能让未完成段落显示为空白或与已润色段落混杂.
    /// Bug fix 2026-07-13: 改段级判断 (之前是 chunk 级连续前缀, 用户看不出
    /// 还差几段). ⚠️原文占位段算已润色 (wasLLMFailure=true 但 cleanedContent 非空).
    func hasCompleteCleanedResults(_ payload: ResultPayload) -> Bool {
        ResultsPresentation.hasCompleteCleanedResults(in: payload)
    }

    /// 段级 checkpoint: 已润色段数 / 总段数. Bug fix 2026-07-13 整体重构 —
    /// 不再按 chunk 切分, 直接按段统计. ⚠️原文占位段 (wasLLMFailure=true)
    /// 算已润色. 进度显示 "已润色 para/总 para" 比 "5/6 chunk" 直观.
    /// @testable 访问: 改 internal 让 unit test 覆盖.
    func cleanupCheckpoint(payload: ResultPayload?) -> CleanupCheckpoint {
        let mergedResults = payload.map { activeMergedResults($0) } ?? []
        guard !mergedResults.isEmpty else {
            return CleanupCheckpoint(completed: 0, total: 0)
        }
        let total = mergedResults.count
        let completed = mergedResults.filter {
            !$0.cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return CleanupCheckpoint(completed: completed, total: total)
    }

    /// Cleanup dialog only selects credentials and mode; lifecycle ownership is
    /// delegated to ResultsCleanupCoordinator.
    private func startCleanupWithSelectedKeys(
        service: LLMCleanupService,
        token: CancellationToken,
        mode: CleanupStartMode
    ) {
        guard let payload else { return }
        let capturedJobID = jobId
        guard let identity = viewState.currentIdentity(for: capturedJobID) else { return }
        ResultsCleanupCoordinator.start(
            payload: payload,
            jobID: capturedJobID,
            storedPath: currentJob?.transcriptPath,
            currentJob: currentJob,
            modelContext: modelContext,
            fileCoordinator: coordinator,
            activeSegments: activeSegments(payload),
            speakerNames: speakerNameMap(payload),
            glossary: SettingsStore.shared.glossary(),
            service: service,
            token: token,
            settings: SettingsStore.shared.cleanupSettings(),
            mode: mode,
            callbacks: .init(
                isShowingJob: { viewState.isCurrent(identity) },
                updatePayload: {
                    guard viewState.isCurrent(identity), $0.jobId == capturedJobID else { return }
                    viewState.payload = $0
                },
                setCleanupError: {
                    guard viewState.isCurrent(identity) else { return }
                    viewState.cleanupError = $0
                },
                setPersistenceError: {
                    guard viewState.isCurrent(identity) else { return }
                    viewState.persistenceError = $0
                },
                setSyncBanner: {
                    guard viewState.isCurrent(identity) else { return }
                    viewState.syncBanner = $0
                },
                showCompletedPreview: {
                    guard viewState.isCurrent(identity) else { return }
                    viewState.showMerged = true
                    viewState.showRawText = false
                    viewState.previewContentVersion &+= 1
                }
            )
        )
    }

    func exportText(
        payload: ResultPayload,
        displaySegments: [DisplaySegment]? = nil
    ) {
        ResultsExportCoordinator.export(
            payload: payload,
            displaySegments: displaySegments ?? buildSegmentList(payload: payload),
            showSpeakerIDs: showSpeakerIDs,
            showTimestamps: showTimestamps,
            reportError: { self.persistenceError = $0 }
        )
    }

    // MARK: - Phase 7：润色按钮启用条件 + tooltip
    /// 是否有可用 key（启用 + 非空 value）
    var hasUsableApiKey: Bool {
        SettingsStore.shared.hasUsableGeminiKey()
    }

    var cleanupButtonTooltip: String {
        if payload?.segments.isEmpty == true {
            return "当前 result.json 没有段"
        }
        if !hasUsableApiKey {
            return "未配置 Gemini API Key。请到「设置 → Gemini API Keys」添加。"
        }
        return "用 Gemini 润色当前预览"
    }
}
