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

/// 设置窗口主视图：左侧边栏分页，侧栏底部显示纯文本版本号。
struct SettingsWindowView: View {
    @State private var selection: SettingsPage? = .service

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selection) { page in
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

    /// 侧栏底部：纯文本版本号。
    private var sidebarFooter: some View {
        Text("版本 \(AppInfo.version)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}
