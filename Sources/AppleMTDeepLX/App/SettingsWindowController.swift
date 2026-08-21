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
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = AppInfo.displayName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsWindowView()
                .environment(appState)
                .environment(self))
        // 兜底禁用缩放与全屏能力（styleMask 已不含 .resizable）
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior.remove(.fullScreenPrimary)

        self.window = window
        return window
    }
}
