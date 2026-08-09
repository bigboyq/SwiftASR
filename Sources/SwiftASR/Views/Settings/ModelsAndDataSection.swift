import SwiftUI
import AppKit

// MARK: - 模型管理 + 数据位置 Section

/// 合并在一个文件：ModelRow + DataLocationRow + AboutSection。
/// 三者都从 `ModelsInspector` 读纯展示数据，没有共享 state，没必要拆 3 个文件。
public struct AboutSection: View {
    /// SettingsTab 已经维护的 `cleanup` binding 里读的 .model，避免 AboutSection
    /// 每次 body 重算都去同步 IO 读 settings.json。用户在 CleanupSection 改了
    /// model → @State cleanup 变化 → SettingsTab re-render → AboutSection 收到新值。
    let cleanupModel: String

    public init(cleanupModel: String) {
        self.cleanupModel = cleanupModel
    }

    public var body: some View {
        Section {
            LabeledContent("ASR", value: "SeACo-Paraformer large (zh-cn)")
            LabeledContent("VAD", value: "FSMN-VAD")
            LabeledContent("Speaker", value: "ERes2NetV2")
            LabeledContent("LLM 润色", value: cleanupModel)
        } header: {
            Label("关于", systemImage: "info.circle")
        } footer: {
            Text("SwiftASR 是 FunASR-Mac 的 Swift + ONNX Runtime + SwiftData 原生重构版本。")
                .font(.caption)
        }
    }
}

// MARK: - 模型管理 Section

public struct ModelsSection: View {
    let models: [ModelInfo]
    public init(models: [ModelInfo]) { self.models = models }

    public var body: some View {
        Section {
            ForEach(models) { m in
                ModelRow(model: m)
            }
        } header: {
            Label("模型管理", systemImage: "cube.transparent")
        } footer: {
            Text("路径在 \(ModelsInspector.modelsRoot)。每个模型由 1-4 个 ONNX/mvn/tokens.json/.mlmodelc 文件组成；VAD/ASR/Punc 默认 CPU，speaker 直接 Native CoreML（无 ONNX/CoreML EP failover，.mlmodelc 加载失败会直接报错）。未来可升级到动态下载。")
                .font(.caption)
        }
    }
}

/// 一行展示一个模型：状态图标 + 用途/名称 + backend + 文件列表 + 总大小 + Finder 入口
struct ModelRow: View {
    let model: ModelInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: model.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.isReady ? .green : .red)
                Text("\(model.role.rawValue) · \(model.name)")
                    .font(.body.weight(.medium))
                Spacer()
                Text(model.backend.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.directory)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示 \(model.directory)")
            }
            Text(model.directory)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            // 文件清单
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.files, id: \.name) { f in
                    HStack(spacing: 4) {
                        Image(systemName: f.exists ? "checkmark.circle" : "xmark.circle")
                            .font(.caption2)
                            .foregroundStyle(f.exists ? .green : .red)
                        Text(f.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(f.exists ? .primary : .secondary)
                        Spacer()
                        if f.exists {
                            Text(formatBytes(f.sizeBytes))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("缺失")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(.leading, 22)
            HStack {
                Text("总计 \(formatBytes(model.totalSizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.leading, 22)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 数据位置 Section

public struct DataLocationSection: View {
    let locations: [DataLocation]
    let onRefresh: () -> Void
    let onClearLogs: () -> Void

    public init(locations: [DataLocation], onRefresh: @escaping () -> Void, onClearLogs: @escaping () -> Void) {
        self.locations = locations
        self.onRefresh = onRefresh
        self.onClearLogs = onClearLogs
    }

    public var body: some View {
        Section {
            ForEach(locations) { loc in
                DataLocationRow(location: loc, onClearLogs: onClearLogs)
            }
        } header: {
            HStack {
                Label("数据位置", systemImage: "externaldrive")
                Spacer()
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新数据位置信息")
            }
        } footer: {
            Text("settings.json / stage result.json / SwiftData store / 日志。可在 Finder 中显示，日志可一键清理。")
                .font(.caption)
        }
    }
}

struct DataLocationRow: View {
    let location: DataLocation
    let onClearLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                Text(location.title)
                    .font(.body.weight(.medium))
                Spacer()
                if location.fileCount > 0 || location.sizeBytes > 0 {
                    Text(summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location.path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
                // 清理日志的 destructive 按钮降级为普通按钮 + 红色（跟说话人页"删除指纹"、设置页"删除 Key"一致）
                if location.id == .logs && location.fileCount > 0 {
                    Button {
                        let confirmed = AlertHelper.confirm(
                            title: "清理所有日志？",
                            message: "将永久删除所有 swiftasr-*.log 文件，下次写入会自动创建新文件。",
                            confirmTitle: "清理"
                        )
                        if confirmed {
                            onClearLogs()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("清理所有日志")
                }
            }
            Text(location.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(location.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch location.id {
        case .settingsJSON:   return "doc.text"
        case .stageResults:   return "tray.full"
        case .swiftDataStore: return "cylinder.split.1x2"
        case .logs:           return "doc.text.below.ecg"
        }
    }

    private var summary: String {
        var parts: [String] = []
        if location.sizeBytes > 0 {
            parts.append(formatBytes(location.sizeBytes))
        }
        if location.fileCount > 0 {
            parts.append("\(location.fileCount) 个文件")
        }
        return parts.isEmpty ? "空" : parts.joined(separator: " · ")
    }
}
