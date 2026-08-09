import Foundation
import SwiftData
import Testing
@testable import SwiftASR

/// Contract-level integration test for the persistence half of a pipeline run.
/// It deliberately uses a deterministic PipelineRunner operation so ongoing
/// diarization algorithm work cannot make this regression flaky.
@Suite("Pipeline persistence integration")
@MainActor
struct PipelinePersistenceIntegrationTests {
    private enum IntegrationFailure: LocalizedError {
        case sidecarWrite
        case pipeline

        var errorDescription: String? {
            switch self {
            case .sidecarWrite: return "injected speaker-input write failure"
            case .pipeline: return "injected pipeline failure"
            }
        }
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(SwiftASRModelSchema.modelTypes)
        let configuration = ModelConfiguration(
            "PipelinePersistenceIntegrationTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    @Test func runnerOutputSurvivesResultStoreSwiftDataExportAndCleanup() async throws {
        let jobId = "pipeline-persistence-integration"
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-persistence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let utterances = [
            UtteranceData(startMs: 0, endMs: 1_000, rawText: "你好。", speakerLabel: "说话人 1"),
            UtteranceData(startMs: 1_000, endMs: 2_000, rawText: "世界。", speakerLabel: "说话人 1")
        ]
        let embedding = [Float](repeating: 0.25, count: 192)
        let profile = SpeakerProfileData(
            speakerLabel: "说话人 1",
            fingerprintId: "fp_integration",
            totalDurationMs: 2_000,
            chunkCount: 1,
            centroidEmbedding: embedding,
            embeddingData: Data(bytes: embedding, count: embedding.count * MemoryLayout<Float>.size)
        )
        let metrics = PipelineStageMetrics()
        let runner = PipelineRunner { _, _, _, _, _ in
            PipelineRunnerOutput(
                utterances: utterances,
                speakerProfiles: [profile],
                metrics: metrics
            )
        }

        var completedOutput: PipelineRunnerOutput?
        for await event in runner.events(audioPath: "/tmp/integration.wav", token: CancellationToken()) {
            if case .completed(let resultUtterances, let resultProfiles, let resultMetrics) = event {
                completedOutput = PipelineRunnerOutput(
                    utterances: resultUtterances,
                    speakerProfiles: resultProfiles,
                    metrics: resultMetrics
                )
            }
        }
        let output = try #require(completedOutput)

        let context = try makeContext()
        let job = ASRJob(
            id: jobId,
            sourceAudioPath: "/tmp/integration.wav",
            sourceAudioHash: jobId,
            durationSeconds: 2
        )
        context.insert(job)
        try context.save()
        let lifecycle = JobLifecycleStore(modelContext: context)
        try lifecycle.markPipelineRunning(job, kind: .transcription)

        var payload = ResultPayload.from(
            utterances: output.utterances,
            audioPath: job.sourceAudioPath,
            jobId: job.id
        )
        payload.speakers = [ResultSpeaker(
            speakerLabel: "说话人 1",
            fingerprintId: output.speakerProfiles[0].fingerprintId
        )]
        let resultPath = ResultStore.stageResultPath(jobId: job.id, stageRoot: stageRoot.path)
        try ResultStore.write(payload, to: resultPath)

        job.transcriptPath = resultPath.path
        job.totalSpeakers = payload.speakers.count
        job.asrProcessingSeconds = Double(output.metrics.asrProcessingMilliseconds) / 1_000
        job.speakerProcessingSeconds = Double(output.metrics.speakerMs) / 1_000
        try lifecycle.finishPipeline(
            job,
            status: .done,
            pipelineStage: "done",
            pipelineFraction: 1,
            pipelineMessage: "完成",
            errorMessage: nil,
            finishedAt: Date(timeIntervalSince1970: 10),
            operationKind: .transcription,
            operationStatus: .succeeded,
            operationMessage: "转写完成"
        )

        let restored = try ResultStore.read(from: resultPath)
        #expect(job.jobStatus == .done)
        #expect(restored.segments.map(\.rawText) == ["你好。", "世界。"])
        // “合并原文”先按自动 label 建立持久化单元，再固定按有效人名生成导出预览。
        let merged = SegmentMerger().buildMergedResults(segments: restored.segments)
        let display = SegmentMerger().buildDisplaySegments(
            mergedResults: merged,
            speakerNames: [:],
            showRawText: true
        )
        let exported = Exporter().exportParagraphs(
            utterances: display.map {
                UtteranceData(
                    startMs: $0.startMs,
                    endMs: $0.endMs,
                    rawText: $0.text,
                    speakerLabel: $0.displaySpeakerName
                )
            }
        )
        #expect(exported.contains("你好。世界。"))

        let deletion = try ResultArtifactDeletionTransaction(
            jobId: job.id,
            storedPath: resultPath.path,
            stageRoot: stageRoot.path
        )
        context.delete(job)
        try context.save()
        try deletion.commit()
        #expect(!FileManager.default.fileExists(atPath: resultPath.path))
        #expect(try context.fetch(FetchDescriptor<ASRJob>()).isEmpty)
    }

