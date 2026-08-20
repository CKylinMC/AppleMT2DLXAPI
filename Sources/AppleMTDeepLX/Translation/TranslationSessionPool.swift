import Foundation
import Translation
import os

/// TranslationSession 会话池：按语言对缓存复用（会话创建含模型装载，成本高）。
/// - LRU 上限 8 个语言对；空闲超过 10 分钟回收
/// - 创建前用 LanguageAvailability 校验：不支持 → 400 类错误；未安装 → 503 类错误
/// - macOS 26.4+ 优先使用 lowLatency 策略
/// - acquire/release 语义保证同一语言对会话任意时刻只有一个批次在使用
actor TranslationSessionPool {
    private struct Entry {
        let session: TranslationSession
        var lastUsed: Date
        var inUse: Bool = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private struct PairKey: Hashable {
        let source: String
        let target: String

        init(source: Locale.Language, target: Locale.Language) {
            self.source = source.minimalIdentifier
            self.target = target.minimalIdentifier
        }
    }

    private static let maxEntries = 8
    private static let idleTimeout: TimeInterval = 600

    private let logger = Logger(subsystem: "in.ckyl.applemtdeeplx", category: "SessionPool")
    private var cache: [PairKey: Entry] = [:]
    private let availability = LanguageAvailability()

    /// 获取（或创建）指定语言对的会话；若该会话正被其他批次使用则等待。
    func acquire(source: Locale.Language, target: Locale.Language) async throws -> TranslationSession {
        evictIdle()

        let key = PairKey(source: source, target: target)

        // 若已有会话但正被占用，先等待释放
        if let entry = cache[key], entry.inUse {
            await withCheckedContinuation { continuation in
                cache[key]?.waiters.append(continuation)
            }
        }

        let session: TranslationSession
        if var entry = cache[key] {
            entry.inUse = true
            entry.lastUsed = Date()
            cache[key] = entry
            session = entry.session
        } else {
            session = try await createSession(key: key, source: source, target: target)
        }
        return session
    }

    /// 归还会话；invalidate 为 true 时销毁（下次重建），用于 internalError 恢复。
    func release(source: Locale.Language, target: Locale.Language, invalidate: Bool = false) {
        let key = PairKey(source: source, target: target)
        guard var entry = cache[key] else { return }

        if invalidate {
            cache.removeValue(forKey: key)
            logger.warning("销毁翻译会话 \(key.source, privacy: .public)→\(key.target, privacy: .public)")
        } else {
            entry.inUse = false
            entry.lastUsed = Date()
            cache[key] = entry
        }

        // 唤醒等待该语言对的下一个批次（重建后会话可用）
        if !entry.waiters.isEmpty {
            let waiter = entry.waiters.removeFirst()
            cache[key]?.waiters = entry.waiters
            waiter.resume()
        }
    }

    private func createSession(
        key: PairKey, source: Locale.Language, target: Locale.Language
    ) async throws -> TranslationSession {
        // 创建前校验语言对可用性
        let status = await availability.status(from: source, to: target)
        let pairDescription = "\(source.minimalIdentifier)→\(target.minimalIdentifier)"
        switch status {
        case .unsupported:
            throw TranslationEngineError.unsupportedPair(
                message: "unsupported language pair \"\(pairDescription)\"")
        case .supported:
            // 框架支持但语言包未下载安装
            throw TranslationEngineError.languagePackNotInstalled(pair: pairDescription)
        case .installed:
            break
        default:
            throw TranslationEngineError.unsupportedPair(
                message: "unknown language availability for \"\(pairDescription)\"")
        }

        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(
                installedSource: source, target: target,
                preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }

        if cache.count >= Self.maxEntries {
            evictLeastRecentlyUsed()
        }
        cache[key] = Entry(session: session, lastUsed: Date(), inUse: true)
        logger.info("创建翻译会话 \(pairDescription, privacy: .public)，当前池大小 \(self.cache.count)")
        return session
    }

    private func evictIdle() {
        let now = Date()
        let expired = cache.filter { !$0.value.inUse && now.timeIntervalSince($0.value.lastUsed) > Self.idleTimeout }
        for key in expired.keys {
            cache.removeValue(forKey: key)
        }
        if !expired.isEmpty {
            logger.debug("回收空闲会话 \(expired.count) 个")
        }
    }

    private func evictLeastRecentlyUsed() {
        guard let oldest = cache
            .filter({ !$0.value.inUse })
            .min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
        cache.removeValue(forKey: oldest.key)
    }
}
