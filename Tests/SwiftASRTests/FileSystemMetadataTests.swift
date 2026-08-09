import Foundation
import Testing
@testable import SwiftASR

@Suite("FileSystemMetadata")
struct FileSystemMetadataTests {
    @Test func byteSizeReturnsInt64FromAttributes() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-metadata-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.txt")
        try? Data("hello".utf8).write(to: file)
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        #expect(FileSystemMetadata.byteSize(from: attrs) == 5)
    }

    @Test func directoryTotalSizeSumsAllRegularFilesRecursively() {
        // 构造一个临时目录树:
        //   root/
        //     a.txt (3 bytes: "aaa")
        //     sub/
        //       b.txt (4 bytes: "bbbb")
        //       deep/
        //         c.txt (5 bytes: "ccccc")
        // 总和应该是 3+4+5 = 12 bytes
        // 不应该被 directory 自身的 entry size 干扰（macOS 上是 96 / 128 之类）
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-dir-size-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try? Data("aaa".utf8).write(to: root.appendingPathComponent("a.txt"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try? Data("bbbb".utf8).write(to: sub.appendingPathComponent("b.txt"))
        let deep = sub.appendingPathComponent("deep", isDirectory: true)
        try? FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try? Data("ccccc".utf8).write(to: deep.appendingPathComponent("c.txt"))

        #expect(FileSystemMetadata.directoryTotalSize(at: root.path) == 12)
    }

    @Test func directoryTotalSizeSkipsSymlinks() {
        // symlink 不解析也不计入 size — 防止环，也防止通过 symlink 算到
        // 外部文件的大小。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-dir-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try? Data("real".utf8).write(to: root.appendingPathComponent("real.txt"))
        // symlink 指 root 自身会形成环；用 /tmp/.. 之类的也行
        try? FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root
        )

        #expect(FileSystemMetadata.directoryTotalSize(at: root.path) == 4)
    }

    @Test func directoryTotalSizeReturnsZeroForNonexistent() {
        let missing = "/tmp/fs-metadata-missing-\(UUID().uuidString)"
        #expect(FileSystemMetadata.directoryTotalSize(at: missing) == 0)
    }

    @Test func directoryTotalSizeReturnsZeroForRegularFile() {
        // 对 file 路径调 directoryTotalSize 应当返回 0（不是 file 自己的 size），
        // 跟"非 directory 路径视作无效"语义一致。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-metafile-\(UUID().uuidString).txt")
        try? Data("xxx".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(FileSystemMetadata.directoryTotalSize(at: tmp.path) == 0)
    }
}
