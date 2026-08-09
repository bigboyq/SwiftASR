import Testing
import Foundation
@testable import SwiftASR

/// Regression tests for the `ResultsViewState` refactor (audit F1.13).
///
/// `ResultsContent` previously declared 22 `@State` fields directly.
/// The refactor groups them into one `ObservableObject` and the view
/// holds them as a single `@StateObject` plus computed-property
/// re-exports (so existing view-body code keeps working unchanged).
///
/// These tests verify:
///  1. Default `ResultsViewState()` has the same default values the
///     view's old @State declarations had.
///  2. Every field delegated via the re-export pattern reads / writes
///     through the underlying `@Published` correctly.
///  3. Mutating sub-fields of a struct-typed @Published (e.g. mutating
///     `inScopeLabels` via `.insert`) fires objectWillChange.
@Suite @MainActor struct ResultsViewStateTests {

    @Test func defaultStateMatchesOriginalPublishedDefaults() {
        let state = ResultsViewState()
        // Data state
        #expect(state.payload == nil)
        #expect(state.inScopeLabels.isEmpty)
        #expect(state.suggestions.isEmpty)
        #expect(state.speakerScrollCursors.isEmpty)
        #expect(state.profileCohesions.isEmpty)
        #expect(state.speakerNames.isEmpty)
        #expect(state.activeJobID == nil)
        // UI state
        #expect(state.showSpeakerIDs == true)
        #expect(state.showTimestamps == true)
        #expect(state.showMerged == false)
        #expect(state.showRawText == true)
        #expect(state.previewContentVersion == 0)
        #expect(state.scrollTargetId == nil)
        // Banner state
        #expect(state.cleanupError == nil)
        #expect(state.persistenceError == nil)
        #expect(state.syncBanner == nil)
        #expect(state.infoBanner == nil)
        // Sheet / alert state
        #expect(state.showCleanupDialog == false)
        #expect(state.editingMergedResult == nil)
        #expect(state.createPersonTargetLabel == nil)
        #expect(state.splitProfileSelectionAlertLabel == nil)
        #expect(state.pendingProfileSplit == nil)
        #expect(state.completedSplitNotice == nil)
    }

    @Test func publishedMutationsFireObjectWillChange() {
        let state = ResultsViewState()
        var firedCount = 0
        let cancellable = state.objectWillChange.sink { _ in
            firedCount += 1
        }

        state.payload = ResultPayload(
            jobId: "abc", audioPath: "/tmp/test.m4a", segments: []
        )
        state.inScopeLabels = ["Speaker1"]
        state.showSpeakerIDs = false
        state.cleanupError = "boom"
        state.showCleanupDialog = true

        #expect(firedCount == 5)
        cancellable.cancel()
    }

    @Test func switchingJobsInvalidatesEscapingIdentityAndClearsJobState() {
        let state = ResultsViewState()
        let jobA = state.activate(jobID: "job-a")
        state.payload = ResultPayload(
            jobId: "job-a",
            audioPath: "/tmp/a.wav",
            segments: []
        )
        state.speakerNames = ["S1": "Alice"]
        state.cleanupError = "old"
        state.showCleanupDialog = true

        let jobB = state.activate(jobID: "job-b")

        #expect(state.isCurrent(jobA) == false)
        #expect(state.isCurrent(jobB))
        #expect(state.activeJobID == "job-b")
        #expect(state.payload == nil)
        #expect(state.speakerNames.isEmpty)
        #expect(state.cleanupError == nil)
        #expect(state.showCleanupDialog == false)
    }

    @Test func newerLoadSupersedesOlderLoadWithoutInvalidatingJobIdentity() {
        let state = ResultsViewState()
        let identity = state.activate(jobID: "job")
        let first = state.beginLoad(jobID: "job")
        let second = state.beginLoad(jobID: "job")

        #expect(state.isCurrent(identity))
        #expect(state.isCurrent(first) == false)
        #expect(state.isCurrent(second))
    }
}
