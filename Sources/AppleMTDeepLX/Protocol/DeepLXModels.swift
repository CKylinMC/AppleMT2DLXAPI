import Foundation

// MARK: - 请求 DTO

/// DeepLX free/v1 端点请求体。
struct FreeTranslateRequest: Decodable {
    let text: String?
    let source_lang: String?
    let target_lang: String?
}

/// DeepL 官方 v2 端点请求体（text 为数组）。
struct V2TranslateRequest: Decodable {
    let text: [String]
    let source_lang: String?
    let target_lang: String?
}

// MARK: - 响应 DTO

/// DeepLX free/v1 响应。alternatives 自 v1.2.0 起恒为 null，显式编码保持兼容。
struct FreeTranslateResponse: Encodable {
    let code: Int
    let data: String
    let id: Int64
    let method: String
    let source_lang: String
    let target_lang: String

    private enum CodingKeys: String, CodingKey {
        case alternatives, code, data, id, method
        case source_lang, target_lang
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .alternatives)
        try container.encode(code, forKey: .code)
        try container.encode(data, forKey: .data)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encode(source_lang, forKey: .source_lang)
        try container.encode(target_lang, forKey: .target_lang)
    }
}

/// DeepL 官方 v2 单条译文。
struct V2TranslationItem: Encodable {
    let detected_source_language: String
    let text: String
}

/// DeepL 官方 v2 响应。
struct V2TranslateResponse: Encodable {
    let translations: [V2TranslationItem]
}

/// 统一错误响应（DeepLX 格式，同时满足 v2 的 message 字段要求）。
struct DeepLXErrorResponse: Encodable {
    let code: Int
    let message: String
}

/// 根路径健康信息。
struct RootInfoResponse: Encodable {
    let name: String
    let version: String
    let message: String
    let endpoints: [String]
}
