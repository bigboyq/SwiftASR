import Foundation

/// 流式 VAD/ASR 的执行边界。
///
/// `AudioPipeline` 保留模型生命周期与各阶段编排；本 extension 只负责由 VAD producer
/// 和多个独立 ASR session 组成的有界生产/消费流水线。
extension AudioPipeline {
    static func reportCombinedProgress(
        vadEndFrame: Int,
        totalFrames: Int,
        progress: StreamingASRProgress,
        onProgress: @Sendable @escaping (String, Double, String) -> Void
    ) async {
        let vadFraction = Double(vadEndFrame) / Double(max(1, totalFrames))
        let snap = await progress.snapshot()
        let combined = vadFraction * 0.3 + snap.asrFraction * 0.7
        let message = "语音分段 \(Int(vadFraction * 100))% · 转写 \(snap.completed)/\(snap.produced) 批"
        onProgress("asr", combined, message)
    }

    static func transcribeWithStreamingVAD(
        fbank80: [Float],
        totalFrames: Int,
        totalDurationMs: Int,
        vad: VADONNXEngine,
        asrEngines: [ASRONNXEngine],
        asrDecoder: ASRDecoder,
        modelsRoot: String,
        onProgress: @Sendable @escaping (String, Double, String) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool
    ) async throws -> StreamingTranscriptionResult {
        let startedAt = Date()
        let channel = StreamingASRBatchChannel(capacity: asrEngines.count * 2)
        let progress = StreamingASRProgress(totalDurationMs: totalDurationMs)
        let asrFrontend = try ASRFrontend(modelsRoot: modelsRoot)
        let vadMvn = try FbankExtractor.loadMvnFile(
            path: ModelCatalog.filePath(definitionID: "vad", file: "am.mvn", modelsRoot: modelsRoot)
        )
        let vadChunkFrames = 6_000

        var vadMetrics: VADStreamMetrics?
        var asrWorkerMetrics: [ASRWorkerMetrics] = []
        try await withThrowingTaskGroup(of: StreamingTranscriptionEvent.self) { group in
            group.addTask {
                let vadStartedAt = Date()
                var frontendSeconds = 0.0
                var inferenceSeconds = 0.0
                var emittedSegments: [(startMs: Int, endMs: Int)] = []
                var nextBatchOrdinal = 0
                do {
                    let localExtractor = FbankExtractor()
                    let detector = try vad.makeStreamingDetector()
                    func enqueue(_ plans: [AudioPipelineUtilities.ASRBatchPlan]) async {
                        let batches = plans.map { plan in
                            defer { nextBatchOrdinal += 1 }
                            return StreamingASRBatch(
                                ordinal: nextBatchOrdinal,
                                startMs: plan.startMs,
                                endMs: plan.endMs,
                                ownershipRangesMs: plan.ownershipRangesMs
                            )
                        }
                        await progress.produced(batches)
                        for batch in batches { await channel.send(batch) }
                    }
                    // 3 个 enqueue site 都是同一个模式：
                    //   if condition { await enqueue(Self.asrBatches(...)) }
                    // 抽 enqueueBatches 包装 asrBatches + 空 guard，少 6 行重复参数。
                    func enqueueBatches(_ segments: [(startMs: Int, endMs: Int)]) async {
                        guard !segments.isEmpty else { return }
                        await enqueue(AudioPipelineUtilities.asrBatchPlans(
                            from: segments,
                            totalDurationMs: totalDurationMs,
                            maxBatchMs: 60_000
                        ))
                    }

                    for startFrame in stride(from: 0, to: totalFrames, by: vadChunkFrames) {
                        if shouldCancel() { throw PipelineCancelled(stage: "vad") }
                        let endFrame = min(totalFrames, startFrame + vadChunkFrames)
                        let frontendStartedAt = Date()
                        let features = localExtractor.applyLFR_CMVNRange(
                            fbank80: fbank80, lfrM: 5, lfrN: 1,
                            outputFrameRange: startFrame..<endFrame, mvn: vadMvn
                        )
                        frontendSeconds += Date().timeIntervalSince(frontendStartedAt)

                        let inferenceStartedAt = Date()
                        let closedSegments = try detector.consume(
                            fbankFeatures: features, framesCount: endFrame - startFrame
                        )
                        inferenceSeconds += Date().timeIntervalSince(inferenceStartedAt)
                        emittedSegments.append(contentsOf: closedSegments)
                        await enqueueBatches(closedSegments)
                        await Self.reportCombinedProgress(
                            vadEndFrame: endFrame, totalFrames: totalFrames,
                            progress: progress, onProgress: onProgress
                        )
                    }

                    let trailingSegments = detector.finish()
                    emittedSegments.append(contentsOf: trailingSegments)
                    await enqueueBatches(trailingSegments)
                    // VAD 一整段都未消费任何帧（很短的静音音频）：也得让 ASR
                    // 跑一次，否则 ASR worker 会一直等。0 序号触发 1 个 whole-range batch。
                    if nextBatchOrdinal == 0 {
                        await enqueueBatches([(startMs: 0, endMs: totalDurationMs)])
                    }
                    await progress.finishProducing()
                    await channel.finish()
                    // ASR worker completions wake this loop immediately. This retains the
                    // end-of-stream ASR progress updates without adding the former two-second
                    // polling delay to every completed transcription.
                    while true {
                        let update = try await progress.waitForCompletionUpdate()
                        if shouldCancel() { throw PipelineCancelled(stage: "vad") }
                        await Self.reportCombinedProgress(
                            vadEndFrame: totalFrames, totalFrames: totalFrames,
                            progress: progress, onProgress: onProgress
                        )
                        if update == .completed { break }
                    }
                    onProgress("asr", 1.0, "VAD+ASR 完成")
                    return .vad(VADStreamMetrics(
                        segments: emittedSegments,
                        frontendSeconds: frontendSeconds,
                        inferenceSeconds: inferenceSeconds,
                        wallSeconds: Date().timeIntervalSince(vadStartedAt)
                    ))
                } catch {
                    await channel.finish()
                    throw error
                }
            }

            group.addTask {
                .asrPool(try await ASRInferencePool.run(
                    fbank80: fbank80,
                    engines: asrEngines,
                    decoder: asrDecoder,
                    frontend: asrFrontend,
                    channel: channel,
                    progress: progress,
                    shouldCancel: shouldCancel
                ))
            }

            for try await event in group {
                switch event {
                case let .vad(metrics): vadMetrics = metrics
                case let .asrPool(metrics): asrWorkerMetrics.append(contentsOf: metrics)
                }
            }
        }

        guard let vadMetrics else {
            throw AudioPipelineError.vadStreamingMetricsMissing
        }
        let sentences = asrWorkerMetrics
            .flatMap(\.sentences)
            .sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
        return StreamingTranscriptionResult(
            vadSegments: vadMetrics.segments,
            asrResult: ASRResult(sentences: sentences, rawText: sentences.map(\.text).joined(separator: "")),
            wallSeconds: Date().timeIntervalSince(startedAt),
            vadWallSeconds: vadMetrics.wallSeconds,
            vadFrontendSeconds: vadMetrics.frontendSeconds,
            vadInferenceSeconds: vadMetrics.inferenceSeconds,
            asrFrontendSeconds: asrWorkerMetrics.reduce(0) { $0 + $1.frontendSeconds },
            asrInferenceSeconds: asrWorkerMetrics.reduce(0) { $0 + $1.inferenceSeconds },
            asrInputPreparationSeconds: asrWorkerMetrics.reduce(0) { $0 + $1.inputPreparationSeconds },
            asrSessionRunSeconds: asrWorkerMetrics.reduce(0) { $0 + $1.sessionRunSeconds },
            asrOutputMaterializationSeconds: asrWorkerMetrics.reduce(0) { $0 + $1.outputMaterializationSeconds },
            asrDecodeSeconds: asrWorkerMetrics.reduce(0) { $0 + $1.decodeSeconds },
            asrBatchCount: asrWorkerMetrics.reduce(0) { $0 + $1.batchCount }
        )
    }

