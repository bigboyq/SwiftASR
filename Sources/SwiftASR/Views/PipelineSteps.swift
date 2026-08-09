import SwiftUI
import SwiftData

/// Pipeline 4 阶段（顺序固定：preprocess → asr → punc → speaker）。
/// AudioPipeline 内部仍报 5 个原始 stage (preprocess / vad / asr / punc / speaker)，
/// D-3 之后 UI 端把 vad+asr 合并到 "asr"（"文字识别"）显示。preprocess 拆
/// 自原 "load" 阶段（PCM 解码 + fbank 物化），asr 阶段含 VAD+ASR 流水线。
///
/// 4 阶段而非 3 阶段: 用户诉求是看更细的进度 (完成一段就勾上, 没开始的就漏斗,
/// 正在做的转圈)，VAD+ASR 单独算一段更清晰。
///
/// 与 AudioPipeline.swift 里 onProgress 调用的 stage 字符串保持兼容——
/// 5 原始 stage 都通过 mapToBroadStage 映射到 4 阶段。
/// 多个 view 复用：Sidebar 状态图标 / FileDetailView checklist / ResultsContent 等
enum PipelineSteps {
    /// 4 阶段顺序固定
    static let all: [(stage: String, label: String)] = [
        ("preprocess", "预处理"),       // PCM 解码 + fbank 物化
        ("asr", "文字识别"),            // VAD + ASR 流水线
        ("punc", "标点"),
        ("speaker", "说话人"),
    ]

    /// 把 AudioPipeline 报的原始 stage 映射到 4 阶段。
    static func mapToBroadStage(_ stage: String) -> String {
        switch stage {
        case "load":                   return "preprocess"
        case "vad", "asr":             return "asr"
        case "punc":                   return "punc"
        case "speaker", "speaker_failed", "done": return "speaker"
        default:                       return "preprocess"
        }
    }

    static func stageLabel(_ stage: String) -> String {
        switch stage {
        case "preprocess": return "预处理"
        case "load":       return "预处理"  // 老 stage 字符串兼容
        case "asr":        return "文字识别"
        case "vad":        return "文字识别"  // 老 stage 字符串兼容
        case "punc":       return "标点"
        case "speaker":    return "说话人"
        case "done":       return "完成"
        case "speaker_failed": return "说话人"
        // 空串：转写还没开始第一个 stage。Sidebar / FileDetailView 之前
        // 各自有 "转写中" 的兜底文案，集中在这一处给所有人用。
        case "":           return "转写中"
        default:           return stage
        }
    }
}
