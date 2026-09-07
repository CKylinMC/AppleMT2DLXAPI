import Foundation

/// 自动输出语言规则：请求 target_lang 显式为 auto/AUTO 时，
/// 按规则池自上而下匹配第一条命中的规则决定输出语言。
///
/// 条件模式（互斥）：
/// - any：无条件命中（兜底）
/// - languages：按“规则族键”匹配解析出的源语言；请求未提供 source_lang 时，
///   仅当 allowAutoDetect 为 true 且自动检测成功时按检测码参与匹配
/// - pattern：正则直接匹配请求 source_lang 的原始字符串（不做规范化解析），
///   source_lang 缺失/空时不参与匹配
struct AutoTargetRule: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, Sendable, CaseIterable {
        case any
        case languages
        case pattern
    }

    var id: UUID = UUID()
    var mode: Mode = .languages
    /// mode = languages 时：源语言码集合（DeepL 规范码）
    var languages: Set<String> = []
    /// mode = languages 时：请求未提供 source_lang，允许自动检测结果满足本规则
    var allowAutoDetect: Bool = true
    /// mode = pattern 时：匹配 source_lang 原始字符串的正则
    var pattern: String = ""
    /// 命中后的输出语言（DeepL 规范码）
    var targetCode: String = "ZH"

    /// 条件模式是否要求指定语言（languages 模式下显示自动检测开关）。
    var usesLanguages: Bool { mode == .languages }

    /// 规则自身校验问题（nil 表示合法）；供设置界面行级内联展示。
    func validationIssue(policy: LanguagePolicy) -> String? {
        switch mode {
        case .any:
            break
        case .languages:
            if languages.isEmpty {
                return "至少选择一种语言"
            }
            for code in languages {
                if !LanguageCodes.isValidTargetCode(code) {
                    return "条件语言“\(code.uppercased())”不合法"
                }
            }
        case .pattern:
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return "正则不能为空"
            }
            if (try? NSRegularExpression(pattern: trimmed)) == nil {
                return "正则表达式不合法"
            }
        }
        let target = targetCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard LanguageCodes.isValidTargetCode(target) else {
            return "输出语言“\(targetCode)”不合法"
        }
        guard policy.isEnabled(target) else {
            return "输出语言“\(target)”未在启用语言列表内"
        }
        return nil
    }

    /// 内置默认规则池：中文（简/繁）→ 英语、其余 → 中文。
    /// 空的自定义规则列表在运行时即使用本默认池。
    static func defaultRules() -> [AutoTargetRule] {
        var zhToEn = AutoTargetRule()
        zhToEn.languages = ["ZH", "ZH-HANT"]
        zhToEn.allowAutoDetect = true
        zhToEn.targetCode = "EN"

        var anyToZh = AutoTargetRule()
        anyToZh.mode = .any
        anyToZh.allowAutoDetect = true
        anyToZh.targetCode = "ZH"

        return [zhToEn, anyToZh]
    }
}
