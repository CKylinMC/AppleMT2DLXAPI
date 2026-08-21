import Foundation
import Observation

/// 配置存储：UserDefaults + JSON 持久化，变更时回调通知编排层（服务热重启等）。
@MainActor
@Observable
final class SettingsStore {
    private static let storageKey = "settings.v1"

    private(set) var settings: AppSettings

    /// 配置变更回调（新值），由 AppState 注册以编排服务重启。
    @ObservationIgnored
    var onChange: ((AppSettings) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    /// 以事务方式修改配置并持久化；校验失败时抛出字段级错误且不写入。
    func update(_ mutate: (inout AppSettings) -> Void) throws {
        var new = settings
        mutate(&new)
        let issues = new.validationIssues()
        if !issues.isEmpty {
            throw SettingsError.invalid(issues)
        }
        settings = new
        persist()
        onChange?(new)
    }

    /// 跳过校验的直接写入（用于内部回写，如自动选端口成功后记录实际端口）。
    func forceUpdate(_ mutate: (inout AppSettings) -> Void) {
        var new = settings
        mutate(&new)
        settings = new
        persist()
        onChange?(new)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

enum SettingsError: LocalizedError {
    case invalid([AppSettings.SettingsField: AppSettings.ValidationIssue])

    var errorDescription: String? {
        switch self {
        case .invalid(let issues): issues.values.first?.rawValue
        }
    }
}
