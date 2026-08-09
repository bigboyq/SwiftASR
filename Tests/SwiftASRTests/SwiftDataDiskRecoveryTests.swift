import Foundation
import SwiftData
import Testing
@testable import SwiftASR

/// Snapshot of the pre-removal entity graph. These test-only models deliberately
/// retain the original entity names so the test creates the same `ASRJob` /
/// `Utterance` tables as an installed build did.
private enum LegacyUtteranceDiskSchema {
    @Model
    final class ASRJob {
        @Attribute(.unique) var id: String
        var sourceAudioPath: String
        var sourceAudioHash: String
        var durationSeconds: Double
        var mode: String
        var asrBackend: String
        var speakerBackend: String
        var device: String
        var status: String
        var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \Utterance.job)
        var utterances: [Utterance] = []

        init(
            id: String,
            sourceAudioPath: String,
            sourceAudioHash: String,
            durationSeconds: Double
        ) {
            self.id = id
            self.sourceAudioPath = sourceAudioPath
            self.sourceAudioHash = sourceAudioHash
            self.durationSeconds = durationSeconds
            self.mode = "turbo"
            self.asrBackend = "paraformer"
            self.speakerBackend = "eres2netv2"
            self.device = "auto"
            self.status = JobStatus.done.rawValue
            self.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        }
    }

    @Model
    final class Utterance {
        @Attribute(.unique) var id: String
        var startMs: Int
        var endMs: Int
        var rawText: String
        var cleanedText: String
        var speakerLabel: String
        var speakerName: String?
        var confidence: Double?
        var job: ASRJob?

        init(id: String, job: ASRJob) {
            self.id = id
            self.startMs = 0
            self.endMs = 1_000
            self.rawText = "legacy"
            self.cleanedText = ""
            self.speakerLabel = "说话人 1"
            self.job = job
        }
    }
}

