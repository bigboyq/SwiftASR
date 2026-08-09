import Foundation
import Testing
@testable import SwiftASR

@Suite @MainActor struct ProfileSplitPreviewCoordinatorTests {
    @Test func supersededSplitSetCannotPublishItsOldPreview() async {
        let coordinator = ProfileSplitPreviewCoordinator { input in
            if input.identity.splitProfileLabels == ["A"] {
                // The old task has already entered its computation when the
                // user changes the Split Set. Cancellation must still prevent
                // this result from reaching UI state.
                Thread.sleep(forTimeInterval: 0.08)
                return ["A": "stale"]
            }
            return ["B": "current"]
        }

        coordinator.refresh(makeInput(splitLabels: ["A"]))
        try? await Task.sleep(nanoseconds: 10_000_000)
        coordinator.refresh(makeInput(splitLabels: ["B"]))

        #expect(await waitUntil { coordinator.tooltips == ["B": "current"] })
        try? await Task.sleep(nanoseconds: 120_000_000)
        #expect(coordinator.tooltips == ["B": "current"])
    }

    @Test func identicalInputUsesCachedPreview() async {
        let calls = InvocationCounter()
        let coordinator = ProfileSplitPreviewCoordinator { input in
            calls.increment()
            return [input.identity.jobID: "preview"]
        }
        let input = makeInput(splitLabels: ["A"])

        coordinator.refresh(input)
        #expect(await waitUntil { coordinator.tooltips == ["job": "preview"] })
        coordinator.refresh(input)

        #expect(coordinator.tooltips == ["job": "preview"])
        #expect(calls.value == 1)
    }

    @Test func cacheEvictsOldestIdentityWhenFull() async {
        let calls = InvocationCounter()
        let coordinator = ProfileSplitPreviewCoordinator { input in
            calls.increment()
            return [input.identity.jobID: "preview"]
        }
        let limit = ProfileSplitPreviewCoordinator.maxCacheEntries

        // Fill the cache with `limit` distinct job identities.
        for i in 0..<limit {
            coordinator.refresh(makeInput(jobID: "job-\(i)", splitLabels: ["A"]))
            #expect(
                await waitUntil { coordinator.tooltips == ["job-\(i)": "preview"] }
            )
        }
        let baselineCalls = calls.value
        #expect(baselineCalls == limit)

        // The first identity is still cached — refresh should NOT recompute.
        let first = makeInput(jobID: "job-0", splitLabels: ["A"])
        coordinator.refresh(first)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(calls.value == baselineCalls)

        // Adding a new (limit+1)-th identity evicts the oldest one AND
        // requires a fresh compute for the new entry.
        let overflow = makeInput(jobID: "job-overflow", splitLabels: ["A"])
        coordinator.refresh(overflow)
        #expect(
            await waitUntil { coordinator.tooltips == ["job-overflow": "preview"] }
        )
        #expect(calls.value == baselineCalls + 1)

        // The original first identity has been evicted; refreshing it again
        // must recompute, pushing calls to baselineCalls + 2.
        let recomputedFirst = makeInput(jobID: "job-0", splitLabels: ["A"])
        coordinator.refresh(recomputedFirst)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(calls.value == baselineCalls + 2)
    }

    @Test func deinitDuringPendingTask_doesNotCrash() async {
        // Coordinator is dropped while a detached preview task is still
        // running. The deinit must cancel the in-flight task; the task must
        // short-circuit before publishing and must not dereference the
        // already-released coordinator.
        let computeStarted = InvocationCounter()
        do {
            let coordinator = ProfileSplitPreviewCoordinator { input in
                computeStarted.increment()
                // Block synchronously to keep the task in flight when the
                // owning scope ends. Cancellation only takes effect after
                // this returns, so the cancelled-but-already-completed
                // branch in `accept` is exercised as well.
                Thread.sleep(forTimeInterval: 0.15)
                return [input.identity.jobID: "slow"]
            }
            coordinator.refresh(makeInput(splitLabels: ["A"]))
        }
        // The detached compute may not have started yet (cancel can land
        // before the body even runs); if it did, the counter was bumped.
        // Either way, after waiting for the sleep + cancel-aware unwind,
        // the counter is stable.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let finalValue = computeStarted.value
        #expect(finalValue == 0 || finalValue == 1)
        // Wait again to make sure no late publish happens.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(computeStarted.value == finalValue)
    }

    private func makeInput(splitLabels: [String]) -> ProfileSplitPreviewCoordinator.Input {
        makeInput(jobID: "job", splitLabels: splitLabels)
    }

    private func makeInput(jobID: String, splitLabels: [String]) -> ProfileSplitPreviewCoordinator.Input {
        let snapshot = SpeakerRoutingSnapshot(
            profileMappings: [
                .init(acousticLabel: 0, speakerLabel: "A"),
                .init(acousticLabel: 1, speakerLabel: "B")
            ],
            tokens: [],
            pauseCandidates: []
        )
        let operation = SpeakerSplitOperation(
            splitProfileLabels: splitLabels,
            routingSnapshotVersion: snapshot.version,
            routingSnapshotIdentity: snapshot.stableIdentity,
            derivedAt: "test",
            derivedSegments: [],
            derivedMergedResults: []
        )
        return .init(
            jobID: jobID,
            speakerInput: SpeakerRecognitionInput(audioPath: "/tmp/audio.m4a", sentences: []),
            routingSnapshot: snapshot,
            currentOperation: operation
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
