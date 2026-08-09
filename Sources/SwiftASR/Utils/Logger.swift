import Foundation
import os

/// 轻量文件日志。
/// - 按天 rotate：``~/Library/Application Support/SwiftASR/logs/swiftasr-YYYY-MM-DD.log``
/// - 保留最近 7 天（旧文件自动清理）
/// - 线程安全：内部用 NSLock 串行化文件写入
/// - 权限收敛：日志目录为 0700，日志文件为 0600
/// - 同时写一行到 stderr（开发期能看到）
/// - ``Logger.shared`` 是单例；埋点直接用 ``Logger.shared.info/warn/error(_:)``
///
/// Phase 7 新增。设计原则：只记录低频重大事件，避免在 hot path 上同步写日志。
/// 重大事件（pipeline 启动/完成/失败、cleanup 启动/完成/失败、speaker fallback）埋点；
/// 高频事件（每段 ASR）不埋，避免日志爆炸。
public final class Logger: @unchecked Sendable {
    public enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    public static let shared = Logger()

    /// 默认日志根：``~/Library/Application Support/SwiftASR/logs``
    public static var defaultLogRoot: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/SwiftASR/logs").path
    }

    /// 日志根（实例属性，单元测试可注入临时路径）
    public let logRoot: String

    /// 保留天数（默认 7 天）
    public let retentionDays: Int

    private let lock = NSLock()
    private let dateFormatter: DateFormatter
    private let fileDateFormatter: DateFormatter
    private let stderr = FileHandle.standardError

    /// 单元测试可注入：override 当天文件名（用于测试 rotate）
    private let clock: () -> Date

    public init(logRoot: String = Logger.defaultLogRoot, retentionDays: Int = 7,
                clock: @escaping () -> Date = Date.init) {
        self.logRoot = logRoot
        self.retentionDays = retentionDays
        self.clock = clock
        self.dateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            return f
        }()
        self.fileDateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            return f
        }()
        _ = secureLogStorage()
    }

    @discardableResult
    public func info(_ message: @autoclosure () -> String,
                     file: String = #fileID, line: Int = #line) -> Bool {
        log(level: .info, message: message(), file: file, line: line)
    }

    @discardableResult
    public func warn(_ message: @autoclosure () -> String,
                     file: String = #fileID, line: Int = #line) -> Bool {
        log(level: .warn, message: message(), file: file, line: line)
    }

    @discardableResult
    public func error(_ message: @autoclosure () -> String,
                      file: String = #fileID, line: Int = #line) -> Bool {
        log(level: .error, message: message(), file: file, line: line)
    }

    /// 写一条日志。会触发：当日文件 rotate + 7 天前文件清理
    /// - Returns: 日志正文成功追加且安全权限已确认时为 `true`。
    @discardableResult
    public func log(
        level: Level,
        message: String,
        file: String = #fileID,
        line: Int = #line
    ) -> Bool {
        return withLock {
            // DateFormatter 与 FileHandle 都不是并发值，统一放在同一临界区。
            let now = clock()
            let timestamp = dateFormatter.string(from: now)
            let day = fileDateFormatter.string(from: now)
            let entry = "\(timestamp) [\(level.rawValue)] [\(file):\(line)] \(message)\n"

            // stderr（开发期能看到）
            stderr.write(Data(entry.utf8))

            // 文件
            guard secureLogRoot() else { return false }

            let path = URL(fileURLWithPath: logRoot)
                .appendingPathComponent("swiftasr-\(day).log")
                .path

            let fm = FileManager.default
            let existed = fm.fileExists(atPath: path)
            if !existed {
                let created = fm.createFile(
                    atPath: path,
                    contents: nil,
                    attributes: [.posixPermissions: NSNumber(value: 0o600)]
                )
                guard created else {
                    writeDiagnostic("无法创建日志文件")
                    return false
                }
            }
            guard secureLogFile(atPath: path) else { return false }

            // 写新文件时顺手清理过期文件。
            if !existed {
                _ = purgeExpiredLocked(reference: now)
            }

            do {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
                return true
            } catch {
                writeDiagnostic("无法写入日志文件", error: error)
                return false
            }
        }
    }

    /// 删除早于 retentionDays 的日志文件
    @discardableResult
    public func purgeExpired(reference: Date? = nil) -> Bool {
        withLock {
            purgeExpiredLocked(reference: reference)
        }
    }

    private func purgeExpiredLocked(reference: Date? = nil) -> Bool {
        let ref = reference ?? clock()
        let fm = FileManager.default
        let files: [String]
        do {
            files = try fm.contentsOfDirectory(atPath: logRoot)
        } catch {
            writeDiagnostic("无法读取日志目录", error: error)
            return false
        }

        var succeeded = true
        let cutoff = ref.addingTimeInterval(-Double(retentionDays) * 86400.0)
        for name in files where isLogFilename(name) {
            let path = URL(fileURLWithPath: logRoot).appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if mtime < cutoff {
                do {
                    try fm.removeItem(atPath: path)
                } catch {
                    succeeded = false
                    writeDiagnostic("无法清理过期日志文件", error: error)
                }
            }
        }
        return succeeded
    }

    /// 所有日志文件列表（按 mtime 倒序）
    public func listLogFiles() -> [(name: String, path: String, sizeBytes: Int64, modifiedAt: Date)] {
        withLock {
            listLogFilesLocked()
        }
    }

    private func listLogFilesLocked()
        -> [(name: String, path: String, sizeBytes: Int64, modifiedAt: Date)]
    {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logRoot) else { return [] }
        var out: [(name: String, path: String, sizeBytes: Int64, modifiedAt: Date)] = []
        for name in files where isLogFilename(name) {
            let path = URL(fileURLWithPath: logRoot).appendingPathComponent(name).path
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = FileSystemMetadata.byteSize(from: attrs) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            out.append((name: name, path: path, sizeBytes: size, modifiedAt: mtime))
        }
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 强制清理所有日志文件（SettingsTab "清理日志"按钮调用）
    @discardableResult
    public func clearAll() -> Bool {
        withLock {
            clearAllLocked()
        }
    }

    private func clearAllLocked() -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logRoot) else { return false }
        var succeeded = true
        for name in files where isLogFilename(name) {
            let path = URL(fileURLWithPath: logRoot).appendingPathComponent(name).path
            do {
                try fm.removeItem(atPath: path)
            } catch {
                succeeded = false
                // Do not call Logger recursively while clearing its own files.
                writeDiagnostic("无法清理日志文件", error: error)
            }
        }
        return succeeded
    }

    private func secureLogStorage() -> Bool {
        guard secureLogRoot() else { return false }

        let fm = FileManager.default
        let files: [String]
        do {
            files = try fm.contentsOfDirectory(atPath: logRoot)
        } catch {
            writeDiagnostic("无法读取日志目录", error: error)
            return false
        }

        var succeeded = true
        for name in files where isLogFilename(name) {
            let path = URL(fileURLWithPath: logRoot).appendingPathComponent(name).path
            if !secureLogFile(atPath: path) {
                succeeded = false
            }
        }
        return succeeded
    }

    private func secureLogRoot() -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: logRoot, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                writeDiagnostic("日志根路径不是目录")
                return false
            }
        } else {
            do {
                try fm.createDirectory(
                    atPath: logRoot,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                writeDiagnostic("无法创建日志目录", error: error)
                return false
            }
        }

        do {
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: logRoot
            )
            return true
        } catch {
            writeDiagnostic("无法收敛日志目录权限", error: error)
            return false
        }
    }

    private func secureLogFile(atPath path: String) -> Bool {
        let fm = FileManager.default
        do {
            let attributes = try fm.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                writeDiagnostic("日志路径不是普通文件")
                return false
            }
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: path
            )
            return true
        } catch {
            writeDiagnostic("无法收敛日志文件权限", error: error)
            return false
        }
    }

    private func isLogFilename(_ name: String) -> Bool {
        name.hasPrefix("swiftasr-") && name.hasSuffix(".log")
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// 权限或文件系统错误不能再进入 Logger，否则失败路径会递归。
    /// 诊断只描述操作与系统错误，不包含原始日志正文。
    private func writeDiagnostic(_ operation: String, error: Error? = nil) {
        let detail = error.map { "：\($0.localizedDescription)" } ?? ""
        stderr.write(Data("[ERROR] \(operation)\(detail)\n".utf8))
    }
}
