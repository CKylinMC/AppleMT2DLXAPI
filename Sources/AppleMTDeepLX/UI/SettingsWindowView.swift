import AppKit
import SwiftUI

/// 设置窗口页面。
enum SettingsPage: String, CaseIterable, Identifiable {
    case service, network, translation, language, auth, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .service: "服务"
        case .network: "网络"
        case .translation: "翻译"
        case .language: "语言"
        case .auth: "鉴权"
        case .general: "通用"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .service: "dot.radiowaves.left.and.right"
        case .network: "network"
        case .translation: "character.bubble"
        case .language: "globe"
        case .auth: "key"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// 设置窗口主视图：左侧边栏分页，侧栏底部为玻璃风格的关于/版本/退出区。
struct SettingsWindowView: View {
    @State private var selection: SettingsPage? = .service

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases.filter { $0 != .about }, selection: $selection) { page in
                Label(page.title, systemImage: page.systemImage)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(180)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            SettingsView(page: selection ?? .service)
        }
    }

    /// 侧栏底部：关于入口、版本号与一键退出（macOS 26 玻璃风格卡片）。
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            Button {
                selection = .about
            } label: {
                Label("关于", systemImage: SettingsPage.about.systemImage)
            }
            .buttonStyle(.bordered)

            Text("版本 \(AppInfo.version)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("退出 AT2DLX") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
    }
}
