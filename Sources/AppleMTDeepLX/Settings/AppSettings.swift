import Foundation

/// 应用全局配置（持久化到 UserDefaults，JSON 编码）。
struct AppSettings: Codable, Equatable, Sendable {
    /// 默认端口（与 DeepLX 官方默认一致）
    static let defaultPort: UInt16 = 10825

    var serviceEnabled: Bool = false
    var port: UInt16 = AppSettings.defaultPort
    /// 端口被占用时自动向上探测空闲端口
    var autoSelectPort: Bool = true
    var launchAtLogin: Bool = false
    /// 同时在途的翻译任务（批次）数量，超出排队
    var maxConcurrency: Int = 10
    /// 单次翻译超时（秒）
    var timeoutSeconds: Double = 10
    var authEnabled: Bool = false
    var apiKey: String = ""
    /// true 监听 0.0.0.0（局域网可访问）；false 仅本机回环
    var allowLAN: Bool = false

    enum ValidationIssue: String, Sendable {
        case portOutOfRange = "端口必须在 1024–65535 范围内"
        case concurrencyOutOfRange = "并发数必须在 1–50 范围内"
        case timeoutOutOfRange = "超时必须在 1–60 秒范围内"
        case apiKeyEmpty = "已开启鉴权，API 密钥不能为空"
    }

    /// 校验配置合法性，返回首个问题；nil 表示合法。
    func validate() -> ValidationIssue? {
        if port < 1024 { return .portOutOfRange }
        if !(1...50).contains(maxConcurrency) { return .concurrencyOutOfRange }
        if !(1...60).contains(timeoutSeconds) { return .timeoutOutOfRange }
        if authEnabled && apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return .apiKeyEmpty }
        return nil
    }

    /// 对外展示的服务地址。
    var baseURL: String {
        "http://127.0.0.1:\(port)"
    }

    /// 影响 HTTP 监听、需要重启服务才能生效的字段。
    func serverEquals(_ other: AppSettings) -> Bool {
        serviceEnabled == other.serviceEnabled
            && port == other.port
            && autoSelectPort == other.autoSelectPort
            && allowLAN == other.allowLAN
    }
}