    static func offsetASRSentences(_ sentences: [ASRSentence], by offsetMs: Int) -> [ASRSentence] {
        sentences.map {
            ASRSentence(
                text: $0.text,
                startMs: $0.startMs + offsetMs,
                endMs: $0.endMs + offsetMs,
                tokens: $0.tokens.map {
                    ASRToken(text: $0.text, startMs: $0.startMs + offsetMs, endMs: $0.endMs + offsetMs)
                }
            )
        }
    }

    /// Removes tokens decoded only from a short batch's borrowed padding.
    /// A token is owned by the range containing its midpoint; its visible
    /// timestamp is then intersected with that range. Ownership ranges are
    /// absolute and disjoint across emitted batches.
    static func offsetAndTrimASRSentences(
        _ sentences: [ASRSentence],
        by offsetMs: Int,
        ownershipRangesMs: [Range<Int>]
    ) -> [ASRSentence] {
        let offset = offsetASRSentences(sentences, by: offsetMs)
        return offset.compactMap { sentence in
            let tokens = sentence.tokens.compactMap { token -> ASRToken? in
                let midpoint = token.startMs + max(0, token.endMs - token.startMs) / 2
                guard let ownership = ownershipRangesMs.first(where: {
                    $0.contains(midpoint)
                }) else { return nil }
                let start = max(token.startMs, ownership.lowerBound)
                let end = min(max(start, token.endMs), ownership.upperBound)
                return ASRToken(text: token.text, startMs: start, endMs: max(start, end))
            }
            guard let first = tokens.first, let last = tokens.last else { return nil }
            return ASRSentence(
                text: tokens.map(\.text).joined(),
                startMs: first.startMs,
                endMs: max(first.startMs, last.endMs),
                tokens: tokens
            )
        }
    }

}

