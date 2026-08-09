import Testing
import Foundation
@testable import SwiftASR

@Test func streamingChannelCancellationWakesBlockedConsumer() async {
    let channel = AudioPipeline.StreamingASRBatchChannel(capacity: 1)
    let task = Task { await channel.next() }

    task.cancel()
    let result = await task.value

    #expect(result == nil)
}

@Test func streamingChannelCancellationWakesBlockedProducer() async {
    let channel = AudioPipeline.StreamingASRBatchChannel(capacity: 1)
    let first = AudioPipeline.StreamingASRBatch(ordinal: 0, startMs: 0, endMs: 100)
    let second = AudioPipeline.StreamingASRBatch(ordinal: 1, startMs: 100, endMs: 200)
    await channel.send(first)

    let task = Task { await channel.send(second) }
    task.cancel()
    await task.value

    #expect(await channel.next()?.ordinal == first.ordinal)
    #expect(await channel.next() == nil)
}

// MARK: - StreamingASRProgress 时间序 fraction 单调性回归测试
//
// 覆盖 ASR 阶段 progress fraction 乱跳 bug（commit pending）：
// - count-based fraction (`completed / max(produced, completed)`) 分母不稳定，
//   VAD 没跑完时 produced 持续增长，asr fraction 不可比
// - 改用时间序 fraction (`completedThroughMs / totalDurationMs`)，分母稳定
// - VAD 端用 `vad_endFrame / totalFrames`，两个分母都是提前知道的 totalDurationMs/totalFrames
// - VAD 线程算 `combined = vad * 0.3 + asr * 0.7`，ASR worker 只 `incrementCompleted`

@Test func streamingASRProgress_sequentialCompleted_isMonotonic() async {
    // 顺序完成 (ord 0, 1, 2, 3, 4) — 简单 baseline
    // endMs 1000, 2000, 3000, 4000, 5000 / total 10000
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 10_000)
    let batches = (0..<5).map { ord in
        AudioPipeline.StreamingASRBatch(
            ordinal: ord,
            startMs: ord * 1_000,
            endMs: (ord + 1) * 1_000
        )
    }
    await progress.produced(batches)
    var fractions: [Double] = []
    for batch in batches {
        let snapshot = await progress.completed(batch)
        fractions.append(snapshot.fraction)
    }
    // 单调非降
    for i in 1..<fractions.count {
        #expect(fractions[i] >= fractions[i - 1], "fraction 下降 at \(i): \(fractions[i - 1]) → \(fractions[i])")
    }
    // 时间序: endMs 推进 1000, 2000, 3000, 4000, 5000 / 10000 = 0.5 终值
    #expect(abs(fractions.last! - 0.5) < 1e-6, "终值应 0.5 (5×1000/10000), got \(fractions.last!)")
}

@Test func streamingASRProgress_outOfOrderCompleted_isMonotonic() async {
    // 乱序完成: VAD 顺序 emit endMs 升序, ASR worker 并发可能乱序完成
    // endMs 1000, 2000, 3000, 4000, 5000 / total 10000
    // 完成顺序: ord 1, 3, 0, 2, 4
    // 期望推进:
    //   ord 1 complete → completedThroughMs 推进到 2000 (因为 ord 0 还没)
    //                     → 等下, ordinal 推进是连续, ord 0 还没就停止
    //   修正: nextContiguousOrdinal=0, ord 0 不在 set → 推进停止, completedThroughMs=0
    //   ord 3 complete → ord 0 还没 → 仍 0
    //   ord 0 complete → ord 0 在, 推进到 max(0, 1000) = 1000 → fraction 0.1
    //   ord 2 complete → ord 1 还在 set, 推进到 max(1000, 2000) = 2000
    //                     ord 2 在 set, 推进到 max(2000, 3000) = 3000 → fraction 0.3
    //   ord 4 complete → ord 3 在, 推进到 max(3000, 4000) = 4000
    //                     ord 4 在, 推进到 max(4000, 5000) = 5000 → fraction 0.5
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 10_000)
    let batches = (0..<5).map { ord in
        AudioPipeline.StreamingASRBatch(
            ordinal: ord,
            startMs: ord * 1_000,
            endMs: (ord + 1) * 1_000
        )
    }
    await progress.produced(batches)
    let completionOrder = [1, 3, 0, 2, 4]
    var fractions: [Double] = []
    for ord in completionOrder {
        let snapshot = await progress.completed(batches[ord])
        fractions.append(snapshot.fraction)
    }
    // 单调非降
    for i in 1..<fractions.count {
        #expect(fractions[i] >= fractions[i - 1], "乱序 fraction 降 at \(i): \(fractions[i - 1]) → \(fractions[i])")
    }
}

