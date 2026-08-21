import Observation
import Sparkle

/// 更新通道代理：按“接收测试版更新”偏好返回允许订阅的更新通道（默认仅稳定通道）。
/// 独立成类以便在 UpdaterAccess 的 super.init 前创建（Sparkle 弱引用代理，需外部持有）。
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: "receiveBetaUpdates") ? ["beta"] : []
    }
}

/// Sparkle 更新器包装：SPUStandardUpdaterController 是 ObjC 类，不符合 Observable，
/// 无法经 SwiftUI @Environment 注入，以本包装作为环境注入载体。
@MainActor
@Observable
final class UpdaterAccess: NSObject {
    /// 更新器控制器：创建即启动自动检查更新，并承载更新提示/安装界面
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Sparkle 弱引用代理，需持有以保活
    @ObservationIgnored private let channelDelegate: UpdateChannelDelegate

    var updater: SPUUpdater { controller.updater }

    override init() {
        let delegate = UpdateChannelDelegate()
        channelDelegate = delegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        super.init()
    }

    /// 发起检查更新（菜单栏/关于页入口）
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
