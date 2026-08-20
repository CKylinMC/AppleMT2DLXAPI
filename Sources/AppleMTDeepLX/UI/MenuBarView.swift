import AppKit
import SwiftUI

/// 菜单栏下拉菜单：启动/关闭（按状态切换文案）、复制地址、设置、关于、退出。
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @State private var showAbout = false

    var body: some View {
        statusItem

        Button(appState.isServiceRunning ? "关闭服务" : "启动服务") {
            appState.toggleService()
        }

        Button("复制地址") {
            appState.copyServiceURL()
        }

        Divider()

        Button("设置…") {
            openSettings()
        }

        Button("关于 AppleMTDeepLX") {
            showAbout = true
        }

        Divider()

        Button("退出 AppleMTDeepLX") {
            NSApp.terminate(nil)
        }

        .sheet(isPresented: $showAbout) {
            AboutView()
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
