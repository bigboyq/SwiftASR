import Foundation

/// 在后台预热并复用一个 `AudioPipeline`。
///
/// `AudioPipeline` 不持有 PCM 或 fbank；那些大数组仅存在于每次 run 的局部变量中，
/// 因此缓存它只会保留 ONNX / CoreML model session。全局转写本来就是串行的，复用
/// 同一个 actor 也不会让多个 job 并发使用同一组 session。
public final class PrewarmedAudioPipelineStore: @unchecked Sendable {
    public enum Readiness: Sendable, Equatable {
        case idle
        case warming
        case ready
    }

    private let lock = NSLock()
    private var pipeline: AudioPipeline?
    private var modelsRoot: String?
    private var warmupTask: Task<AudioPipeline, Error>?
    /// 切换模型目录或释放缓存时递增，避免已经取消的预热任务重新写回缓存。
    private var generation = 0

    public init() {}

    public func readiness(for modelsRoot: String) -> Readiness {
        lock.withLock {
            guard self.modelsRoot == modelsRoot else { return .idle }
            if pipeline != nil { return .ready }
            return warmupTask == nil ? .idle : .warming
        }
    }

    /// 若模型未就绪则在 detached task 中构建 ONNX / CoreML sessions；若已在预热，
    /// 所有调用方等待同一 task，避免为同一模型重复占用内存和 CPU。
    public func acquire(modelsRoot: String) async throws -> AudioPipeline {
        let setup: (cached: AudioPipeline?, task: Task<AudioPipeline, Error>?, generation: Int) = lock.withLock {
            if self.modelsRoot == modelsRoot, let pipeline {
                return (pipeline, nil, generation)
            }

            if self.modelsRoot != modelsRoot {
                warmupTask?.cancel()
                pipeline = nil
                warmupTask = nil
                self.modelsRoot = modelsRoot
                generation += 1
            }

            if let existing = warmupTask {
                return (nil, existing, generation)
            }

            let root = modelsRoot
            let task = Task.detached(priority: .userInitiated) { () throws -> AudioPipeline in
                Logger.shared.info("开始后台预热转写模型")
                return try AudioPipeline(modelsRoot: root)
            }
            warmupTask = task
            return (nil, task, generation)
        }

        if let cached = setup.cached { return cached }
        guard let task = setup.task else {
            throw NSError(
                domain: "PrewarmedAudioPipelineStore",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "模型预热状态无效，未找到可等待的 pipeline task。"]
            )
        }

        let prepared: AudioPipeline
        do {
            prepared = try await task.value
        } catch is CancellationError {
            // R4-P2-15：modelsRoot 切换或 release 取消了预热任务。
            // 不要把 CancellationError 冒泡成"构造失败"——这是预期取消。
            lock.withLock {
                guard generation == setup.generation, self.modelsRoot == modelsRoot else { return }
                warmupTask = nil
            }
            throw CancellationError()
        } catch {
            lock.withLock {
                guard generation == setup.generation, self.modelsRoot == modelsRoot else { return }
                warmupTask = nil
            }
            throw error
        }

        let didCache = lock.withLock {
            guard generation == setup.generation, self.modelsRoot == modelsRoot else { return false }
            pipeline = prepared
            warmupTask = nil
            return true
        }
        if didCache {
            Logger.shared.info("转写模型预热完成，已缓存 session")
        }
        return prepared
    }

    public func prewarm(modelsRoot: String) async throws {
        _ = try await acquire(modelsRoot: modelsRoot)
    }

    /// 退出时同步移除缓存引用，让 ONNX / CoreML session 释放。
    /// 正在运行的 job 会暂时持有自己的局部引用，直到其取消和退出。
    public func release() {
        lock.withLock {
            warmupTask?.cancel()
            warmupTask = nil
            pipeline = nil
            modelsRoot = nil
            generation += 1
        }
        Logger.shared.info("已释放预热的转写模型")
    }
}
