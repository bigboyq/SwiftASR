import Foundation
import Testing
@testable import SwiftASR

/// Opt-in memory stress diagnostic for the 2h audio path. Gated by
/// `SWIFTASR_RUN_PIPELINE_MEMORY_STRESS=1` to avoid blowing up
/// normal test runs.
@Suite struct PipelineMemoryStressDiagnostic {

    static let isEnabled = ProcessInfo.processInfo.environment[
        "SWIFTASR_RUN_PIPELINE_MEMORY_STRESS"
    ] == "1"

    static func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    static func mb(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1024.0 / 1024.0)
    }

    /// Test 1: ONNX session init memory.
    /// Safe to run with ~1.5GB peak.
    @Test func measureONNXSessionInitMemory() throws {
        guard Self.isEnabled else {
            print("Skipped: set SWIFTASR_RUN_PIPELINE_MEMORY_STRESS=1 to run this opt-in diagnostic")
            return
        }
        let modelsRoot = ModelCatalog.defaultModelsRoot
        if modelsRoot.isEmpty {
            print("Skipped: ModelCatalog.defaultModelsRoot is empty; set SWIFTASR_DEV_MODELS_ROOT")
            return
        }
        let r0 = Self.currentRSSBytes()
        print("ONNX-init: baseline RSS=\(Self.mb(r0))")
        let t0 = Date()
        let pipeline = try AudioPipeline(modelsRoot: modelsRoot)
        let initSeconds = Date().timeIntervalSince(t0)
        let r1 = Self.currentRSSBytes()
        print("After AudioPipeline init: RSS=\(Self.mb(r1)) (delta +\(Self.mb(r1 - r0)))")
        print("Init seconds: \(String(format: "%.2f", initSeconds))")
        _ = pipeline
    }

    /// Test 2: 1h audio data memory (extrapolates to 2h).
    @Test func measure1hAudioDataMemory() throws {
        guard Self.isEnabled else {
            print("Skipped: set SWIFTASR_RUN_PIPELINE_MEMORY_STRESS=1 to run this opt-in diagnostic")
            return
        }
        let r0 = Self.currentRSSBytes()
        print("1h-audio: baseline RSS=\(Self.mb(r0))")
        let sampleRate = 16_000
        let durationSeconds = 1 * 3600
        let fbankFrameRate = 100
        let fbankDim = 80

        let pcm = [Float](repeating: 0, count: sampleRate * durationSeconds)
        let r1 = Self.currentRSSBytes()
        print("After PCM 1h: RSS=\(Self.mb(r1)) (delta +\(Self.mb(r1 - r0)))")

        let fbank80 = [Float](repeating: 0, count: fbankFrameRate * durationSeconds * fbankDim)
        let r2 = Self.currentRSSBytes()
        print("After fbank 1h: RSS=\(Self.mb(r2)) (delta +\(Self.mb(r2 - r1)))")
        print("1h total data: \(Self.mb(r2 - r0))")
        print("2h extrapolation: \(Self.mb((r2 - r0) * 2))")
        _ = pcm
        _ = fbank80
    }

    /// Test 3: B 修复对比 - 当前 pattern（pcm 在外层 scope）vs 修复后（pcm 在 sub-function）
    ///
    /// 用独立 sub-function 隔离每个 pattern 的 scope，确保 pcm 在 Pattern A 的 sub-function
    /// 返回时释放，Pattern B 看到的是干净的 baseline。
    ///
    /// 当前 _runPipelineInternal:
    ///   let decodeOut = try await decodeStage(...)  // decodeOut.pcm 一直 hold
    ///   let fbankOut = try await fbankStage(pcm: decodeOut.pcm, ...)
    ///   // decodeOut 仍然 in scope, pcm 没释放
    ///   let vadAsrOut = try await vadAsrStage(... pcmSeconds: decodeOut.pcmSeconds, ...)
    ///
    /// 修复后 (B):
    ///   let (fbankOut, pcmSeconds, totalDurationMs) = try await runDecodeAndFbank(...)
    ///   // pcm 在 runDecodeAndFbank 内部, 函数返回时释放
    ///   let vadAsrOut = try await vadAsrStage(...)
    @Test func compareCurrentVsFixedPcmPattern() throws {
        guard Self.isEnabled else {
            print("Skipped: set SWIFTASR_RUN_PIPELINE_MEMORY_STRESS=1 to run this opt-in diagnostic")
            return
        }

        // Pattern A: simulate current code where pcm + fbank both alive in outer scope
        // Each pattern in its own sub-function so pcm/fbank are released on return
        let patternAResult = measurePatternACurrently()
        // Pattern B: simulate B's fix where pcm is in sub-function (released on return)
        let patternBResult = measurePatternBWithFix()

        print("=== Result ===")
        print("Pattern A (current, pcm + fbank alive): \(Self.mb(patternAResult))")
        print("Pattern B (B's fix, only fbank alive):   \(Self.mb(patternBResult))")
        let saved = patternAResult > patternBResult ? patternAResult - patternBResult : 0
        print("B's fix saves: \(Self.mb(saved))")
    }

    /// Pattern A: pcm + fbank both alive in scope, then measure RSS.
    /// Returns: pcm + fbank footprint (1h Float32).
    private func measurePatternACurrently() -> UInt64 {
        let pcm = [Float](repeating: 0, count: 16_000 * 3600)
        let fbank = [Float](repeating: 0, count: 100 * 3600 * 80)
        // Both alive here
        return Self.currentRSSBytes()
        // Both released when this function returns
    }

    /// Pattern B: pcm in sub-function (released on return), only fbank alive.
    /// Returns: fbank only footprint.
    private func measurePatternBWithFix() -> UInt64 {
        let fbank = subFunctionOwnsPcm()
        // pcm from sub-function already released
        return Self.currentRSSBytes()
    }

    /// Simulates B's proposed fix: pcm owned by sub-function, released on return.
    private func subFunctionOwnsPcm() -> [Float] {
        let pcm = [Float](repeating: 0, count: 16_000 * 3600)
        // "Materialize" fbank (simulated)
        let fbank = [Float](repeating: 0, count: 100 * 3600 * 80)
        // pcm goes out of scope when this function returns
        return fbank
    }
}
