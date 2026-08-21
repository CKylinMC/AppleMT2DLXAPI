import SwiftUI

@main
struct AppleMTDeepLXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.appState)
                .environment(appDelegate.windowController)
                .environment(appDelegate.updaterAccess)
        } label: {
            // 驻留图标：右下角小圆点指示服务状态（运行中绿色，已停止/异常红色）
            // 模板渲染（MenuBarGlyph，18pt，含 1x/2x 位图），随浅色/深色模式自动取色
            Image("MenuBarGlyph")
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(appDelegate.appState.isServiceRunning ? .green : .red)
                        .frame(width: 6, height: 6)
                }
        }
        .menuBarExtraStyle(.menu)
    }
}
