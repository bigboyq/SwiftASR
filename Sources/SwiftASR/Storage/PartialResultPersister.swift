import Foundation
import SwiftData

enum PartialResultPersistenceOutcome: Equatable {
    case persisted
    case unavailable
    case failed(String)
}

/// 将 result.json 写入从生命周期状态机中隔离，测试可注入失败 writer 验证不会伪造 `.partial`。
protocol ResultPayloadWriting {
    func write(_ payload: ResultPayload, to url: URL) throws

    /// Production writers can opt into a cross-medium rollback transaction.
    /// Test writers keep the simpler write-only contract by using the default.
    func beginTransaction(_ payload: ResultPayload, to url: URL) throws -> ResultWriteTransaction?
}

extension ResultPayloadWriting {
    func beginTransaction(_ payload: ResultPayload, to url: URL) throws -> ResultWriteTransaction? {
        nil
    }
}

struct ResultStorePayloadWriter: ResultPayloadWriting {
    func write(_ payload: ResultPayload, to url: URL) throws {
        try ResultStore.write(payload, to: url)
    }

    func beginTransaction(_ payload: ResultPayload, to url: URL) throws -> ResultWriteTransaction? {
        try ResultWriteTransaction(payload: payload, to: url)
    }
}

@MainActor
struct PartialResultPersister {
    let writer: any ResultPayloadWriting

    init(writer: any ResultPayloadWriting = ResultStorePayloadWriter()) {
        self.writer = writer
    }

    func persist(
        input: SpeakerRecognitionInput,
        jobId: String,
        storedPath: String? = nil,
        errorMessage: String,
        pipelineMessage: String,
        modelContext: ModelContext
    ) -> PartialResultPersistenceOutcome {
        let resultPath = ResultStore.writePath(jobId: jobId, storedPath: storedPath)
        let payload = ResultPayload.partialFromSpeakerInput(input, jobId: jobId)
        var transaction: ResultWriteTransaction?
        var boundJob: ASRJob?
        var previousResultTransactionID: String?
        do {
            transaction = try writer.beginTransaction(payload, to: resultPath)
            if let transaction {
                try transaction.commit()
            } else {
                try writer.write(payload, to: resultPath)
            }
            guard let job = try ASRJobRepository.findById(jobId, in: modelContext) else {
                throw NSError(
                    domain: "PartialResultPersister",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "找不到对应任务，无法更新 partial 状态。"]
                )
            }
            if let transaction {
                boundJob = job
                previousResultTransactionID = job.resultTransactionID
                job.resultTransactionID = transaction.id
            }
            try JobLifecycleStore(modelContext: modelContext).markPartialResult(
                job,
                resultPath: resultPath.path,
                errorMessage: errorMessage,
                pipelineMessage: pipelineMessage
            )
            // `markPartialResult` saved SwiftData successfully; only now may
            // startup recovery retain the replacement artifact.
            // Cleanup failure must not turn a successful cross-medium commit
            // into a rollback: the database already records the artifact.
            do {
                try transaction?.markPersistenceSucceeded()
                try transaction?.finalize()
            } catch {
                Logger.shared.warn("partial result transaction cleanup failed: \(error)")
            }
            return .persisted
        } catch {
            boundJob?.resultTransactionID = previousResultTransactionID
            try? transaction?.rollback()
            let message = "无法保存 ASR partial 结果：\(error.localizedDescription)"
            Logger.shared.error(message)
            return .failed(message)
        }
    }
}
