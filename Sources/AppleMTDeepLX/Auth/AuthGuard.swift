import Foundation

/// 鉴权守卫：支持三种密钥携带方式
/// - URL 参数 `?token=<key>`
/// - `Authorization: Bearer <key>`（DeepLX 风格）
/// - `Authorization: DeepL-Auth-Key <key>`（DeepL 官方 v2 风格）
struct AuthGuard: Sendable {
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    /// 返回 nil 表示通过；否则为 401 响应。
    func authorize(_ request: HTTPRequest) async -> HTTPResponse? {
        let settings = await MainActor.run { store.settings }
        guard settings.authEnabled else { return nil }

        let key = settings.apiKey
        var authenticated = false
        if let token = request.queryToken, constantTimeEquals(token, key) {
            authenticated = true
        } else if let authorization = request.header("authorization") {
            let trimmed = authorization.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("bearer ") {
                let credential = String(trimmed.dropFirst("bearer ".count))
                authenticated = constantTimeEquals(credential, key)
            } else if trimmed.lowercased().hasPrefix("deepl-auth-key ") {
                let credential = String(trimmed.dropFirst("deepl-auth-key ".count))
                authenticated = constantTimeEquals(credential, key)
            }
        }

        if authenticated { return nil }
        return .jsonEncoded(
            status: 401,
            DeepLXErrorResponse(code: 401, message: "invalid or missing access token"))
    }

    /// 常量时间比较，避免时序侧信道泄露密钥长度/前缀。
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<lhsBytes.count {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
    }
}
