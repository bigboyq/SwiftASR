import Testing
@testable import SwiftASR

@Test func asrCPUConcurrencyKeepsTwoWorkersAndSplitsPerformanceCoreBudget() {
    #expect(ASRCPUConcurrency.workerCount == 2)
    #expect(ASRCPUConcurrency.intraOpThreads(performanceCoreCount: 1) == 1)
    #expect(ASRCPUConcurrency.intraOpThreads(performanceCoreCount: 2) == 1)
    #expect(ASRCPUConcurrency.intraOpThreads(performanceCoreCount: 6) == 3)
    #expect(ASRCPUConcurrency.intraOpThreads(performanceCoreCount: 8) == 4)
}
