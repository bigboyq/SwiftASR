import Testing
import Foundation
@testable import SwiftASR

// MARK: - PipelineStageMetrics 4 阶段关键信息测试
//
// 验证 PipelineChecklist ✅ 后显示的关键信息 (e.g. "PCM 8.0s · fbank 2.9s · 5284 帧")
// 在各 stage 下的行为:
// - preprocess: PCM time, fbank time, fbank frames
// - asr (文字识别): wall time, VAD 段数
// - punc: time
// - speaker: time

@Test func pipelineStageMetrics_emptyStageAllReturnNil() {
    let m = PipelineStageMetrics.empty
    #expect(m.summary(for: "preprocess") == nil)
    #expect(m.summary(for: "asr") == nil)
    #expect(m.summary(for: "punc") == nil)
    #expect(m.summary(for: "speaker") == nil)
    // 未知 stage 也 nil
    #expect(m.summary(for: "unknown") == nil)
}

@Test func pipelineStageMetrics_preprocessFullSummary() {
    // 模拟 1h 音频: PCM 8s + fbank 2.9s + 5284 帧
    let m = PipelineStageMetrics(
        pcmDecodeMs: 8000,
        fbankMaterialiseMs: 2900,
        fbankFrames: 5284,
        totalDurationMs: 4_487_545,
        vadAsrWallMs: 0,
        vadSegmentCount: 0,
        puncMs: 0,
        speakerMs: 0
    )
    #expect(m.summary(for: "preprocess") == "PCM 8.0s · fbank 2.9s · 5284 帧")
}

@Test func pipelineStageMetrics_preprocessPartialFbank() {
    // fbank 时间 0 但 fbankFrames > 0: 仍应显示
    let m = PipelineStageMetrics(
        pcmDecodeMs: 0,
        fbankMaterialiseMs: 0,
        fbankFrames: 100,
        totalDurationMs: 1000,
        vadAsrWallMs: 0,
        vadSegmentCount: 0,
        puncMs: 0,
        speakerMs: 0
    )
    #expect(m.summary(for: "preprocess") == "100 帧")
}

@Test func pipelineStageMetrics_asrSummary() {
    // 模拟 1h 音频 ASR: 95s wall + 0 段 (实际有 VAD 段, 这里测试 fallback)
    let m = PipelineStageMetrics(
        pcmDecodeMs: 0, fbankMaterialiseMs: 0, fbankFrames: 0, totalDurationMs: 0,
        vadAsrWallMs: 95_000, vadSegmentCount: 12,
        puncMs: 0, speakerMs: 0
    )
    #expect(m.summary(for: "asr") == "95.0s · 12 段")
}

@Test func pipelineStageMetrics_asrOnlyWall() {
    let m = PipelineStageMetrics(
        pcmDecodeMs: 0, fbankMaterialiseMs: 0, fbankFrames: 0, totalDurationMs: 0,
        vadAsrWallMs: 30_500, vadSegmentCount: 0,
        puncMs: 0, speakerMs: 0
    )
    #expect(m.summary(for: "asr") == "30.5s")
}

@Test func pipelineStageMetrics_puncAndSpeaker() {
    let m = PipelineStageMetrics(
        pcmDecodeMs: 0, fbankMaterialiseMs: 0, fbankFrames: 0, totalDurationMs: 0,
        vadAsrWallMs: 0, vadSegmentCount: 0,
        puncMs: 1_430,
        speakerMs: 104_000
    )
    #expect(m.summary(for: "punc") == "1.4s")
    #expect(m.summary(for: "speaker") == "104.0s")
}

@Test func pipelineStageMetrics_asrProcessingTimeUsesPipelineWallTime() {
    let m = PipelineStageMetrics(
        pcmDecodeMs: 8_000,
        fbankMaterialiseMs: 2_900,
        fbankFrames: 0,
        totalDurationMs: 0,
        vadAsrWallMs: 95_000,
        vadSegmentCount: 0,
        puncMs: 1_430,
        speakerMs: 104_000
    )

    // VAD 和 ASR 是并行流水线，使用 vadAsrWallMs 一次，不能双计。
    #expect(m.asrProcessingMilliseconds == 107_330)
}

@Test func pipelineStageMetrics_equatable() {
    // Equatable 默认是按字段, 测试用于 coordinator @Published 更新
    let a = PipelineStageMetrics(
        pcmDecodeMs: 100, fbankMaterialiseMs: 200, fbankFrames: 300, totalDurationMs: 400,
        vadAsrWallMs: 0, vadSegmentCount: 0, puncMs: 0, speakerMs: 0
    )
    let b = PipelineStageMetrics(
        pcmDecodeMs: 100, fbankMaterialiseMs: 200, fbankFrames: 300, totalDurationMs: 400,
        vadAsrWallMs: 0, vadSegmentCount: 0, puncMs: 0, speakerMs: 0
    )
    let c = PipelineStageMetrics(
        pcmDecodeMs: 100, fbankMaterialiseMs: 200, fbankFrames: 300, totalDurationMs: 401,
        vadAsrWallMs: 0, vadSegmentCount: 0, puncMs: 0, speakerMs: 0
    )
    #expect(a == b)
    #expect(a != c)
}

@Test func pipelineStageMetrics_sendableCrossActor() async {
    // PipelineStageMetrics 跨 actor 传递 (AudioPipeline actor 写, MainActor
    // coordinator 读). 验证 Sendable 编译期约束 + 实际 round-trip.
    func roundTrip(_ m: PipelineStageMetrics) async -> PipelineStageMetrics {
        // 模拟跨 task boundary 传递
        await Task.detached { m }.value
    }
    let original = PipelineStageMetrics(
        pcmDecodeMs: 8000, fbankMaterialiseMs: 2900, fbankFrames: 5284, totalDurationMs: 4_487_545,
        vadAsrWallMs: 95_000, vadSegmentCount: 12, puncMs: 1_430, speakerMs: 104_000
    )
    let received = await roundTrip(original)
    #expect(received == original)
}
