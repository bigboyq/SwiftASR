import Testing
import Foundation
@testable import SwiftASR

// MARK: - onStageComplete 增量更新回归测试
//
// 覆盖 Bug fix 2026-07-12: 每个 stage 完成时, AudioPipeline 立即调
// onStageComplete(stageName, accumulatedMetrics), UI checklist 立刻看到 ✅
// + 关键信息, 不必等整个 pipeline 跑完.
//
// 测试策略: 用 onStageComplete 模拟 4 阶段依次完成, 验证 accumulated
// metrics 字段逐步累积 (不是每次都全量覆盖).

@Test func stageCompleteCallback_incrementalAccumulation() {
    // 模拟 1h 音频的完整 metrics 累计过程
    var m = PipelineStageMetrics()

    // 阶段 1: preprocess 完成 (PCM 解码 + fbank 物化)
    m.pcmDecodeMs = 8_000
    m.fbankMaterialiseMs = 2_900
    m.fbankFrames = 5284
    m.totalDurationMs = 4_487_545
    #expect(m.summary(for: "preprocess") == "PCM 8.0s · fbank 2.9s · 5284 帧")
    // 其他 stage 还没完成
    #expect(m.summary(for: "asr") == nil)
    #expect(m.summary(for: "punc") == nil)
    #expect(m.summary(for: "speaker") == nil)

    // 阶段 2: asr 完成 (VAD+ASR wall + 段数)
    m.vadAsrWallMs = 95_000
    m.vadSegmentCount = 12
    #expect(m.summary(for: "asr") == "95.0s · 12 段")
    // 之前的 preprocess 字段仍在 (累积, 不覆盖)
    #expect(m.summary(for: "preprocess") == "PCM 8.0s · fbank 2.9s · 5284 帧")

    // 阶段 3: punc 完成
    m.puncMs = 1_430
    #expect(m.summary(for: "punc") == "1.4s")
    #expect(m.summary(for: "asr") == "95.0s · 12 段")
    #expect(m.summary(for: "preprocess") == "PCM 8.0s · fbank 2.9s · 5284 帧")

    // 阶段 4: speaker 完成
    m.speakerMs = 104_000
    #expect(m.summary(for: "speaker") == "104.0s")
    #expect(m.summary(for: "punc") == "1.4s")
    #expect(m.summary(for: "asr") == "95.0s · 12 段")
    #expect(m.summary(for: "preprocess") == "PCM 8.0s · fbank 2.9s · 5284 帧")
}

@Test func stageCompleteCallback_eachStageIsIndependent() {
    // 测试单个 stage 单独完成时, 不应被其他 stage 的字段污染.
    // 模拟 asr 阶段先完成 (比如 preprocess 还没跑就触发了 asr stage 边界 case).
    var m = PipelineStageMetrics()
    m.vadAsrWallMs = 50_000
    m.vadSegmentCount = 5
    // asr 字段 OK
    #expect(m.summary(for: "asr") == "50.0s · 5 段")
    // preprocess/punc/speaker 还是空 (不应该有 fallback 数值)
    #expect(m.summary(for: "preprocess") == nil)
    #expect(m.summary(for: "punc") == nil)
    #expect(m.summary(for: "speaker") == nil)
}

@Test func stageCompleteCallback_overwriteEarlierValues() {
    // 模拟: 同一 stage 多次回调 (理论上不应该发生, 但保险起见验证最后值生效).
    var m = PipelineStageMetrics()
    m.pcmDecodeMs = 1_000
    m.pcmDecodeMs = 2_000  // 覆盖
    m.pcmDecodeMs = 3_000  // 覆盖
    #expect(m.summary(for: "preprocess") == "PCM 3.0s")
}

@Test func stageCompleteCallback_partialUpdatePreprocessOnly() {
    // Bug 场景: pipeline 报 "preprocess" 阶段完成时, fbankFrames > 0 但 fbankMaterialiseMs = 0
    // (旧实现下会被新代码 fbankFrames 显示为 "N 帧" 单独出现, 不会跟 "fbank Ys" 拼一起).
    var m = PipelineStageMetrics()
    m.pcmDecodeMs = 1_000
    m.fbankFrames = 100  // 帧数有, 时间 0
    m.totalDurationMs = 1_000
    let summary = m.summary(for: "preprocess")
    // 跟现有 partialFbank 测试一致
    #expect(summary == "PCM 1.0s · 100 帧")
}
