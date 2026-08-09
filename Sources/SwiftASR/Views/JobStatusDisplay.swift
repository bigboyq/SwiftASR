import SwiftUI

// MARK: - Job 状态展示

/// Job 6 状态在 UI 端展示的统一入口。3 处文件之前各自手写 emoji + 颜色：
/// - `FileDetailView.StatusPill`（顶部胶囊）
/// - `Sidebar.FileRow.statusIcon` + `pipelineMessage`（左侧行）
/// - `PipelineSteps.statusText` / `statusColor`（`mapToBroadStage` 配套）
///
/// Phase 19（2026-07-12）抽出统一 enum，跟说话人页 `ProfileHealth` 风格一致：
/// - `icon: String` — SF Symbol 名字（不用 emoji，Apple HIG 不鼓励）
/// - `color: Color` — 系统色或 .tint
/// - `label: String` — 状态中文文案
/// - `shortMessage(job:)` — Sidebar 行内副标题（"已处理 · 1:14:48"）
///
/// 调用方全部走 `JobStatusDisplay(.done)` / `JobStatusDisplay(job.jobStatus)`，
/// 不再直接拼 emoji。
enum JobStatusDisplay {
    case done
    case running
    case failed
    case cancelled
    case queued
    case partial

    init(_ status: JobStatus) {
        switch status {
        case .done:                 self = .done
        case .running, .processing: self = .running
        case .failed:               self = .failed
        case .cancelled:            self = .cancelled
        case .queued:               self = .queued
        case .partial:              self = .partial
        }
    }

    /// SF Symbol 名字
    var icon: String {
        switch self {
        case .done:      return "checkmark.circle.fill"
        case .running:   return "arrow.triangle.2.circlepath"
        case .failed:    return "xmark.octagon.fill"
        case .cancelled: return "minus.circle.fill"
        case .queued:    return "clock.fill"
        case .partial:   return "exclamationmark.triangle.fill"
        }
    }

    /// 系统色
    var color: Color {
        switch self {
        case .done:      return .green
        case .running:   return .blue
        case .failed:    return .red
        case .cancelled: return .gray
        case .queued:    return .yellow
        case .partial:   return .orange
        }
    }

    /// 状态中文文案（带 SF Symbol 一起展示时的文字部分）
    var label: String {
        switch self {
        case .done:      return "已处理"
        case .running:   return "转写中"
        case .failed:    return "失败"
        case .cancelled: return "已取消"
        case .queued:    return "排队"
        case .partial:   return "部分完成"
        }
    }

    /// 状态胶囊背景色（`StatusPill` 用，opacity 0.20）
    var pillBackground: Color {
        color.opacity(0.20)
    }

    /// Sidebar 行内副标题：带进度/时长/错误信息。
    /// nil = 不显示（queued 状态没进度可显示）。
    func shortMessage(job: ASRJob) -> String? {
        switch self {
        case .done:
            let dur = formatDuration(job.durationSeconds)
            return "已处理 · \(dur)"
        case .running:
            // 优先用 stage label（来自 PipelineSteps.stageLabel，跟 4 阶段显示一致）。
            // `nonEmpty` 是 Sidebar.swift 私有 String 扩展，跨文件不可见 — 显式判 isEmpty。
            let stage = job.pipelineStage
            if !stage.isEmpty {
                let pct = Int(job.pipelineFraction * 100)
                return "\(PipelineSteps.stageLabel(stage)) · \(pct)%"
            }
            return "转写中…"
        case .failed:
            let err = job.errorMessage ?? ""
            // 截 60 字符避免长错误信息撑爆 Sidebar
            let prefix = String(err.prefix(60))
            return prefix.isEmpty ? "失败" : "失败：\(prefix)"
        case .cancelled:
            return "已取消"
        case .queued:
            return nil
        case .partial:
            return "Speaker 失败 · ASR 已保存"
        }
    }
}
