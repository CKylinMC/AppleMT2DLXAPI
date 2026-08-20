import Foundation

/// 翻译引擎统一错误类型，携带 DeepLX 语义的 HTTP 状态码。
enum TranslationEngineError: Error, Sendable {
    /// 语言对不受支持（语言码非法或框架不支持）→ 400
    case unsupportedPair(message: String)
    /// 语言包尚未下载安装 → 503
    case languagePackNotInstalled(pair: String)
    /// 请求超时 → 429
    case timeout
    /// 队列已满 → 429
    case queueFull
    /// 上游引擎内部错误 → 503
    case engineFailure(message: String)
}

extension TranslationEngineError {
    var httpStatus: Int {
        switch self {
        case .unsupportedPair: 400
        case .languagePackNotInstalled: 503
        case .timeout, .queueFull: 429
        case .engineFailure: 503
        }
    }

    var userMessage: String {
        switch self {
        case .unsupportedPair(let message): message
        case .languagePackNotInstalled(let pair):
            "language pack for \(pair) is not installed; download it in System Settings or translate once in a system app"
        case .timeout: "translation timed out"
        case .queueFull: "too many requests; translation queue is full"
        case .engineFailure(let message): "translation engine failure: \(message)"
        }
    }
}
