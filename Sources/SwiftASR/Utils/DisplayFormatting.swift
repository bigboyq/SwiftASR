import Foundation

/// 显示用的格式化 helper, 多个 view 共用:
///
/// - `formatBytes` 用了 ~6 处 (FileDetailView / ModelsAndDataSection / 等)
/// - `formatDuration` 用了 ~6 处 (FileDetailView / JobWorkspaces / JobStatusDisplay / ResultHistorySheet / 等)
///
/// 注意: `Results/JobInfoCard.swift` 内部有自己的 `formatDuration(seconds: Int)` 重载,
/// Swift 走 method-scope 解析, 不跟全局这个冲突. 不要把那个挪过来合并,
/// 否则要重写一堆 caller.

/// 把字节数格式化成 "1.2 MB" / "456 B" / "3.4 GB" 这种用户友好的字符串.
/// 用 `ByteCountFormatter` 默认 `.file` 计数风格 (1024 base).
func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

/// 把秒数格式化成 "MM:SS" 或 "H:MM:SS" 形式.
/// ≤ 0 返回 "—" (跟历史行为一致, 给"还没算出来"的状态用).
func formatDuration(_ seconds: Double) -> String {
    if seconds <= 0 { return "—" }
    let totalSec = Int(seconds.rounded())
    let h = totalSec / 3600
    let m = (totalSec % 3600) / 60
    let s = totalSec % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

/// 把秒数格式化成 "X 小时 Y 分" 或 "X 分钟" 形式（中文时长短句）。
func formatChineseDuration(_ sec: Double) -> String {
    let totalMinutes = Int(sec / 60)
    if totalMinutes < 60 {
        return "\(totalMinutes) 分钟"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
}
