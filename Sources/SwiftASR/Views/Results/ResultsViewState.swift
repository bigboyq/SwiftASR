import Foundation
import SwiftUI
import SwiftData

/// All `@State` owned by `ResultsContent`, grouped into one
/// `ObservableObject` so the view declares 1 `@StateObject` instead of
/// 21 scattered `@State` fields (audit F1.13, 2026-07-26).
///
/// Audit originally said 11 @State; the current count is 21 because
/// the profile-split / split-preflight workflow (2026-07-23+) added
/// several presentation-state fields (`pendingProfileSplit` /
/// `completedSplitNotice` / `splitProfileSelectionAlertLabel` /
/// `profileCohesions`).  Split-preview tooltip work lives in
/// `ProfileSplitPreviewCoordinator`, which owns its cancellation and cache.
///
/// Categories:
///   - **Data state** (loaded from disk / model): `payload` /
///     `inScopeLabels` / `suggestions` / `speakerScrollCursors` /
///     `profileCohesions`
///   - **UI state** (booleans): `showSpeakerIDs` /
///     `showTimestamps` / `showMerged` / `showRawText` /
///     `previewContentVersion` / `scrollTargetId`
///   - **Banner state** (errors / success / info): `cleanupError` /
///     `persistenceError` / `syncBanner` / `infoBanner`
///   - **Sheet / alert state** (modals, in-flight): `showCleanupDialog` /
///     `editingMergedResult` / `createPersonTargetLabel` /
///     `splitProfileSelectionAlertLabel` / `pendingProfileSplit` /
///     `completedSplitNotice`
///
/// Why an `ObservableObject` class (not a struct): SwiftUI's
/// `@StateObject` is the canonical owner for view-model state; the
/// parent view re-renders on every `@Published` mutation, and child
/// views can take a `Binding<T>` via `$viewState.<field>` (which
/// SwiftUI's property-wrapper magic wires up to the underlying
/// `@Published`).
@MainActor
public final class ResultsViewState: ObservableObject {
    struct JobIdentity: Equatable, Sendable {
        let jobID: String
        let generation: UInt64
    }

    struct LoadToken: Equatable, Sendable {
        let identity: JobIdentity
        let generation: UInt64
    }

    /// The identity is owned by this reference-type view model rather than by
    /// an escaping SwiftUI `View` value. Cleanup and load callbacks must match
    /// it before publishing, so a callback created for job A cannot mutate the
    /// state after the same view position starts showing job B.
    private(set) var activeJobID: String?
    private(set) var identityGeneration: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    // MARK: - Data state (loaded from disk / model)

    /// Currently-loaded `result.json` for `jobId`.  nil = not loaded
    /// or load failed.
    @Published var payload: ResultPayload?

    /// User-toggled set of speaker labels to display in the preview.
    /// Empty = show all; non-empty = filter to labels in the set.
    @Published var inScopeLabels: Set<String> = []

    /// `speakerLabel → SpeakerSuggestion` (person binding suggestion
    /// from `SpeakerProfileRepository`).
    @Published var suggestions: [String: SpeakerSuggestion] = [:]

    /// Per-speaker scroll cursor: each speaker has an independent
    /// "已访问过的位置数" pointer; chevron-tap advances, wrap on mod.
    @Published var speakerScrollCursors: [String: Int] = [:]

    /// Per-profile cohesion (packed-window centroid) for the current
    /// `speaker-routing.json` snapshot.  Old snapshots fall back to
    /// the persisted token evidence as a caution proxy.
    @Published var profileCohesions: [String: Float] = [:]

    /// Cached projection populated when profiles are loaded. Rendering the
    /// SwiftUI body must not fetch every `SpeakerProfile` repeatedly.
    @Published var speakerNames: [String: String] = [:]

    // MARK: - UI state (booleans / sort keys)

    @Published var showSpeakerIDs = true
    @Published var showTimestamps = true
    @Published var showMerged = false
    @Published var showRawText = true
    /// chunk 完成后 payload 虽已更新，但 LazyVStack 的行 identity 只由
    /// mergeId 构成；同一 mergeId 的 raw/cleaned 文本切换需要显式换
    /// 一代视图，避免直到切换任务才刷新预览。
    @Published var previewContentVersion = 0
    /// 触发 ScrollViewReader 滚动的目标 segment id。设值后 onChange
    /// 滚动并清回 nil。
    @Published var scrollTargetId: String?

