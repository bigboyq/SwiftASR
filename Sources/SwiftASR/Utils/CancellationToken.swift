import Foundation

/// 协作式取消 token。
/// 跟 FunASR-Mac `services/pipeline/_cancellation.py::CancellationToken` 一致：
///   - `check(stage)` 在每个 stage 入口检查（throw if cancelled）
///   - `cancel()` 触发取消（一次性，不可恢复）
///   - `isCancelled` 用于软检查（如循环中）
///
/// Swift 的 `Task.cancel()` 是协作式的（要 task 内 `Task.checkCancellation()`），
/// 但我们希望从外部（文件工作区的取消按钮）取消一个具体的 pipeline 任务，
/// 所以单独实现一个显式的 CancellationToken。
public final class CancellationToken: @unchecked Sendable {
    private var _cancelled: Bool = false
    private let lock = NSLock()

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }

    /// 在每个 stage 入口调用。已取消时抛 ``PipelineCancelled`` 错误。
    public func check(_ stage: String) throws {
        if isCancelled {
            throw PipelineCancelled(stage: stage)
        }
    }
}

public struct PipelineCancelled: Error, LocalizedError {
    public let stage: String
    public var errorDescription: String? { "已在 \(stage) 阶段取消" }
}

/// A non-cancellation pipeline failure with an explicit owning stage. The
/// coordinator uses this distinction to derive a partial result only when
/// speaker recognition failed; ASR/punctuation failures must remain hard
/// failures even if a stale sidecar happens to exist.
public struct PipelineStageFailure: Error, LocalizedError, Sendable {
    public let stage: String
    public let message: String

    public init(stage: String, underlying: Error) {
        self.stage = stage
        self.message = underlying.localizedDescription
    }

    public var errorDescription: String? {
        "\(stage) 阶段失败：\(message)"
    }
}
