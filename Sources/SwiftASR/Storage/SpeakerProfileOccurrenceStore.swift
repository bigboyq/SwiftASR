import Foundation
import SwiftData

public enum SpeakerProfileOccurrenceStoreError: Error, LocalizedError {
    case invalidCounts(fingerprintId: String, utteranceCount: Int, durationSeconds: Double)

    public var errorDescription: String? {
        switch self {
        case let .invalidCounts(fingerprintId, utteranceCount, durationSeconds):
            return "声纹 \(fingerprintId) 的统计值无效（段数 \(utteranceCount)，时长 \(durationSeconds) 秒）。"
        }
    }
}

/// Applies one pipeline result to the global profile library through
/// job-local occurrence rows.
public enum SpeakerProfileOccurrenceStore {
    public static func apply(
        _ data: [SpeakerProfileData],
        profileIDs: [String: String],
        job: ASRJob,
        modelContext: ModelContext
    ) throws {
        var activeProfileIDs = Set<String>()
        var appliedFingerprints = Set<String>()
        var resolved: [(
            item: SpeakerProfileData,
            profile: SpeakerProfile,
            oldOccurrence: JobSpeakerProfileOccurrence?,
            isNew: Bool,
            baseUtterances: Int,
            baseDuration: Double
        )] = []
        let now = Date()

        for item in data {
            guard item.fingerprintId != SpeakerDiarizationPipeline.sentinelFingerprint,
                  appliedFingerprints.insert(item.fingerprintId).inserted
            else { continue }

            let duration = Double(item.totalDurationMs) / 1_000
            guard item.chunkCount >= 0, duration >= 0 else {
                throw SpeakerProfileOccurrenceStoreError.invalidCounts(
                    fingerprintId: item.fingerprintId,
                    utteranceCount: item.chunkCount,
                    durationSeconds: duration
                )
            }

            let profile: SpeakerProfile
            let isNew: Bool
            if let existing = try SpeakerProfileRepository.findByFingerprintId(item.fingerprintId, in: modelContext) {
                profile = existing
                isNew = false
            } else {
                profile = SpeakerProfile(
                    id: profileIDs[item.speakerLabel] ?? UUID().uuidString,
                    fingerprintId: item.fingerprintId,
                    speakerLabel: item.speakerLabel,
                    backend: item.backend,
                    totalUtterances: 0,
                    totalDurationSeconds: 0,
                    embeddingData: item.embeddingData
                )
                isNew = true
            }

            activeProfileIDs.insert(profile.id)
            let oldOccurrence = job.speakerOccurrences.first { $0.profile?.id == profile.id }
            // Historical profile aggregates and job-local occurrences may use
            // different counting units after the occurrence migration. Treat
            // the old contribution as a best-effort delta: never let a stale
            // aggregate go below zero, then add the latest job contribution.
            // This keeps the current result usable while repairing the global
            // counters on the next successful save.
            let baseUtterances = max(
                0,
                profile.totalUtterances - (oldOccurrence?.utteranceCount ?? 0)
            )
            let baseDuration = max(
                0,
                profile.totalDurationSeconds - (oldOccurrence?.durationSeconds ?? 0)
            )
            resolved.append((
                item,
                profile,
                oldOccurrence,
                isNew,
                baseUtterances,
                baseDuration
            ))
        }

        for record in resolved {
            let item = record.item
            let profile = record.profile
            let oldOccurrence = record.oldOccurrence
            let newDuration = Double(item.totalDurationMs) / 1_000

            if record.isNew {
                modelContext.insert(profile)
            }
            profile.totalUtterances = record.baseUtterances + item.chunkCount
            profile.totalDurationSeconds = record.baseDuration + newDuration
            profile.speakerLabel = item.speakerLabel
            profile.lastSeenAt = now
            if profile.embeddingData == nil { profile.embeddingData = item.embeddingData }

            if let oldOccurrence {
                oldOccurrence.speakerLabel = item.speakerLabel
                oldOccurrence.utteranceCount = item.chunkCount
                oldOccurrence.durationSeconds = newDuration
            } else {
                let occurrence = JobSpeakerProfileOccurrence(
                    id: JobSpeakerProfileOccurrence.makeID(jobID: job.id, profileID: profile.id),
                    speakerLabel: item.speakerLabel,
                    utteranceCount: item.chunkCount,
                    durationSeconds: newDuration,
                    job: job,
                    profile: profile
                )
                modelContext.insert(occurrence)
            }
        }

        // A rerun may have fewer speakers. Remove stale contributions from the
        // old result, while leaving the global profile row available to other jobs.
        for occurrence in Array(job.speakerOccurrences)
            where !activeProfileIDs.contains(occurrence.profile?.id ?? "") {
            if let profile = occurrence.profile {
                profile.totalUtterances = max(0, profile.totalUtterances - occurrence.utteranceCount)
                profile.totalDurationSeconds = max(0, profile.totalDurationSeconds - occurrence.durationSeconds)
            }
            modelContext.delete(occurrence)
        }
    }
}
