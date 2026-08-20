import Foundation
import os

/// DeepLX 协议适配层：解析校验 → 调度翻译 → 错误码映射 → 组装响应。
///
/// 错误语义对齐 DeepLX v1.2.1：
/// - 400：target_lang/source_lang 非法（响应附合法码列表）
/// - 401：鉴权失败
/// - 404：text 为空
/// - 429：队列满 / 请求超时（附 Retry-After）
/// - 503：语言包未安装 / 引擎内部错误
final class DeepLXHandler: Sendable {
    private let logger = Logger(subsystem: "in.ckyl.applemtdeeplx", category: "DeepLX")
    private let scheduler: TranslationScheduler

    init(scheduler: TranslationScheduler) {
        self.scheduler = scheduler
    }

    // MARK: - 端点入口

    func rootInfo() -> HTTPResponse {
        .jsonEncoded(RootInfoResponse(
            name: "AppleMTDeepLX",
            version: "1.0.0",
            message: "DeepLX-compatible translation API backed by Apple Translation",
            endpoints: ["POST /translate", "POST /v1/translate", "POST /v2/translate"]))
    }

    /// DeepLX free / v1 端点（单文本）。
    func handleFreeTranslate(
        _ request: HTTPRequest, authGuard: AuthGuard, method: String
    ) async -> HTTPResponse {
        if let denied = await authGuard.authorize(request) { return denied }

        guard let dto = try? JSONDecoder().decode(FreeTranslateRequest.self, from: request.body) else {
            return errorResponse(400, "invalid request body")
        }
        let text = dto.text ?? ""
        if text.isEmpty {
            return errorResponse(404, "Translation text is empty")
        }

        return await translateAndRespond(
            texts: [text], sourceLang: dto.source_lang, targetLang: dto.target_lang
        ) { results, targetEcho in
            let result = results[0]
            return FreeTranslateResponse(
                code: 200,
                data: result.text,
                id: Self.requestID(),
                method: method,
                source_lang: result.detectedSourceCode,
                target_lang: targetEcho)
        }
    }

    /// DeepL 官方 v2 端点（文本数组，JSON 或 form-urlencoded）。
    func handleV2Translate(
        _ request: HTTPRequest, authGuard: AuthGuard
    ) async -> HTTPResponse {
        if let denied = await authGuard.authorize(request) { return denied }

        guard let dto = decodeV2Body(request) else {
            return errorResponse(400, "invalid request body")
        }
        if dto.text.isEmpty {
            return errorResponse(404, "Translation text is empty")
        }
        if dto.text.contains(where: { $0.isEmpty }) {
            return errorResponse(400, "text entries must not be empty")
        }

        return await translateAndRespond(
            texts: dto.text, sourceLang: dto.source_lang, targetLang: dto.target_lang
        ) { results, _ in
            V2TranslateResponse(translations: results.map {
                V2TranslationItem(detected_source_language: $0.detectedSourceCode, text: $0.text)
            })
        }
    }

    // MARK: - 核心流程

    private func translateAndRespond<Payload: Encodable>(
        texts: [String],
        sourceLang: String?,
        targetLang: String?,
        buildPayload: ([TranslationResult], _ targetEcho: String) -> Payload
    ) async -> HTTPResponse {
        // 目标语言校验
        guard let targetLang, !targetLang.isEmpty else {
            return errorResponse(400, "target_lang is required")
        }
        let targetEcho = targetLang.uppercased()
        guard let targetLocale = LanguageCodes.localeLanguage(forTargetCode: targetLang) else {
            return errorResponse(400, "unsupported target_lang \"\(targetLang)\"; \(LanguageCodes.validCodesMessage)")
        }

        // 源语言校验与解析（auto / 缺省 → 检测）
        guard LanguageCodes.isValidSourceCode(sourceLang) else {
            return errorResponse(400, "unsupported source_lang \"\(sourceLang ?? "")\"; \(LanguageCodes.validCodesMessage)")
        }
        let sourceLocale: Locale.Language
        if let resolved = LanguageCodes.localeLanguage(forSourceCode: sourceLang) {
            sourceLocale = resolved
        } else {
            // 合并全文检测主导语言（同一请求内文本通常为同一语言）
            let detectedCode = SourceLanguageDetector.detect(texts.joined(separator: "\n"))
            sourceLocale = LanguageCodes.localeLanguage(forTargetCode: detectedCode)
                ?? Locale.Language(identifier: "en")
        }

        do {
            let results = try await scheduler.translate(
                texts: texts, source: sourceLocale, target: targetLocale)
            let payload = buildPayload(results, targetEcho)
            return .jsonEncoded(payload)
        } catch let engineError as TranslationEngineError {
            var extraHeaders: [String: String] = [:]
            if engineError.httpStatus == 429 {
                extraHeaders["Retry-After"] = "1"
            }
            logger.warning("翻译请求失败（\(engineError.httpStatus)）：\(engineError.userMessage, privacy: .public)")
            return .jsonEncoded(
                status: engineError.httpStatus,
                DeepLXErrorResponse(code: engineError.httpStatus, message: engineError.userMessage),
                extraHeaders: extraHeaders)
        } catch {
            logger.error("翻译请求异常：\(error.localizedDescription, privacy: .public)")
            return errorResponse(503, "translation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 辅助

    /// v2 支持 JSON 与 application/x-www-form-urlencoded 两种请求体。
    private func decodeV2Body(_ request: HTTPRequest) -> V2TranslateRequest? {
        if request.contentType.contains("x-www-form-urlencoded") {
            return parseForm(request.body)
        }
        if let json = try? JSONDecoder().decode(V2TranslateRequest.self, from: request.body) {
            return json
        }
        // 未声明类型时兜底尝试 form 解析
        return parseForm(request.body)
    }

    private func parseForm(_ body: Data) -> V2TranslateRequest? {
        guard let raw = String(data: body, encoding: .utf8), !raw.isEmpty else { return nil }
        var texts: [String] = []
        var sourceLang: String?
        var targetLang: String?

        for pair in raw.split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = Self.formDecode(keyValue[0])
            let value = Self.formDecode(keyValue.count > 1 ? keyValue[1] : "")
            switch key {
            case "text": texts.append(value)
            case "source_lang": sourceLang = value
            case "target_lang": targetLang = value
            default: break
            }
        }
        guard let targetLang, !texts.isEmpty else { return nil }
        return V2TranslateRequest(text: texts, source_lang: sourceLang, target_lang: targetLang)
    }

    /// form-urlencoded 解码：先还原 '+' 再百分号解码。
    private static func formDecode(_ substring: Substring) -> String {
        let plusRestored = substring.replacingOccurrences(of: "+", with: " ")
        return plusRestored.removingPercentEncoding ?? plusRestored
    }

    private func errorResponse(_ status: Int, _ message: String) -> HTTPResponse {
        var extraHeaders: [String: String] = [:]
        if status == 429 {
            extraHeaders["Retry-After"] = "1"
        }
        return .jsonEncoded(
            status: status,
            DeepLXErrorResponse(code: status, message: message),
            extraHeaders: extraHeaders)
    }

    /// DeepLX 风格请求 ID：毫秒时间戳。
    private static func requestID() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
