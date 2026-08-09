import Foundation

/// Value-only replay state loaded together with `result.json`.
///
/// Both sidecars can be several megabytes for long recordings. Keeping their
/// decoding in this nonisolated loader lets `ResultsContent` perform the disk
/// work in its detached load task, then hand one immutable snapshot to the
/// main-actor split coordinator. The same decoded routing snapshot backs both
/// cohesion badges and split previews.
struct ResultsSplitReplayContext: Sendable {
    let jobID: String
    let storedPath: String?
    let speakerInput: SpeakerRecognitionInput?
    let routingSnapshot: SpeakerRoutingSnapshot?
    let profileCohesions: [String: Float]

    func matches(jobID: String, storedPath: String?) -> Bool {
        self.jobID == jobID && self.storedPath == storedPath
    }
}

enum ResultsSplitReplayLoader {
    nonisolated static func load(
        jobID: String,
        storedPath: String?
    ) -> ResultsSplitReplayContext {
        let input = ResultStore.locateSpeakerInputPath(
            jobId: jobID,
            storedPath: storedPath
        ).flatMap { try? ResultStore.readSpeakerInput(from: $0) }
        let snapshot = ResultStore.locateSpeakerRoutingSnapshotPath(
            jobId: jobID,
            storedPath: storedPath
        ).flatMap { try? ResultStore.readSpeakerRoutingSnapshot(from: $0) }
        let cohesions = snapshot.map(profileCohesions) ?? [:]
        return ResultsSplitReplayContext(
            jobID: jobID,
            storedPath: storedPath,
            speakerInput: input,
            routingSnapshot: snapshot,
            profileCohesions: cohesions
        )
    }

    nonisolated private static func profileCohesions(
        snapshot: SpeakerRoutingSnapshot
    ) -> [String: Float] {
        Dictionary(uniqueKeysWithValues: snapshot.profileMappings.compactMap { mapping in
            guard let cohesion = ProfileSplitReassignmentService.cohesion(
                for: mapping.speakerLabel,
                snapshot: snapshot
            ) else { return nil }
            return (mapping.speakerLabel, cohesion)
        })
    }
}
