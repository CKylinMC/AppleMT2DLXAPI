import AppKit
import SwiftUI

/// 应用委托：确保 accessory 激活策略（无 Dock 图标），持有编排层。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement 已在 Info.plist 中声明，此处兜底保证无 Dock 图标
        NSApp.setActivationPolicy(.accessory)
    }
}
