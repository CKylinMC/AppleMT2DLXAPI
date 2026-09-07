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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return .jsonEncoded(RootInfoResponse(
            name: "AppleMTDeepLX",
            version: version,
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
        let source: SourceDescriptor
        switch resolveSourceLocale(sourceLang: sourceLang, texts: texts, policy: policy) {
        case .success(let descriptor):
            source = descriptor
        case .failure(let message):
            return errorResponse(400, message)
        }

        // 目标语言解析：target_lang=auto/AUTO 走规则池；缺失/空沿用默认输出回退；
        // 其余按强制默认 → 显式指定 → 与源相同回退默认的既有语义
        let targetLocale: Locale.Language
        let targetEcho: String
        switch resolveTargetLocale(
            targetLang: targetLang, source: source, rawSource: sourceLang,
            policy: policy, rules: settings.autoTargetRules) {
        case .success(let resolvedLocale, let resolvedEcho):
            targetLocale = resolvedLocale
            targetEcho = resolvedEcho
        case .failure(let message):
            return errorResponse(400, message)
        }

        do {
            let results = try await scheduler.translate(
                texts: texts, source: source.locale, target: targetLocale)
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
        case success(SourceDescriptor)
        case failure(String)
    }

    /// 已解析的源语言及其来源信息（供 AUTO 规则引擎区分显式/强制/检测）。
    private struct SourceDescriptor: Sendable {
        let locale: Locale.Language
        /// 请求显式指定并合法的规范码（非 auto/空）
        let explicitCode: String?
        /// 服务器决定（强制默认输入 / 检测失败回退）的规范码
        let forcedCode: String?
        /// 自动检测出的规范码（检测成功且可用时）
        let detectedCode: String?

        /// 解析失败时的回退提示（如"检测失败回退"日志场景使用）。
        var resolutionLog: String {
            if let code = explicitCode { return "显式指定 \(code)" }
            if let code = forcedCode { return "服务器回退 \(code)" }
            if let code = detectedCode { return "自动检测 \(code)" }
            return "未知"
        }
    }

    /// 目标语言解析结果：成功时携带实际生效的语言与回填码。
    private enum TargetResolution {
        case success(locale: Locale.Language, echo: String)
        case failure(String)
    }

    /// 解析源语言：强制默认 → 显式指定（校验启用）→ 自动检测（不可用时回退默认输入）。
    /// 返回的 SourceDescriptor 携带来源信息，供 AUTO 规则引擎区分显式/强制/检测。
    private func resolveSourceLocale(
        sourceLang: String?, texts: [String], policy: LanguagePolicy
    ) -> SourceResolution {
        // 强制使用默认输入语言：跳过检测与请求码
        if policy.forceDefaultSource, let forced = policy.defaultSource, let code = policy.defaultSourceCode {
            logger.notice("强制使用默认输入语言 \(code, privacy: .public)")
            return .success(SourceDescriptor(
                locale: forced, explicitCode: nil, forcedCode: code, detectedCode: nil))
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
            guard let locale = LanguageCodes.localeLanguage(forSourceCode: sourceLang) else {
                return .failure("unsupported source_lang \"\(sourceLang)\"; \(LanguageCodes.validCodesMessage)")
            }
            return .success(SourceDescriptor(
                locale: locale,
                explicitCode: sourceLang.trimmingCharacters(in: .whitespaces).uppercased(),
                forcedCode: nil, detectedCode: nil))
        }

        // auto / 缺省：合并全文检测主导语言（同一请求内文本通常为同一语言）
        let detectedCode = SourceLanguageDetector.detect(texts.joined(separator: "\n"))
        if let detectedCode, policy.isEnabled(detectedCode),
           let locale = LanguageCodes.localeLanguage(forTargetCode: detectedCode) {
            return .success(SourceDescriptor(
                locale: locale, explicitCode: nil, forcedCode: nil, detectedCode: detectedCode))
        }
        // 检测失败或检测出的语言不可用 → 回退默认输入语言
        if let fallback = policy.defaultSource, let code = policy.defaultSourceCode {
            logger.notice("输入语言不可用（检测：\(detectedCode ?? "失败", privacy: .public)），回退默认输入语言 \(code, privacy: .public)")
            return .success(SourceDescriptor(
                locale: fallback, explicitCode: nil, forcedCode: code, detectedCode: nil))
        }
        // 未设置默认输入语言：保持存量行为（EN）
        return .success(SourceDescriptor(
            locale: Locale.Language(identifier: "en"),
            explicitCode: nil, forcedCode: "EN", detectedCode: nil))
    }

    /// 解析目标语言：强制默认 → auto 规则池 → 缺失回退默认 → 显式指定（校验启用、与源相同回退默认）。
    /// 仅当 target_lang 显式为 auto/AUTO 时进入规则池；缺失/空仍沿用默认输出语言回退。
    private func resolveTargetLocale(
        targetLang: String?, source: SourceDescriptor, rawSource: String?,
        policy: LanguagePolicy, rules: [AutoTargetRule]
    ) -> TargetResolution {
        // 强制使用默认输出语言
        if policy.forceDefaultTarget, let forced = policy.defaultTarget, let code = policy.defaultTargetCode {
            // 边界：强制后与源相同且请求显式指定了不同的合法目标时，优先尊重请求
            if forced.minimalIdentifier == source.locale.minimalIdentifier,
               let requested = targetLang,
               policy.isEnabled(requested),
               let requestedLocale = LanguageCodes.localeLanguage(forTargetCode: requested),
               requestedLocale.minimalIdentifier != source.locale.minimalIdentifier {
                logger.notice("强制默认输出与输入相同，改用请求指定的 \(requested.uppercased(), privacy: .public)")
                return .success(locale: requestedLocale, echo: requested.uppercased())
            }
            logger.notice("强制使用默认输出语言 \(code, privacy: .public)")
            return .success(locale: forced, echo: code)
        }

        // target_lang 显式为 auto/AUTO → 按规则池（自上而下首条命中）决定输出语言
        let normalizedTarget = targetLang?.trimmingCharacters(in: .whitespaces).uppercased()
        if normalizedTarget == "AUTO" {
            return resolveAutoTarget(source: source, rawSource: rawSource, policy: policy, rules: rules)
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
        if locale.minimalIdentifier == source.locale.minimalIdentifier,
           let fallback = policy.defaultTarget, let code = policy.defaultTargetCode,
           fallback.minimalIdentifier != source.locale.minimalIdentifier {
            logger.notice("输出与输入语言相同，改用默认输出语言 \(code, privacy: .public)")
            return .success(locale: fallback, echo: code)
        }
        if locale.minimalIdentifier == source.locale.minimalIdentifier {
            logger.debug("输出与输入语言相同且无可用默认输出，维持原语言对")
        }
        return .success(locale: locale, echo: targetLang.uppercased())
    }

    /// AUTO 规则池匹配：自上而下取第一条命中；规则池为空 = 使用内置默认规则。
    /// 命中规则输出与源语言同族时跳过继续向下；全部不命中 → 400。
    private func resolveAutoTarget(
        source: SourceDescriptor, rawSource: String?, policy: LanguagePolicy, rules: [AutoTargetRule]
    ) -> TargetResolution {
        let rulePool = rules.isEmpty ? AutoTargetRule.defaultRules() : rules
        for rule in rulePool {
            guard let targetLocale = LanguageCodes.localeLanguage(forTargetCode: rule.targetCode),
                  policy.isEnabled(rule.targetCode) else { continue }

            let matched: Bool
            switch rule.mode {
            case .any:
                matched = true
            case .languages:
                // 候选源：显式指定 / 服务器强制或回退；检测结果仅在规则允许自动判断时参与
                var candidates: [String] = []
                if let code = source.explicitCode { candidates.append(code) }
                if let code = source.forcedCode { candidates.append(code) }
                if rule.allowAutoDetect, let code = source.detectedCode { candidates.append(code) }
                matched = candidates.contains { candidate in
                    rule.languages.contains {
                        LanguageCodes.ruleFamilyKey(of: $0) == LanguageCodes.ruleFamilyKey(of: candidate)
                    }
                }
            case .pattern:
                // 直接匹配 source_lang 原始字符串（不做解析）；缺失/空不参与
                let pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
                guard let raw = rawSource,
                      !raw.isEmpty,
                      let regex = try? NSRegularExpression(pattern: pattern) else {
                    matched = false
                    break
                }
                matched = regex.firstMatch(
                    in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
            }
            guard matched else { continue }

            // 输出与输入属同一基础语族（如中→中简繁互转、英→英区域互转）时
            // Apple 引擎无翻译空间 → 跳过该规则继续向下，避免必然失败的空转
            let sourceDeepCode = LanguageCodes.deeplCode(for: source.locale)
            if LanguageCodes.baseCode(of: rule.targetCode) == LanguageCodes.baseCode(of: sourceDeepCode) {
                logger.debug("AUTO 规则命中但输出与输入同语族，跳过（规则 \(rule.targetCode, privacy: .public)）")
                continue
            }
            let echo = rule.targetCode.trimmingCharacters(in: .whitespaces).uppercased()
            logger.notice("target_lang=auto：源 \(source.resolutionLog, privacy: .public) → 输出 \(echo, privacy: .public)")
            return .success(locale: targetLocale, echo: echo)
        }
        return .failure(
            "no auto language rule matched source_lang (\(source.explicitCode ?? source.detectedCode ?? source.forcedCode ?? "?")); check auto language rules in settings")
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
