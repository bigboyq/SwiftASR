import Testing
@testable import SwiftASR

@Suite("App workspace routing")
struct AppNavigationTests {
    @Test func resultsContainsOnlyEditableResultStates() {
        #expect(JobStatus.done.belongsInResults)
        #expect(JobStatus.partial.belongsInResults)
        #expect(!JobStatus.queued.belongsInResults)
        #expect(!JobStatus.failed.belongsInResults)
    }

    @Test func transcriptionContainsEveryNonResultState() {
        for status in [JobStatus.queued, .running, .processing, .failed, .cancelled] {
            #expect(status.belongsInTranscription)
        }
        #expect(!JobStatus.done.belongsInTranscription)
        #expect(!JobStatus.partial.belongsInTranscription)
    }

    @Test func primaryNavigationMatchesProductInformationArchitecture() {
        #expect(AppSection.allCases.map(\.title) == ["文件", "转写", "结果", "说话人", "设置"])
    }
}
