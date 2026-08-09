import Foundation
import AppKit
import Testing
@testable import SwiftASR

/// M1 round-3 F-NEW-2: 验证 `AlertHelper` 通过 `AlertPresenting` 协议
/// 解耦，`MockAlertPresenter` 正确记录调用而不是阻塞 `NSAlert.runModal()`。
///
/// 关键收益：未来 coordinator 单测（F4.7 系列）如果需要走 alert 路径，
/// 可以 `AlertHelper.presenter = MockAlertPresenter()` 替换，**不再需要
/// monkey-patch 全局 NSApp**。F4_7 之前绕开 alert 路径正是因为
/// `runModal()` 阻塞单元测试。
@Suite("AlertPresenter")
@MainActor
struct AlertPresenterTests {

    // MARK: - MockAlertPresenter 自身行为

    @Test func mockAlertPresenter_recordsShowInfoCalls() {
        let mock = MockAlertPresenter()
        mock.showInfo(title: "保存失败", message: "磁盘空间不足", buttonTitle: "知道了", style: .warning)
        mock.showInfo(title: "网络中断", message: nil, buttonTitle: "OK", style: .informational)

        #expect(mock.showInfoCalls.count == 2)
        #expect(mock.showInfoCalls[0].title == "保存失败")
        #expect(mock.showInfoCalls[0].message == "磁盘空间不足")
        #expect(mock.showInfoCalls[0].buttonTitle == "知道了")
        #expect(mock.showInfoCalls[0].style == .warning)
        #expect(mock.showInfoCalls[1].title == "网络中断")
        #expect(mock.showInfoCalls[1].message == nil)
    }

    @Test func mockAlertPresenter_recordsConfirmCalls() {
        let mock = MockAlertPresenter()
        mock.nextConfirmResult = true
        let r1 = mock.confirm(
            title: "删除？", message: "不可恢复",
            confirmTitle: "删除", cancelTitle: "取消", style: .warning
        )
        #expect(r1 == true)
        #expect(mock.confirmCalls.count == 1)
        #expect(mock.confirmCalls[0].title == "删除？")
        #expect(mock.confirmCalls[0].confirmTitle == "删除")
        #expect(mock.confirmCalls[0].cancelTitle == "取消")
    }

    @Test func mockAlertPresenter_defaultConfirmReturnsFalse() {
        // 默认 nextConfirmResult = false（"用户点取消"）
        let mock = MockAlertPresenter()
        let r = mock.confirm(
            title: "X", message: nil,
            confirmTitle: "Yes", cancelTitle: "No", style: .informational
        )
        #expect(r == false)
    }

    @Test func mockAlertPresenter_resetClearsAllCalls() {
        let mock = MockAlertPresenter()
        mock.showInfo(title: "a", message: nil, buttonTitle: "x", style: .informational)
        mock.confirm(title: "b", message: nil, confirmTitle: "y", cancelTitle: "n", style: .warning)
        #expect(mock.showInfoCalls.count == 1)
        #expect(mock.confirmCalls.count == 1)
        mock.reset()
        #expect(mock.showInfoCalls.isEmpty)
        #expect(mock.confirmCalls.isEmpty)
        #expect(mock.nextConfirmResult == false)
    }

    // MARK: - AlertHelper facade 通过 presenter 转发

    @Test func alertHelper_showInfoDelegatesToPresenter() {
        let original = AlertHelper.presenter
        let mock = MockAlertPresenter()
        AlertHelper.presenter = mock
        defer { AlertHelper.presenter = original }

        AlertHelper.showInfo(title: "通过 facade 调 showInfo", message: "test msg", style: .critical)

        #expect(mock.showInfoCalls.count == 1)
        #expect(mock.showInfoCalls[0].title == "通过 facade 调 showInfo")
        #expect(mock.showInfoCalls[0].message == "test msg")
        #expect(mock.showInfoCalls[0].style == .critical)
        #expect(mock.showInfoCalls[0].buttonTitle == "知道了")  // default
    }

    @Test func alertHelper_confirmDelegatesToPresenter() {
        let original = AlertHelper.presenter
        let mock = MockAlertPresenter()
        mock.nextConfirmResult = true
        AlertHelper.presenter = mock
        defer { AlertHelper.presenter = original }

        let r = AlertHelper.confirm(
            title: "通过 facade 调 confirm",
            message: "msg",
            confirmTitle: "Yes",
            cancelTitle: "No"
        )

        #expect(r == true)
        #expect(mock.confirmCalls.count == 1)
        #expect(mock.confirmCalls[0].title == "通过 facade 调 confirm")
        #expect(mock.confirmCalls[0].confirmTitle == "Yes")
        #expect(mock.confirmCalls[0].cancelTitle == "No")
        #expect(mock.confirmCalls[0].style == .warning)  // default
    }

    // MARK: - Default presenter 是 NSAlertAlertPresenter

    @Test func alertHelper_defaultPresenterIsNSAlert() {
        // 不可直接 == 比较 type（NSAlertAlertPresenter 是 struct），
        // 验证类型是 NSAlertAlertPresenter 即可。
        let original = AlertHelper.presenter
        defer { AlertHelper.presenter = original }
        let isNSAlert = AlertHelper.presenter is NSAlertAlertPresenter
        #expect(isNSAlert, "production 默认 presenter 必须是 NSAlertAlertPresenter")
    }
}
