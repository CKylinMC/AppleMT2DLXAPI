import Foundation
import NaturalLanguage
import os

/// 源语言自动检测：Translation 无头会话不支持 auto，
/// 用 NLLanguageRecognizer 检测后映射为 DeepL 码。
enum SourceLanguageDetector {
    private static let logger = Logger(subsystem: "in.ckyl.applemtdeeplx", category: "LanguageDetect")

    /// 检测文本的主导语言并映射为 DeepL 码；检测失败或不支持时回退 "EN"。
    static func detect(_ text: String) -> String {
        guard let nl = NLLanguageRecognizer.dominantLanguage(for: text) else {
            logger.warning("语言检测失败，回退为 EN")
            return "EN"
        }
        let code = LanguageCodes.deeplCode(for: Locale.Language(identifier: nl.rawValue))
        if code == "EN", nl != .english {
            // 检测出的语言不在 DeepL 支持列表中，回退 EN
            logger.notice("检测语言 \(nl.rawValue, privacy: .public) 不在支持列表，回退 EN")
        }
        return code
    }
}
