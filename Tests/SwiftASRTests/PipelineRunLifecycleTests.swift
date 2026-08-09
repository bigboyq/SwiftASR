import Testing
@testable import SwiftASR

@Suite("Pipeline run lifecycle")
@MainActor
struct PipelineRunLifecycleTests {
    @Test func endedEventStreamUsesCancellationWhenEitherCancellationSignalIsSet() {
        #expect(
            PipelineRunLifecycle.terminalForEndedEventStream(
                taskCancelled: false,
                tokenCancelled: true
            ) == .cancelled
        )
        #expect(
            PipelineRunLifecycle.terminalForEndedEventStream(
                taskCancelled: true,
                tokenCancelled: false
            ) == .cancelled
        )
    }

    @Test func endedEventStreamWithoutCancellationIsAnInternalFailure() {
        #expect(
            PipelineRunLifecycle.terminalForEndedEventStream(
                taskCancelled: false,
                tokenCancelled: false
            ) == .failed
        )
    }

    @Test func runMustStartBeforeItCanFinish() throws {
        var lifecycle = PipelineRunLifecycle()

        #expect(lifecycle.state == .created)
        #expect(throws: PipelineRunLifecycleError.notRunning) {
            try lifecycle.finish(.failed)
        }

        try lifecycle.start()
        #expect(lifecycle.state == .running)
    }

    @Test func runAcceptsExactlyOneTerminalOutcome() throws {
        var lifecycle = PipelineRunLifecycle()
        try lifecycle.start()
        try lifecycle.finish(.completed)

        #expect(lifecycle.state == .finished(.completed))
        #expect(lifecycle.isTerminal)
        #expect(throws: PipelineRunLifecycleError.alreadyFinished(.completed)) {
            try lifecycle.finish(.failed)
        }
    }

    @Test func runCannotStartTwice() throws {
        var lifecycle = PipelineRunLifecycle()
        try lifecycle.start()

        #expect(throws: PipelineRunLifecycleError.alreadyStarted) {
            try lifecycle.start()
        }
    }

    @Test func handleClaimsTerminalOnlyOnce() throws {
        let handle = PipelineRunHandle(
            jobId: "job",
            operationKind: .transcription,
            token: CancellationToken()
        )
        try handle.start()

        #expect(handle.claimTerminal())
        #expect(!handle.claimTerminal())
        try handle.finish(.failed)
        #expect(handle.lifecycle.state == .finished(.failed))
    }
}
