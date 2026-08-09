import Foundation

/// 模型管理面板用的模型信息。
/// Phase 7 新增。每个模型描述：用途、目录路径、关键文件、是否存在、总大小。
/// 状态：✅ ready / ❌ missing
public struct ModelInfo: Identifiable, Sendable {
    public enum Role: String, Sendable {
        case vad = "VAD"
        case asr = "ASR"
        case punc = "标点"
        case speaker = "说话人"
    }

    public enum Backend: String, Sendable {
        case onnxCPU = "ONNX/CPU"
        case onnxCoreMLEP = "ONNX/CoreML EP"
        case nativeCoreML = "Native CoreML"
    }

    public let id: String           // "vad" / "asr" / "punc" / "speaker"
    public let role: Role
    public let name: String         // "FSMN-VAD" 等
    public let backend: Backend     // 当前 production 路由的 ONNX execution provider
    public let directory: String    // 绝对路径
    public let files: [FileInfo]    // 关键文件
    public let requiredFileGroups: [[String]]

    public var isReady: Bool {
        requiredFileGroups.allSatisfy { group in
            group.contains { file in files.first(where: { $0.name == file })?.exists == true }
        }
    }
    public var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    public struct FileInfo: Sendable {
        public let name: String           // "model_quant.onnx"
        public let path: String           // 完整路径
        public let sizeBytes: Int64       // 0 = 不存在
        public let exists: Bool
    }
}

/// 数据位置面板用的目录/文件信息。
public struct DataLocation: Identifiable, Sendable {
    public enum Kind: Sendable {
        case settingsJSON
        case stageResults
        case swiftDataStore
        case logs
    }

    public let id: Kind
    public let title: String
    public let path: String
    public let sizeBytes: Int64
    public let fileCount: Int
    public let description: String
}

/// ModelsInspector：扫描模型目录 + 数据位置。
/// 静态函数无 IO 副作用，只读 + 派生统计。
public enum ModelsInspector {
    public static let modelsRoot = ModelCatalog.defaultModelsRoot
    /// 兼容现有测试与调用点；定义只在 ``ModelCatalog`` 维护。
    public static let modelDefinitions = ModelCatalog.definitions

    public static func inspectModels() -> [ModelInfo] {
        modelDefinitions.map { def in
            let dir = ModelCatalog.directoryPath(definitionID: def.id, modelsRoot: modelsRoot)
            let fileInfos = def.requiredFiles.map { fname -> ModelInfo.FileInfo in
                let p = ModelCatalog.filePath(definitionID: def.id, file: fname, modelsRoot: modelsRoot)
                let fm = FileManager.default
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: p, isDirectory: &isDir)
                // directory 的 .size 只是 directory entry 本身（224 / 128 这种小数字），
                // 跟用户心智模型里"目录总大小"对不上。CoreML bundle (.mlmodelc)
                // 真正占磁盘的是里面 weights/ + coremldata.bin + model.mil，递归算总和。
                // 2026-07-26: `.mlpackage` 不再是生产契约的一部分，coremltools 源
                // 格式只供 `scripts/export_speaker_batch16_coreml.py` 导出 .mlmodelc
                // 时用，不应该出现在 Models 目录里。
                let size: Int64
                if exists, isDir.boolValue {
                    size = FileSystemMetadata.directoryTotalSize(at: p)
                } else if exists, let attrs = try? fm.attributesOfItem(atPath: p),
                          let s = FileSystemMetadata.byteSize(from: attrs) {
                    size = s
                } else {
                    size = 0
                }
                return ModelInfo.FileInfo(name: fname, path: p, sizeBytes: size, exists: exists)
            }
            return ModelInfo(
                id: def.id, role: ModelInfo.Role(rawValue: def.role.rawValue) ?? .asr,
                name: def.name,
                backend: ModelInfo.Backend(rawValue: def.backend.rawValue) ?? .onnxCPU,
                directory: dir, files: fileInfos,
                requiredFileGroups: def.requiredFileGroups
            )
        }
    }

    // MARK: - 数据位置

    public static func inspectDataLocations() -> [DataLocation] {
        let fm = FileManager.default
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SwiftASR")

        var out: [DataLocation] = []

        // 1. settings.json
        let settingsURL = appSupport.appendingPathComponent("settings.json")
        let settingsSize = fileSize(at: settingsURL.path)
        out.append(DataLocation(
            id: .settingsJSON, title: "设置文件",
            path: settingsURL.path,
            sizeBytes: settingsSize, fileCount: 1,
            description: "API Keys / 术语表 / 润色设置。Phase 7 起 keypool 切换也会回写。"
        ))

        // 2. stage result.json 根
        let stageRoot = appSupport.appendingPathComponent("stage").path
        let stageStats = directoryStats(at: stageRoot, suffixFilter: ".result.json")
        out.append(DataLocation(
            id: .stageResults, title: "转写结果（result.json）",
            path: stageRoot,
            sizeBytes: stageStats.sizeBytes, fileCount: stageStats.fileCount,
            description: "按 SHA256 分桶 stage/<xx>/<xx>/<hash>.result.json；speaker sidecar 不计入此统计。"
        ))

        // 3. SwiftData store
        // swift run 默认位置：~/Library/Application Support/default.store
        let storePath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/default.store")
            .path
        let storeSize = fileSize(at: storePath) + fileSize(at: storePath + "-wal") + fileSize(at: storePath + "-shm")
        out.append(DataLocation(
            id: .swiftDataStore, title: "SwiftData 数据库",
            path: storePath,
            sizeBytes: storeSize, fileCount: 1,
            description: "ASRJob / SpeakerProfile / JobSpeakerProfileOccurrence / Person 等表。WAL + SHM 算在里面。"
        ))

        // 4. 日志
        let logsRoot = Logger.defaultLogRoot
        let logsStats = directoryStats(at: logsRoot, extensionFilter: "log", prefix: "swiftasr-")
        out.append(DataLocation(
            id: .logs, title: "日志（按天）",
            path: logsRoot,
            sizeBytes: logsStats.sizeBytes, fileCount: logsStats.fileCount,
            description: "保留最近 7 天自动 rotate。可一键清理。"
        ))

        return out
    }

    // MARK: - 工具

    private static func fileSize(at path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = FileSystemMetadata.byteSize(from: attrs) else { return 0 }
        return size
    }

    private static func directoryStats(
        at root: String,
        extensionFilter ext: String? = nil,
        suffixFilter suffix: String? = nil,
        prefix: String? = nil
    )
        -> (sizeBytes: Int64, fileCount: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let enumerator = fm.enumerator(atPath: root) else {
            return (0, 0)
        }
        var total: Int64 = 0
        var count = 0
        while let name = enumerator.nextObject() as? String {
            if let ext = ext, (name as NSString).pathExtension != ext { continue }
            if let suffix, !name.hasSuffix(suffix) { continue }
            if let p = prefix, !(name.hasPrefix(p)) { continue }
            let full = "\(root)/\(name)"
            total += fileSize(at: full)
            count += 1
        }
        return (total, count)
    }
}
