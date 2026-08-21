import AppKit
import SwiftUI

/// 应用标识与版本信息（显示名与窗口标题的单一事实来源）。
enum AppInfo {
    static let displayName = "AT2DLX 本地翻译服务"

    static var version: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version)（\(build)）"
    }
}

/// GitHub 仓库相关链接（主页、反馈）。
enum AppLinks {
    private static let repositoryBase = "https://github.com/CKylinMC/AppleMT2DLXAPI"

    static let repository = URL(string: repositoryBase)!
    static let issues = URL(string: "\(repositoryBase)/issues")!
}

/// 关于页：内嵌于设置窗口侧栏分页，展示图标、名称、版本、项目链接与版权。
struct AboutView: View {
    @Environment(UpdaterAccess.self) private var updaterAccess

    var body: some View {
        VStack(spacing: 12) {
            // 展示与应用图标（AppIcon）一致的真实图标；
            // 注意：AppIcon 不会以命名资源形式导出到 Assets.car，
            // 需通过 NSApplication.applicationIconImage 获取
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)

            Text(AppInfo.displayName)
                .font(.title2)
                .bold()

            Text("版本 \(AppInfo.version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("将 macOS 系统翻译以 DeepLX 兼容的本地 API 形式提供，\n供浏览器翻译插件等软件集成。")
                .font(.callout)
                .multilineTextAlignment(.center)

            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 10) {
                linkButton("访问项目主页", systemImage: "globe", url: AppLinks.repository)
                linkButton("意见反馈", systemImage: "bubble.left", url: AppLinks.issues)
                Button {
                    updaterAccess.checkForUpdates()
                } label: {
                    Label("检查最新版本", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.bordered)
            }

            Divider()
                .padding(.vertical, 4)

            Text("© 2026 CKylinMC")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 外链按钮：在默认浏览器中打开指定网址。
    private func linkButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
    }
}
