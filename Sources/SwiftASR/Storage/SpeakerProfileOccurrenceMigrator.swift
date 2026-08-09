import Foundation
import SwiftData

public enum SpeakerProfileOccurrenceMigrationError: Error, LocalizedError {
    case resultPathUnavailable(jobID: String, storedPath: String)
    case resultUnreadable(jobID: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case let .resultPathUnavailable(jobID, _):
            return "任务 \(jobID) 的历史结果路径不可用，无法迁移说话人来源。"
        case let .resultUnreadable(jobID, underlying):
            return "任务 \(jobID) 的历史 result.json 无法读取：\(underlying.localizedDescription)"
        }
    }
}

/// Rebuilds job/profile links from persisted result JSON after the schema
/// switched from `SpeakerProfile.job` to `JobSpeakerProfileOccurrence`.
///
/// This migration deliberately does not change profile aggregate counters:
/// those counters already include the historical job in the old schema. It
/// only establishes the baseline rows used by future delta updates. It is
/// safe to run repeatedly because occurrence IDs are deterministic.
public enum SpeakerProfileOccurrenceMigrator {
    @discardableResult
    public static func migrateIfNeeded(in context: ModelContext) throws -> Int {
        let jobs = try context.fetch(FetchDescriptor<ASRJob>())
        let profiles = try context.fetch(FetchDescriptor<SpeakerProfile>())
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let profilesByFingerprint = profiles.reduce(into: [String: SpeakerProfile]()) { result, profile in
            if result[profile.fingerprintId] == nil {
                result[profile.fingerprintId] = profile
            }
        }
        var createdCount = 0

        for job in jobs {
            guard [.done, .partial].contains(job.jobStatus) else { continue }
            // A non-empty relationship is already the migrated baseline. Do
            // not make startup depend on rereading an old result forever.
            guard job.speakerOccurrences.isEmpty else { continue }
            guard let storedPath = job.transcriptPath else { continue }
            guard let resultPath = ResultStore.resolveStoredPath(storedPath) else {
                throw SpeakerProfileOccurrenceMigrationError.resultPathUnavailable(
                    jobID: job.id, storedPath: storedPath
                )
            }

            let payload: ResultPayload
            do {
                payload = try ResultStore.read(from: resultPath)
                try payload.validate(expectedJobID: job.id)
            } catch {
                throw SpeakerProfileOccurrenceMigrationError.resultUnreadable(
                    jobID: job.id, underlying: error
                )
            }

            for speaker in payload.speakers {
                let profile = speaker.speakerProfileId.flatMap { profilesByID[$0] }
                    ?? speaker.fingerprintId.flatMap { profilesByFingerprint[$0] }
                guard let profile else { continue }

                let segments = payload.segments.filter { $0.speakerLabel == speaker.speakerLabel }
                guard !segments.isEmpty else { continue }
                let duration = segments.reduce(0.0) { total, segment in
                    total + max(0, Double(segment.endMs - segment.startMs)) / 1_000
                }
                let occurrence = JobSpeakerProfileOccurrence(
                    id: JobSpeakerProfileOccurrence.makeID(jobID: job.id, profileID: profile.id),
                    speakerLabel: speaker.speakerLabel,
                    utteranceCount: segments.count,
                    durationSeconds: duration,
                    job: job,
                    profile: profile
                )
                context.insert(occurrence)
                createdCount += 1
            }
        }

        if createdCount > 0 {
            try context.save()
        }
        return createdCount
    }
}
