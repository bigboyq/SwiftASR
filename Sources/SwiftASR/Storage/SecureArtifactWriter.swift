import Foundation

/// Owner-only 权限收敛工具，统一 result artifact 的写入与目录初始化。
///
/// `settings.json` / 日志已经有自己的权限实现（`SettingsStore` / `Logger`）。
/// 这里覆盖的是 result artifact 侧：`result.json`、speaker sidecar、事务
/// manifest、stage 目录、删除事务目录以及删除事务内部备份文件。
///
/// 默认权限：普通文件 `0600`，目录 `0700`。审计 R4-P0-1 / R4-P1-10。
enum SecureArtifactWriter {
    /// 安全写入的普通文件权限。
    static let filePermissions: Int = 0o600
    /// 安全写入的目录权限。
    static let directoryPermissions: Int = 0o700

    /// 原子写入一个 `Encodable` 到 `path`，并保证文件权限收紧到
    /// `filePermissions`。父目录不存在时按 `directoryPermissions` 递归创建，
    /// 已存在的父目录也会被收紧（best-effort，失败抛错让调用方观测）。
    ///
    /// `.atomic` 本身不接受 `attributes`，所以先原子落盘再 `setAttributes`
    /// 收紧。与 `Logger` / `SettingsStore` 的两步法一致。
    static func writeEncodable<T: Encodable>(
        _ value: T,
        to path: URL,
        outputFormatting: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys]
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        let data = try encoder.encode(value)
        try writeData(data, to: path)
    }

    /// 原子写入原始 `Data`，落盘后收紧到 `filePermissions`。父目录按
    /// `directoryPermissions` 创建/收紧。
    static func writeData(_ data: Data, to path: URL) throws {
        try ensureDirectory(path.deletingLastPathComponent())
        try data.write(to: path, options: [.atomic])
        try restrictFile(at: path)
    }

    /// 保证目录存在并收紧到 `directoryPermissions`。已存在的目录会被
    /// best-effort 收紧；权限收紧失败抛错，调用方必须能观测到（与
    /// `SettingsStore.protectSettingsDirectory` 行为一致）。
    ///
    /// `createDirectory(withIntermediateDirectories: true, attributes:)` 只把
    /// attributes 应用到新创建的叶子目录，中间目录用系统默认权限。这里对
    /// SwiftASR 应用支持根下的整条祖先链逐级创建并收紧，确保 stage 根目录、
    /// hash 分片目录都不会以宽松权限残留。
    ///
    /// **边界**：只收紧 SwiftASR 应用支持根（``~/Library/Application
    /// Support/SwiftASR``）及其子目录。落到系统临时目录、用户指定外部目录
    /// 等位置的写入（测试 fixture、自定义 stageRoot）不会收紧父目录权限，
    /// 避免破坏共享目录。这些外部目录的文件本身仍会在落盘后由调用方按
    /// `restrictFile` 收紧。
    static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        let supportRoot = swiftasrSupportRoot()
        let withinSupport = isWithinSwiftASRSupport(url, supportRoot: supportRoot)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists, userInfo: [
                    NSFilePathErrorKey: url.path
                ])
            }
            if withinSupport {
                try restrictSupportDirectoryChain(at: url, supportRoot: supportRoot)
            }
            return
        }
        try fm.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: withinSupport
                ? [.posixPermissions: NSNumber(value: directoryPermissions)]
                : nil
        )
        if withinSupport {
            // createDirectory 的 attributes 只作用于新创建的叶子目录；
            // 中间目录由 withIntermediateDirectories 创建时使用系统默认权限。
            // 无论目录是新建还是已存在，都对支持根下的整条祖先链逐级收紧。
            try restrictSupportDirectoryChain(at: url, supportRoot: supportRoot)
        }
    }

    /// 收紧 `url` 以及 SwiftASR 支持根下所有已存在的祖先目录。
    /// 该方法同时覆盖首次创建和历史目录升级，避免旧的 0755 stage/hash
    /// 分片目录在后续写入时继续保留宽松权限。
    private static func restrictSupportDirectoryChain(
        at url: URL,
        supportRoot: URL
    ) throws {
        let root = supportRoot.standardizedFileURL
        var current = url.standardizedFileURL
        var directories: [URL] = []

        while isWithinSwiftASRSupport(current, supportRoot: root) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: current.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                break
            }
            directories.append(current)
            if current.path == root.path { break }
            current = current.deletingLastPathComponent()
        }

        for directory in directories.reversed() {
            try restrictDirectory(at: directory)
        }
    }

    /// SwiftASR 应用支持根：``~/Library/Application Support/SwiftASR``。
    private static func swiftasrSupportRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SwiftASR")
    }

    /// `url` 是否等于或在 SwiftASR 应用支持根之下。
    private static func isWithinSwiftASRSupport(_ url: URL, supportRoot: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = supportRoot.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    /// 返回 `url` 路径上最深的已存在祖先目录。若所有祖先都不存在，
    /// 返回根 `/`，此时 ensureDirectory 会从文件系统根开始收紧（实际不会发生，
    /// 因为应用支持目录总是存在）。
    /// 收紧普通文件权限到 `filePermissions`。
    static func restrictFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: filePermissions)],
            ofItemAtPath: url.path
        )
    }

    /// 收紧目录权限到 `directoryPermissions`。
    static func restrictDirectory(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: directoryPermissions)],
            ofItemAtPath: url.path
        )
    }

    /// 读取文件当前 posix 权限（测试与诊断用）。失败返回 nil。
    static func currentPermissions(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attrs[.posixPermissions] as? NSNumber
        else { return nil }
        return permissions.intValue
    }
}
