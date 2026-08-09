import Foundation
import Testing
@testable import SwiftASR

@Suite("Pipeline runner event boundary")
@MainActor
struct PipelineRunnerTests {
    private enum TestError: Error, Equatable {
        case modelContract
    }

    @Test func forwardsCallbacksAndCompletesExactlyOnce() async {
        let metrics = PipelineStageMetrics()
        let sentence = ASRSentence(text: "hello", startMs: 0, endMs: 100)
        let input = SpeakerRecognitionInput(audioPath: "test.wav", sentences: [sentence])
        let runner = PipelineRunner { path, onProgress, shouldCancel, onSpeakerInput, onStageComplete in
            #expect(path == "test.wav")
            #expect(!shouldCancel())
            onProgress("load", 0.5, "loading")
            onSpeakerInput(input)
            onStageComplete("preprocess", metrics)
            return PipelineRunnerOutput(utterances: [], speakerProfiles: [], metrics: metrics)
        }
        let token = CancellationToken()
        var events: [PipelineRunner.Event] = []

        for await event in runner.events(audioPath: "test.wav", token: token) {
            events.append(event)
        }

        #expect(events.count == 4)
        if case .progress(stage: "load", fraction: 0.5, message: "loading") = events[0] {} else {
            Issue.record("progress callback was not forwarded")
        }
        if case .speakerInput(let received) = events[1] {
            #expect(received.audioPath == input.audioPath)
        } else {
            Issue.record("speaker input callback was not forwarded")
        }
        switch events[2] {
        case .stageMetrics(let stage, let receivedMetrics):
            #expect(stage == "preprocess")
            #expect(receivedMetrics == metrics)
        default:
            Issue.record("stage metrics callback was not forwarded")
        }
        switch events[3] {
        case .completed(let utterances, let profiles, let receivedMetrics):
            #expect(utterances.isEmpty)
            #expect(profiles.isEmpty)
            #expect(receivedMetrics == metrics)
        default:
            Issue.record("runner did not finish with completed")
        }
    }

    @Test func mapsPipelineCancellationToCancelledTerminalEvent() async {
        let runner = PipelineRunner { _, _, _, _, _ in
            throw PipelineCancelled(stage: "asr")
        }
        let token = CancellationToken()
        var events: [PipelineRunner.Event] = []

        for await event in runner.events(audioPath: "test.wav", token: token) {
            events.append(event)
        }

        #expect(events.count == 1)
        if case .cancelled = events.first {} else {
            Issue.record("PipelineCancelled was not mapped to cancelled")
        }
    }

    @Test func mapsUnexpectedPipelineErrorToFailedTerminalEvent() async {
        let runner = PipelineRunner { _, _, _, _, _ in
            throw TestError.modelContract
        }
        var events: [PipelineRunner.Event] = []

        for await event in runner.events(audioPath: "test.wav", token: CancellationToken()) {
            events.append(event)
        }

        #expect(events.count == 1)
        if case .failed(let error) = events.first {
            #expect((error as? TestError) == .modelContract)
        } else {
            Issue.record("unexpected pipeline error was not mapped to failed")
        }
    }

    @Test func mapsNonCancellationAudioConversionFailureToFailedTerminalEvent() async {
        let runner = PipelineRunner { _, _, _, _, _ in
            throw AudioConverterError.conversionError(underlying: nil)
        }
        var events: [PipelineRunner.Event] = []

        for await event in runner.events(audioPath: "test.wav", token: CancellationToken()) {
            events.append(event)
        }

        #expect(events.count == 1)
        if case let .failed(error) = events.first {
            // R4-P2-6：conversionError 现在携带 underlying，用模式匹配断言。
            if case .conversionError = error as? AudioConverterError {} else {
                Issue.record("audio conversion failure must not be presented as cancellation")
            }
        } else {
            Issue.record("audio conversion failure must not be presented as cancellation")
        }
    }

    @Test func operationSeesCancellationFromToken() async {
        let observed = LockedBox(false)
        let runner = PipelineRunner { _, _, shouldCancel, _, _ in
            while !shouldCancel() {
                try? await Task.sleep(for: .milliseconds(1))
            }
            observed.set(true)
            throw PipelineCancelled(stage: "load")
        }
        let token = CancellationToken()
        let stream = runner.events(audioPath: "test.wav", token: token)
        let consumer = Task {
            for await _ in stream {}
        }

        token.cancel()
        _ = await consumer.value

        #expect(observed.value)
    }

    @Test func emitsEventsInDocumentedOrder() async {
        // progress → stageMetrics → speakerInput → completed is the contract
        // the runner follows.  This pins it so a future refactor that
        // changes the order has to update this test deliberately.
        let metrics = PipelineStageMetrics(speakerMs: 100)
        let input = SpeakerRecognitionInput(audioPath: "test.wav", sentences: [])
        let runner = PipelineRunner { _, onProgress, _, onSpeakerInput, onStageComplete in
            onProgress("load", 0.0, "starting")
            onProgress("vad", 0.3, "decoding")
            onStageComplete("preprocess", metrics)
            onSpeakerInput(input)
            return PipelineRunnerOutput(
                utterances: [],
                speakerProfiles: [],
                metrics: metrics
            )
        }

        var eventOrder: [String] = []
        for await event in runner.events(audioPath: "test.wav", token: CancellationToken()) {
            switch event {
            case .progress(let stage, _, _): eventOrder.append("progress:\(stage)")
            case .stageMetrics(let stage, _): eventOrder.append("stageMetrics:\(stage)")
            case .speakerInput:              eventOrder.append("speakerInput")
            case .completed:                 eventOrder.append("completed")
            case .cancelled:                 eventOrder.append("cancelled")
            case .failed:                    eventOrder.append("failed")
            }
        }

        #expect(eventOrder == [
            "progress:load",
            "progress:vad",
            "stageMetrics:preprocess",
            "speakerInput",
            "completed"
        ])
    }

    @Test func cancellationDuringLongRunningOperationEmitsCancelledAndFinishesStream() async {
        // The runner contract: a long-running operation that respects
        // shouldCancel() must produce a single .cancelled event followed by
        // stream termination, with no .completed / .failed mixed in.
        let runner = PipelineRunner { _, _, shouldCancel, _, _ in
            for _ in 0..<10 where !shouldCancel() {
                try? await Task.sleep(for: .milliseconds(5))
            }
            throw PipelineCancelled(stage: "vad")
        }
        let token = CancellationToken()

        let task = Task {
            var events: [PipelineRunner.Event] = []
            for await event in runner.events(audioPath: "test.wav", token: token) {
                events.append(event)
            }
            return events
        }

        try? await Task.sleep(for: .milliseconds(10))
        token.cancel()
        let events = await task.value

        #expect(events.count == 1)
        if case .cancelled = events.first {} else {
            Issue.record("expected single .cancelled event, got \(events)")
        }
    }

    @Test func errorDuringSpeakerInputCallbackPropagatesAsFailed() async {
        // Defensive: the operation is supposed to handle sidecar write
        // failures itself.  This test pins that contract — the runner
        // does NOT translate AudioPipeline-internal errors; whatever the
        // operation throws is what the runner yields.
        let runner = PipelineRunner { _, _, _, _, _ in
            throw TestError.modelContract
        }

        var events: [PipelineRunner.Event] = []
        for await event in runner.events(audioPath: "test.wav", token: CancellationToken()) {
            events.append(event)
        }

        #expect(events.count == 1)
        if case .failed(let error) = events.first {
            #expect((error as? TestError) == .modelContract)
        } else {
            Issue.record("expected .failed event, got \(events)")
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
