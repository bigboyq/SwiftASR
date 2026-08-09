import Testing
@testable import SwiftASR

@Suite("Results speaker suggestion publication")
@MainActor
struct ResultsSpeakerSuggestionPublisherTests {
    @Test("stale job projection cannot overwrite the active job")
    func staleJobProjectionIsDiscarded() {
        let state = ResultsViewState()
        let jobA = state.activate(jobID: "job-a")
        _ = state.activate(jobID: "job-b")
        let current = SpeakerSuggestion(
            personName: "当前任务",
            personId: "current",
            score: 0.9,
            confidence: .high
        )
        state.suggestions = ["SpeakerB": current]

        ResultsSpeakerSuggestionPublisher.publish(
            [
                "SpeakerA": SpeakerSuggestion(
                    personName: "旧任务",
                    personId: "stale",
                    score: 0.8,
                    confidence: .medium
                )
            ],
            for: jobA,
            to: state
        )

        #expect(state.suggestions == ["SpeakerB": current])
    }

    @Test("current job projection publishes synchronously")
    func currentJobProjectionPublishes() {
        let state = ResultsViewState()
        let identity = state.activate(jobID: "job")
        let suggestion = SpeakerSuggestion(
            personName: "新推荐",
            personId: "person",
            score: 0.95,
            confidence: .high
        )

        ResultsSpeakerSuggestionPublisher.publish(
            ["Speaker0": suggestion],
            for: identity,
            to: state
        )

        #expect(state.suggestions == ["Speaker0": suggestion])
    }
}
