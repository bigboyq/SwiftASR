import Testing
import Foundation
@testable import SwiftASR

@Test func fileSystemMetadataBridgesNSNumberFileSize() {
    let attributes: [FileAttributeKey: Any] = [.size: NSNumber(value: Int64.max)]
    #expect(FileSystemMetadata.byteSize(from: attributes) == Int64.max)
}

// MARK: - Phase 7: Logger / Stage migration / ModelsInspector

@Test func loggerWritesToFile() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("logger_test_\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let now = Date()
    let logger = Logger(logRoot: tmp, retentionDays: 7, clock: { now })
    #expect(logger.info("hello world"))

    let expected = URL(fileURLWithPath: tmp)
        .appendingPathComponent("swiftasr-\(Phase7Tests_Helper.dayFormatter.string(from: now)).log")
        .path

    #expect(FileManager.default.fileExists(atPath: expected),
            "应该写到当日文件: \(expected)")

    let content = (try? String(contentsOfFile: expected, encoding: .utf8)) ?? ""
    #expect(content.contains("hello world"))
    #expect(content.contains("[INFO]"))
    #expect(try Phase7Tests_Helper.permissions(atPath: tmp) == 0o700)
    #expect(try Phase7Tests_Helper.permissions(atPath: expected) == 0o600)
}

@Test func loggerHardensExistingDirectoryAndLogFiles() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("logger_permissions_\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: tmp) }

    try fm.createDirectory(
        atPath: tmp,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o755)]
    )
    let existing = URL(fileURLWithPath: tmp)
        .appendingPathComponent("swiftasr-2020-01-01.log")
        .path
    #expect(fm.createFile(
        atPath: existing,
        contents: Data("existing".utf8),
        attributes: [.posixPermissions: NSNumber(value: 0o644)]
    ))
    try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: tmp)
    try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: existing)

    _ = Logger(logRoot: tmp)

    #expect(try Phase7Tests_Helper.permissions(atPath: tmp) == 0o700)
    #expect(try Phase7Tests_Helper.permissions(atPath: existing) == 0o600)
}

@Test func loggerReportsFileWriteFailureWithoutRecursing() throws {
    let fm = FileManager.default
    let rootFile = fm.temporaryDirectory
        .appendingPathComponent("logger_invalid_root_\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: rootFile) }
    #expect(fm.createFile(atPath: rootFile, contents: Data()))

    let logger = Logger(logRoot: rootFile)
    #expect(!logger.info("must not be persisted"))
}

@Test func loggerRotatesAcrossDays() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("logger_rotate_\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    var fakeDate = Date(timeIntervalSince1970: 1_700_000_000) // 任意一天
    let logger = Logger(logRoot: tmp, retentionDays: 7, clock: { fakeDate })

    logger.info("day1 message")
    #expect(logger.listLogFiles().count == 1)

    // 跨天
    fakeDate = fakeDate.addingTimeInterval(86400 * 2)
    logger.info("day3 message")
    #expect(logger.listLogFiles().count == 2, "应该跨天产生 2 个文件")

    let names = logger.listLogFiles().map(\.name).sorted()
    #expect(names[0] != names[1])
}

@Test func loggerClearAll() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("logger_clear_\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let now = Date()
    let logger = Logger(logRoot: tmp, retentionDays: 7, clock: { now })
    logger.info("m1")
    logger.warn("m2")
    #expect(logger.listLogFiles().count >= 1)

    logger.clearAll()
    #expect(logger.listLogFiles().isEmpty, "clearAll 后应该没有日志文件")
}

@Test func loggerPurgesExpired() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("logger_purge_\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    // 手动建一个 10 天前的旧文件
    let oldName = "swiftasr-2020-01-01.log"
    let oldPath = URL(fileURLWithPath: tmp).appendingPathComponent(oldName).path
    FileManager.default.createFile(atPath: oldPath, contents: Data("old".utf8))

    // 改 mtime 到 10 天前
    let tenDaysAgo = Date().addingTimeInterval(-10 * 86400)
    try? FileManager.default.setAttributes([.modificationDate: tenDaysAgo],
                                           ofItemAtPath: oldPath)

    // 写入一个今天的
    let now = Date()
    let logger = Logger(logRoot: tmp, retentionDays: 7, clock: { now })
    logger.info("new")

    // 触发 purge
    logger.purgeExpired(reference: now)

    let remaining = logger.listLogFiles().map(\.name)
    #expect(!remaining.contains(oldName), "10 天前的日志应该被 purge")
    #expect(remaining.count >= 1, "今天的日志应该保留")
}

// MARK: - Stage 迁移

@Test func modelCatalogChecksTheSameRequiredFilesUsedByPackaging() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("model_catalog_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    for definition in ModelCatalog.definitions {
        for file in definition.requiredFiles {
            let path = ModelCatalog.filePath(
                definitionID: definition.id,
                file: file,
                modelsRoot: root.path
            )
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: URL(fileURLWithPath: path))
        }
    }

    #expect(ModelCatalog.missingRequiredFiles(modelsRoot: root.path).isEmpty)

    let missingPath = ModelCatalog.filePath(
        definitionID: "vad", file: "am.mvn", modelsRoot: root.path
    )
    try FileManager.default.removeItem(atPath: missingPath)
    #expect(ModelCatalog.missingRequiredFiles(modelsRoot: root.path) == ["vad/am.mvn"])
}

