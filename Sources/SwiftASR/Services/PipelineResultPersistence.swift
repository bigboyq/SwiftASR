import Foundation
import SwiftData

/// Owns the durable result side of a successful transcription run.
///
/// Pipeline execution and UI progress live in `FileActionCoordinator`; this
/// type owns only the cross-medium commit of speaker profiles, result.json,
/// and the SwiftData job row. Keeping that boundary here prevents future run
/// paths from drifting from the recovery-safe transaction protocol.
@MainActor
struct PipelineResultPersistence {
    struct SpeakerProfileResolution {
        let ids: [String: String]
    }

    @discardableResult
    static func persistTranscriptionSuccess(
        jobID: String,
        audioPath: String,
        utterances: [UtteranceData],
        speakerProfiles: [SpeakerProfileData],
        metrics: PipelineStageMetrics,
        modelContext: ModelContext
    ) throws -> ResultPayload {
        guard let job = try ASRJobRepository.findById(jobID, in: modelContext) else {
            throw NSError(
                domain: "PipelineResultPersistence",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "找不到已完成的 pipeline 任务。"]
            )
        }

        let resolution = try prepareSpeakerProfileResolution(
            speakerProfiles, modelContext: modelContext
        )
        let payload = makePayload(
            utterances: utterances,
            speakerProfiles: speakerProfiles,
            audioPath: audioPath,
            jobID: jobID,
            profileResolution: resolution
        )
        let resultPath = ResultStore.stageResultPath(jobId: jobID)
        let transaction = try ResultWriteTransaction(payload: payload, to: resultPath)
        let previousResultTransactionID = job.resultTransactionID
        do {
            try SpeakerProfileOccurrenceStore.apply(
                speakerProfiles, profileIDs: resolution.ids,
                job: job, modelContext: modelContext
            )
            JobLifecycleStore(modelContext: modelContext).writeSuccessJobMetrics(
                job,
                audioPath: audioPath,
                utterances: utterances,
                metrics: metrics,
                resultPath: resultPath,
                speakersCount: payload.speakers.count
            )
            try transaction.commit()
            job.resultTransactionID = transaction.id
            try JobLifecycleStore(modelContext: modelContext).finishPipeline(
                job,
                status: .done,
                pipelineStage: "done",
                pipelineFraction: 1,
                pipelineMessage: "转写完成",
                errorMessage: nil,
                finishedAt: Date(),
                operationKind: .transcription,
                operationStatus: .succeeded,
                operationMessage: "转写完成",
                save: true
            )
            do {
                try transaction.markPersistenceSucceeded()
                try transaction.finalize()
            } catch {
                Logger.shared.warn("pipeline result transaction cleanup failed: \(error)")
            }
            return payload
        } catch {
            job.resultTransactionID = previousResultTransactionID
            try? transaction.rollback()
            modelContext.rollback()
            throw error
        }
    }

    static func prepareSpeakerProfileResolution(
        _ data: [SpeakerProfileData],
        modelContext: ModelContext
    ) throws -> SpeakerProfileResolution {
        var ids: [String: String] = [:]
        var idsByFingerprint: [String: String] = [:]
        for item in data {
            guard item.fingerprintId != SpeakerDiarizationPipeline.sentinelFingerprint else { continue }
            if let existingID = idsByFingerprint[item.fingerprintId] {
                ids[item.speakerLabel] = existingID
            } else if let existing = try SpeakerProfileRepository.findByFingerprintId(
                item.fingerprintId, in: modelContext
            ) {
                idsByFingerprint[item.fingerprintId] = existing.id
                ids[item.speakerLabel] = existing.id
            } else {
                let id = UUID().uuidString
                idsByFingerprint[item.fingerprintId] = id
                ids[item.speakerLabel] = id
            }
        }
        return SpeakerProfileResolution(ids: ids)
    }

    static func outputFingerprintIDs(_ data: [SpeakerProfileData]) -> [String: String] {
        var ids = Dictionary(uniqueKeysWithValues: data.map { ($0.speakerLabel, $0.fingerprintId) })
        ids[SpeakerDiarizationPipeline.sentinelLabel] = SpeakerDiarizationPipeline.sentinelFingerprint
        return ids
    }

    static func makePayload(
        utterances: [UtteranceData],
        speakerProfiles: [SpeakerProfileData],
        audioPath: String,
        jobID: String,
        profileResolution: SpeakerProfileResolution
    ) -> ResultPayload {
        var payload = ResultPayload.from(
            utterances: utterances, audioPath: audioPath, jobId: jobID
        )
        let fingerprintIDs = outputFingerprintIDs(speakerProfiles)
        payload.speakers = makeSpeakers(
            labels: payload.segments.map(\.speakerLabel).uniqueElements(),
            fingerprintIDs: fingerprintIDs,
            profileIDs: profileResolution.ids
        )
        return payload
    }

    /// Builds the job-local label mapping used by both the full pipeline and
    /// speaker-only reidentification. Keeping this at the persistence boundary
    /// prevents the two write paths from drifting in sentinel/profile handling.
    static func makeSpeakers(
        labels: [String],
        fingerprintIDs: [String: String],
        profileIDs: [String: String]
    ) -> [ResultSpeaker] {
        labels.map {
            ResultSpeaker(
                speakerLabel: $0,
                speakerProfileId: profileIDs[$0],
                fingerprintId: fingerprintIDs[$0]
            )
        }
    }
}
