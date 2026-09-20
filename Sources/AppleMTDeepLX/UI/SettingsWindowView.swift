import SwiftUI

/// 设置窗口页面。
enum SettingsPage: String, CaseIterable, Identifiable {
    case service, network, translation, language, autoLang, auth, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .service: "服务"
        case .network: "网络"
        case .translation: "翻译"
        case .language: "语言"
        case .autoLang: "自动语言"
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
        case .autoLang: "arrow.triangle.2.circlepath"
        case .auth: "key"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// 设置窗口主视图：左侧边栏分页，侧栏底部显示纯文本版本号。
struct SettingsWindowView: View {
    @State private var selection: SettingsPage? = .service
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SettingsPage.allCases, selection: $selection) { page in
                pageLabel(page)
                    .tag(page)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(180)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            SettingsView(page: selection ?? .service)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel(Text(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏"))
                .help(Text(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏"))
            }
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

    /// 侧栏分页项：全部使用 SF Symbol 图标（不使用应用图标资源）。
    @ViewBuilder
    private func pageLabel(_ page: SettingsPage) -> some View {
        Label(page.title, systemImage: page.systemImage)
    }
}
