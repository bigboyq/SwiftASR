import SwiftUI

// MARK: - Lifecycle helpers（拆出来避免 body 复杂度过高导致 type-check timeout）

struct LifecycleActions {
    let onAppear: () -> Void
    let onJobIdChange: () -> Void
    let onPayloadChange: () -> Void
    let onStatusChange: () -> Void
    let onStageChange: () -> Void
    let onPersonsChange: () -> Void
}

struct LifecycleModifiers: ViewModifier {
    let jobId: String
    let payloadJobId: String
    let currentJobStatus: String
    let currentJobStage: String
    let allPersonIds: [String]
    let onLifecycle: LifecycleActions

    func body(content: Content) -> some View {
        content
            .onAppear { onLifecycle.onAppear() }
            .onChange(of: jobId) { _, _ in onLifecycle.onJobIdChange() }
            .onChange(of: payloadJobId) { _, _ in onLifecycle.onPayloadChange() }
            .onChange(of: currentJobStatus) { _, _ in onLifecycle.onStatusChange() }
            .onChange(of: currentJobStage) { _, _ in onLifecycle.onStageChange() }
            .onChange(of: allPersonIds) { _, _ in onLifecycle.onPersonsChange() }
    }
}

// MARK: - 润色按钮样式切换

/// Toolbar 润色按钮：有没有润色记录决定样式。
/// `.bordered` (灰) / `.borderedProminent` (蓝) 是不同 type，不能 ternary 直接换。
/// 用 ViewModifier 走两个 if 分支，编译器在 ViewBuilder 上下文能选。
struct CleanupButtonStyle: ViewModifier {
    let hasCleanedResults: Bool
    func body(content: Content) -> some View {
        if hasCleanedResults {
            content.buttonStyle(.bordered)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