    @Test func sidecarWriteFailureMarksJobFailedInsteadOfPublishingSuccess() async throws {
        let context = try makeContext()
        let jobId = "sidecar-write-failure-" + UUID().uuidString
        let job = ASRJob(
            id: jobId,
            sourceAudioPath: "/tmp/sidecar-write-failure.wav",
            sourceAudioHash: jobId,
            durationSeconds: 0,
            status: JobStatus.queued.rawValue
        )
        context.insert(job)
        try JobLifecycleStore(modelContext: context).enqueue(job)

        let input = SpeakerRecognitionInput(
            audioPath: job.sourceAudioPath,
            sentences: [ASRSentence(text: "测试", startMs: 0, endMs: 100)]
        )
        let coordinator = FileActionCoordinator(
            settingsStore: SettingsStore.createTestInstance(),
            pipelineRunnerBuilder: { _, _, _ in
                PipelineRunner { _, _, _, onSpeakerInput, _ in
                    onSpeakerInput(input)
                    return PipelineRunnerOutput(
                        utterances: [], speakerProfiles: [], metrics: PipelineStageMetrics()
                    )
                }
            },
            speakerInputWriter: { _, _ in throw IntegrationFailure.sidecarWrite }
        )

        coordinator.startQueuedJob(
            jobId: jobId, audioPath: job.sourceAudioPath, modelContext: context
        )
        #expect(await waitUntil { !coordinator.hasActivePipeline })

        let restored = try #require(try ASRJobRepository.findById(jobId, in: context))
        #expect(restored.jobStatus == .failed)
        #expect(restored.transcriptPath == nil)
        #expect(!FileManager.default.fileExists(atPath: ResultStore.stageResultPath(jobId: jobId).path))
    }

    @Test func terminalRunAutomaticallyStartsNextQueuedJob() async throws {
        let context = try makeContext()
        let settings = SettingsStore.createTestInstance()
        settings.setQueueSettings(.init(isPaused: false, automaticallyStartNext: true))
        let firstID = "queue-first-" + UUID().uuidString
        let secondID = "queue-second-" + UUID().uuidString
        for (id, path) in [
            (firstID, "/tmp/queue-first.wav"),
            (secondID, "/tmp/queue-second.wav")
        ] {
            let job = ASRJob(
                id: id, sourceAudioPath: path, sourceAudioHash: id,
                durationSeconds: 0, status: JobStatus.queued.rawValue
            )
            context.insert(job)
            try JobLifecycleStore(modelContext: context).enqueue(job)
        }

        var startedJobIDs: [String] = []
        let coordinator = FileActionCoordinator(
            settingsStore: settings,
            pipelineRunnerBuilder: { jobId, _, _ in
                startedJobIDs.append(jobId)
                return PipelineRunner { _, _, _, _, _ in
                    throw IntegrationFailure.pipeline
                }
            }
        )

        coordinator.startNextQueuedJobIfPossible(modelContext: context)
        #expect(await waitUntil { !coordinator.hasActivePipeline && startedJobIDs.count == 2 })

        #expect(startedJobIDs == [firstID, secondID])
        let first = try #require(try ASRJobRepository.findById(firstID, in: context))
        let second = try #require(try ASRJobRepository.findById(secondID, in: context))
        #expect(first.jobStatus == .failed)
        #expect(second.jobStatus == .failed)
    }

