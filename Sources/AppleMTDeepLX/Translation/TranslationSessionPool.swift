import Foundation
import Translation
import os

/// TranslationSession 会话池：按语言对缓存复用（会话创建含模型装载，成本高）。
/// - LRU 上限 8 个语言对；空闲超过 10 分钟回收
/// - 创建前用 LanguageAvailability 校验：不支持 → 400 类错误；未安装 → 503 类错误
/// - macOS 26.4+ 优先使用 lowLatency 策略
/// - acquire/release 语义保证同一语言对会话任意时刻只有一个批次在使用；
///   等待方受 deadline 约束，超时以 .timeout 退出；resetAll() 以 .queueFlushed 全量终止
actor TranslationSessionPool {
    private struct Entry {
        /// 会话可能被失效清空（invalidate/reset），下次获取时重建
        var session: TranslationSession?
        var lastUsed: Date
        var inUse: Bool = false
        var waiters: [Waiter] = []
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
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
    /// 等待者 id → 所在语言对（供到期定时器定位）
    private var waiterKeys: [UUID: PairKey] = [:]
    private let availability = LanguageAvailability()

    /// 获取（或创建）指定语言对的会话；若该会话正被其他批次使用则等待。
    /// deadline 覆盖等待期：到期未轮到则抛 .timeout，等待者自队列移除。
    func acquire(
        source: Locale.Language, target: Locale.Language, deadline: Date?
    ) async throws -> TranslationSession {
        evictIdle()

        let key = PairKey(source: source, target: target)

        // 已有会话但正被占用 → 等待释放（受 deadline 约束）
        if let entry = cache[key], entry.inUse {
            if let deadline, deadline <= Date() {
                throw TranslationEngineError.timeout
            }
            let waiterID = UUID()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                cache[key]?.waiters.append(Waiter(id: waiterID, continuation: continuation))
                waiterKeys[waiterID] = key
                if let deadline {
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining > 0 {
                        Task {
                            try? await Task.sleep(for: .seconds(remaining))
                            await self.expireWaiter(waiterID)
                        }
                    }
                }
            }
            waiterKeys[waiterID] = nil
        }

        if var entry = cache[key] {
            if let session = entry.session {
                entry.inUse = true
                entry.lastUsed = Date()
                cache[key] = entry
                return session
            }
            // 会话已被失效清空：标记在用后走重建路径
            entry.inUse = true
            cache[key] = entry
        } else {
            cache[key] = Entry(session: nil, lastUsed: Date(), inUse: true)
        }
        return try await createSession(key: key, source: source, target: target)
    }

    /// 到期定时器触发：终止仍排在队中的等待者。
    private func expireWaiter(_ id: UUID) {
        guard let key = waiterKeys.removeValue(forKey: id),
              var entry = cache[key],
              let index = entry.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = entry.waiters.remove(at: index)
        cache[key] = entry
        waiter.continuation.resume(throwing: TranslationEngineError.timeout)
    }

    /// 归还会话；invalidate 为 true 时销毁会话（下次重建），用于 internalError 恢复与看门狗弃用。
    func release(source: Locale.Language, target: Locale.Language, invalidate: Bool = false) {
        let key = PairKey(source: source, target: target)
        guard var entry = cache[key] else { return }

        if invalidate {
            entry.session = nil
            logger.warning("销毁翻译会话 \(key.source, privacy: .public)→\(key.target, privacy: .public)")
        }
        entry.inUse = false
        entry.lastUsed = Date()
        cache[key] = entry

        // 唤醒等待该语言对的第一个批次（会话缺失时由其在获取路径中重建）
        if let waiter = entry.waiters.first {
            cache[key]?.waiters.removeFirst()
            waiter.continuation.resume()
        }
    }

    /// 服务重置：终止全部等待者并丢弃全部会话与占位。
    /// 在途批次持有的会话引用随批次回收，其后的 release 因条目缺失而无操作。
    func resetAll() {
        for key in cache.keys {
            for waiter in cache[key]?.waiters ?? [] {
                waiterKeys[waiter.id] = nil
                waiter.continuation.resume(throwing: TranslationEngineError.queueFlushed)
            }
        }
        cache.removeAll()
    }

    private func createSession(
        key: PairKey, source: Locale.Language, target: Locale.Language
    ) async throws -> TranslationSession {
        // 创建前校验语言对可用性
        let status = await availability.status(from: source, to: target)
        let pairDescription = "\(source.minimalIdentifier)→\(target.minimalIdentifier)"
        switch status {
        case .unsupported:
            failWaiters(key: key, error: TranslationEngineError.unsupportedPair(
                message: "unsupported language pair \"\(pairDescription)\""))
            throw TranslationEngineError.unsupportedPair(
                message: "unsupported language pair \"\(pairDescription)\"")
        case .supported:
            // 框架支持但语言包未下载安装
            failWaiters(key: key, error: TranslationEngineError.languagePackNotInstalled(pair: pairDescription))
            throw TranslationEngineError.languagePackNotInstalled(pair: pairDescription)
        case .installed:
            break
        default:
            failWaiters(key: key, error: TranslationEngineError.unsupportedPair(
                message: "unknown language availability for \"\(pairDescription)\""))
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

        if cache.count > Self.maxEntries {
            evictLeastRecentlyUsed()
        }
        // 保留既有的排队等待者（重建/失效恢复场景下会话被替换时不得丢失）
        let existingWaiters = cache[key]?.waiters ?? []
        cache[key] = Entry(session: session, lastUsed: Date(), inUse: true, waiters: existingWaiters)
        logger.info("创建翻译会话 \(pairDescription, privacy: .public)，当前池大小 \(self.cache.count)")
        return session
    }

    /// 以错误终止某个语言对的全部等待者并移除条目（会话创建失败时使用，避免等待者悬挂）。
    private func failWaiters(key: PairKey, error: Error) {
        guard let entry = cache[key] else { return }
        for waiter in entry.waiters {
            waiterKeys[waiter.id] = nil
            waiter.continuation.resume(throwing: error)
        }
        cache.removeValue(forKey: key)
    }

    private func evictIdle() {
        let now = Date()
        var removed = 0
        for key in cache.keys {
            guard let entry = cache[key] else { continue }
            // 会话已失效（nil）且无等待者 → 立即回收占位
            let vacant = entry.session == nil && entry.waiters.isEmpty && !entry.inUse
            let expired = entry.session != nil && !entry.inUse
                && now.timeIntervalSince(entry.lastUsed) > Self.idleTimeout
            if vacant || expired {
                cache.removeValue(forKey: key)
                removed += 1
            }
        }
        if removed > 0 {
            logger.debug("回收空闲会话 \(removed) 个")
        }
    }

    private func evictLeastRecentlyUsed() {
        guard let oldest = cache
            .filter({ !$0.value.inUse && ($0.value.session != nil) })
            .min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
        cache.removeValue(forKey: oldest.key)
    }
}
