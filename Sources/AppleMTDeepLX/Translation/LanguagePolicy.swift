import Foundation

/// 语言策略：由设置派生的不可变快照，集中承载启用列表、默认语言与强制开关语义。
/// 纯值类型、无副作用；分支编排（HTTP 错误文案等）留在 DeepLXHandler。
struct LanguagePolicy: Sendable {
    /// 启用的语言码集合（规范化大写码）；空集 = 全部启用
    let enabledSet: Set<String>
    /// 默认输入语言码（规范化后）；非法/未设置为 nil
    let defaultSourceCode: String?
    /// 默认输出语言码（规范化后）；非法/未设置为 nil
    let defaultTargetCode: String?
    /// 默认输入语言（init 时一次性预解析）
    let defaultSource: Locale.Language?
    /// 默认输出语言（init 时一次性预解析）
    let defaultTarget: Locale.Language?
    let forceDefaultSource: Bool
    let forceDefaultTarget: Bool

    init(settings: AppSettings) {
        enabledSet = Set(settings.enabledLanguages
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty })
        defaultSourceCode = Self.normalizedCode(settings.defaultSourceCode)
        defaultTargetCode = Self.normalizedCode(settings.defaultTargetCode)
        defaultSource = defaultSourceCode.flatMap(LanguageCodes.localeLanguage(forTargetCode:))
        defaultTarget = defaultTargetCode.flatMap(LanguageCodes.localeLanguage(forTargetCode:))
        forceDefaultSource = settings.forceDefaultSource
        forceDefaultTarget = settings.forceDefaultTarget
    }

    /// 启用列表是否为空（= 全部启用）。
    var allEnabled: Bool { enabledSet.isEmpty }

    /// 判断语言码是否启用：空集 → true；精确匹配 → true；
    /// 否则按基础语言码匹配（启用 EN 覆盖 EN-US/EN-GB；启用 ZH-HANS 覆盖检测出的 ZH）。
    func isEnabled(_ code: String) -> Bool {
        if enabledSet.isEmpty { return true }
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalized.isEmpty else { return false }
        if enabledSet.contains(normalized) { return true }
        let base = LanguageCodes.baseCode(of: normalized)
        return enabledSet.contains { LanguageCodes.baseCode(of: $0) == base }
    }

    /// 规范化为合法 DeepL 码；非法或未设置返回 nil。
    private static func normalizedCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard LanguageCodes.isValidTargetCode(normalized) else { return nil }
        return normalized
    }
}