/// Uses a real on-disk SwiftData store rather than `isStoredInMemoryOnly`.
/// The two container scopes model a process exit followed by a fresh launch.
@Suite("SwiftData disk persistence and startup recovery")
@MainActor
struct SwiftDataDiskRecoveryTests {
    private func makePersistentContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let configuration = ModelConfiguration(
            "SwiftDataDiskRecoveryTests",
            schema: schema,
            url: storeURL
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @Test func removingLegacyUtteranceEntityPreservesASRJobOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-utterance-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("SwiftASR.store")
        let jobID = "legacy-utterance-job"

        do {
            let legacySchema = Schema([
                LegacyUtteranceDiskSchema.ASRJob.self,
                LegacyUtteranceDiskSchema.Utterance.self
            ])
            let configuration = ModelConfiguration(
                "LegacyUtteranceDiskSchema",
                schema: legacySchema,
                url: storeURL
            )
            let container = try ModelContainer(
                for: legacySchema,
                configurations: [configuration]
            )
            let context = ModelContext(container)
            let job = LegacyUtteranceDiskSchema.ASRJob(
                id: jobID,
                sourceAudioPath: "/tmp/legacy.wav",
                sourceAudioHash: "legacy",
                durationSeconds: 1
            )
            let utterance = LegacyUtteranceDiskSchema.Utterance(
                id: "legacy-utterance",
                job: job
            )
            context.insert(job)
            context.insert(utterance)
            try context.save()
            #expect(try context.fetch(
                FetchDescriptor<LegacyUtteranceDiskSchema.Utterance>()
            ).count == 1)
        }

        do {
            let container = try makePersistentContainer(at: storeURL)
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<SwiftASR.ASRJob>(
                predicate: #Predicate { $0.id == jobID }
            )
            let migratedJob = try #require(try context.fetch(descriptor).first)
            #expect(migratedJob.sourceAudioHash == "legacy")
            #expect(migratedJob.jobStatus == .done)
        }
    }

    @Test func storeReopensFromDiskAndStartupRecoveryMigratesOccurrences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftasr-disk-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("SwiftASR.store")
        let stageRoot = root.appendingPathComponent("stage")
        let runningID = "disk-running-job"
        let queuedID = "disk-queued-job"
        let doneID = "disk-done-job"
        let profileID = "disk-profile"
        let resultPath = ResultStore.stageResultPath(jobId: doneID, stageRoot: stageRoot.path)

        // First process: create a persistent store with interrupted and
        // migratable records, then let this scope go out of lifetime.
        do {
            let container = try makePersistentContainer(at: storeURL)
            let context = ModelContext(container)
            let profile = SpeakerProfile(
                id: profileID,
                fingerprintId: "fp_disk",
                speakerLabel: "说话人 1"
            )
            let running = ASRJob(
                id: runningID,
                sourceAudioPath: "/tmp/running.wav",
                sourceAudioHash: runningID,
                durationSeconds: 1,
                status: JobStatus.running.rawValue
            )
            running.pipelineStage = "asr"
            running.pipelineFraction = 0.5
            running.cleanupJobStatus = .running
            let queued = ASRJob(
                id: queuedID,
                sourceAudioPath: "/tmp/queued.wav",
                sourceAudioHash: queuedID,
                durationSeconds: 1,
                status: JobStatus.queued.rawValue
            )
            queued.queueOrder = 0
            let done = ASRJob(
                id: doneID,
                sourceAudioPath: "/tmp/done.wav",
                sourceAudioHash: doneID,
                durationSeconds: 1,
                status: JobStatus.done.rawValue
            )
            done.transcriptPath = resultPath.path
            let payload = ResultPayload(
                jobId: doneID,
                audioPath: done.sourceAudioPath,
                segments: [ResultSegment(
                    segmentId: 1,
                    startMs: 0,
                    endMs: 1_000,
                    speakerLabel: "说话人 1",
                    rawText: "磁盘结果"
                )],
                speakers: [ResultSpeaker(
                    speakerLabel: "说话人 1",
                    speakerProfileId: profileID,
                    fingerprintId: "fp_disk"
                )]
            )
            try ResultStore.write(payload, to: resultPath)

            context.insert(profile)
            context.insert(running)
            context.insert(queued)
            context.insert(done)
            try context.save()
        }

        // Second process: reopen the same on-disk store and run the exact
        // coordinator startup recovery path.
        do {
            let container = try makePersistentContainer(at: storeURL)
            let context = ModelContext(container)
            let coordinator = FileActionCoordinator()

            let cleaned = try coordinator.recoverStaleJobsIfNeeded(modelContext: context)
            #expect(cleaned == 1)

            let running = try #require(try ASRJobRepository.findById(runningID, in: context))
            let queued = try #require(try ASRJobRepository.findById(queuedID, in: context))
            let done = try #require(try ASRJobRepository.findById(doneID, in: context))
            let profile = try #require(try SpeakerProfileRepository.findById(profileID, in: context))

            #expect(running.jobStatus == .failed)
            #expect(running.cleanupJobStatus == nil)
            #expect(queued.jobStatus == .queued)
            #expect(done.jobStatus == .done)
            #expect(done.speakerOccurrences.count == 1)
            #expect(done.speakerOccurrences.first?.profile?.id == profileID)
            #expect(done.speakerOccurrences.first?.utteranceCount == 1)
            #expect(profile.jobOccurrences.count == 1)

            // Confirm the recovered state and migrated relationship survive a
            // second save, not only the in-memory context.
            try context.save()
        }

        do {
            let container = try makePersistentContainer(at: storeURL)
            let context = ModelContext(container)
            let running = try #require(try ASRJobRepository.findById(runningID, in: context))
            let done = try #require(try ASRJobRepository.findById(doneID, in: context))
            let profile = try #require(try SpeakerProfileRepository.findById(profileID, in: context))

            #expect(running.jobStatus == .failed)
            #expect(done.jobStatus == .done)
            #expect(done.speakerOccurrences.count == 1)
            #expect(profile.jobOccurrences.count == 1)
        }
    }
}
