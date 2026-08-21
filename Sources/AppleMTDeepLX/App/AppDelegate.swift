import AppKit
import SwiftUI

/// 应用委托：持有编排层、设置窗口控制器与更新器包装；启动时无 Dock 图标，窗口开/关时切换激活策略。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    /// Sparkle 更新器包装：创建即启动自动检查更新
    let updaterAccess = UpdaterAccess()
    private(set) lazy var windowController = SettingsWindowController(
        appState: appState, updaterAccess: updaterAccess)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement 已在 Info.plist 中声明，此处兜底保证启动时无 Dock 图标
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点击 Dock 图标且无可见窗口时，重新打开设置窗口
        if !flag {
            windowController.show()
        }
        return true
    }
}