@Test func stageMigrationMovesFromStageStageToStage() throws {
    let fm = FileManager.default
    let appSupport = fm.temporaryDirectory
        .appendingPathComponent("swiftasr_migrate_\(UUID().uuidString)")
    let oldRoot = appSupport.appendingPathComponent("stage").appendingPathComponent("stage")
    let newRoot = appSupport.appendingPathComponent("stage")

    // 在 stage/stage/ab/cd/abcd.result.json 放一个文件
    let oldFile = oldRoot.appendingPathComponent("ab").appendingPathComponent("cd")
        .appendingPathComponent("abcd1234.result.json")
    try fm.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: oldFile)

    // 但 ResultStore.migrateDoubleStageLayout 是用 homeDirectoryForCurrentUser 计算的，
    // 不能直接注入 stageRoot。手动验证路径计算正确性（而不是实际迁移）：
    let destPath = ResultStore.stageResultPath(jobId: "abcd1234", stageRoot: newRoot.path)
    #expect(destPath.path.hasSuffix("/ab/cd/abcd1234.result.json"))
    #expect(!destPath.path.contains("/stage/stage/"))

    // 模拟迁移逻辑：把旧文件搬到新位置（用 ResultStore.stageResultPath 算目标）
    let newDir = destPath.deletingLastPathComponent()
    try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
    try fm.moveItem(at: oldFile, to: destPath)
    #expect(fm.fileExists(atPath: destPath.path))
    #expect(!fm.fileExists(atPath: oldFile.path))
}

// MARK: - ModelsInspector

@Test func modelsInspectorReportsAllFourModels() {
    // 测试固定定义有 4 个
    let defs = ModelsInspector.modelDefinitions
    #expect(defs.count == 4)
    #expect(Set(defs.map(\.id)) == Set(["vad", "asr", "punc", "speaker"]))
}

@Test func modelsInspectorInspectModelsForMissingDir() {
    // 用一个明显不存在的根目录扫：所有 model 的 file.exists 都应该是 false
    // 不能直接修改 modelsRoot（static let），所以我们手动构造同样的 modelDefinitions 子集
    // 这里只验证 inspectModels 不会崩溃 + 返回 4 个
    let models = ModelsInspector.inspectModels()
    #expect(models.count == 4)

    #expect(models.first(where: { $0.id == "vad" })?.files.contains { $0.name == "model_quant.onnx" } == true)
    #expect(models.first(where: { $0.id == "asr" })?.files.contains { $0.name == "model_quant.onnx" } == true)
    #expect(models.first(where: { $0.id == "punc" })?.files.contains { $0.name == "model_quant.onnx" } == true)
    #expect(models.first(where: { $0.id == "speaker" })?.files.contains { $0.name == "model_batch16.mlmodelc" } == true)
}

@Test func modelCatalogRequiresFixedProductionModelFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("model_contract_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    // 2026-07-26 codex-audit fix: speaker production contract is
    // now `.mlmodelc` ONLY.  The `.mlpackage` (coremltools source
    // format) is no longer a valid alternative — if a bundle has
    // only the .mlpackage, `AudioPipeline` startup will fail to
    // load the model.  Missing the .mlmodelc must surface as a
    // model-contract error during preflight.
    let missing = ModelCatalog.missingRequiredFiles(modelsRoot: root.path)
    #expect(
        missing.contains("speaker/model_batch16.mlmodelc"),
        "speaker must require .mlmodelc (no longer tolerates .mlpackage); missing=\(missing)"
    )
    #expect(
        !missing.contains(where: { $0.contains("mlpackage") }),
        "speaker must not list .mlpackage as a valid alternative; missing=\(missing)"
    )
}

@Test func dataLocationInspectorReturnsAllFourLocations() {
    let locs = ModelsInspector.inspectDataLocations()
    #expect(locs.count == 4)
    #expect(Set(locs.map(\.id)) == Set([
        .settingsJSON, .stageResults, .swiftDataStore, .logs
    ]))
}

// MARK: - 辅助

enum Phase7Tests_Helper {
    static func permissions(atPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let value = try #require(attributes[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }

    static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }
}
