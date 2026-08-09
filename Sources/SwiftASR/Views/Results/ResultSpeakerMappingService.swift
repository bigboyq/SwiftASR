import Foundation
import SwiftData

/// Persists result-page speaker-to-Person assignments without taking ownership
/// of SwiftUI presentation state.  `ResultsContent` decides which menu/sheet
/// to show; this service owns only payload hydration and the cross-medium
/// result.json + SwiftData commit.
///
/// 架构边界（R4-P1-5，2026-08-05 复核确认）：
/// - **JobLifecycleStore** 负责 job 状态/阶段/进度/完成/失败/取消/cleanup/recovery。
/// - **ResultSpeakerMappingService**（本类型）负责 result-page 的 speaker
///   label→profile 映射、`result.json` 中的 speaker 字段、speaker metrics，
///   以及这些修改的原子保存。它**不**改变 job 的生命周期状态。
/// - UI / `ResultsSplitCoordinator` 只做编排，不直接改 job 字段或裸调
///   `modelContext.save()`（split replay 除外，见 ResultsSplitCoordinator 注释）。
///
/// 这里的直接 `modelContext.save()` 是 speaker 映射事务的提交边界，不是
/// "绕过 JobLifecycleStore"：映射操作本身不触发 job 状态迁移。
@MainActor
enum ResultSpeakerMappingService {
    static func hydrateProfileMappings(
        _ payload: inout ResultPayload,
        activeSegments: [ResultSegment],
        currentJob: ASRJob?,
        profiles: [SpeakerProfile]
    ) -> Bool {
        let currentProfileIDs = Set(
            currentJob?.speakerOccurrences.compactMap { $0.profile?.id } ?? []
        )
        let profileByLabel = Dictionary(uniqueKeysWithValues: profiles.compactMap {
            profile -> (String, SpeakerProfile)? in
            guard currentProfileIDs.contains(profile.id) else { return nil }
            return (profile.speakerLabel, profile)
        })
        var changed = false
        for label in Set(activeSegments.map(\.speakerLabel)) {
            guard payload.speakerProfileId(for: label) == nil,
                  let profile = profileByLabel[label] else { continue }
            payload.setSpeakerProfileId(profile.id, for: label)
            changed = true
        }
        return changed
    }

    static func assign(
        person: Person?,
        to label: String,
        payload: ResultPayload,
        activeSegments: [ResultSegment],
        currentJob: ASRJob?,
        profiles: [SpeakerProfile],
        jobID: String,
        modelContext: ModelContext
    ) throws -> ResultPayload? {
        var updatedPayload = payload
        var profiles = profiles
        var changedMapping = hydrateProfileMappings(
            &updatedPayload,
            activeSegments: activeSegments,
            currentJob: currentJob,
            profiles: profiles
        )

        let profile: SpeakerProfile
        if let profileID = updatedPayload.speakerProfileId(for: label),
           let existing = profiles.first(where: { $0.id == profileID }) {
            profile = existing
        } else if label == SpeakerDiarizationPipeline.sentinelLabel, person != nil {
            if let existing = profiles.first(where: {
                $0.fingerprintId == SpeakerDiarizationPipeline.sentinelFingerprint
            }) {
                profile = existing
            } else {
                profile = SpeakerProfile(
                    fingerprintId: SpeakerDiarizationPipeline.sentinelFingerprint,
                    speakerLabel: SpeakerDiarizationPipeline.sentinelLabel,
                    backend: "user-managed-sentinel",
                    totalUtterances: 0,
                    totalDurationSeconds: 0,
                    embeddingData: nil
                )
                modelContext.insert(profile)
                profiles.append(profile)
            }
            updatedPayload.setSpeakerProfileId(profile.id, for: label)
            changedMapping = true
        } else {
            return nil
        }

        profile.person = person
        currentJob?.totalSpeakers = updatedPayload.speakers.count
        currentJob?.namedSpeakers = updatedPayload.speakers.filter { speaker in
            guard let id = speaker.speakerProfileId else { return false }
            return profiles.first(where: { $0.id == id })?.person != nil
        }.count

        var transaction: ResultWriteTransaction?
        let previousResultTransactionID = currentJob?.resultTransactionID
        do {
            transaction = changedMapping
                ? try ResultWriteTransaction(
                    payload: updatedPayload,
                    to: ResultStore.writePath(jobId: jobID, storedPath: currentJob?.transcriptPath)
                )
                : nil
            try transaction?.commit()
            if let transaction {
                guard let currentJob else {
                    throw NSError(
                        domain: "ResultSpeakerMappingService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "找不到任务，无法原子保存说话人映射。"]
                    )
                }
                currentJob.resultTransactionID = transaction.id
            }
            try modelContext.save()
            do {
                try transaction?.markPersistenceSucceeded()
                try transaction?.finalize()
            } catch {
                Logger.shared.warn("speaker mapping result transaction cleanup failed: \(error)")
            }
            return updatedPayload
        } catch {
            currentJob?.resultTransactionID = previousResultTransactionID
            try? transaction?.rollback()
            modelContext.rollback()
            throw error
        }
    }
}
