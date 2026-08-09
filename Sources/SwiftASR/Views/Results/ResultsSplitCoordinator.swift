import Combine
import Foundation
import SwiftData

/// Owns the result-page speaker-split workflow: immutable replay input,
/// preview calculation, commit-time cleanup invalidation, and the state needed
/// to render the split controls. `ResultsContent` only presents its outcomes.
@MainActor
final class ResultsSplitCoordinator: ObservableObject {
    typealias CleanupPersistence = @MainActor (
        _ job: ASRJob,
        _ splitSet: Set<String>,
        _ baselineCleanup: SpeakerSplitBaselineCleanup?,
        _ modelContext: ModelContext
    ) throws -> Void
    struct CommittedChange {
        let payload: ResultPayload
        let splitSet: Set<String>
        let changedLabel: String
        let wasMarked: Bool
    }

    struct ReplayRecovery {
        let baselineCleanup: SpeakerSplitBaselineCleanup?
        let validationMessage: String
    }

    struct ReplayInstallation {
        let payload: ResultPayload
        let profileCohesions: [String: Float]
        let recovery: ReplayRecovery?

        var validationMessage: String? { recovery?.validationMessage }
    }

    enum ToggleOutcome {
        case confirmation(PendingProfileSplit)
        case committed(CommittedChange, completionNotice: ProfileSplitReassignmentService.SplitPreview?)
    }

    @Published private(set) var previewTooltips: [String: String] = [:]
    @Published private(set) var splittableProfileLabels: Set<String> = []

    private let previewCoordinator = ProfileSplitPreviewCoordinator()
    private let cleanupPersistence: CleanupPersistence
    private var tooltipObservation: AnyCancellable?
    private var replayContext: ResultsSplitReplayContext?

