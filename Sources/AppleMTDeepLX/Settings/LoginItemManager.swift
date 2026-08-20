import AppKit
import Foundation
import ServiceManagement

/// 开机自启动管理：基于 SMAppService.mainApp。
/// 注意：应用需位于稳定路径（如 /Applications）才能可靠注册。
@MainActor
enum LoginItemManager {

    enum RegistrationState: Sendable {
        /// 已注册并启用
        case enabled
        /// 未注册
        case disabled
        /// 已注册但等待用户在系统设置中批准
        case requiresApproval
        /// 注册表项异常（如应用被移动过）
        case notFound
    }

    static var currentState: RegistrationState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .disabled
        }
    }

    /// 应用是否位于稳定路径；构建目录下注册不可靠，UI 应给出提示。
    static var isAtStablePath: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications")
    }

    /// 设置开关。开启后若系统要求批准，返回 .requiresApproval 由 UI 引导用户。
    static func setEnabled(_ enabled: Bool) throws -> RegistrationState {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .enabled { return .enabled }
            try service.register()
        } else {
            if service.status != .notFound {
                try service.unregister()
            }
            return .disabled
        }
        return currentState
    }

    /// 打开"系统设置 → 通用 → 登录项与扩展"，用于引导用户批准。
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
