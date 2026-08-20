import Foundation
import NaturalLanguage
import os

/// 源语言自动检测：Translation 无头会话不支持 auto，
/// 用 NLLanguageRecognizer 检测后映射为 DeepL 码。
enum SourceLanguageDetector {
    private static let logger = Logger(subsystem: "in.ckyl.applemtdeeplx", category: "LanguageDetect")

    /// 检测文本的主导语言并映射为 DeepL 码。
    /// 检测失败或检测出的语言不在支持列表时返回 nil，
    /// 回退策略（默认输入语言 / EN）由调用方（语言策略层）决定。
    static func detect(_ text: String) -> String? {
        guard let nl = NLLanguageRecognizer.dominantLanguage(for: text) else {
            logger.warning("语言检测失败，交由语言策略回退")
            return nil
        }
        let code = LanguageCodes.deeplCode(for: Locale.Language(identifier: nl.rawValue))
        if code == "EN", nl != .english {
            // 检测出的语言不在 DeepL 支持列表中，交由语言策略回退
            logger.notice("检测语言 \(nl.rawValue, privacy: .public) 不在支持列表，交由语言策略回退")
            return nil
        }
        return code
    }
}
