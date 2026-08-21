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

/// 关于页：内嵌于设置窗口侧栏分页，展示图标、名称、版本与版权。
struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(width: 96, height: 96)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))

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

            Text("© 2026 CKylinMC")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
