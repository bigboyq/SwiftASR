import Foundation
import Testing
@testable import SwiftASR

@Suite("Result history query")
struct ResultHistoryQueryTests {
    @Test func excludesJobsWithoutEditableResultsAndSortsByCompletion() {
        let older = job(id: "older", path: "/audio/older.wav", status: .done, createdAt: 1, finishedAt: 2)
        let newer = job(id: "newer", path: "/audio/newer.wav", status: .partial, createdAt: 1, finishedAt: 3)
        let queued = job(id: "queued", path: "/audio/queued.wav", status: .queued, createdAt: 4)

        #expect(ResultHistoryQuery.entries(from: [older, queued, newer]).map(\.id) == ["newer", "older"])
    }

    @Test func searchesBothFileNameAndParentDirectory() {
        let filename = ResultHistoryEntry(job: job(id: "a", path: "/audio/meeting.wav", status: .done, createdAt: 1))
        let directory = ResultHistoryEntry(job: job(id: "b", path: "/archive/client/call.wav", status: .done, createdAt: 2))

        let byFilename = ResultHistoryQuery.page(entries: [filename, directory], searchText: "MEET", filter: .all, requestedPage: 0)
        let byDirectory = ResultHistoryQuery.page(entries: [filename, directory], searchText: "client", filter: .all, requestedPage: 0)

        #expect(byFilename.entries.map(\.id) == ["a"])
        #expect(byDirectory.entries.map(\.id) == ["b"])
    }

    @Test func filtersByCleanupStateAndPaginatesWithClampedPage() {
        let cleaned = job(
            id: "cleaned", path: "/audio/cleaned.wav", status: .done,
            createdAt: 1, cleanupStatus: .done, cleanedAt: 3
        )
        let remaining = (0..<51).map { offset in
            job(id: "raw-\(offset)", path: "/audio/raw-\(offset).wav", status: .done, createdAt: offset + 2)
        }
        let entries = ResultHistoryQuery.entries(from: [cleaned] + remaining)

        let cleanedPage = ResultHistoryQuery.page(entries: entries, searchText: "", filter: .cleaned, requestedPage: 0)
        let finalRawPage = ResultHistoryQuery.page(entries: entries, searchText: "", filter: .uncleaned, requestedPage: 99)

        #expect(cleanedPage.entries.map(\.id) == ["cleaned"])
        #expect(finalRawPage.totalCount == 51)
        #expect(finalRawPage.pageCount == 2)
        #expect(finalRawPage.pageIndex == 1)
        #expect(finalRawPage.entries.count == 1)
    }

    @Test func staleDoneCleanupWithoutCompletionTimeIsNotCleaned() {
        let stale = job(
            id: "stale", path: "/audio/stale.wav", status: .done,
            createdAt: 1, cleanupStatus: .done
        )
        let entry = ResultHistoryEntry(job: stale)

        #expect(!entry.isCleaned)
    }

    @Test func orderedJobsPreferMostRecentlyFinishedResult() {
        // Bug fix 2026-07-24: 之前按 `finishedAt ?? createdAt` 排序 → 重新识别说话人 (re-identify) 后
        // 不会更新 finishedAt,UI 列表不响应。现在按 `mostRecentActivity` (max of lastOperationAt
        // / cleanedAt / finishedAt / createdAt) 排序,re-identify / re-transcribe / 润色完成
        // 都会让对应 job 冒到顶。ASRJob.mostRecentActivity 计算 max 链。
        let oldJob = job(
            id: "old", path: "/audio/old.wav", status: .done,
            createdAt: 10, finishedAt: 20, lastOperationAt: 18
        )
        // 跟旧测试反着:这个 job 创建得晚 (30),re-identify 后 lastOperationAt=25
        // 比 oldJob.finishedAt=20 晚 → 它应该排第一
        let reidentified = job(
            id: "reidentified", path: "/audio/reid.wav", status: .done,
            createdAt: 30, finishedAt: 15, lastOperationAt: 25
        )

        #expect(ResultHistoryQuery.orderedJobs(from: [oldJob, reidentified]).map(\.id) == ["reidentified", "old"])
    }

    private func job(
        id: String,
        path: String,
        status: JobStatus,
        createdAt: Int,
        finishedAt: Int? = nil,
        cleanupStatus: JobStatus? = nil,
        cleanedAt: Int? = nil,
        lastOperationAt: Int? = nil
    ) -> ASRJob {
        ASRJob(
            id: id,
            sourceAudioPath: path,
            sourceAudioHash: id,
            durationSeconds: 60,
            status: status.rawValue,
            cleanupStatus: cleanupStatus?.rawValue,
            createdAt: Date(timeIntervalSinceReferenceDate: Double(createdAt)),
            finishedAt: finishedAt.map { Date(timeIntervalSinceReferenceDate: Double($0)) },
            cleanedAt: cleanedAt.map { Date(timeIntervalSinceReferenceDate: Double($0)) },
            lastOperationAt: lastOperationAt.map { Date(timeIntervalSinceReferenceDate: Double($0)) }
        )
    }
}