    init(cleanupPersistence: @escaping CleanupPersistence = ResultsSplitCoordinator.persistCleanup) {
        self.cleanupPersistence = cleanupPersistence
        tooltipObservation = previewCoordinator.$tooltips
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.previewTooltips = $0 }
    }

    /// Installs the sidecars decoded by the result load task and refreshes all
    /// replay-backed presentation from that one immutable snapshot.
    ///
    /// The returned payload falls back to its immutable baseline if the
    /// persisted operation points at a different routing snapshot. Returning
    /// cohesions keeps `ResultsContent` from reaching back to disk.
    func installReplayContext(
        _ context: ResultsSplitReplayContext?,
        payload: ResultPayload?,
        jobID: String,
        storedPath: String?
    ) -> ReplayInstallation? {
        guard var payload else {
            replayContext = nil
            splittableProfileLabels = []
            previewCoordinator.refresh(nil)
            return nil
        }
        guard let context, context.matches(jobID: jobID, storedPath: storedPath) else {
            replayContext = nil
            splittableProfileLabels = []
            previewCoordinator.refresh(nil)
            let recovery = discardInvalidOperationIfNeeded(&payload)
            return ReplayInstallation(
                payload: payload,
                profileCohesions: [:],
                recovery: recovery
            )
        }
        replayContext = context
        splittableProfileLabels = Set(
            context.routingSnapshot?.profileMappings.map(\.speakerLabel) ?? []
        )
        let recovery = discardInvalidOperationIfNeeded(
            &payload,
            snapshot: context.routingSnapshot
        )
        refreshPreview(payload: payload, jobID: jobID, storedPath: storedPath)
        return ReplayInstallation(
            payload: payload,
            profileCohesions: context.profileCohesions,
            recovery: recovery
        )
    }

    /// Makes a fail-visible replay fallback durable without splitting the file
    /// and SwiftData cleanup updates into separate commits. The caller must not
    /// install the recovered payload as editable state until this succeeds.
    func persistInvalidReplayFallback(
        _ installation: ReplayInstallation,
        jobID: String,
        storedPath: String?,
        currentJob: ASRJob?,
        modelContext: ModelContext
    ) throws {
        guard let recovery = installation.recovery else { return }
        guard let currentJob else {
            throw ResultsSplitError.jobUnavailable
        }
        guard currentJob.id == jobID else {
            throw ResultsSplitError.jobMismatch
        }
        try persistTransaction(
            installation.payload,
            splitSet: [],
            baselineCleanup: recovery.baselineCleanup,
            jobID: jobID,
            storedPath: storedPath,
            currentJob: currentJob,
            modelContext: modelContext
        )
        refreshPreview(payload: installation.payload, jobID: jobID, storedPath: storedPath)
    }

    func refreshPreview(
        payload: ResultPayload?,
        jobID: String,
        storedPath: String?
    ) {
        guard let payload,
              let replayContext,
              replayContext.matches(jobID: jobID, storedPath: storedPath),
              let input = replayContext.speakerInput,
              let snapshot = replayContext.routingSnapshot,
              payload.speakerSplitOperation?.routingSnapshotIdentity == nil
                || payload.speakerSplitOperation?.routingSnapshotIdentity == snapshot.stableIdentity
        else {
            previewCoordinator.refresh(nil)
            return
        }
        previewCoordinator.refresh(.init(
            jobID: jobID,
            speakerInput: input,
            routingSnapshot: snapshot,
            currentOperation: payload.speakerSplitOperation
        ))
    }

    func toggle(
        label: String,
        payload: ResultPayload,
        jobID: String,
        storedPath: String?,
        currentJob: ASRJob?,
        modelContext: ModelContext
    ) throws -> ToggleOutcome {
        var working = payload
        let baselineCleanup = working.speakerSplitOperation?.baselineCleanup
            ?? captureBaselineCleanup(currentJob)
        var splitSet = Set(working.speakerSplitOperation?.splitProfileLabels ?? [])
        let wasMarked = splitSet.contains(label)
        guard wasMarked || splittableProfileLabels.contains(label) else {
            throw ProfileSplitReassignmentError.unknownSplitProfile(label)
        }
        if wasMarked {
            splitSet.remove(label)
        } else {
            splitSet.insert(label)
        }

        if splitSet.isEmpty {
            working.speakerSplitOperation = nil
            return .committed(try commit(
                working,
                splitSet: splitSet,
                changedLabel: label,
                wasMarked: wasMarked,
                baselineCleanup: baselineCleanup,
                jobID: jobID,
                storedPath: storedPath,
                currentJob: currentJob,
                modelContext: modelContext
            ), completionNotice: nil)
        }

        let replay = try loadReplayInputs(
            payload: working,
            jobID: jobID,
            storedPath: storedPath
        )
        var operation = try ProfileSplitReassignmentService.derive(
            input: replay.input,
            snapshot: replay.snapshot,
            splitProfileLabels: splitSet
        )
        operation.baselineCleanup = baselineCleanup
        working.speakerSplitOperation = operation

        guard !wasMarked else {
            return .committed(try commit(
                working,
                splitSet: splitSet,
                changedLabel: label,
                wasMarked: true,
                baselineCleanup: baselineCleanup,
                jobID: jobID,
                storedPath: storedPath,
                currentJob: currentJob,
                modelContext: modelContext
            ), completionNotice: nil)
        }

        let preview = ProfileSplitReassignmentService.preview(
            operation: operation,
            sourceProfileLabel: label,
            snapshot: replay.snapshot
        )
        if preview.requiresSplitConfirmation {
            return .confirmation(PendingProfileSplit(
                payload: working,
                splitSet: splitSet,
                sourceProfileLabel: label,
                preview: preview,
                baselineCleanup: baselineCleanup
            ))
        }
        return .committed(try commit(
            working,
            splitSet: splitSet,
            changedLabel: label,
            wasMarked: false,
            baselineCleanup: baselineCleanup,
            jobID: jobID,
            storedPath: storedPath,
            currentJob: currentJob,
            modelContext: modelContext
        ), completionNotice: preview)
    }

    func commitConfirmation(
        _ pending: PendingProfileSplit,
        jobID: String,
        storedPath: String?,
        currentJob: ASRJob?,
        modelContext: ModelContext
    ) throws -> CommittedChange {
        try commit(
            pending.payload,
            splitSet: pending.splitSet,
            changedLabel: pending.sourceProfileLabel,
            wasMarked: false,
            baselineCleanup: pending.baselineCleanup,
            jobID: jobID,
            storedPath: storedPath,
            currentJob: currentJob,
            modelContext: modelContext
        )
    }

    static func message(
        _ preview: ProfileSplitReassignmentService.SplitPreview?,
        includesCaution: Bool
    ) -> String {
        guard let preview else { return "" }
        return ProfileSplitPreviewText.message(preview, includesCaution: includesCaution)
    }

    private func commit(
        _ payload: ResultPayload,
        splitSet: Set<String>,
        changedLabel: String,
        wasMarked: Bool,
        baselineCleanup: SpeakerSplitBaselineCleanup?,
        jobID: String,
        storedPath: String?,
        currentJob: ASRJob?,
        modelContext: ModelContext
    ) throws -> CommittedChange {
        try persistTransaction(
            payload,
            splitSet: splitSet,
            baselineCleanup: baselineCleanup,
            jobID: jobID,
            storedPath: storedPath,
            currentJob: currentJob,
            modelContext: modelContext
        )
        refreshPreview(payload: payload, jobID: jobID, storedPath: storedPath)
        return CommittedChange(
            payload: payload,
            splitSet: splitSet,
            changedLabel: changedLabel,
            wasMarked: wasMarked
        )
    }

    private func persistTransaction(
        _ payload: ResultPayload,
        splitSet: Set<String>,
        baselineCleanup: SpeakerSplitBaselineCleanup?,
        jobID: String,
        storedPath: String?,
        currentJob: ASRJob?,
        modelContext: ModelContext
    ) throws {
        let transaction = try ResultWriteTransaction(
            payload: payload,
            to: ResultStore.writePath(jobId: jobID, storedPath: storedPath)
        )
        let previousResultTransactionID = currentJob?.resultTransactionID
        do {
            try transaction.commit()
            if let currentJob {
                currentJob.resultTransactionID = transaction.id
                try cleanupPersistence(
                    currentJob,
                    splitSet,
                    baselineCleanup,
                    modelContext
                )
            }
            do {
                try transaction.markPersistenceSucceeded(
                    persistedExternally: currentJob != nil
                )
            } catch {
                if currentJob == nil {
                    throw error
                }
                Logger.shared.warn("speaker split result transaction cleanup failed: \(error)")
            }
            do {
                try transaction.finalize()
            } catch {
                Logger.shared.warn("speaker split result transaction cleanup failed: \(error)")
            }
        } catch {
            currentJob?.resultTransactionID = previousResultTransactionID
            try? transaction.rollback()
            modelContext.rollback()
            throw error
        }
    }

    private static func persistCleanup(
        _ job: ASRJob,
        splitSet: Set<String>,
        baselineCleanup: SpeakerSplitBaselineCleanup?,
        modelContext: ModelContext
    ) throws {
        let lifecycle = JobLifecycleStore(modelContext: modelContext)
        if splitSet.isEmpty, let baselineCleanup {
            try lifecycle.restoreCleanup(job, from: baselineCleanup)
        } else if !splitSet.isEmpty {
            try lifecycle.invalidateCleanup(job)
        } else {
            // R4-P1-5 边界说明：splitSet 为空且无 baseline cleanup 可恢复时，
            // 这里没有 job 生命周期状态需要变更（split replay 既没产生新 split，
            // 也没有需要还原的旧 cleanup），只是把 split replay 对 result/speaker
            // 字段的修改提交。resultTransactionID 是启动恢复所需的 job
            // metadata，由 JobLifecycleStore 负责持久化；speaker 映射规则仍
            // 不进入 lifecycle store。
            try lifecycle.persistResultTransactionReference(job)
        }
    }

    private func loadReplayInputs(
        payload: ResultPayload,
        jobID: String,
        storedPath: String?
    ) throws -> (input: SpeakerRecognitionInput, snapshot: SpeakerRoutingSnapshot) {
        guard let replayContext,
              replayContext.matches(jobID: jobID, storedPath: storedPath),
              let input = replayContext.speakerInput
        else {
            throw ResultsSplitError.missingSpeakerInput
        }
        guard let snapshot = replayContext.routingSnapshot else {
            throw ResultsSplitError.missingRoutingSnapshot
        }
        if let existing = payload.speakerSplitOperation,
           existing.routingSnapshotVersion != snapshot.version
            || existing.routingSnapshotIdentity != snapshot.stableIdentity {
            throw ResultsSplitError.snapshotChanged
        }
        return (input, snapshot)
    }

    private func discardInvalidOperationIfNeeded(
        _ payload: inout ResultPayload,
        snapshot: SpeakerRoutingSnapshot? = nil
    ) -> ReplayRecovery? {
        guard let operation = payload.speakerSplitOperation else { return nil }
        guard let snapshot,
              operation.routingSnapshotVersion == snapshot.version,
              operation.routingSnapshotIdentity == snapshot.stableIdentity
        else {
            payload.speakerSplitOperation = nil
            return ReplayRecovery(
                baselineCleanup: operation.baselineCleanup,
                validationMessage: "混合 Profile 派生层与当前 speaker-routing 数据不一致，已安全回退显示基线结果；请重新执行说话人识别后再分拆。"
            )
        }
        return nil
    }

    private func captureBaselineCleanup(_ job: ASRJob?) -> SpeakerSplitBaselineCleanup? {
        guard let job else { return nil }
        return SpeakerSplitBaselineCleanup(
            status: job.cleanupStatus,
            completedAt: job.cleanedAt,
            model: job.cleanedModel,
            processingSeconds: job.llmProcessingSeconds
        )
    }
}

enum ResultsSplitError: LocalizedError {
    case missingSpeakerInput
    case missingRoutingSnapshot
    case snapshotChanged
    case jobUnavailable
    case jobMismatch

    var errorDescription: String? {
        switch self {
        case .missingSpeakerInput:
            return "该历史结果缺少 speaker-input.json，无法安全重算；请重新执行说话人识别。"
        case .missingRoutingSnapshot:
            return "该历史结果缺少 speaker-routing.json，无法安全重算；请重新执行说话人识别。"
        case .snapshotChanged:
            return "当前说话人重算数据与已有分拆操作不一致；请重新执行说话人识别。"
        case .jobUnavailable:
            return "当前任务尚未加载，无法安全保存分拆回退。"
        case .jobMismatch:
            return "当前结果与任务不匹配，无法安全保存分拆回退。"
        }
    }
}
