import Foundation

/// 结果页润色的可恢复执行循环。
///
/// 视图负责用户交互、banner 和 SwiftData 状态；本类型只处理 chunk 调用、checkpoint
/// 写盘及进度文本，避免这些业务细节继续堆在 `ResultsContent` 内。
@MainActor
enum ResultsCleanupExecutor {
    struct CompletedRun {
        let fallbackCount: Int
        let tierEscalations: [TierEscalationEvent]
    }

    static func run(
        initialPayload: ResultPayload,
        chunks: [[MergedResult]],
        totalSegments: Int,
        initialCleanedCount: Int,
        jobId: String,
        storedPath: String?,
        glossary: [String],
        speakerNames: [String: String],
        service: LLMCleanupService,
        token: CancellationToken,
        settings: SettingsStore.CleanupSettings,
        onCheckpoint: (ResultPayload, String) -> Void
    ) async throws -> CompletedRun {
        var payload = initialPayload
        var cleanedCount = initialCleanedCount

        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled || token.isCancelled { throw CleanupCancelled() }
            let updated = try await service.cleanupMergedChunk(
                mergedResults: chunk,
                speakerNames: speakerNames,
                glossary: glossary,
                chunkIndex: index + 1,
                shouldCancel: { [token] in Task.isCancelled || token.isCancelled }
            )
            if Task.isCancelled || token.isCancelled { throw CleanupCancelled() }

            let updates = Dictionary(uniqueKeysWithValues: updated.map { ($0.mergeId, $0) })
            if payload.speakerSplitOperation != nil {
                for payloadIndex in payload.speakerSplitOperation!.derivedMergedResults.indices {
                    if let update = updates[payload.speakerSplitOperation!.derivedMergedResults[payloadIndex].mergeId] {
                        payload.speakerSplitOperation!.derivedMergedResults[payloadIndex] = update
                    }
                }
            } else {
                for payloadIndex in payload.mergedResults.indices {
                    if let update = updates[payload.mergedResults[payloadIndex].mergeId] {
                        payload.mergedResults[payloadIndex] = update
                    }
                }
            }
            payload.cleanedModel = settings.model

            let chunkSucceeded = updated.filter {
                !$0.cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            cleanedCount += chunkSucceeded
            try ResultStore.write(
                payload,
                to: ResultStore.writePath(jobId: jobId, storedPath: storedPath)
            )

            let rateLimit = await service.failover.rateLimitCount
            let overload = await service.failover.serverOverloadCount
            let escalations = await service.failover.tierEscalations
            var progress = "\(cleanedCount)/\(totalSegments) paras · \(index + 1)/\(chunks.count) chunks"
            if rateLimit > 0 { progress += " · 429×\(rateLimit)" }
            if overload > 0 { progress += " · 5xx×\(overload)" }
            if let latestEscalation = escalations.last {
                progress += " (\(latestEscalation.userFacingDescription))"
            }
            Logger.shared.info("LLMCleanupService checkpoint: \(progress)")
            onCheckpoint(payload, progress)
        }

        let finalEscalations = await service.failover.tierEscalations
        return CompletedRun(
            fallbackCount: ResultsPresentation.activeMergedResults(in: payload).filter(\.wasLLMFailure).count,
            tierEscalations: finalEscalations
        )
    }
}