    @Test func queuedRetranscriptionUsesItsDestructiveStartPath() async throws {
        let context = try makeContext()
        let settings = SettingsStore.createTestInstance()
        settings.setQueueSettings(.init(isPaused: false, automaticallyStartNext: true))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftasr-queued-retranscription-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let jobID = "queued-retranscription-" + UUID().uuidString
        let resultURL = root.appendingPathComponent("\(jobID).result.json")
        let payload = ResultPayload(
            jobId: jobID,
            audioPath: "/tmp/queued-retranscription.wav",
            segments: [ResultSegment(
                segmentId: 1,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "说话人 1",
                rawText: "旧结果"
            )]
        )
        try ResultStore.write(payload, to: resultURL)
        let job = ASRJob(
            id: jobID,
            sourceAudioPath: payload.audioPath,
            sourceAudioHash: jobID,
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            transcriptPath: resultURL.path
        )
        context.insert(job)
        try context.save()
        try JobLifecycleStore(modelContext: context).enqueue(
            job,
            operation: .retranscription,
            restoreStatus: .done
        )

        var artifactExistedWhenRunnerStarted: Bool?
        let coordinator = FileActionCoordinator(
            settingsStore: settings,
            pipelineRunnerBuilder: { _, _, _ in
                artifactExistedWhenRunnerStarted = FileManager.default.fileExists(
                    atPath: resultURL.path
                )
                return PipelineRunner { _, _, _, _, _ in
                    throw IntegrationFailure.pipeline
                }
            }
        )

        coordinator.startNextQueuedJobIfPossible(modelContext: context)
        #expect(await waitUntil {
            artifactExistedWhenRunnerStarted != nil && !coordinator.hasActivePipeline
        })

