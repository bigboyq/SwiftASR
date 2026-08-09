import Foundation
import SwiftData
import Testing
@testable import SwiftASR

@Suite("SpeakerProfileRepository result reference checks")
@MainActor
struct SpeakerProfileRepositoryTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let config = ModelConfiguration(
            "SpeakerProfileRepositoryTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func makeProfile() -> SpeakerProfile {
        SpeakerProfile(
            id: "profile-1",
            fingerprintId: "fp_profile_1",
            speakerLabel: "Speaker1"
        )
    }

    @Test func findsProfileReferencedByResultJSON() throws {
        let context = try makeContext()
        let profile = makeProfile()
        let job = ASRJob(
            id: "job-1",
            sourceAudioPath: "/tmp/audio.wav",
            sourceAudioHash: "job-1",
            durationSeconds: 1,
            status: JobStatus.done.rawValue
        )
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-profile-reference-\(UUID().uuidString).result.json")
        defer { try? FileManager.default.removeItem(at: resultURL) }

        job.transcriptPath = resultURL.path
        context.insert(profile)
        context.insert(job)
        try context.save()
        try ResultStore.write(
            ResultPayload(
                jobId: job.id,
                audioPath: job.sourceAudioPath,
                segments: [],
                speakers: [
                    ResultSpeaker(
                        speakerLabel: profile.speakerLabel,
                        speakerProfileId: profile.id,
                        fingerprintId: profile.fingerprintId
                    )
                ]
            ),
            to: resultURL
        )

        let matches = try SpeakerProfileRepository.referencingJobs(profile: profile, in: context)
        #expect(matches.map(\.id) == [job.id])
    }

    @Test func unreadableReferencedResultFailsClosed() throws {
        let context = try makeContext()
        let profile = makeProfile()
        let job = ASRJob(
            id: "job-2",
            sourceAudioPath: "/tmp/audio.wav",
            sourceAudioHash: "job-2",
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftasr-missing-\(UUID().uuidString).result.json").path
        )
        context.insert(profile)
        context.insert(job)
        try context.save()

        #expect(throws: SpeakerProfileRepositoryError.self) {
            try SpeakerProfileRepository.referencingJobs(profile: profile, in: context)
        }
    }

    @Test func unreferencedProfilesRemovesOnlyProfilesAbsentFromCurrentResults() throws {
        let context = try makeContext()
        let current = SpeakerProfile(id: "profile-current", fingerprintId: "fp_current", speakerLabel: "Speaker1")
        let rerunResidual = SpeakerProfile(id: "profile-rerun-residual", fingerprintId: "fp_rerun_residual", speakerLabel: "Speaker2")
        let deletedTaskResidual = SpeakerProfile(id: "profile-deleted-task", fingerprintId: "fp_deleted_task", speakerLabel: "Speaker3")
        let job = ASRJob(
            id: "job-current",
            sourceAudioPath: "/tmp/current.wav",
            sourceAudioHash: "job-current",
            durationSeconds: 1,
            status: JobStatus.done.rawValue
        )
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-profile-sweep-\(UUID().uuidString).result.json")
        defer { try? FileManager.default.removeItem(at: resultURL) }

        job.transcriptPath = resultURL.path
        context.insert(current)
        context.insert(rerunResidual)
        context.insert(deletedTaskResidual)
        context.insert(job)
        try context.save()
        try ResultStore.write(
            ResultPayload(
                jobId: job.id,
                audioPath: job.sourceAudioPath,
                segments: [],
                speakers: [
                    ResultSpeaker(
                        speakerLabel: current.speakerLabel,
                        speakerProfileId: current.id,
                        fingerprintId: current.fingerprintId
                    )
                ]
            ),
            to: resultURL
        )

        let orphaned = try SpeakerProfileRepository.unreferencedProfiles(in: context)
        #expect(orphaned.map(\.id) == [deletedTaskResidual.id, rerunResidual.id])
    }

    @Test func unreferencedProfileScanFailsClosedWhenAnyTaskResultIsUnreadable() throws {
        let context = try makeContext()
        let profile = makeProfile()
        let job = ASRJob(
            id: "job-unreadable-sweep",
            sourceAudioPath: "/tmp/audio.wav",
            sourceAudioHash: "job-unreadable-sweep",
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftasr-missing-sweep-\(UUID().uuidString).result.json").path
        )
        context.insert(profile)
        context.insert(job)
        try context.save()

        #expect(throws: SpeakerProfileRepositoryError.self) {
            try SpeakerProfileRepository.unreferencedProfiles(in: context)
        }
        #expect(try context.fetch(FetchDescriptor<SpeakerProfile>()).map(\.id) == [profile.id])
    }

    @Test func profileSampleUsesOccurrenceLabelForEachJob() async throws {
        let context = try makeContext()
        let profile = makeProfile()
        let oldJob = ASRJob(
            id: "job-sample-old", sourceAudioPath: "/tmp/old.wav", sourceAudioHash: "old",
            durationSeconds: 1, createdAt: Date(timeIntervalSince1970: 1)
        )
        let newJob = ASRJob(
            id: "job-sample-new", sourceAudioPath: "/tmp/new.wav", sourceAudioHash: "new",
            durationSeconds: 1, createdAt: Date(timeIntervalSince1970: 2)
        )
        let oldOccurrence = JobSpeakerProfileOccurrence(
            speakerLabel: "Speaker1", utteranceCount: 1, durationSeconds: 1, job: oldJob, profile: profile
        )
        let newOccurrence = JobSpeakerProfileOccurrence(
            speakerLabel: "Speaker7", utteranceCount: 1, durationSeconds: 1, job: newJob, profile: profile
        )
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-profile-sample-\(UUID().uuidString).result.json")
        defer { try? FileManager.default.removeItem(at: resultURL) }

        newJob.transcriptPath = resultURL.path
        context.insert(profile)
        context.insert(oldJob)
        context.insert(newJob)
        context.insert(oldOccurrence)
        context.insert(newOccurrence)
        try context.save()
        try ResultStore.write(
            ResultPayload(
                jobId: newJob.id,
                audioPath: newJob.sourceAudioPath,
                segments: [ResultSegment(segmentId: 1, startMs: 0, endMs: 1_000, speakerLabel: "Speaker7", rawText: "新样本")],
                speakers: [ResultSpeaker(speakerLabel: "Speaker7", speakerProfileId: profile.id, fingerprintId: profile.fingerprintId)]
            ),
            to: resultURL
        )

        #expect(await profile.sampleText() == "新样本")
    }

    @Test func occurrenceMigrationIsIdempotentAndPreservesProfileTotals() throws {
        let context = try makeContext()
        let profile = makeProfile()
        let job = ASRJob(
            id: "job-migrate",
            sourceAudioPath: "/tmp/audio.wav",
            sourceAudioHash: "job-migrate",
            durationSeconds: 2,
            status: JobStatus.done.rawValue
        )
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-occurrence-migration-\(UUID().uuidString).result.json")
        defer { try? FileManager.default.removeItem(at: resultURL) }

        job.transcriptPath = resultURL.path
        profile.totalUtterances = 17
        profile.totalDurationSeconds = 42
        context.insert(profile)
        context.insert(job)
        try context.save()
        try ResultStore.write(
            ResultPayload(
                jobId: job.id,
                audioPath: job.sourceAudioPath,
                segments: [
                    ResultSegment(segmentId: 1, startMs: 0, endMs: 500, speakerLabel: "Speaker1", rawText: "a"),
                    ResultSegment(segmentId: 2, startMs: 500, endMs: 2_000, speakerLabel: "Speaker1", rawText: "b")
                ],
                speakers: [
                    ResultSpeaker(
                        speakerLabel: "Speaker1",
                        speakerProfileId: profile.id,
                        fingerprintId: profile.fingerprintId
                    )
                ]
            ),
            to: resultURL
        )

        #expect(try SpeakerProfileOccurrenceMigrator.migrateIfNeeded(in: context) == 1)
        #expect(try SpeakerProfileOccurrenceMigrator.migrateIfNeeded(in: context) == 0)
        #expect(job.speakerOccurrences.count == 1)
        #expect(job.speakerOccurrences[0].utteranceCount == 2)
        #expect(job.speakerOccurrences[0].durationSeconds == 2.0)
        #expect(profile.totalUtterances == 17)
        #expect(profile.totalDurationSeconds == 42)
    }

    @Test func deletingJobDeletesOccurrenceButKeepsGlobalProfile() throws {
        let context = try makeContext()
        let profile = makeProfile()
        let job = ASRJob(
            id: "job-delete-occurrence",
            sourceAudioPath: "/tmp/audio.wav",
            sourceAudioHash: "job-delete-occurrence",
            durationSeconds: 1
        )
        let occurrence = JobSpeakerProfileOccurrence(
            speakerLabel: profile.speakerLabel,
            utteranceCount: 1,
            durationSeconds: 1,
            job: job,
            profile: profile
        )
        context.insert(profile)
        context.insert(job)
        context.insert(occurrence)
        try context.save()

        context.delete(job)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<JobSpeakerProfileOccurrence>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SpeakerProfile>()).map(\.id) == [profile.id])
    }

    @Test func occurrenceStoreAppliesRerunDeltaWithoutDoubleCounting() throws {
        let context = try makeContext()
        let job = ASRJob(
            id: "job-delta",
            sourceAudioPath: "/tmp/audio.wav",
            sourceAudioHash: "job-delta",
            durationSeconds: 3
        )
        context.insert(job)
        try context.save()

        let first = SpeakerProfileData(
            speakerLabel: "Speaker1",
            fingerprintId: "fp_delta",
            totalDurationMs: 3_000,
            chunkCount: 3,
            centroidEmbedding: [],
            embeddingData: Data(repeating: 0, count: 8)
        )
        try SpeakerProfileOccurrenceStore.apply(
            [first], profileIDs: ["Speaker1": "profile-delta"], job: job, modelContext: context
        )
        try context.save()

        let profile = try #require(
            try SpeakerProfileRepository.findByFingerprintId("fp_delta", in: context)
        )
        #expect(profile.totalUtterances == 3)
        #expect(profile.totalDurationSeconds == 3)
        #expect(job.speakerOccurrences.count == 1)

        try SpeakerProfileOccurrenceStore.apply(
            [first], profileIDs: ["Speaker1": "profile-delta"], job: job, modelContext: context
        )
        #expect(profile.totalUtterances == 3)
        #expect(profile.totalDurationSeconds == 3)
        #expect(job.speakerOccurrences.count == 1)

        let rerun = SpeakerProfileData(
            speakerLabel: "Speaker1",
            fingerprintId: "fp_delta",
            totalDurationMs: 2_000,
            chunkCount: 2,
            centroidEmbedding: [],
            embeddingData: Data(repeating: 0, count: 8)
        )
        try SpeakerProfileOccurrenceStore.apply(
            [rerun], profileIDs: ["Speaker1": "profile-delta"], job: job, modelContext: context
        )
        #expect(profile.totalUtterances == 2)
        #expect(profile.totalDurationSeconds == 2)
        #expect(job.speakerOccurrences[0].utteranceCount == 2)

        let secondJob = ASRJob(
            id: "job-delta-second",
            sourceAudioPath: "/tmp/audio-2.wav",
            sourceAudioHash: "job-delta-second",
            durationSeconds: 3
        )
        context.insert(secondJob)
        try SpeakerProfileOccurrenceStore.apply(
            [first], profileIDs: ["Speaker1": "profile-delta"], job: secondJob, modelContext: context
        )
        #expect(profile.totalUtterances == 5)
        #expect(profile.totalDurationSeconds == 5)
        #expect(profile.jobOccurrences.count == 2)

        try SpeakerProfileOccurrenceStore.apply(
            [], profileIDs: [:], job: job, modelContext: context
        )
        try context.save()
        #expect(profile.totalUtterances == 3)
        #expect(profile.totalDurationSeconds == 3)
        #expect(try context.fetch(FetchDescriptor<JobSpeakerProfileOccurrence>()).count == 1)
    }

    @Test func occurrenceStoreRepairsStaleAggregateBeforeApplyingLatestCounts() throws {
        let context = try makeContext()
        let profile = SpeakerProfile(
            id: "profile-stale",
            fingerprintId: "fp-stale",
            speakerLabel: "Speaker1",
            totalUtterances: 1,
            totalDurationSeconds: 1
        )
        let job = ASRJob(
            id: "job-stale",
            sourceAudioPath: "/tmp/stale.wav",
            sourceAudioHash: "job-stale",
            durationSeconds: 3
        )
        let occurrence = JobSpeakerProfileOccurrence(
            speakerLabel: "Speaker1",
            utteranceCount: 3,
            durationSeconds: 3,
            job: job,
            profile: profile
        )
        context.insert(profile)
        context.insert(job)
        context.insert(occurrence)
        try context.save()

        let latest = SpeakerProfileData(
            speakerLabel: "Speaker1",
            fingerprintId: "fp-stale",
            totalDurationMs: 2_000,
            chunkCount: 2,
            centroidEmbedding: [],
            embeddingData: Data(repeating: 0, count: 8)
        )
        try SpeakerProfileOccurrenceStore.apply(
            [latest], profileIDs: ["Speaker1": profile.id], job: job, modelContext: context
        )

        #expect(profile.totalUtterances == 2)
        #expect(profile.totalDurationSeconds == 2)
        #expect(job.speakerOccurrences[0].utteranceCount == 2)
        #expect(job.speakerOccurrences[0].durationSeconds == 2)

        try SpeakerProfileOccurrenceStore.apply(
            [], profileIDs: [:], job: job, modelContext: context
        )
        try context.save()
        #expect(profile.totalUtterances == 0)
        #expect(profile.totalDurationSeconds == 0)
        #expect(try context.fetch(FetchDescriptor<JobSpeakerProfileOccurrence>()).isEmpty)
    }

    @Test func occurrenceStoreRejectsInvalidCountsBeforeMutatingContext() throws {
        let context = try makeContext()
        let job = ASRJob(
            id: "job-invalid-occurrence",
            sourceAudioPath: "/tmp/audio.wav",
            sourceAudioHash: "job-invalid-occurrence",
            durationSeconds: 1
        )
        context.insert(job)
        try context.save()

        let invalid = SpeakerProfileData(
            speakerLabel: "Speaker1",
            fingerprintId: "fp-invalid",
            totalDurationMs: -1,
            chunkCount: 1,
            centroidEmbedding: [],
            embeddingData: Data()
        )

        #expect(throws: SpeakerProfileOccurrenceStoreError.self) {
            try SpeakerProfileOccurrenceStore.apply(
                [invalid], profileIDs: ["Speaker1": "profile-invalid"], job: job, modelContext: context
            )
        }
        #expect(try context.fetch(FetchDescriptor<SpeakerProfile>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<JobSpeakerProfileOccurrence>()).isEmpty)
    }
}
