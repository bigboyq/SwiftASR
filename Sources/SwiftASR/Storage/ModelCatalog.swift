import Foundation

/// 固定模型集的唯一目录与文件契约。
///
/// 不向用户暴露模型选择；这里的职责是让 pipeline 加载、设置页健康检查和打包脚本
/// 对同一组路径达成一致。发布版只接受 app bundle 内的 Models 目录；开发机 fallback
/// 被严格限制在 DEBUG，避免把个人绝对路径带进可分发构建。
public enum ModelCatalog {
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

    public struct Definition: Sendable, Equatable {
        public let id: String
        public let role: Role
        public let name: String
        public let backend: Backend
        public let subdirectory: String
        public let requiredFiles: [String]
        /// Each group describes one fixed production requirement. Groups are
        /// retained for the Settings UI, but no runtime model-file fallback is
        /// allowed; only the production bundle and development root may vary.
        public let requiredFileGroups: [[String]]

        public init(
            id: String,
            role: Role,
            name: String,
            backend: Backend,
            subdirectory: String,
            requiredFiles: [String],
            requiredFileGroups: [[String]]? = nil
        ) {
            self.id = id
            self.role = role
            self.name = name
            self.backend = backend
            self.subdirectory = subdirectory
            self.requiredFiles = requiredFiles
            self.requiredFileGroups = requiredFileGroups ?? requiredFiles.map { [$0] }
        }
    }

    public static let definitions: [Definition] = [
        Definition(
            id: "vad", role: .vad, name: "FSMN-VAD", backend: .onnxCPU,
            subdirectory: "vad", requiredFiles: ["model_quant.onnx", "am.mvn"]
        ),
        Definition(
            id: "asr", role: .asr, name: "SeACo-Paraformer", backend: .onnxCPU,
            subdirectory: "seaco_paraformer",
            requiredFiles: ["model_quant.onnx", "model_eb_quant.onnx", "tokens.json", "am.mvn"]
        ),
        Definition(
            id: "punc", role: .punc, name: "CT-Punc", backend: .onnxCPU,
            subdirectory: "punc", requiredFiles: ["model_quant.onnx", "tokens.json"]
        ),
        // 2026-07-26 codex-audit fix: speaker production contract is
        // now `.mlmodelc` ONLY.  The `.mlpackage` is the
        // coremltools source format used by `scripts/export_speaker_
        // batch16_coreml.py` to *produce* the .mlmodelc; it must
        // never reach the app bundle (≈34 MB of duplicated weights
        // for every release).  build_app.sh now strips it from
        // Resources/Models.  AudioPipeline loads the model via
        // `SpeakerNativeCoreMLEngine` (always native CoreML, no
        // ONNX/CoreML EP failover), so requiring only `.mlmodelc`
        // matches the runtime contract exactly.
        Definition(
            id: "speaker", role: .speaker, name: "ERes2NetV2", backend: .nativeCoreML,
            subdirectory: "speaker",
            requiredFiles: ["model_batch16.mlmodelc"]
        )
    ]

    /// 生产包优先使用内置模型；DEBUG 才允许回退到开发目录。
    /// Release 没有 bundle 模型时返回空字符串，后续初始化会给出明确的缺模型错误。
    public static let defaultModelsRoot: String = {
        if let bundlePath = Bundle.main.resourcePath {
            let candidate = "\(bundlePath)/Models"
            if isDirectory(candidate) {
                return candidate
            }
        }
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SWIFTASR_DEV_MODELS_ROOT"], !env.isEmpty {
            if isDirectory(env) { return env }
        }
        let checkoutRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Models", isDirectory: true)
            .path
        if isDirectory(checkoutRoot) { return checkoutRoot }
        #endif
        return ""
    }()

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public static func filePath(
        definitionID: String,
        file: String,
        modelsRoot: String
    ) -> String {
        guard let definition = definitions.first(where: { $0.id == definitionID }) else {
            preconditionFailure("Unknown model definition: \(definitionID)")
        }
        return URL(fileURLWithPath: modelsRoot)
            .appendingPathComponent(definition.subdirectory)
            .appendingPathComponent(file)
            .path
    }

    public static func directoryPath(definitionID: String, modelsRoot: String) -> String {
        guard let definition = definitions.first(where: { $0.id == definitionID }) else {
            preconditionFailure("Unknown model definition: \(definitionID)")
        }
        return URL(fileURLWithPath: modelsRoot).appendingPathComponent(definition.subdirectory).path
    }

    /// 供打包前校验和设置页健康检查共用；返回相对 `Models` 根目录的缺失文件。
    public static func missingRequiredFiles(modelsRoot: String) -> [String] {
        definitions.flatMap { definition in
            definition.requiredFileGroups.compactMap { group in
                let hasFile = group.contains { file in
                    let path = filePath(definitionID: definition.id, file: file, modelsRoot: modelsRoot)
                    return FileManager.default.fileExists(atPath: path)
                }
                guard !hasFile else { return nil }
                let requirement = group.count == 1
                    ? group[0]
                    : "(\(group.joined(separator: " | ")))"
                return "\(definition.subdirectory)/\(requirement)"
            }
        }
    }
}