        #expect(artifactExistedWhenRunnerStarted == false)
        #expect(job.transcriptPath == nil)
        #expect(!FileManager.default.fileExists(atPath: resultURL.path))
    }

    @Test func unpausingQueuedSpeakerReidentificationNeverStartsFullTranscription() async throws {
        let context = try makeContext()
        let settings = SettingsStore.createTestInstance()
        settings.setQueueSettings(.init(isPaused: true, automaticallyStartNext: true))
        let jobID = "queued-speaker-reidentification-" + UUID().uuidString
        let finishedAt = Date(timeIntervalSince1970: 100)
        let job = ASRJob(
            id: jobID,
            sourceAudioPath: "/tmp/queued-speaker-reidentification.wav",
            sourceAudioHash: jobID,
            durationSeconds: 1,
            status: JobStatus.done.rawValue,
            finishedAt: finishedAt
        )
        context.insert(job)
        try context.save()
        try JobLifecycleStore(modelContext: context).enqueue(
            job,
            operation: .speakerReidentification,
            restoreStatus: .done,
            restoreFinishedAt: finishedAt
        )

        var fullPipelineStarts = 0
        let coordinator = FileActionCoordinator(
            settingsStore: settings,
            pipelineRunnerBuilder: { _, _, _ in
                fullPipelineStarts += 1
                return PipelineRunner { _, _, _, _, _ in
                    throw IntegrationFailure.pipeline
                }
            }
        )

        coordinator.setQueuePaused(false, modelContext: context)
        #expect(await waitUntil { !coordinator.hasActivePipeline && job.jobStatus != .queued })

        #expect(fullPipelineStarts == 0)
        #expect(job.jobStatus == .done)
        #expect(job.finishedAt == finishedAt)
        #expect(job.latestOperationKind == .speakerReidentification)
        #expect(job.latestOperationStatus == .failed)
    }

    @Test func cancellationDuringASRIgnoresStaleSpeakerInputSidecar() async throws {
        // A previous run left a speaker-input sidecar. A retry that is cancelled
        // during ASR (before this run emits its own speakerInput) must NOT derive
        // `.partial` from the stale sidecar.
        let context = try makeContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftasr-stale-sidecar-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let jobID = "stale-sidecar-\(UUID().uuidString)"
        let resultURL = root.appendingPathComponent("\(jobID).result.json")
        let speakerInputURL = root.appendingPathComponent("\(jobID).speaker-input.json")
        let stalePayload = ResultPayload(
            jobId: jobID,
            audioPath: "/tmp/stale-sidecar.wav",
            segments: [ResultSegment(
                segmentId: 1, startMs: 0, endMs: 1_000,
                speakerLabel: "说话人 1", rawText: "旧结果"
            )]
        )
        try ResultStore.write(stalePayload, to: resultURL)
        let staleInput = SpeakerRecognitionInput(
            audioPath: "/tmp/stale-sidecar.wav",
            sentences: [ASRSentence(text: "旧结果", startMs: 0, endMs: 1_000)]
        )
        try ResultStore.writeSpeakerInput(staleInput, to: speakerInputURL)

        let job = ASRJob(
            id: jobID,
            sourceAudioPath: "/tmp/stale-sidecar.wav",
            sourceAudioHash: jobID,
            durationSeconds: 1,
            status: JobStatus.failed.rawValue,
            transcriptPath: resultURL.path
        )
        context.insert(job)
        try context.save()
        try JobLifecycleStore(modelContext: context).markRetryQueued(job)
        try JobLifecycleStore(modelContext: context).moveQueuedJobToTop(id: jobID)

        let coordinator = FileActionCoordinator(
            settingsStore: SettingsStore.createTestInstance(),
            pipelineRunnerBuilder: { _, _, _ in
                // Cancel immediately during ASR, before any speakerInput.
                PipelineRunner { _, _, _, _, _ in
                    throw PipelineCancelled(stage: "asr")
                }
            }
        )

        coordinator.runPipeline(jobId: jobID, audioPath: job.sourceAudioPath, modelContext: context)
        #expect(await waitUntil { !coordinator.hasActivePipeline })

        let restored = try #require(try ASRJobRepository.findById(jobID, in: context))
        #expect(restored.jobStatus == .cancelled)
        // The stale result.json must not have been overwritten by a partial persister.
        let reloaded = try ResultStore.read(from: resultURL)
        #expect(reloaded.segments.map(\.rawText) == ["旧结果"])
    }

    @Test func cancellationAfterCurrentRunSpeakerInputDerivesPartial() async throws {
        // When the current run emits its own speakerInput and then is cancelled,
        // `.partial` is valid and must be derived.
        let context = try makeContext()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftasr-current-sidecar-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let jobID = "current-sidecar-\(UUID().uuidString)"
        let resultURL = root.appendingPathComponent("\(jobID).result.json")
        let speakerInputURL = root.appendingPathComponent("\(jobID).speaker-input.json")

        let job = ASRJob(
            id: jobID,
            sourceAudioPath: "/tmp/current-sidecar.wav",
            sourceAudioHash: jobID,
            durationSeconds: 1,
            status: JobStatus.queued.rawValue
        )
        context.insert(job)
        try JobLifecycleStore(modelContext: context).enqueue(job)

        let input = SpeakerRecognitionInput(
            audioPath: job.sourceAudioPath,
            sentences: [ASRSentence(text: "本次 ASR 结果", startMs: 0, endMs: 500)]
        )
        let coordinator = FileActionCoordinator(
            settingsStore: SettingsStore.createTestInstance(),
            pipelineRunnerBuilder: { _, _, _ in
                PipelineRunner { _, _, _, onSpeakerInput, _ in
                    onSpeakerInput(input)
                    throw PipelineCancelled(stage: "speaker")
                }
            },
            // Redirect the sidecar write into the temp dir so locateSpeakerInputPath
            // (which searches beside the transcript path) finds the current run's sidecar.
            speakerInputWriter: { payload, _ in
                try ResultStore.writeSpeakerInput(payload, to: speakerInputURL)
            }
        )
        job.transcriptPath = resultURL.path

        coordinator.startQueuedJob(jobId: jobID, audioPath: job.sourceAudioPath, modelContext: context)
        #expect(await waitUntil { !coordinator.hasActivePipeline })

        let restored = try #require(try ASRJobRepository.findById(jobID, in: context))
        #expect(restored.jobStatus == .partial)
        #expect(restored.transcriptPath != nil)
        // The partial result must be readable from wherever writePath resolved it.
        let resolved = try ResultStore.readPath(jobId: jobID, storedPath: restored.transcriptPath)
        let reloaded = try ResultStore.read(from: resolved)
        #expect(reloaded.jobId == jobID)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
