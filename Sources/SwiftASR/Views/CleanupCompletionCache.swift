import Combine
import Foundation

/// 后台读取 result.json，按结果页的实际预览规则判断当前 job 是否已经完整润色。
@MainActor
final class CleanupCompletionCache: ObservableObject {
    @Published private(set) var states: [String: Bool] = [:]
    @Published private(set) var loadedIDs: Set<String> = []

    private var requestedKeys: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func refresh(jobs: [ASRJob]) {
        let snapshots = jobs.map {
            JobSnapshot(
                id: $0.id,
                storedPath: $0.transcriptPath,
                activityKey: "\($0.transcriptPath ?? "")|\($0.mostRecentActivity.timeIntervalSinceReferenceDate)"
            )
        }
        let incomingIDs = Set(snapshots.map(\.id))
        for removedID in Set(requestedKeys.keys).subtracting(incomingIDs) {
            tasks.removeValue(forKey: removedID)?.cancel()
            requestedKeys.removeValue(forKey: removedID)
            states.removeValue(forKey: removedID)
            loadedIDs.remove(removedID)
        }

        for snapshot in snapshots {
            guard requestedKeys[snapshot.id] != snapshot.activityKey else { continue }
            requestedKeys[snapshot.id] = snapshot.activityKey
            tasks.removeValue(forKey: snapshot.id)?.cancel()
            states.removeValue(forKey: snapshot.id)
            loadedIDs.remove(snapshot.id)

            let expectedKey = snapshot.activityKey
            tasks[snapshot.id] = Task.detached(priority: .utility) { [weak self] in
                let complete = Self.readState(for: snapshot)
                guard !Task.isCancelled else { return }
                await self?.accept(
                    complete,
                    jobID: snapshot.id,
                    activityKey: expectedKey
                )
            }
        }
    }

    /// nil = 结果文件尚未完成读取；false = 已读取且当前结果没有完整润色。
    func state(for jobID: String) -> Bool? {
        guard loadedIDs.contains(jobID) else { return nil }
        return states[jobID] ?? false
    }

    private struct JobSnapshot: Sendable {
        let id: String
        let storedPath: String?
        let activityKey: String
    }

    private func accept(_ state: Bool, jobID: String, activityKey: String) {
        guard requestedKeys[jobID] == activityKey else { return }
        states[jobID] = state
        loadedIDs.insert(jobID)
        tasks.removeValue(forKey: jobID)
    }

    private nonisolated static func readState(for job: JobSnapshot) -> Bool {
        do {
            let path = try ResultStore.readPath(jobId: job.id, storedPath: job.storedPath)
            let payload = try ResultStore.read(from: path)
            return ResultsPresentation.hasCompleteCleanedResults(in: payload)
        } catch {
            // 没有 result 或 result 损坏时，宁可显示未润色，也不显示错误的已润色。
            return false
        }
    }
}
