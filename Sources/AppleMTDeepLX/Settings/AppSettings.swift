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

    /// 启用的语言码集合（大写规范码）；空集 = 全部启用
    var enabledLanguages: Set<String> = []
    /// 默认输入语言（DeepL 码）；nil = 未设置
    var defaultSourceCode: String? = nil
    /// 默认输出语言（DeepL 码）；nil = 未设置
    var defaultTargetCode: String? = nil
    /// 强制使用默认输入语言（忽略请求指定/自动检测结果）
    var forceDefaultSource: Bool = false
    /// 强制使用默认输出语言（忽略请求指定的输出语言）
    var forceDefaultTarget: Bool = false

    enum ValidationIssue: String, Sendable {
        case portOutOfRange = "端口必须在 1024–65535 范围内"
        case concurrencyOutOfRange = "并发数必须在 1–50 范围内"
        case timeoutOutOfRange = "超时必须在 1–60 秒范围内"
        case apiKeyEmpty = "已开启鉴权，API 密钥不能为空"
        case invalidDefaultLanguage = "默认语言码不合法"
        case defaultLanguageNotEnabled = "默认语言必须在启用语言列表内"
    }

    /// 校验配置合法性，返回首个问题；nil 表示合法。
    func validate() -> ValidationIssue? {
        if port < 1024 { return .portOutOfRange }
        if !(1...50).contains(maxConcurrency) { return .concurrencyOutOfRange }
        if !(1...60).contains(timeoutSeconds) { return .timeoutOutOfRange }
        if authEnabled && apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return .apiKeyEmpty }

        // 语言策略：默认语言码必须合法，且启用列表非空时须包含在列表内
        let policy = LanguagePolicy(settings: self)
        if defaultSourceCode != nil && policy.defaultSourceCode == nil { return .invalidDefaultLanguage }
        if defaultTargetCode != nil && policy.defaultTargetCode == nil { return .invalidDefaultLanguage }
        if let code = policy.defaultSourceCode, !policy.isEnabled(code) { return .defaultLanguageNotEnabled }
        if let code = policy.defaultTargetCode, !policy.isEnabled(code) { return .defaultLanguageNotEnabled }
        return nil
    }

    /// 对外展示的服务地址。
    var baseURL: String {
        "http://127.0.0.1:\(port)"
    }

    /// 影响 HTTP 监听、需要重启服务才能生效的字段。
    /// 语言策略字段不含在内：请求级生效，变更无需重启服务。
    func serverEquals(_ other: AppSettings) -> Bool {
        serviceEnabled == other.serviceEnabled
            && port == other.port
            && autoSelectPort == other.autoSelectPort
            && allowLAN == other.allowLAN
    }
}

extension AppSettings {
    /// 手写解码以保证向后兼容：旧版 JSON（无语言策略字段）缺失键时不抛错。
    /// 合成 Decodable 对带默认值的非可选字段仍用 decode，缺键会导致
    /// SettingsStore 整体回退默认值、静默重置全部配置。
    /// 放在 extension 中以保留成员初始化器。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceEnabled = try container.decode(Bool.self, forKey: .serviceEnabled)
        port = try container.decode(UInt16.self, forKey: .port)
        autoSelectPort = try container.decode(Bool.self, forKey: .autoSelectPort)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        maxConcurrency = try container.decode(Int.self, forKey: .maxConcurrency)
        timeoutSeconds = try container.decode(Double.self, forKey: .timeoutSeconds)
        authEnabled = try container.decode(Bool.self, forKey: .authEnabled)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        allowLAN = try container.decode(Bool.self, forKey: .allowLAN)
        enabledLanguages = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLanguages) ?? []
        defaultSourceCode = try container.decodeIfPresent(String.self, forKey: .defaultSourceCode)
        defaultTargetCode = try container.decodeIfPresent(String.self, forKey: .defaultTargetCode)
        forceDefaultSource = try container.decodeIfPresent(Bool.self, forKey: .forceDefaultSource) ?? false
        forceDefaultTarget = try container.decodeIfPresent(Bool.self, forKey: .forceDefaultTarget) ?? false
    }
}