// MARK: - Streaming support types

extension AudioPipeline {
    // internal 让 @testable import 测单调性; 生产代码只在 transcribeWithStreamingVAD 里用。
    struct StreamingASRBatch: Sendable {
        let ordinal: Int
        let startMs: Int
        let endMs: Int
        let ownershipRangesMs: [Range<Int>]

        init(
            ordinal: Int,
            startMs: Int,
            endMs: Int,
            ownershipRangesMs: [Range<Int>]? = nil
        ) {
            self.ordinal = ordinal
            self.startMs = startMs
            self.endMs = endMs
            self.ownershipRangesMs = ownershipRangesMs
                ?? (endMs > startMs ? [startMs..<endMs] : [])
        }
    }

    struct VADStreamMetrics: Sendable {
        let segments: [(startMs: Int, endMs: Int)]
        let frontendSeconds: TimeInterval
        let inferenceSeconds: TimeInterval
        let wallSeconds: TimeInterval
    }

    struct ASRWorkerMetrics: Sendable {
        let sentences: [ASRSentence]
        let frontendSeconds: TimeInterval
        let inferenceSeconds: TimeInterval
        let inputPreparationSeconds: TimeInterval
        let sessionRunSeconds: TimeInterval
        let outputMaterializationSeconds: TimeInterval
        let decodeSeconds: TimeInterval
        let batchCount: Int
    }

    enum ASRBatchFailure: Error, LocalizedError, Sendable {
        case frontendUnavailable(ordinal: Int, startMs: Int, endMs: Int)
        case inferenceFailed(ordinal: Int, startMs: Int, endMs: Int, message: String)

        var errorDescription: String? {
            switch self {
            case let .frontendUnavailable(ordinal, startMs, endMs):
                return "ASR batch \(ordinal) frontend unavailable (\(startMs)-\(endMs)ms)"
            case let .inferenceFailed(ordinal, startMs, endMs, message):
                return "ASR batch \(ordinal) inference failed (\(startMs)-\(endMs)ms): \(message)"
            }
        }
    }

    enum StreamingTranscriptionEvent: Sendable {
        case vad(VADStreamMetrics)
        case asrPool([ASRWorkerMetrics])
    }

    struct StreamingTranscriptionResult {
        let vadSegments: [(startMs: Int, endMs: Int)]
        let asrResult: ASRResult
        let wallSeconds: TimeInterval
        let vadWallSeconds: TimeInterval
        let vadFrontendSeconds: TimeInterval
        let vadInferenceSeconds: TimeInterval
        let asrFrontendSeconds: TimeInterval
        let asrInferenceSeconds: TimeInterval
        let asrInputPreparationSeconds: TimeInterval
        let asrSessionRunSeconds: TimeInterval
        let asrOutputMaterializationSeconds: TimeInterval
        let asrDecodeSeconds: TimeInterval
        let asrBatchCount: Int
    }

