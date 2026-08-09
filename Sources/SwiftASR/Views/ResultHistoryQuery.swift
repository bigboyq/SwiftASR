import Foundation

enum ResultHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case cleaned
    case uncleaned

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .cleaned: return "已润色"
        case .uncleaned: return "未润色"
        }
    }
}

struct ResultHistoryEntry: Identifiable, Equatable {
    let id: String
    let sourceAudioPath: String
    let durationSeconds: Double
    let jobStatus: JobStatus
    let cleanupStatus: JobStatus?
    let cleanedAt: Date?
    let createdAt: Date
    let finishedAt: Date?
    let namedSpeakers: Int
    let totalSpeakers: Int
    let cleanupComplete: Bool

    init(job: ASRJob, cleanupComplete: Bool? = nil) {
        id = job.id
        sourceAudioPath = job.sourceAudioPath
        durationSeconds = job.durationSeconds
        jobStatus = job.jobStatus
        cleanupStatus = job.cleanupJobStatus
        cleanedAt = job.cleanedAt
        createdAt = job.createdAt
        finishedAt = job.finishedAt
        namedSpeakers = job.namedSpeakers
        totalSpeakers = job.totalSpeakers
        self.cleanupComplete = cleanupComplete ?? job.hasCleanupCompletion
    }

    var fileName: String { URL(fileURLWithPath: sourceAudioPath).lastPathComponent }
    var parentDirectory: String { URL(fileURLWithPath: sourceAudioPath).deletingLastPathComponent().path }
    var completedAt: Date { finishedAt ?? createdAt }
    var isCleaned: Bool { cleanupComplete }
}

struct ResultHistoryPage: Equatable {
    let entries: [ResultHistoryEntry]
    let totalCount: Int
    let pageIndex: Int
    let pageCount: Int

    var pageNumber: Int { pageIndex + 1 }
}

enum ResultHistoryQuery {
    static let pageSize = 50

    static func orderedJobs(from jobs: [ASRJob]) -> [ASRJob] {
        jobs.lazy
            .filter { $0.jobStatus.belongsInResults }
            .sorted {
                // 按"最近一次活动"排序（max of lastOperationAt/cleanedAt/finishedAt/createdAt）,
                // 旧版本只用 finishedAt ?? createdAt → 重新识别说话人/润色后不更新排序,UI 体验坏。
                let lhs = $0.mostRecentActivity
                let rhs = $1.mostRecentActivity
                if lhs != rhs { return lhs > rhs }
                return $0.id > $1.id
            }
    }

    /// Startup selection equivalent for the Sendable job snapshots returned
    /// by the background SwiftData recovery pass.
    static func orderedJobSnapshots(from jobs: [StartupJobSnapshot]) -> [StartupJobSnapshot] {
        jobs.lazy
            .filter { $0.status.belongsInResults }
            .sorted {
                if $0.mostRecentActivity != $1.mostRecentActivity {
                    return $0.mostRecentActivity > $1.mostRecentActivity
                }
                return $0.id > $1.id
            }
    }

    static func entries(
        from jobs: [ASRJob],
        cleanupStates: [String: Bool] = [:]
    ) -> [ResultHistoryEntry] {
        orderedJobs(from: jobs).map { job in
            ResultHistoryEntry(job: job, cleanupComplete: cleanupStates[job.id])
        }
    }

    static func page(
        entries: [ResultHistoryEntry],
        searchText: String,
        filter: ResultHistoryFilter,
        requestedPage: Int
    ) -> ResultHistoryPage {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            let matchesSearch = query.isEmpty
                || entry.fileName.localizedCaseInsensitiveContains(query)
                || entry.parentDirectory.localizedCaseInsensitiveContains(query)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .cleaned: matchesFilter = entry.isCleaned
            case .uncleaned: matchesFilter = !entry.isCleaned
            }
            return matchesSearch && matchesFilter
        }
        guard !filtered.isEmpty else {
            return ResultHistoryPage(entries: [], totalCount: 0, pageIndex: 0, pageCount: 0)
        }

        let pageCount = Int(ceil(Double(filtered.count) / Double(pageSize)))
        let pageIndex = min(max(requestedPage, 0), pageCount - 1)
        let start = pageIndex * pageSize
        let end = min(start + pageSize, filtered.count)
        return ResultHistoryPage(
            entries: Array(filtered[start..<end]),
            totalCount: filtered.count,
            pageIndex: pageIndex,
            pageCount: pageCount
        )
    }
}
