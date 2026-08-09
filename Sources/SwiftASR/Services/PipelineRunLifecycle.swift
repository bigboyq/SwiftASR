import Foundation

/// 单次 pipeline run 的内存生命周期。
///
/// 它不负责 SwiftData 持久化，只约束 runner/coordinator 之间的事件契约：
/// 一次 run 必须先启动，且只能提交一次终态。
enum PipelineRunTerminal: Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

enum PipelineRunLifecycleError: Error, Equatable, LocalizedError {
    case alreadyStarted
    case notRunning
    case alreadyFinished(PipelineRunTerminal)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "Pipeline run 已经启动。"
        case .notRunning:
            return "Pipeline run 尚未进入 running。"
        case let .alreadyFinished(terminal):
            return "Pipeline run 已经提交终态：\(terminal)。"
        }
    }
}

struct PipelineRunLifecycle: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case created
        case running
        case finished(PipelineRunTerminal)
    }

    private(set) var state: State = .created

    /// Resolves an AsyncStream consumer that ended without a terminal event.
    /// Cancellation is an expected user/lifecycle outcome; an un-cancelled
    /// stream ending is an internal runner bug and must surface as failure.
    static func terminalForEndedEventStream(
        taskCancelled: Bool,
        tokenCancelled: Bool
    ) -> PipelineRunTerminal {
        taskCancelled || tokenCancelled ? .cancelled : .failed
    }

    var isTerminal: Bool {
        if case .finished = state { return true }
        return false
    }

    mutating func start() throws {
        guard state == .created else {
            if case let .finished(terminal) = state {
                throw PipelineRunLifecycleError.alreadyFinished(terminal)
            }
            throw PipelineRunLifecycleError.alreadyStarted
        }
        state = .running
    }

    mutating func finish(_ terminal: PipelineRunTerminal) throws {
        guard state == .running else {
            if case let .finished(existing) = state {
                throw PipelineRunLifecycleError.alreadyFinished(existing)
            }
            throw PipelineRunLifecycleError.notRunning
        }
        state = .finished(terminal)
    }
}

/// Coordinator 持有的单次 pipeline 运行句柄。
///
/// task/token/runID 必须作为一个整体管理，避免旧 task 的 defer 清理新一轮
/// 同 job 运行状态。句柄本身只在 MainActor 上使用；token 负责跨并发域取消。
@MainActor
final class PipelineRunHandle {
    let id = UUID()
    let jobId: String
    let operationKind: JobOperationKind
    let token: CancellationToken
    private(set) var lifecycle = PipelineRunLifecycle()
    private(set) var terminalClaimed = false
    var task: Task<Void, Never>?

    init(jobId: String, operationKind: JobOperationKind, token: CancellationToken) {
        self.jobId = jobId
        self.operationKind = operationKind
        self.token = token
    }

    func start() throws {
        try lifecycle.start()
    }

    /// 终态事件只允许被当前 run 消费一次。
    func claimTerminal() -> Bool {
        guard !terminalClaimed, lifecycle.state == .running else { return false }
        terminalClaimed = true
        return true
    }

    func finish(_ terminal: PipelineRunTerminal) throws {
        try lifecycle.finish(terminal)
    }
}