    /// A bounded producer/consumer channel. VAD is the only producer; each
    /// ASR worker owns a distinct ORT session and receives each batch once.
    /// The capacity applies back-pressure to VAD instead of letting it run
    /// arbitrarily far ahead of ASR on a long recording.
    actor StreamingASRBatchChannel {
        private struct SendWaiter {
            let batch: StreamingASRBatch
            let continuation: CheckedContinuation<Void, Never>
        }

        private let capacity: Int
        private var pending: [StreamingASRBatch] = []
        private var waiters: [CheckedContinuation<StreamingASRBatch?, Never>] = []
        private var sendWaiters: [SendWaiter] = []
        private var finished = false

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        func send(_ batch: StreamingASRBatch) async {
            if finished { return }
            if !waiters.isEmpty {
                waiters.removeFirst().resume(returning: batch)
            } else if pending.count < capacity {
                pending.append(batch)
            } else {
                await withTaskCancellationHandler(operation: {
                    await withCheckedContinuation { continuation in
                        if finished {
                            continuation.resume()
                        } else {
                            sendWaiters.append(SendWaiter(batch: batch, continuation: continuation))
                        }
                    }
                }, onCancel: {
                    Task { await self.finish() }
                })
            }
        }

        func next() async -> StreamingASRBatch? {
            if !pending.isEmpty {
                let batch = pending.removeFirst()
                if !sendWaiters.isEmpty {
                    let waiter = sendWaiters.removeFirst()
                    pending.append(waiter.batch)
                    waiter.continuation.resume()
                }
                return batch
            }
            if !sendWaiters.isEmpty {
                let waiter = sendWaiters.removeFirst()
                waiter.continuation.resume()
                return waiter.batch
            }
            if finished { return nil }
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if finished {
                        continuation.resume(returning: nil)
                    } else {
                        waiters.append(continuation)
                    }
                }
            }, onCancel: {
                Task { await self.finish() }
            })
        }

        func finish() {
            guard !finished else { return }
            finished = true
            let currentWaiters = waiters
            waiters.removeAll()
            for waiter in currentWaiters { waiter.resume(returning: nil) }
            let currentSendWaiters = sendWaiters
            sendWaiters.removeAll()
            for waiter in currentSendWaiters { waiter.continuation.resume() }
        }
    }

    // internal (not private) 让 @testable import 测单调性。
    actor StreamingASRProgress {
        enum CompletionUpdate: Sendable, Equatable {
            case progress
            case completed
        }

        private typealias CompletionWaiter = CheckedContinuation<CompletionUpdate?, Never>

        private let totalDurationMs: Int
        private var produced = 0
        private var completed = 0
        private var producerFinished = false
        private var endMsByOrdinal: [Int: Int] = [:]
        private var completedOrdinals: Set<Int> = []
        private var nextContiguousOrdinal = 0
        private var completedThroughMs = 0
        private var monotonicFraction: Double = 0
        private var completionWaiters: [UUID: CompletionWaiter] = [:]

        init(totalDurationMs: Int) {
            self.totalDurationMs = max(1, totalDurationMs)
        }

        func produced(_ batches: [StreamingASRBatch]) {
            produced += batches.count
            for batch in batches { endMsByOrdinal[batch.ordinal] = batch.endMs }
        }

        func incrementCompleted(_ batch: StreamingASRBatch) {
            completed += 1
            completedOrdinals.insert(batch.ordinal)
            while completedOrdinals.remove(nextContiguousOrdinal) != nil {
                let ordinalEndMs = endMsByOrdinal[nextContiguousOrdinal] ?? batch.endMs
                completedThroughMs = max(completedThroughMs, ordinalEndMs)
                nextContiguousOrdinal += 1
            }
            let raw = min(1.0, Double(completedThroughMs) / Double(totalDurationMs))
            monotonicFraction = max(monotonicFraction, raw)
            resumeCompletionWaiters(
                with: isComplete ? .completed : .progress
            )
        }

        /// 兼容旧测试；实际生产路径使用 snapshot().
        func completed(_ batch: StreamingASRBatch) -> (completed: Int, produced: Int, isFinalCount: Bool, fraction: Double) {
            incrementCompleted(batch)
            return (completed, produced, producerFinished, monotonicFraction)
        }

        func finishProducing() {
            producerFinished = true
            if isComplete {
                resumeCompletionWaiters(with: .completed)
            }
        }

        func snapshot() -> (completed: Int, produced: Int, isFinalCount: Bool, asrFraction: Double) {
            let rawFraction = min(1.0, Double(completedThroughMs) / Double(totalDurationMs))
            monotonicFraction = max(monotonicFraction, rawFraction)
            return (completed, produced, producerFinished, monotonicFraction)
        }

        /// Suspends until an ASR completion changes progress, or until the
        /// producer has closed and every emitted batch has completed.
        /// Cancellation removes only this waiter; it does not alter the shared
        /// producer/consumer channel.
        func waitForCompletionUpdate() async throws -> CompletionUpdate {
            try Task.checkCancellation()
            let waiterID = UUID()
            let update = await withTaskCancellationHandler(operation: {
                await suspendUntilCompletionUpdate(waiterID: waiterID)
            }, onCancel: {
                Task { await self.cancelCompletionWaiter(waiterID) }
            })
            guard let update else { throw CancellationError() }
            return update
        }

        private func suspendUntilCompletionUpdate(
            waiterID: UUID
        ) async -> CompletionUpdate? {
            guard !Task.isCancelled else { return nil }
            guard !isComplete else { return .completed }
            return await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if isComplete {
                    continuation.resume(returning: .completed)
                } else {
                    completionWaiters[waiterID] = continuation
                }
            }
        }

        private func cancelCompletionWaiter(_ waiterID: UUID) {
            completionWaiters.removeValue(forKey: waiterID)?.resume(returning: nil)
        }

        private var isComplete: Bool {
            producerFinished && completed >= produced
        }

        private func resumeCompletionWaiters(with update: CompletionUpdate) {
            let waiters = completionWaiters
            completionWaiters.removeAll()
            for waiter in waiters.values {
                waiter.resume(returning: update)
            }
        }
    }
}
