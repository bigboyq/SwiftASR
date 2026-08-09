import Foundation

// MARK: - PipelineStageMetrics
//
// 4 阶段 (preprocess / asr / punc / speaker) 的关键 timing + 数量指标。
// AudioPipeline.runPipelineWithProfiles 在 pipeline 跑完后算出来,
// coordinator 写到 @Published activeStageMetrics, view 端读出来在
// ✅ checklist 后显示 "PCM 8.0s · fbank 2.9s · 5284 帧" 之类信息.
//
// 4 阶段对应:
// - preprocess: pcmDecodeMs, fbankMaterialiseMs, fbankFrames, totalDurationMs
// - asr:        vadAsrWallMs, vadSegmentCount (VAD 段数, 也作 VAD 数量)
// - punc:       puncMs
// - speaker:    speakerMs

/// Pipeline 4 阶段的关键 timing + 数量指标, 给 UI checklist "✅ 完成" 状态用。
public struct PipelineStageMetrics: Sendable, Equatable {
    // 预处理
    var pcmDecodeMs: Int = 0
    var fbankMaterialiseMs: Int = 0
    var fbankFrames: Int = 0
    var totalDurationMs: Int = 0
    // 文字识别 (VAD+ASR)
    var vadAsrWallMs: Int = 0
    var vadSegmentCount: Int = 0
    // 标点
    var puncMs: Int = 0
    // 说话人
    var speakerMs: Int = 0

    static let empty = PipelineStageMetrics()

    /// ASR 行展示/保存的实际耗时：预处理、VAD+ASR 流水线和标点按串行阶段相加。
    /// VAD 与 ASR 在同一流水线内并行，`vadAsrWallMs` 已是两者的 wall time，
    /// 因此不能再分别累加。
    public var asrProcessingMilliseconds: Int {
        pcmDecodeMs + fbankMaterialiseMs + vadAsrWallMs + puncMs
    }

    /// 给具体 stage 算"完成了"的子指标摘要, 给 UI 显示 "PCM 8.0s · fbank 2.9s · 5284 帧"
    /// 之类. 返回 nil 表示该 stage 还没完成或没指标.
    public func summary(for stage: String) -> String? {
        switch stage {
        case "preprocess":
            if pcmDecodeMs == 0, fbankMaterialiseMs == 0, fbankFrames == 0 { return nil }
            var parts: [String] = []
            if pcmDecodeMs > 0 {
                parts.append(String(format: "PCM %.1fs", Double(pcmDecodeMs) / 1000))
            }
            if fbankMaterialiseMs > 0 {
                parts.append(String(format: "fbank %.1fs", Double(fbankMaterialiseMs) / 1000))
            }
            if fbankFrames > 0 {
                parts.append("\(fbankFrames) 帧")
            }
            return parts.joined(separator: " · ")
        case "asr":
            if vadAsrWallMs == 0, vadSegmentCount == 0 { return nil }
            var parts: [String] = []
            if vadAsrWallMs > 0 {
                parts.append(String(format: "%.1fs", Double(vadAsrWallMs) / 1000))
            }
            if vadSegmentCount > 0 {
                parts.append("\(vadSegmentCount) 段")
            }
            return parts.joined(separator: " · ")
        case "punc":
            if puncMs == 0 { return nil }
            return String(format: "%.1fs", Double(puncMs) / 1000)
        case "speaker":
            if speakerMs == 0 { return nil }
            return String(format: "%.1fs", Double(speakerMs) / 1000)
        default:
            return nil
        }
    }
}
