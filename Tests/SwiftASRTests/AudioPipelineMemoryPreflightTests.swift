import Foundation
import Testing
@testable import SwiftASR

/// Pure-function tests for the memory preflight estimator added with A
/// (2026-08-02). These don't touch the diagnostic `SWIFTASR_RUN_PIPELINE_MEMORY_STRESS=1`
/// gate — they only verify the math, which is deterministic and cheap.
@Suite struct AudioPipelineMemoryPreflightTests {

    /// 数字口径（实测 2026-08-02, PipelineMemoryStressDiagnostic）：
    /// - ONNX in-memory: 1,500 MB
    /// - PCM 1h: 587 MB
    /// - fbank80 1h: 305 MB
    @Test func estimateMemoryFootprint_zeroDuration() {
        let mb = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 0,
            pcmReleased: true
        )
        #expect(mb == 1500.0)
    }

    @Test func estimateMemoryFootprint_oneHourPcmReleased() {
        // 1h: ONNX 1500 + fbank 305 = 1805
        let mb = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 3600,
            pcmReleased: true
        )
        #expect(mb == 1805.0)
    }

    @Test func estimateMemoryFootprint_oneHourPcmNotReleased() {
        // 1h: ONNX 1500 + pcm 587 + fbank 305 = 2392
        let mb = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 3600,
            pcmReleased: false
        )
        #expect(mb == 2392.0)
    }

    @Test func estimateMemoryFootprint_twoHoursPcmReleased() {
        // 2h: ONNX 1500 + fbank 610 = 2110 (B 修后)
        let mb = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 7200,
            pcmReleased: true
        )
        #expect(mb == 2110.0)
    }

    @Test func estimateMemoryFootprint_twoHoursPcmNotReleased() {
        // 2h: ONNX 1500 + pcm 1174 + fbank 610 = 3284 (B 修前)
        let mb = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 7200,
            pcmReleased: false
        )
        #expect(mb == 3284.0)
    }

    @Test func estimateMemoryFootprint_threeHours() {
        // 3h: ONNX 1500 + pcm 1761 + fbank 915 = 4176
        let mb = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 10800,
            pcmReleased: false
        )
        #expect(mb == 4176.0)
    }

    @Test func estimateMemoryFootprint_bRefactorSavesOneGB() {
        // B 修前 - 修后 = 1174MB ≈ 1GB（2h 音频的 pcm 减负）
        let before = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 7200, pcmReleased: false
        )
        let after = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 7200, pcmReleased: true
        )
        #expect(before - after == 1174.0)
    }

    @Test func estimateMemoryFootprint_scalesLinearly() {
        // 30min 应该是 1h 的一半（pcm/fbank 部分）
        let halfHour = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 1800, pcmReleased: false
        )
        let oneHour = AudioPipeline.estimateMemoryFootprintMB(
            durationSec: 3600, pcmReleased: false
        )
        // 1.5 * halfHour = oneHour 的 ONNX 以外部分
        // halfHour = 1500 + 0.5*587 + 0.5*305 = 1500 + 446
        // oneHour  = 1500 + 587 + 305 = 2392
        #expect(halfHour == 1946.0)
        #expect(oneHour == 2392.0)
    }
}
