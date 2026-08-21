import AppKit
import SwiftUI

/// 菜单栏下拉菜单：启动/关闭（按状态切换文案）、复制地址、检查更新、设置、退出。
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsWindowController.self) private var windowController
    @Environment(UpdaterAccess.self) private var updaterAccess

    var body: some View {
        statusItem

        Button(appState.isServiceRunning ? "关闭服务" : "启动服务") {
            appState.toggleService()
        }

        Button("复制地址") {
            appState.copyServiceURL()
        }

        Divider()

        Button("检查更新…") {
            updaterAccess.checkForUpdates()
        }

        Button("设置…") {
            windowController.show()
        }

        Divider()

        Button("退出 AT2DLX") {
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder
    private var statusItem: some View {
        switch appState.serverState {
        case .running(let port):
            Button("运行中 · 端口 \(port)") {}.disabled(true)
        case .failed(let message):
            Button("服务异常 · \(message)") {}.disabled(true)
        case .stopped:
            Button("服务已停止") {}.disabled(true)
        }
    }
}
