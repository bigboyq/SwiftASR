import AppKit

/// F-NEW-2 (round-3): 抽 `AlertPresenting` 协议，AlertHelper 改成
/// facade + `presenter` 单点依赖。`NSAlertAlertPresenter` 是默认实现
/// (保留原 NSAlert.runModal 行为)，`MockAlertPresenter` 是单测实现
/// (记录最后调用的 title/message/confirm 状态，避免 `runModal` 阻塞
/// 主线程让测试 hang — F4.7 8 个测试就是因为这个绕路不测 alert 路径)。
///
/// 调用方：保持 `AlertHelper.showInfo(...)` / `AlertHelper.confirm(...)` 不变。
/// 切换实现：`AlertHelper.presenter = MockAlertPresenter()` 在测试 setup 里。

@MainActor
public protocol AlertPresenting {
    func showInfo(
        title: String,
        message: String?,
        buttonTitle: String,
        style: NSAlert.Style
    )
    func confirm(
        title: String,
        message: String?,
        confirmTitle: String,
        cancelTitle: String,
        style: NSAlert.Style
    ) -> Bool
}

/// 默认实现：原 `NSAlert.runModal()` 行为。
@MainActor
public struct NSAlertAlertPresenter: AlertPresenting {
    public init() {}

    public func showInfo(
        title: String,
        message: String?,
        buttonTitle: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.alertStyle = style
        alert.addButton(withTitle: buttonTitle)
        alert.runModal()
    }

    public func confirm(
        title: String,
        message: String?,
        confirmTitle: String,
        cancelTitle: String,
        style: NSAlert.Style
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.alertStyle = style
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// 测试 mock：记录所有调用而非真正弹 NSAlert。`runModal()` 会阻塞
/// 主线程等用户点按钮，单测无 UI 循环会 hang — 用这个 mock 替换
/// `AlertHelper.presenter` 即可正常跑 alert 路径的 coordinator 单测。
///
/// 用法（@MainActor 测试）：
/// ```swift
/// let mock = MockAlertPresenter()
/// AlertHelper.presenter = mock
/// defer { AlertHelper.presenter = NSAlertAlertPresenter() }
///
/// // ...触发 alert 路径...
///
/// #expect(mock.showInfoCalls.count == 1)
/// #expect(mock.showInfoCalls.first?.title == "...")
/// ```
@MainActor
public final class MockAlertPresenter: AlertPresenting {
    public struct ShowInfoCall: Equatable, Sendable {
        public let title: String
        public let message: String?
        public let buttonTitle: String
        public let style: NSAlert.Style
    }
    public struct ConfirmCall: Equatable, Sendable {
        public let title: String
        public let message: String?
        public let confirmTitle: String
        public let cancelTitle: String
        public let style: NSAlert.Style
    }

    public private(set) var showInfoCalls: [ShowInfoCall] = []
    public private(set) var confirmCalls: [ConfirmCall] = []
    /// 队列式 `confirm` 结果，若非空按顺序弹出；若为空返回 `nextConfirmResult`。
    public var confirmResultsQueue: [Bool] = []
    /// `confirm` 默认返回 `false`（即"用户点了取消"），跟 `NSAlert.runModal()`
    /// 在 `applicationShouldTerminateAfterLastWindowClosed` 强制返回 `.alertSecondButtonReturn`
    /// 时的行为一致。测试可单独覆盖 `nextConfirmResult`。
    public var nextConfirmResult: Bool = false

    public init() {}

    public func showInfo(
        title: String,
        message: String?,
        buttonTitle: String,
        style: NSAlert.Style
    ) {
        showInfoCalls.append(ShowInfoCall(
            title: title, message: message,
            buttonTitle: buttonTitle, style: style
        ))
    }

    public func confirm(
        title: String,
        message: String?,
        confirmTitle: String,
        cancelTitle: String,
        style: NSAlert.Style
    ) -> Bool {
        confirmCalls.append(ConfirmCall(
            title: title, message: message,
            confirmTitle: confirmTitle, cancelTitle: cancelTitle, style: style
        ))
        if !confirmResultsQueue.isEmpty {
            return confirmResultsQueue.removeFirst()
        }
        return nextConfirmResult
    }

    public func reset() {
        showInfoCalls.removeAll()
        confirmCalls.removeAll()
        confirmResultsQueue.removeAll()
        nextConfirmResult = false
    }
}

/// Shared AppKit alert helpers. The codebase used to inline ~22 NSAlert
/// creations across Services / SwiftASRApp / Views; consolidating them
/// here keeps the message / button strings / styles in one place and
/// makes future i18n / test-mock a single edit instead of a sweep.
///
/// Convention: every `confirm` here returns `true` when the user
/// clicks the **first** (left) button. The first button is the
/// destructive / confirm action, matching the pattern already used
/// in the existing 2-button alerts (`.alertFirstButtonReturn`).
///
/// F-NEW-2: facade over `AlertPresenting`。Production = `NSAlertAlertPresenter()`。
/// Tests can swap `AlertHelper.presenter` for a mock that records calls
/// instead of running `NSAlert.runModal()`.
@MainActor
public enum AlertHelper {

    /// Indirection seam for tests. Production keeps the AppKit-backed
    /// presenter; tests can substitute `MockAlertPresenter` to record
    /// arguments without blocking on `runModal()`.
    public static var presenter: AlertPresenting = NSAlertAlertPresenter()

    /// Single-button information alert. Use for "X 失败" / "请先等当前任务完成"
    /// 之类只需要"知道了"按钮的提示。
    public static func showInfo(
        title: String,
        message: String? = nil,
        buttonTitle: String = "知道了",
        style: NSAlert.Style = .informational
    ) {
        presenter.showInfo(
            title: title, message: message,
            buttonTitle: buttonTitle, style: style
        )
    }

    /// Two-button confirmation. First button = confirm (destructive) action,
    /// second = cancel. Returns `true` if the user picked the confirm button.
    public static func confirm(
        title: String,
        message: String? = nil,
        confirmTitle: String = "确定",
        cancelTitle: String = "取消",
        style: NSAlert.Style = .warning
    ) -> Bool {
        presenter.confirm(
            title: title, message: message,
            confirmTitle: confirmTitle, cancelTitle: cancelTitle, style: style
        )
    }
}
