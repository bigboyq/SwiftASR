import Foundation
import SwiftData

/// Reconciles the durable result artifacts with the SwiftData job row after an
/// interrupted write. File replacement and SwiftData save cannot be one
/// transaction, so startup must validate the pair instead of trusting status
/// alone.
public enum ResultArtifactReconciliationService {
    @discardableResult
    public static func reconcile(in context: ModelContext) throws -> Int {
        let jobs = try ASRJobRepository.fetchAll(in: context)
        var changedCount = 0
        let persistedResultTransactionIDs = Set(jobs.compactMap(\.resultTransactionID))
        let allowedArtifactPathsByJobID = Dictionary(
            uniqueKeysWithValues: jobs.map { job in
                (
                    job.id,
                    Set(
                        ResultStore.artifactPaths(
                            jobId: job.id,
                            storedPath: job.transcriptPath
                        ).map { $0.standardizedFileURL.path }
                    )
                )
            }
        )
        let persistedDeletionTransactionIDs = Set(
            jobs.compactMap(\.artifactDeletionTransactionID)
        )

        var recoveredDirectories = try ResultArtifactDeletionTransaction
            .recoverInterruptedTransactions(
                under: URL(
                    fileURLWithPath: ResultStore.defaultStageRoot(),
                    isDirectory: true
                ),
                allowedArtifactPathsByJobID: allowedArtifactPathsByJobID,
                persistedTransactionIDs: persistedDeletionTransactionIDs
            )

        // Recover file-side replacement transactions before deciding a job's
        // result is missing.  The canonical stage tree covers new jobs; the
        // per-job parent pass keeps migrated/historical result locations
        // recoverable as well.  `ResultWriteTransaction` validates its own
        // marker and never touches unknown temporary directories.
        recoveredDirectories += try ResultWriteTransaction.recoverInterruptedTransactions(
            under: URL(fileURLWithPath: ResultStore.defaultStageRoot(), isDirectory: true),
            persistedTransactionIDs: persistedResultTransactionIDs
        )
        var scannedParents = Set<String>()
        for job in jobs {
            guard let storedPath = job.transcriptPath else { continue }
            let parent = URL(fileURLWithPath: storedPath)
                .deletingLastPathComponent()
                .standardizedFileURL
            guard scannedParents.insert(parent.path).inserted else { continue }
            recoveredDirectories += try ResultWriteTransaction.recoverInterruptedTransactions(
                in: parent,
                persistedTransactionIDs: persistedResultTransactionIDs
            )
        }

        for job in jobs {
            let resultURL = locateResultURL(for: job)
            guard let resultURL else {
                if [.done, .partial].contains(job.jobStatus) {
                    markMissingResultFailed(job, detail: "结果文件不存在")
                    changedCount += 1
                }
                continue
            }

            let payload: ResultPayload
            do {
                payload = try ResultStore.read(from: resultURL)
                try payload.validate(expectedJobID: job.id)
            } catch {
                if [.done, .partial].contains(job.jobStatus) {
                    markMissingResultFailed(job, detail: "结果文件无法读取：\(error.localizedDescription)")
                    changedCount += 1
                }
                continue
            }

            if job.transcriptPath != resultURL.path {
                job.transcriptPath = resultURL.path
                changedCount += 1
            }

            if job.jobStatus == .partial,
               ResultStore.locateSpeakerInputPath(
                   jobId: job.id,
                   storedPath: resultURL.path
               ) == nil
            {
                markMissingResultFailed(job, detail: "partial 结果缺少 speaker-input.json，请重新转写")
                changedCount += 1
            }
        }

        if changedCount > 0 {
            do {
                try context.save()
            } catch {
                // M5.6 (round-3): save 失败时回滚内存 mutation，否则下一
                // 个 caller 用同一个 context 会看到一半 mutation 落定
                // (jobStatus / transcriptPath / etc.) + 一半未保存的不
                // 一致视图。SwiftData 不会自动 rollback — 必须显式调
                // modelContext.rollback() 才能清空未保存的 in-memory
                // 改动。下次 reconcile 重新跑会重做相同 mutation。
                context.rollback()
                throw error
            }
        }
        return changedCount + recoveredDirectories
    }

    private static func locateResultURL(for job: ASRJob) -> URL? {
        var candidates: [URL] = []
        if let resolved = ResultStore.resolveStoredPath(job.transcriptPath) {
            candidates.append(resolved)
        }
        candidates.append(ResultStore.stageResultPath(jobId: job.id))

        var seen = Set<String>()
        return candidates.first {
            seen.insert($0.path).inserted &&
                FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func markMissingResultFailed(_ job: ASRJob, detail: String) {
        job.jobStatus = .failed
        job.finishedAt = nil
        job.pipelineStage = "failed"
        job.pipelineFraction = 0
        job.pipelineMessage = "结果恢复失败"
        job.errorMessage = "启动恢复发现任务结果不完整：\(detail)。可以重新转写。"
        job.lastOperationKind = JobOperationKind.transcription.rawValue
        job.lastOperationStatus = JobOperationStatus.failed.rawValue
        job.lastOperationMessage = job.errorMessage
        job.lastOperationAt = Date()
    }
}
