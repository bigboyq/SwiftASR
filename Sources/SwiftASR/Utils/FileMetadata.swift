import Foundation
import AVFoundation

enum FileSystemMetadata {
    /// FileManager attributes 来自 Objective-C；明确先桥接为 NSNumber，避免在不同
    /// Foundation bridge 情况下直接 `as? Int64` 得到意外的 0。
    static func byteSize(from attributes: [FileAttributeKey: Any]?) -> Int64? {
        guard let number = attributes?[.size] as? NSNumber else { return nil }
        return number.int64Value
    }

    /// 递归累加目录下所有 regular file 的 size（不包括子目录自身的 entry size）。
    /// macOS 上对 directory 调 `attributesOfItem` 拿 `.size` 只能拿到 directory entry
    /// 本身的小数字（model_batch16.mlmodelc 之类是 224），跟用户
    /// 心智模型里"目录总大小"对不上——他想知道这个 bundle 实际占多少磁盘。
    ///
    /// - 走 `subpaths(atPath:)` 拿所有 entry → 拼绝对路径 → 累加 file size
    /// - 跳过 directory entry（递归时算里面 file，目录自身不重复算）
    /// - 跳过 symlink（不解析，防止环）
    /// - 路径不存在 / 权限错误给 0 而不是抛，跟 `byteSize` 行为对齐
    static func directoryTotalSize(at path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        guard let entries = fm.subpaths(atPath: path) else { return 0 }
        var total: Int64 = 0
        for relativePath in entries {
            let full = (path as NSString).appendingPathComponent(relativePath)
            guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
            if let type = attrs[.type] as? FileAttributeType, type == .typeDirectory { continue }
            if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink { continue }
            if let size = byteSize(from: attrs) {
                total += size
            }
        }
        return total
    }
}

/// 从磁盘读音频文件元数据 (大小 + 时长).
/// 失败 (文件不存在 / 不可读 / 非音频) 给合理 fallback (size=0, duration=0).
///
/// 用 AVFoundation 拿时长需要 `import AVFoundation` — 之前这条 import 放在
/// `FileActionCoordinator.swift` 第 779 行 (中间位置), 移到独立文件后放在
/// 文件头符合 Swift 习惯.
func fileMetadata(at path: String) -> (fileSize: Int64, durationSeconds: Double) {
    let fm = FileManager.default
    var fileSize: Int64 = 0
    if let attrs = try? fm.attributesOfItem(atPath: path), let size = FileSystemMetadata.byteSize(from: attrs) {
        fileSize = size
    }
    var duration: Double = 0
    let url = URL(fileURLWithPath: path)
    if fm.fileExists(atPath: path) {
        if let audioFile = try? AVAudioFile_readDuration(url: url) {
            duration = audioFile
        }
    }
    return (fileSize, duration)
}

/// `private` 包装: 隔离 AVFoundation API, 失败给 0 fallback.
/// 之前定义在 FileActionCoordinator.swift 文件末尾, 现在跟 fileMetadata 放一起.
private func AVAudioFile_readDuration(url: URL) throws -> Double {
    let f = try AVAudioFile(forReading: url)
    let sr = f.processingFormat.sampleRate
    guard sr > 0 else { return 0 }
    return Double(f.length) / sr
}
