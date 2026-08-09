import SwiftUI
import SwiftData
import OnnxRuntimeBindings
import Darwin

extension Notification.Name {
    static let swiftASRShowFileImporter = Notification.Name("SwiftASR.showFileImporter")
    static let swiftASRNavigate = Notification.Name("SwiftASR.navigate")
    /// AudioPipeline 在长音频 + 低内存机器时发送。userInfo: duration (Double 秒),
    /// estimatedMB (Int), machineGB (Int)。监听端（结果页 banner）应主动建议
    /// 关闭其他大型应用，不应 throw 或 block pipeline。
    static let audioPipelineMemoryWarning = Notification.Name("SwiftASR.audioPipeline.memoryWarning")
}

@MainActor
struct ActiveTerminationRequest {
    let details: String
    let cancelTasks: () -> Void
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// MainSplitView 在出现后注入。AppDelegate 不直接依赖 SwiftData，避免退出
    /// 生命周期和 view / model container 的创建顺序互相耦合。
    var activeTerminationRequest: (() -> ActiveTerminationRequest?)?
    /// 由 MainSplitView 注入；退出时显式释放预热的 ONNX / CoreML session。
    var releasePrewarmedModels: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let request = activeTerminationRequest?() else {
            releasePrewarmedModels?()
            return .terminateNow
        }

        let shouldTerminate = AlertHelper.confirm(
            title: "仍有任务正在运行",
            message: "以下任务会被中断，且不能从中断处继续：\n\n\(request.details)\n\n确认要退出 SwiftASR 吗？",
            confirmTitle: "退出并取消任务",
            cancelTitle: "继续运行"
        )
        if shouldTerminate {
            request.cancelTasks()
            releasePrewarmedModels?()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 兜底：正常退出路径已经释放；这里重复调用是安全的。
        releasePrewarmedModels?()
    }
}

@main
struct SwiftASRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        Self.validateModelsForBuildIfRequested()
        Logger.shared.info("SwiftASR 启动")
    }

    /// `build_app.sh` 通过此入口复用 ModelCatalog 的文件契约，避免脚本另维护一份清单。
    private static func validateModelsForBuildIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.dropFirst().first == "--validate-models" else { return }

        let root = arguments.dropFirst(2).first ?? ModelCatalog.defaultModelsRoot
        let missing = ModelCatalog.missingRequiredFiles(modelsRoot: root)
        guard missing.isEmpty else {
            fputs("ERROR: Models 缺少必需文件：\(missing.joined(separator: ", "))\n", stderr)
            exit(2)
        }
        print("ModelCatalog validation passed: \(ModelCatalog.definitions.count) model definitions")
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
                .modelContainer(for: SwiftASRModelSchema.modelTypes)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加音频") {
                    NotificationCenter.default.post(name: .swiftASRShowFileImporter, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandMenu("导航") {
                navigationCommand("文件", section: .files, shortcut: "1")
                navigationCommand("转写", section: .transcription, shortcut: "2")
                navigationCommand("结果", section: .results, shortcut: "3")
                navigationCommand("说话人", section: .speakers, shortcut: "4")
                navigationCommand("设置", section: .settings, shortcut: "5")
            }
        }
    }

    private func navigationCommand(
        _ title: String,
        section: AppSection,
        shortcut: KeyEquivalent
    ) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .swiftASRNavigate, object: section.rawValue)
        }
        .keyboardShortcut(shortcut, modifiers: [.command])
    }
}
