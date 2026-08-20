import Foundation

/// DeepL 语言码 ↔ Apple Locale.Language 映射。
/// 校验规则对齐 DeepLX v1.2.1：36 个目标码 + EN/PT/ZH-HANS 别名，大小写不敏感。
enum LanguageCodes {

    /// DeepL 目标语言合法码（用于 400 错误信息，与 DeepLX 官方列表一致）。
    static let validTargetCodes: [String] = [
        "AR", "BG", "CS", "DA", "DE", "EL", "EN", "EN-GB", "EN-US", "ES", "ES-419",
        "ET", "FI", "FR", "HE", "HU", "ID", "IT", "JA", "KO", "LT", "LV", "NB", "NL",
        "PL", "PT", "PT-BR", "PT-PT", "RO", "RU", "SK", "SL", "SV", "TR", "UK", "VI",
        "ZH", "ZH-HANS", "ZH-HANT",
    ]

    /// DeepL 码 → Locale.Language 标识符。
    private static let toLocaleIdentifier: [String: String] = [
        "AR": "ar", "BG": "bg", "CS": "cs", "DA": "da", "DE": "de", "EL": "el",
        "EN": "en", "EN-GB": "en-GB", "EN-US": "en-US",
        "ES": "es", "ES-419": "es-419", "ET": "et", "FI": "fi", "FR": "fr",
        "HE": "he", "HU": "hu", "ID": "id", "IT": "it", "JA": "ja", "KO": "ko",
        "LT": "lt", "LV": "lv", "NB": "nb", "NL": "nl", "PL": "pl",
        "PT": "pt", "PT-BR": "pt-BR", "PT-PT": "pt-PT",
        "RO": "ro", "RU": "ru", "SK": "sk", "SL": "sl", "SV": "sv",
        "TR": "tr", "UK": "uk", "VI": "vi",
        "ZH": "zh-Hans", "ZH-HANS": "zh-Hans", "ZH-HANT": "zh-Hant",
    ]

    /// Locale 标识符 → DeepL 码（反向映射，用于回填 source_lang / detected_source_language）。
    private static let fromLocaleIdentifier: [String: String] = [
        "ar": "AR", "bg": "BG", "cs": "CS", "da": "DA", "de": "DE", "el": "EL",
        "en": "EN", "en-GB": "EN-GB", "en-US": "EN-US",
        "es": "ES", "es-419": "ES-419", "et": "ET", "fi": "FI", "fr": "FR",
        "he": "HE", "hu": "HU", "id": "ID", "it": "IT", "ja": "JA", "ko": "KO",
        "lt": "LT", "lv": "LV", "nb": "NB", "nl": "NL", "pl": "PL",
        "pt": "PT", "pt-BR": "PT-BR", "pt-PT": "PT-PT",
        "ro": "RO", "ru": "RU", "sk": "SK", "sl": "SL", "sv": "SV",
        "tr": "TR", "uk": "UK", "vi": "VI",
        "zh": "ZH", "zh-Hans": "ZH", "zh-CN": "ZH", "zh-Hant": "ZH-HANT", "zh-TW": "ZH-HANT",
    ]

    /// 将 DeepL 目标语言码解析为 Locale.Language；非法码返回 nil。
    static func localeLanguage(forTargetCode code: String) -> Locale.Language? {
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let identifier = toLocaleIdentifier[normalized] else { return nil }
        return Locale.Language(identifier: identifier)
    }

    /// 将 DeepL 源语言码解析为 Locale.Language；"auto" 或空返回 nil（交给检测器）。
    static func localeLanguage(forSourceCode code: String?) -> Locale.Language? {
        guard let code, !code.isEmpty else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        if normalized == "AUTO" { return nil }
        guard let identifier = toLocaleIdentifier[normalized] else { return nil }
        return Locale.Language(identifier: identifier)
    }

    /// 判断目标语言码是否在合法列表内。
    static func isValidTargetCode(_ code: String) -> Bool {
        toLocaleIdentifier[code.trimmingCharacters(in: .whitespaces).uppercased()] != nil
    }

    /// 判断源语言码是否合法（允许 auto / 空）。
    static func isValidSourceCode(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return true }
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        return normalized == "AUTO" || toLocaleIdentifier[normalized] != nil
    }

    /// Locale.Language → DeepL 码（无法识别时回退 EN）。
    static func deeplCode(for language: Locale.Language) -> String {
        var identifier = language.languageCode?.identifier ?? "en"
        if let region = language.region?.identifier {
            identifier += "-\(region)"
        } else if let script = language.script?.identifier {
            identifier += "-\(script)"
        }
        if let exact = fromLocaleIdentifier[identifier] { return exact }
        if let base = fromLocaleIdentifier[language.languageCode?.identifier ?? ""] { return base }
        return "EN"
    }

    /// 用于 400 错误信息的合法码清单。
    static var validCodesMessage: String {
        "unsupported language code; valid codes: \(validTargetCodes.joined(separator: ", "))"
    }

    /// 语言码的本地化显示名（如“中文”），供设置界面展示；无法本地化时回退码本身。
    static func displayName(for code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let identifier = toLocaleIdentifier[normalized],
              let name = Locale.current.localizedString(forIdentifier: identifier),
              !name.isEmpty else { return code }
        return name
    }

    /// 基础语言码：规范化后取 `-` 前缀（EN-US → EN、ZH-HANS → ZH），供启用匹配使用。
    static func baseCode(of code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        if let dashIndex = normalized.firstIndex(of: "-") {
            return String(normalized[normalized.startIndex..<dashIndex])
        }
        return normalized
    }
}