    // MARK: - Banner state (errors / success / info)

    @Published var cleanupError: String?
    @Published var persistenceError: String?
    @Published var syncBanner: String?
    /// 黄色温和提示：系统帮用户自动做了一件事（不是错误，不是成功）
    /// 跟 cleanupError（红）/syncBanner（绿）并列，3 种 banner 类型。
    @Published var infoBanner: String?

    // MARK: - Sheet / alert state (modals, in-flight)

    /// B2 CleanupRunDialog visibility.
    @Published var showCleanupDialog: Bool = false
    @Published var editingMergedResult: MergedResult?
    /// 结果页说话人菜单点「新增说话人…」时，保存要绑定的 speaker label。
    @Published var createPersonTargetLabel: String?
    /// 用户试图勾选已分拆 Profile 时的阻断提示。该 Profile 必须先从
    /// Split Set 移除，不能与当前有效说话人筛选混为同一状态。
    @Published var splitProfileSelectionAlertLabel: String?
    @Published var pendingProfileSplit: PendingProfileSplit?
    @Published var completedSplitNotice: ProfileSplitReassignmentService.SplitPreview?

    public init() {}

    /// Cancels an in-flight disk load when the results workspace leaves the
    /// view hierarchy; the token checks still prevent any late callback from
    /// publishing into a reused view state.
    deinit {
        loadTask?.cancel()
    }

    /// Starts showing a job and clears every job-scoped value when identity
    /// changes. Re-activating the same job is intentionally a no-op.
    @discardableResult
    func activate(jobID: String) -> JobIdentity {
        if activeJobID != jobID {
            identityGeneration &+= 1
            loadGeneration &+= 1
            loadTask?.cancel()
            loadTask = nil
            activeJobID = jobID
            resetJobScopedState()
        }
        return JobIdentity(jobID: jobID, generation: identityGeneration)
    }

    func currentIdentity(for jobID: String) -> JobIdentity? {
        guard activeJobID == jobID else { return nil }
        return JobIdentity(jobID: jobID, generation: identityGeneration)
    }

    func isCurrent(_ identity: JobIdentity) -> Bool {
        activeJobID == identity.jobID && identityGeneration == identity.generation
    }

    /// Supersedes any previous disk load without invalidating cleanup
    /// callbacks for the same job.
    func beginLoad(jobID: String) -> LoadToken {
        let identity = activate(jobID: jobID)
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        return LoadToken(identity: identity, generation: loadGeneration)
    }

    func isCurrent(_ token: LoadToken) -> Bool {
        isCurrent(token.identity) && loadGeneration == token.generation
    }

    func installLoadTask(_ task: Task<Void, Never>, for token: LoadToken) {
        guard isCurrent(token) else {
            task.cancel()
            return
        }
        loadTask = task
    }

    func finishLoad(_ token: LoadToken) {
        guard isCurrent(token) else { return }
        loadTask = nil
    }

    private func resetJobScopedState() {
        payload = nil
        inScopeLabels = []
        suggestions = [:]
        speakerScrollCursors = [:]
        profileCohesions = [:]
        speakerNames = [:]

        showSpeakerIDs = true
        showTimestamps = true
        showMerged = false
        showRawText = true
        previewContentVersion = 0
        scrollTargetId = nil

        cleanupError = nil
        persistenceError = nil
        syncBanner = nil
        infoBanner = nil

        showCleanupDialog = false
        editingMergedResult = nil
        createPersonTargetLabel = nil
        splitProfileSelectionAlertLabel = nil
        pendingProfileSplit = nil
        completedSplitNotice = nil
    }
}

/// Stash for "user clicked the split icon → we showed the alert → user
/// is about to confirm/cancel".  Held while the alert is presented so
/// the click-time preview is re-shown to the user if they cancel and
/// re-click.  Carries the baseline-cleanup snapshot the user is
/// about to invalidate (cleared on confirm, restored on cancel).
///
/// Moved from `ResultsContent.swift` (where it was `private struct`)
/// to here (F1.13 view-model refactor) so the view model and the view
/// can both reference the type.
struct PendingProfileSplit {
    let payload: ResultPayload
    let splitSet: Set<String>
    let sourceProfileLabel: String
    let preview: ProfileSplitReassignmentService.SplitPreview
    /// Cleanup state of the baseline preview, captured before the first
    /// Split Set mutation and committed only after the user confirms.
    let baselineCleanup: SpeakerSplitBaselineCleanup?
}