@Test func streamingASRProgress_producedGrowth_doesNotDropFraction() async {
    // 关键测试: VAD 没跑完时 (produced 持续涨) fraction 不能降
    // 时间序 fraction 用 totalDurationMs 作分母, produced 不影响 fraction
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 10_000)
    let batches1 = [
        AudioPipeline.StreamingASRBatch(ordinal: 0, startMs: 0, endMs: 5000),
        AudioPipeline.StreamingASRBatch(ordinal: 1, startMs: 5000, endMs: 10000),
    ]
    await progress.produced(batches1)
    let s1 = await progress.completed(batches1[0])
    // fraction = completedThroughMs(5000) / totalDurationMs(10000) = 0.5
    #expect(abs(s1.fraction - 0.5) < 1e-6, "1st complete 期望 0.5, got \(s1.fraction)")

    // VAD 继续 produce 第 3 个 batch
    let batches2 = [
        AudioPipeline.StreamingASRBatch(ordinal: 2, startMs: 0, endMs: 2000),
    ]
    await progress.produced(batches2)
    // ASR 完成第 2 个 batch: endMs 10000, fraction 推进到 1.0 (假设 ordinal 0, 1 连续)
    let s2 = await progress.completed(batches1[1])
    #expect(s2.fraction >= s1.fraction, "fraction 不能降: \(s1.fraction) → \(s2.fraction)")
    #expect(abs(s2.fraction - 1.0) < 1e-6, "2nd complete 期望 1.0, got \(s2.fraction)")
}

@Test func streamingASRProgress_completedExceedsProduced_safeFraction() async {
    // corner case: completed > produced (理论不可能, ASR 只能 consume 已 produce)
    // 时间序 fraction 不依赖 produced, 仍然按 completedThroughMs/totalDurationMs 算
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 10_000)
    let batch = AudioPipeline.StreamingASRBatch(ordinal: 0, startMs: 0, endMs: 5000)
    let snapshot = await progress.completed(batch)
    // fraction = 5000/10000 = 0.5
    #expect(abs(snapshot.fraction - 0.5) < 1e-6, "无 produced 时 completed 期望 0.5, got \(snapshot.fraction)")
    #expect(snapshot.completed == 1)
    #expect(snapshot.produced == 0)
    #expect(snapshot.isFinalCount == false)
}

@Test func streamingASRProgress_finishProducing_flipsFlag() async {
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 10_000)
    let batch = AudioPipeline.StreamingASRBatch(ordinal: 0, startMs: 0, endMs: 5000)
    await progress.produced([batch])
    let s1 = await progress.completed(batch)
    #expect(s1.isFinalCount == false)
    await progress.finishProducing()
    let s2 = await progress.completed(
        AudioPipeline.StreamingASRBatch(ordinal: 1, startMs: 5000, endMs: 10000)
    )
    #expect(s2.completed == 2)
    #expect(s2.isFinalCount == true)
    // 100% 终值
    #expect(abs(s2.fraction - 1.0) < 1e-6, "终值应 1.0, got \(s2.fraction)")
}

@Test func streamingASRProgress_largeScale_1000Batches_strictlyMonotonic() async {
    // 1000 个 batch, endMs 0-1000000, 乱序完成
    let n = 1000
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: n * 1000)
    let batches = (0..<n).map { i in
        AudioPipeline.StreamingASRBatch(ordinal: i, startMs: i * 1000, endMs: (i + 1) * 1000)
    }
    await progress.produced(batches)
    // 倒序完成
    let completionOrder = Array((0..<n).reversed())
    var lastFraction = 0.0
    for ord in completionOrder {
        let snapshot = await progress.completed(batches[ord])
        #expect(snapshot.fraction >= lastFraction, "乱序 fraction 降: \(lastFraction) → \(snapshot.fraction) at ord \(ord)")
        lastFraction = snapshot.fraction
    }
    // 终值 = 1.0 (全部 ordinal 连续推进后 completedThroughMs = totalDurationMs)
    #expect(abs(lastFraction - 1.0) < 1e-6, "1000 batch 全完成应 1.0, got \(lastFraction)")
}

