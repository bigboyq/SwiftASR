import Foundation
import Testing
@testable import SwiftASR

@Suite("Results split replay loading")
struct ResultsSplitReplayLoaderTests {
    @Test func sidecarsAreLoadedIntoOneReusableContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftasr-results-split-replay-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let jobID = "replay-job"
        let resultPath = root.appendingPathComponent("\(jobID).result.json")
        let inputPath = root.appendingPathComponent("\(jobID).speaker-input.json")
        let snapshotPath = root.appendingPathComponent("\(jobID).speaker-routing.json")
        let input = SpeakerRecognitionInput(audioPath: "/tmp/replay.wav", sentences: [])
        let snapshot = makeSnapshot()
        try ResultStore.writeSpeakerInput(input, to: inputPath)
        try ResultStore.writeSpeakerRoutingSnapshot(snapshot, to: snapshotPath)

        let context = ResultsSplitReplayLoader.load(
            jobID: jobID,
            storedPath: resultPath.path
        )

        #expect(context.matches(jobID: jobID, storedPath: resultPath.path))
        #expect(context.speakerInput?.audioPath == "/tmp/replay.wav")
        #expect(context.routingSnapshot?.stableIdentity == snapshot.stableIdentity)
        #expect(context.profileCohesions["说话人 1"] == 0.72)
    }

    @Test @MainActor
    func staleOperationFallsBackToBaselineWithVisibleMessage() {
        let jobID = "stale-replay-job"
        let snapshot = makeSnapshot()
        let context = ResultsSplitReplayContext(
            jobID: jobID,
            storedPath: nil,
            speakerInput: SpeakerRecognitionInput(audioPath: "/tmp/replay.wav", sentences: []),
            routingSnapshot: snapshot,
            profileCohesions: ["说话人 1": 0.72]
        )
        let payload = makePayload(
            jobID: jobID,
            snapshotVersion: snapshot.version,
            snapshotIdentity: "stale-identity"
        )
        let coordinator = ResultsSplitCoordinator()

        let installation = coordinator.installReplayContext(
            context,
            payload: payload,
            jobID: jobID,
            storedPath: nil
        )

        #expect(installation?.payload.speakerSplitOperation == nil)
        #expect(installation?.validationMessage != nil)
        #expect(installation?.recovery?.baselineCleanup?.status == JobStatus.done.rawValue)
        #expect(installation?.recovery?.baselineCleanup?.model == "gemini-test")
        #expect(installation?.profileCohesions["说话人 1"] == 0.72)
    }

    @Test @MainActor
    func matchingOperationRemainsAttachedToLoadedSnapshot() {
        let jobID = "matching-replay-job"
        let snapshot = makeSnapshot()
        let context = ResultsSplitReplayContext(
            jobID: jobID,
            storedPath: nil,
            speakerInput: SpeakerRecognitionInput(audioPath: "/tmp/replay.wav", sentences: []),
            routingSnapshot: snapshot,
            profileCohesions: ["说话人 1": 0.72]
        )
        let payload = makePayload(
            jobID: jobID,
            snapshotVersion: snapshot.version,
            snapshotIdentity: snapshot.stableIdentity
        )
        let coordinator = ResultsSplitCoordinator()

        let installation = coordinator.installReplayContext(
            context,
            payload: payload,
            jobID: jobID,
            storedPath: nil
        )

        #expect(installation?.payload.speakerSplitOperation != nil)
        #expect(installation?.validationMessage == nil)
    }

    @Test @MainActor
    func onlySnapshotProfileMappingsAreExposedAsSplittable() {
        let jobID = "splittable-labels-job"
        let snapshot = makeSnapshot()
        let context = ResultsSplitReplayContext(
            jobID: jobID,
            storedPath: nil,
            speakerInput: SpeakerRecognitionInput(audioPath: "/tmp/replay.wav", sentences: []),
            routingSnapshot: snapshot,
            profileCohesions: ["说话人 1": 0.72]
        )
        let coordinator = ResultsSplitCoordinator()

        _ = coordinator.installReplayContext(
            context,
            payload: ResultPayload(jobId: jobID, audioPath: "/tmp/replay.wav", segments: []),
            jobID: jobID,
            storedPath: nil
        )

        #expect(coordinator.splittableProfileLabels == ["说话人 1"])
        #expect(!coordinator.splittableProfileLabels.contains(
            SpeakerDiarizationPipeline.sentinelLabel
        ))
    }

    @Test @MainActor
    func operationVersionMismatchAlsoFallsBackToBaseline() {
        let jobID = "version-mismatch-replay-job"
        let snapshot = makeSnapshot()
        let context = ResultsSplitReplayContext(
            jobID: jobID,
            storedPath: nil,
            speakerInput: SpeakerRecognitionInput(audioPath: "/tmp/replay.wav", sentences: []),
            routingSnapshot: snapshot,
            profileCohesions: [:]
        )
        let payload = makePayload(
            jobID: jobID,
            snapshotVersion: snapshot.version + 1,
            snapshotIdentity: snapshot.stableIdentity
        )
        let coordinator = ResultsSplitCoordinator()

        let installation = coordinator.installReplayContext(
            context,
            payload: payload,
            jobID: jobID,
            storedPath: nil
        )

        #expect(installation?.payload.speakerSplitOperation == nil)
        #expect(installation?.validationMessage != nil)
    }

    private func makeSnapshot() -> SpeakerRoutingSnapshot {
        SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "说话人 1", cohesion: 0.72)
            ],
            tokens: [],
            pauseCandidates: []
        )
    }

    private func makePayload(
        jobID: String,
        snapshotVersion: Int,
        snapshotIdentity: String
    ) -> ResultPayload {
        ResultPayload(
            jobId: jobID,
            audioPath: "/tmp/replay.wav",
            segments: [],
            speakerSplitOperation: SpeakerSplitOperation(
                splitProfileLabels: ["说话人 1"],
                routingSnapshotVersion: snapshotVersion,
                routingSnapshotIdentity: snapshotIdentity,
                derivedAt: ResultStore.nowIso(),
                derivedSegments: [],
                derivedMergedResults: [],
                baselineCleanup: SpeakerSplitBaselineCleanup(
                    status: JobStatus.done.rawValue,
                    completedAt: Date(timeIntervalSince1970: 100),
                    model: "gemini-test",
                    processingSeconds: 1.25
                )
            )
        )
    }
}
