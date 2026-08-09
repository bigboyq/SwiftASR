import Foundation
import SwiftData
import Testing
@testable import SwiftASR

@Suite("Results split transaction")
@MainActor
struct ResultsSplitCoordinatorTransactionTests {
    private enum InjectedFailure: Error {
        case swiftDataSave
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let configuration = ModelConfiguration(
            "ResultsSplitCoordinatorTransactionTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return ModelContext(
            try ModelContainer(for: schema, configurations: [configuration])
        )
    }

    @Test func cleanupPersistenceFailureRestoresPreviousResultFile() throws {
        let context = try makeContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftasr-split-transaction-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let jobID = "split-transaction-job"
        let resultURL = root.appendingPathComponent("\(jobID).result.json")
        let job = ASRJob(
            id: jobID,
            sourceAudioPath: "/tmp/split.wav",
            sourceAudioHash: jobID,
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: resultURL.path
        )
        context.insert(job)
        try context.save()

        let operation = SpeakerSplitOperation(
            splitProfileLabels: ["说话人 1"],
            routingSnapshotVersion: 1,
            routingSnapshotIdentity: "snapshot",
            derivedAt: ResultStore.nowIso(),
            derivedSegments: [SpeakerSplitDerivedSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                baselineSpeakerLabel: "说话人 1",
                speakerLabel: "说话人 2",
                rawText: "测试"
            )],
            derivedMergedResults: [MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 2",
                rawContent: "测试。"
            )]
        )
        let original = ResultPayload(
            jobId: jobID,
            audioPath: job.sourceAudioPath,
            segments: [ResultSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 1",
                rawText: "测试"
            )],
            speakerSplitOperation: operation
        )
        try ResultStore.write(original, to: resultURL)

        let coordinator = ResultsSplitCoordinator { _, _, _, _ in
            throw InjectedFailure.swiftDataSave
        }
        #expect(throws: InjectedFailure.self) {
            _ = try coordinator.toggle(
                label: "说话人 1",
                payload: original,
                jobID: jobID,
                storedPath: resultURL.path,
                currentJob: job,
                modelContext: context
            )
        }

        let restored = try ResultStore.read(from: resultURL)
        #expect(restored.speakerSplitOperation?.splitProfileLabels == ["说话人 1"])
    }

    @Test func invalidReplayFallbackRestoresBaselineCleanupWithResultFile() throws {
        let context = try makeContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftasr-split-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let jobID = "split-recovery-job"
        let resultURL = root.appendingPathComponent("\(jobID).result.json")
        let baseline = SpeakerSplitBaselineCleanup(
            status: JobStatus.done.rawValue,
            completedAt: Date(timeIntervalSince1970: 200),
            model: "gemini-recovery",
            processingSeconds: 2.5
        )
        let original = makeSplitPayload(jobID: jobID, baselineCleanup: baseline)
        try ResultStore.write(original, to: resultURL)
        let job = makeJob(jobID: jobID, resultURL: resultURL)
        context.insert(job)
        try context.save()

        let coordinator = ResultsSplitCoordinator()
        let installation = try #require(coordinator.installReplayContext(
            replayContext(
                jobID: jobID,
                storedPath: resultURL.path,
                snapshotIdentitySeed: "current"
            ),
            payload: original,
            jobID: jobID,
            storedPath: resultURL.path
        ))
        #expect(installation.recovery != nil)

        try coordinator.persistInvalidReplayFallback(
            installation,
            jobID: jobID,
            storedPath: resultURL.path,
            currentJob: job,
            modelContext: context
        )

        let restored = try ResultStore.read(from: resultURL)
        #expect(restored.speakerSplitOperation == nil)
        #expect(job.cleanupStatus == baseline.status)
        #expect(job.cleanedAt == baseline.completedAt)
        #expect(job.cleanedModel == baseline.model)
        #expect(job.llmProcessingSeconds == baseline.processingSeconds)
        #expect(job.resultTransactionID != nil)
    }

    @Test func invalidReplayFallbackFailureKeepsOperationAndInvalidatedCleanup() throws {
        let context = try makeContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftasr-split-recovery-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let jobID = "split-recovery-failure-job"
        let resultURL = root.appendingPathComponent("\(jobID).result.json")
        let baseline = SpeakerSplitBaselineCleanup(
            status: JobStatus.done.rawValue,
            completedAt: Date(timeIntervalSince1970: 300),
            model: "gemini-recovery",
            processingSeconds: 3.5
        )
        let original = makeSplitPayload(jobID: jobID, baselineCleanup: baseline)
        try ResultStore.write(original, to: resultURL)
        let job = makeJob(jobID: jobID, resultURL: resultURL)
        context.insert(job)
        try context.save()

        let coordinator = ResultsSplitCoordinator { _, _, _, _ in
            throw InjectedFailure.swiftDataSave
        }
        let installation = try #require(coordinator.installReplayContext(
            replayContext(
                jobID: jobID,
                storedPath: resultURL.path,
                snapshotIdentitySeed: "current"
            ),
            payload: original,
            jobID: jobID,
            storedPath: resultURL.path
        ))

        #expect(throws: InjectedFailure.self) {
            try coordinator.persistInvalidReplayFallback(
                installation,
                jobID: jobID,
                storedPath: resultURL.path,
                currentJob: job,
                modelContext: context
            )
        }

        let restored = try ResultStore.read(from: resultURL)
        #expect(restored.speakerSplitOperation != nil)
        #expect(job.cleanupStatus == nil)
        #expect(job.cleanedAt == nil)
        #expect(job.cleanedModel == nil)
        #expect(job.llmProcessingSeconds == 0)
        #expect(job.resultTransactionID == nil)
    }

    private func makeJob(jobID: String, resultURL: URL) -> ASRJob {
        ASRJob(
            id: jobID,
            sourceAudioPath: "/tmp/\(jobID).wav",
            sourceAudioHash: jobID,
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: resultURL.path
        )
    }

    private func makeSplitPayload(
        jobID: String,
        baselineCleanup: SpeakerSplitBaselineCleanup
    ) -> ResultPayload {
        let baselineSegment = ResultSegment(
            segmentId: 1,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "说话人 1",
            rawText: "测试"
        )
        return ResultPayload(
            jobId: jobID,
            audioPath: "/tmp/\(jobID).wav",
            segments: [baselineSegment],
            speakers: [
                ResultSpeaker(speakerLabel: "说话人 1"),
                ResultSpeaker(speakerLabel: "说话人 2")
            ],
            mergedResults: [MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 1",
                rawContent: "测试。",
                cleanedContent: "润色结果"
            )],
            speakerSplitOperation: SpeakerSplitOperation(
                splitProfileLabels: ["说话人 1"],
                routingSnapshotVersion: 1,
                routingSnapshotIdentity: "stale",
                derivedAt: ResultStore.nowIso(),
                derivedSegments: [SpeakerSplitDerivedSegment(
                    segmentId: 1,
                    startMs: 0,
                    endMs: 1_000,
                    baselineSpeakerLabel: "说话人 1",
                    speakerLabel: "说话人 2",
                    rawText: "测试"
                )],
                derivedMergedResults: [MergedResult(
                    mergeId: 1,
                    startMs: 0,
                    endMs: 1_000,
                    speakerLabel: "说话人 2",
                    rawContent: "测试。"
                )],
                baselineCleanup: baselineCleanup
            )
        )
    }

    private func replayContext(
        jobID: String,
        storedPath: String,
        snapshotIdentitySeed: String
    ) -> ResultsSplitReplayContext {
        let snapshot = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: snapshotIdentitySeed.count, speakerLabel: "说话人 1")
            ],
            tokens: [],
            pauseCandidates: []
        )
        return ResultsSplitReplayContext(
            jobID: jobID,
            storedPath: storedPath,
            speakerInput: SpeakerRecognitionInput(
                audioPath: "/tmp/\(jobID).wav",
                sentences: []
            ),
            routingSnapshot: snapshot,
            profileCohesions: [:]
        )
    }
}