@Test func streamingASRProgress_race_simulatedConcurrent() async {
    // 4 worker 并发完成 100 batch
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 10_000)
    let n = 100
    let batches = (0..<n).map { i in
        AudioPipeline.StreamingASRBatch(ordinal: i, startMs: i * 100, endMs: (i + 1) * 100)
    }
    await progress.produced(batches)
    let workers = 4
    let perWorker = n / workers
    let perWorkerFractions = await withTaskGroup(of: [Double].self, returning: [[Double]].self) { group in
        for w in 0..<workers {
            let start = w * perWorker
            let end = (w == workers - 1) ? n : (w + 1) * perWorker
            let myBatches = Array(batches[start..<end])
            group.addTask {
                var local: [Double] = []
                for b in myBatches {
                    let s = await progress.completed(b)
                    local.append(s.fraction)
                }
                return local
            }
        }
        var all: [[Double]] = []
        for await local in group { all.append(local) }
        return all
    }
    // 1. 每个 worker 自己的 fraction 序列单调非降
    for (w, fractions) in perWorkerFractions.enumerated() {
        for i in 1..<fractions.count {
            #expect(fractions[i] >= fractions[i - 1], "worker \(w) fraction 降 at \(i): \(fractions[i - 1]) → \(fractions[i])")
        }
    }
    // 2. 全局 100 batch 都完成后, 再次访问 actor 应返回 1.0
    let finalSnapshot = await progress.completed(
        AudioPipeline.StreamingASRBatch(ordinal: 100, startMs: 0, endMs: 0)
    )
    #expect(abs(finalSnapshot.fraction - 1.0) < 1e-6, "100 batch 全完成后再 completed 应 1.0, got \(finalSnapshot.fraction)")
    #expect(finalSnapshot.completed == 101)
}

@Test func streamingASRProgress_snapshotMethod_returnsAsrFraction() async {
    // 新设计: VAD 线程通过 snapshot() 读 ASR 端时间序 fraction
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 10_000)
    let batches = (0..<5).map { ord in
        AudioPipeline.StreamingASRBatch(
            ordinal: ord,
            startMs: ord * 2_000,
            endMs: (ord + 1) * 2_000
        )
    }
    await progress.produced(batches)
    // 完成前 2 个: completedThroughMs 推进到 4000
    await progress.incrementCompleted(batches[0])
    await progress.incrementCompleted(batches[1])
    let snap = await progress.snapshot()
    #expect(snap.completed == 2)
    #expect(snap.produced == 5)
    #expect(snap.isFinalCount == false)
    // asrFraction = 4000 / 10000 = 0.4
    #expect(abs(snap.asrFraction - 0.4) < 1e-6, "asr fraction 应 0.4, got \(snap.asrFraction)")
}

@Test func streamingASRProgress_completionWaiterReportsProgressThenFinalCompletion() async throws {
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 2_000)
    let first = AudioPipeline.StreamingASRBatch(ordinal: 0, startMs: 0, endMs: 1_000)
    let second = AudioPipeline.StreamingASRBatch(ordinal: 1, startMs: 1_000, endMs: 2_000)
    await progress.produced([first, second])
    await progress.finishProducing()

    let waiter = Task { try await progress.waitForCompletionUpdate() }
    await Task.yield()
    await progress.incrementCompleted(first)
    #expect(try await waiter.value == .progress)

    let finalWaiter = Task { try await progress.waitForCompletionUpdate() }
    await Task.yield()
    await progress.incrementCompleted(second)
    #expect(try await finalWaiter.value == .completed)
}

@Test func streamingASRProgress_completionWaiterCancellationDoesNotChangeProgressState() async {
    let progress = AudioPipeline.StreamingASRProgress(totalDurationMs: 1_000)
    let batch = AudioPipeline.StreamingASRBatch(ordinal: 0, startMs: 0, endMs: 1_000)
    await progress.produced([batch])
    await progress.finishProducing()

    let waiter = Task { () -> Bool in
        do {
            _ = try await progress.waitForCompletionUpdate()
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }
    await Task.yield()
    waiter.cancel()
    #expect(await waiter.value)

    let snapshot = await progress.snapshot()
    #expect(snapshot.completed == 0)
    #expect(snapshot.produced == 1)
    #expect(snapshot.isFinalCount)
}
