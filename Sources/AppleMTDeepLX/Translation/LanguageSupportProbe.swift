import Foundation
import Translation

/// 语言系统支持状态（仅供设置界面提示）。
enum LanguageSupportStatus: Sendable {
    /// 参考语言对已安装
    case installed
    /// 框架支持但语言包未下载安装
    case notInstalled
    /// 框架不支持
    case unsupported
    /// 尚未探测 / 无法判定
    case unknown
}

/// 系统语言包安装状态探测：仅供设置界面展示，严禁在请求热路径使用
/// （运行时权威校验在 TranslationSessionPool.createSession）。
///
/// Apple 框架只提供按语言对的可用性查询，单语言状态用参考对启发式推导：
/// 对每个码查询 (pivot → code) 与 (code → pivot) 两对（pivot：EN 系语言用 zh-Hans，其余用 en），
/// 任一对 installed → installed；全部 unsupported → unsupported；其余 → notInstalled。
enum LanguageSupportProbe {
    static func scan(codes: [String]) async -> [String: LanguageSupportStatus] {
        let availability = LanguageAvailability()
        let english = Locale.Language(identifier: "en")
        let chinese = Locale.Language(identifier: "zh-Hans")

        var results: [String: LanguageSupportStatus] = [:]
        await withTaskGroup(of: (String, LanguageSupportStatus).self) { group in
            for code in codes {
                group.addTask {
                    guard let language = LanguageCodes.localeLanguage(forTargetCode: code) else {
                        return (code, .unknown)
                    }
                    // EN 系语言改用中文作参考对（语言对两端不能相同）
                    let pivot = LanguageCodes.baseCode(of: code) == "EN" ? chinese : english
                    let forward = await availability.status(from: pivot, to: language)
                    let backward = await availability.status(from: language, to: pivot)
                    let status: LanguageSupportStatus
                    if forward == .installed || backward == .installed {
                        status = .installed
                    } else if forward == .unsupported && backward == .unsupported {
                        status = .unsupported
                    } else {
                        status = .notInstalled
                    }
                    return (code, status)
                }
            }
            for await (code, status) in group {
                results[code] = status
            }
        }
        return results
    }
}
