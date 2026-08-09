import Foundation
import SwiftData

/// Bridges `@Sendable` pipeline callbacks back to the MainActor-owned
/// coordinator and SwiftData context. It intentionally exposes only progress
/// and stage metrics; terminal persistence remains in the run lifecycle.
@MainActor
final class PipelineEventSink {
    private unowned let coordinator: FileActionCoordinator
    private let modelContext: ModelContext

    init(coordinator: FileActionCoordinator, modelContext: ModelContext) {
        self.coordinator = coordinator
        self.modelContext = modelContext
    }

    func applyProgress(
        jobId: String,
        runID: UUID,
        token: CancellationToken,
        stage: String,
        fraction: Double,
        message: String
    ) {
        coordinator.applyPipelineProgress(
            jobId: jobId, runID: runID, token: token, stage: stage, fraction: fraction,
            message: message, modelContext: modelContext
        )
    }

    func applyStageMetrics(
        jobId: String,
        runID: UUID,
        token: CancellationToken,
        stage: String,
        metrics: PipelineStageMetrics
    ) {
        coordinator.applyStageMetrics(
            jobId: jobId, runID: runID, token: token, stage: stage, metrics: metrics,
            modelContext: modelContext
        )
    }
}
