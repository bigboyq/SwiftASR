import Foundation
import Testing
@testable import SwiftASR

@Suite("Cleanup completion cache")
@MainActor
struct CleanupCompletionCacheTests {
    @Test func followsCurrentResultPayloadInsteadOfStaleJobMetadata() async throws {
        let path = try writeResult(
            mergedResults: [MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "S1",
                rawContent: "原文"
            )]
        )
        defer { try? FileManager.default.removeItem(at: path) }

        let job = ASRJob(
            id: "stale-cleanup",
            sourceAudioPath: "/tmp/stale.wav",
            sourceAudioHash: "stale-cleanup",
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            cleanupStatus: JobStatus.done.rawValue,
            cleanedAt: Date(),
            transcriptPath: path.path
        )
        let cache = CleanupCompletionCache()
        cache.refresh(jobs: [job])

        let state = try await waitForState(cache, jobID: job.id)
        #expect(state == false)
    }

    @Test func recognizesCompleteCurrentResult() async throws {
        let path = try writeResult(
            mergedResults: [MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "S1",
                rawContent: "原文",
                cleanedContent: "润色后"
            )]
        )
        defer { try? FileManager.default.removeItem(at: path) }

        let job = ASRJob(
            id: "cleaned-result",
            sourceAudioPath: "/tmp/cleaned.wav",
            sourceAudioHash: "cleaned-result",
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: path.path
        )
        let cache = CleanupCompletionCache()
        cache.refresh(jobs: [job])

        let state = try await waitForState(cache, jobID: job.id)
        #expect(state == true)
    }

    @Test func refreshingAnotherJobDoesNotReparseUnchangedResults() async throws {
        let stablePath = try writeResult(
            mergedResults: [MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "S1",
                rawContent: "原文",
                cleanedContent: "润色后"
            )]
        )
        let otherPath = try writeResult(
            mergedResults: [MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "S1",
                rawContent: "另一个任务"
            )]
        )
        defer {
            try? FileManager.default.removeItem(at: stablePath)
            try? FileManager.default.removeItem(at: otherPath)
        }

        let stableJob = ASRJob(
            id: "stable-job",
            sourceAudioPath: "/tmp/stable.wav",
            sourceAudioHash: "stable-job",
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: stablePath.path
        )
        let cache = CleanupCompletionCache()
        cache.refresh(jobs: [stableJob])
        #expect(try await waitForState(cache, jobID: stableJob.id) == true)

        // If refresh reparses every result, deleting this file would change
        // the cached value to false when an unrelated job is added.
        try FileManager.default.removeItem(at: stablePath)
        let otherJob = ASRJob(
            id: "other-job",
            sourceAudioPath: "/tmp/other.wav",
            sourceAudioHash: "other-job",
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: otherPath.path
        )
        cache.refresh(jobs: [stableJob, otherJob])

        #expect(try await waitForState(cache, jobID: otherJob.id) == false)
        #expect(cache.state(for: stableJob.id) == true)
    }

    @Test func removingJobEvictsItsCachedState() async throws {
        let path = try writeResult(
            mergedResults: [MergedResult(
                mergeId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "S1",
                rawContent: "原文",
                cleanedContent: "润色后"
            )]
        )
        defer { try? FileManager.default.removeItem(at: path) }
        let job = ASRJob(
            id: "removed-job",
            sourceAudioPath: "/tmp/removed.wav",
            sourceAudioHash: "removed-job",
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: path.path
        )
        let cache = CleanupCompletionCache()
        cache.refresh(jobs: [job])
        #expect(try await waitForState(cache, jobID: job.id) == true)

        cache.refresh(jobs: [])

        #expect(cache.state(for: job.id) == nil)
    }

    private func writeResult(mergedResults: [MergedResult]) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftASR-cleanup-cache-\(UUID().uuidString).result.json")
        let payload = ResultPayload(
            jobId: UUID().uuidString,
            audioPath: "/tmp/audio.wav",
            segments: [ResultSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "S1",
                rawText: "原文"
            )],
            mergedResults: mergedResults
        )
        try ResultStore.write(payload, to: path)
        return path
    }

    private func waitForState(
        _ cache: CleanupCompletionCache,
        jobID: String,
        timeoutIterations: Int = 100
    ) async throws -> Bool? {
        for _ in 0..<timeoutIterations {
            if let state = cache.state(for: jobID) { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("CleanupCompletionCache did not finish reading in time")
        return nil
    }
}
