import SwiftUI

/// 关于窗口。
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version)（\(build)）"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("AppleMTDeepLX")
                .font(.title2)
                .bold()

            Text("版本 \(appVersion)")
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

            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 340)
    }
}
