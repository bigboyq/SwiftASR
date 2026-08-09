import Foundation
import SwiftUI

/// All `@Published` state owned by `FileActionCoordinator`, grouped into
/// one frozen-at-init struct so the coordinator exposes a single
/// `state: CoordinatorState` `@Published` to SwiftUI instead of 14
/// individual ones.
///
/// Audit F4.5 (2026-07-26): the coordinator previously had 14
/// `@Published` fields scattered across transcription / cleanup /
/// file-importer / queue-pause / run-handle concerns.  SwiftUI
/// re-evaluates the view body on every `@Published` mutation; grouping
/// them into one struct means view observers fire once per coherent
/// state transition (e.g. `startTranscription()` flipping 4 fields
/// together) rather than 4 separate re-renders.
///
/// All fields are kept mutable (`var`, no `private(set)`) because the
/// coordinator needs to write every one.  The previous
/// `private(set)` access modifier on the coordinator is preserved at
/// the coordinator layer via computed-property re-exports — internal
/// access to `state.actionErrorMessage` is restricted to the
/// coordinator by convention, not by the type system.
///
/// Why a struct (not a class): SwiftUI's `objectWillChange` publisher
/// on the parent `ObservableObject` fires on every `@Published`
/// mutation including nested struct mutation — we get the "one
/// `@Published`" SwiftUI benefit for free without giving up value-type
/// semantics for the state itself.
@MainActor
struct CoordinatorState {
    // MARK: - File import / queue pause

    /// Toggled by the sidebar "import" button; the actual
    /// `.fileImporter` modifier binds to this via a `Binding`.
    var showFileImporter: Bool = false

    /// Last non-recoverable user-action error (import failure, file
    /// not audio, etc.).  Set by `recordActionError(...)`, cleared by
    /// the alert's `isPresented` binding flipping to false.
    var actionErrorMessage: String?

    /// Mirrored from `JobQueueScheduler.isPaused()`.  `setQueuePaused`
    /// writes to the scheduler; this field is then re-read on the
    /// next coordinator init / when the user toggles.
    var isQueuePaused: Bool = false

    /// jobId → live pipeline run handle (token + task + runID). Product policy
    /// permits at most one entry; the dictionary preserves run-ID keyed
    /// cleanup semantics without implying concurrent pipelines.
    var activeRuns: [String: PipelineRunHandle] = [:]

    // MARK: - Transcription / speaker progress (cross-FileDetailView)

    /// Currently-running transcription / speaker jobId.  nil = no
    /// transcription in flight.  See `FileDetailView` for the
    /// "切到其他文件时 progress 仍指向真正在跑那个 job" bug-fix
    /// story (2026-07-12).
    var activeTranscriptionJobId: String?

    /// Current pipeline stage label for the active transcription
    /// (e.g. "vad", "asr", "speaker").  Updated by
    /// `applyPipelineProgress` → `setActiveTranscriptionStage`.
    var activeTranscriptionStage: String = ""

    /// Current pipeline fraction (0.0 - 1.0) for the active
    /// transcription job.
    var activeTranscriptionFraction: Double = 0

    /// Current pipeline progress message for the active
    /// transcription job (e.g. "正在解码 5284 帧").
    var activeTranscriptionMessage: String = ""

    /// 4-stage timing + frame-count metrics (PCM / fbank / VAD+ASR /
    /// speaker), written by `applyStageMetrics` after pipeline
    /// finishes.  nil = pipeline still running or not yet started.
    var activeStageMetrics: PipelineStageMetrics?

    // MARK: - Cleanup / Gemini progress (cross-ResultsContent)

    /// Currently-running LLM cleanup jobId.  nil = no cleanup in
    /// flight.  The coordinator is the single source of truth so
    /// multiple `ResultsContent` instances (one per file tab) share
    /// the same progress banner.
    var activeCleanupJobId: String?

    /// Cancellation token for the active cleanup task.  Set by
    /// `startCleanup`, flipped by `cancelActiveCleanup`.  nil = no
    /// cleanup in flight.
    var activeCleanupToken: CancellationToken?

    /// Top-level `Task` running the cleanup.  `await task.value` is
    /// how we serialise cancel-then-rejoin.  nil = no cleanup in
    /// flight.
    var activeCleanupTask: Task<Void, Never>?

    /// Human-readable chunk-level progress string (e.g. "3/12 chunks ·
    /// 429×2").  nil = not started, or no cleanup running.
    var activeCleanupProgress: String?

    /// Terminal cleanup feedback (success / cancelled / failure)
    /// tied to a jobId.  Set by `recordCleanupOutcome`, cleared by
    /// the next `startCleanup` for the same
    /// jobId.  The view shows this as a banner until the user
    /// navigates away or the next cleanup starts.
    var lastCleanupOutcome: FileActionCoordinator.CleanupOutcome?
}
