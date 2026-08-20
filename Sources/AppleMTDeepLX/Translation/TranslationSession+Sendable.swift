import Foundation
import Translation

/// TranslationSession 由 Translation framework 返回时未标注 Sendable，
/// 但本应用通过调度器保证同一会话任意时刻只有一个在途批次使用
/// （会话池按语言对串行发放，并发上限约束的是不同语言对的在途批次），
/// 因此可安全跨隔离域传递。
extension TranslationSession: @unchecked @retroactive Sendable {}

/// LanguageAvailability 为无状态查询对象，仅在会话池 actor 内使用，
/// 标注 Sendable 以允许跨隔离域调用其 async 查询方法。
extension LanguageAvailability: @unchecked @retroactive Sendable {}
