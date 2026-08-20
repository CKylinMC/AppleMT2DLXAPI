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
    private let store: SettingsStore

    init(scheduler: TranslationScheduler, store: SettingsStore) {
        self.scheduler = scheduler
        self.store = store
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
        // 读取语言策略快照（请求级生效，无需重启服务）
        let settings = await MainActor.run { store.settings }
        let policy = LanguagePolicy(settings: settings)

        // 源语言解析（先源后标：目标语言的回退判断依赖已解析的源语言）
        let sourceLocale: Locale.Language
        switch resolveSourceLocale(sourceLang: sourceLang, texts: texts, policy: policy) {
        case .success(let locale):
            sourceLocale = locale
        case .failure(let message):
            return errorResponse(400, message)
        }

        // 目标语言解析（缺失/与源相同 → 回退默认输出）
        let targetLocale: Locale.Language
        let targetEcho: String
        switch resolveTargetLocale(targetLang: targetLang, sourceLocale: sourceLocale, policy: policy) {
        case .success(let resolved):
            targetLocale = resolved.locale
            targetEcho = resolved.echo
        case .failure(let message):
            return errorResponse(400, message)
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

    // MARK: - 语言策略解析

    /// 源语言解析结果：失败时携带 400 错误文案。
    private enum SourceResolution {
        case success(Locale.Language)
        case failure(String)
    }

    /// 目标语言解析结果：成功时携带实际生效的语言与回填码。
    private enum TargetResolution {
        case success(locale: Locale.Language, echo: String)
        case failure(String)
    }

    /// 解析源语言：强制默认 → 显式指定（校验启用）→ 自动检测（不可用时回退默认输入）。
    private func resolveSourceLocale(
        sourceLang: String?, texts: [String], policy: LanguagePolicy
    ) -> SourceResolution {
        // 强制使用默认输入语言：跳过检测与请求码
        if policy.forceDefaultSource, let forced = policy.defaultSource, let code = policy.defaultSourceCode {
            logger.notice("强制使用默认输入语言 \(code, privacy: .public)")
            return .success(forced)
        }

        // 显式指定（非空且非 auto）
        if let sourceLang, !sourceLang.isEmpty,
           sourceLang.trimmingCharacters(in: .whitespaces).uppercased() != "AUTO" {
            guard LanguageCodes.isValidSourceCode(sourceLang) else {
                return .failure("unsupported source_lang \"\(sourceLang)\"; \(LanguageCodes.validCodesMessage)")
            }
            guard policy.isEnabled(sourceLang) else {
                return .failure("source_lang \"\(sourceLang.uppercased())\" is disabled by server configuration")
            }
            return .success(LanguageCodes.localeLanguage(forSourceCode: sourceLang)!)
        }

        // auto / 缺省：合并全文检测主导语言（同一请求内文本通常为同一语言）
        let detectedCode = SourceLanguageDetector.detect(texts.joined(separator: "\n"))
        if let detectedCode, policy.isEnabled(detectedCode),
           let locale = LanguageCodes.localeLanguage(forTargetCode: detectedCode) {
            return .success(locale)
        }
        // 检测失败或检测出的语言不可用 → 回退默认输入语言
        if let fallback = policy.defaultSource, let code = policy.defaultSourceCode {
            logger.notice("输入语言不可用（检测：\(detectedCode ?? "失败", privacy: .public)），回退默认输入语言 \(code, privacy: .public)")
            return .success(fallback)
        }
        // 未设置默认输入语言：保持存量行为（EN）
        return .success(Locale.Language(identifier: "en"))
    }

    /// 解析目标语言：强制默认 → 缺失回退默认 → 显式指定（校验启用、与源相同回退默认）。
    private func resolveTargetLocale(
        targetLang: String?, sourceLocale: Locale.Language, policy: LanguagePolicy
    ) -> TargetResolution {
        // 强制使用默认输出语言
        if policy.forceDefaultTarget, let forced = policy.defaultTarget, let code = policy.defaultTargetCode {
            // 边界：强制后与源相同且请求显式指定了不同的合法目标时，优先尊重请求
            if forced.minimalIdentifier == sourceLocale.minimalIdentifier,
               let requested = targetLang,
               policy.isEnabled(requested),
               let requestedLocale = LanguageCodes.localeLanguage(forTargetCode: requested),
               requestedLocale.minimalIdentifier != sourceLocale.minimalIdentifier {
                logger.notice("强制默认输出与输入相同，改用请求指定的 \(requested.uppercased(), privacy: .public)")
                return .success(locale: requestedLocale, echo: requested.uppercased())
            }
            logger.notice("强制使用默认输出语言 \(code, privacy: .public)")
            return .success(locale: forced, echo: code)
        }

        // 缺失/空 → 回退默认输出语言
        guard let targetLang, !targetLang.isEmpty else {
            if let fallback = policy.defaultTarget, let code = policy.defaultTargetCode {
                logger.notice("未指定输出语言，使用默认输出语言 \(code, privacy: .public)")
                return .success(locale: fallback, echo: code)
            }
            return .failure("target_lang is required")
        }

        guard let locale = LanguageCodes.localeLanguage(forTargetCode: targetLang) else {
            return .failure("unsupported target_lang \"\(targetLang)\"; \(LanguageCodes.validCodesMessage)")
        }
        guard policy.isEnabled(targetLang) else {
            return .failure("target_lang \"\(targetLang.uppercased())\" is disabled by server configuration")
        }

        // 与源语言相同（minimalIdentifier 比较，与会话池 PairKey 同一规则）→ 回退默认输出
        if locale.minimalIdentifier == sourceLocale.minimalIdentifier,
           let fallback = policy.defaultTarget, let code = policy.defaultTargetCode,
           fallback.minimalIdentifier != sourceLocale.minimalIdentifier {
            logger.notice("输出与输入语言相同，改用默认输出语言 \(code, privacy: .public)")
            return .success(locale: fallback, echo: code)
        }
        if locale.minimalIdentifier == sourceLocale.minimalIdentifier {
            logger.debug("输出与输入语言相同且无可用默认输出，维持原语言对")
        }
        return .success(locale: locale, echo: targetLang.uppercased())
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
        // target_lang 允许缺失（由语言策略回退默认输出语言）
        guard !texts.isEmpty else { return nil }
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
