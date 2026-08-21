import AppKit
import Observation
import SwiftUI

/// 设置窗口控制器：管理按需创建、复用的固定尺寸设置窗口。
///
/// - 窗口有标题，但不允许调整大小与全屏；
/// - 窗口显示时切换 `.regular` 激活策略（Dock 图标出现）；
/// - 窗口关闭时切回 `.accessory`（Dock 图标消失，应用继续以菜单栏驻留图标运行）。
@MainActor
@Observable
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// 窗口固定内容尺寸（侧栏 + 设置页）
    private static let contentSize = NSSize(width: 780, height: 540)

    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// 显示设置窗口（首次使用时创建，之后复用）。
    func show() {
        let window = makeWindowIfNeeded()
        // 先切换激活策略再显示窗口，避免 Dock 图标滞后于窗口出现的闪动
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 窗口关闭后 Dock 图标消失，应用继续以菜单栏驻留图标运行
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - 窗口创建

    private func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = AppInfo.displayName
        window.isReleasedWhenClosed = false
        window.delegate = self

        let hostingController = NSHostingController(
            rootView: SettingsWindowView()
                .environment(appState)
                .environment(self))
        // 禁用按 SwiftUI 固有尺寸调整，避免窗口收缩到内容理想大小
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        // 指派 contentViewController 后重新强制固定内容尺寸
        window.setContentSize(Self.contentSize)

        // 兜底禁用缩放与全屏能力（styleMask 已不含 .resizable）
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior.remove(.fullScreenPrimary)

        self.window = window
        return window
    }
}
