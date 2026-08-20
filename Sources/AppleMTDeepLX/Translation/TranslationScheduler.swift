import Foundation
import Translation
import os

/// 单条待翻译文本。
struct TranslationItem: Sendable {
    let text: String
}

/// 单条翻译结果。
struct TranslationResult: Sendable {
    let text: String
    /// 实际源语言（DeepL 码），优先取框架检测值。
    let detectedSourceCode: String
}

/// 翻译调度器：并发上限 + FIFO 排队 + 超时 + 机会式合批。
///
/// - 每个 API 请求作为一个作业入队；并发上限约束的是"在途批次"数量
/// - 队列满（256）立即拒绝 → 429
/// - 超时覆盖完整生命周期：排队等待超时在出队时判定；执行中超时由看门狗
///   调用 session.cancel() 打断在途翻译
/// - 出队时把队头连续同语言对作业合并为一个批次（上限 16 条文本），
///   一次 translations(from:) 调用完成，摊薄框架开销
actor TranslationScheduler {
    struct Config: Sendable, Equatable {
        var maxConcurrency: Int = 10
        var timeoutSeconds: Double = 10
        var maxQueueSize: Int = 256
    }

    private struct QueuedJob: Sendable {
        let source: Locale.Language
        let target: Locale.Language
        let items: [TranslationItem]
        let deadline: Date
        let continuation: CheckedContinuation<[TranslationResult], Error>
    }

    /// 单批次最多合并的文本条数
    private static let batchItemLimit = 16

    private let logger = Logger(subsystem: "in.ckyl.applemtdeeplx", category: "Scheduler")
    private let pool: TranslationSessionPool
    private let stats: ServerStats
    private var config = Config()
    private var running = 0
    private var queue: [QueuedJob] = []

    init(pool: TranslationSessionPool, stats: ServerStats) {
        self.pool = pool
        self.stats = stats
    }

    // MARK: - 配置与状态

    func updateConfig(maxConcurrency: Int, timeoutSeconds: Double) {
        config.maxConcurrency = max(1, maxConcurrency)
        config.timeoutSeconds = timeoutSeconds
        pump()
    }

    var runningCount: Int { running }
    var queuedCount: Int { queue.count }

    // MARK: - 对外入口

    /// 翻译一批文本（同一源/目标语言）。按配置排队、限并发、限时。
    func translate(
        texts: [String], source: Locale.Language, target: Locale.Language
    ) async throws -> [TranslationResult] {
        try await withCheckedThrowingContinuation { continuation in
            let job = QueuedJob(
                source: source, target: target,
                items: texts.map { TranslationItem(text: $0) },
                deadline: Date().addingTimeInterval(config.timeoutSeconds),
                continuation: continuation)
            Task { self.enqueue(job) }
        }
    }

    // MARK: - 排队与调度

    private func enqueue(_ job: QueuedJob) {
        if queue.count >= config.maxQueueSize {
            logger.warning("队列已满，拒绝请求（排队 \(self.queue.count)）")
            job.continuation.resume(throwing: TranslationEngineError.queueFull)
            Task { await stats.recordRejected() }
            return
        }
        queue.append(job)
        updateGauges()
        pump()
    }

    /// 有空闲槽位且队列非空时，组建批次并派发。
    private func pump() {
        while running < config.maxConcurrency && !queue.isEmpty {
            let batch = takeBatch()
            updateGauges()
            if batch.isEmpty { continue }
            running += 1
            Task { await self.run(batch: batch) }
        }
        updateGauges()
    }

    /// 丢弃已超时作业后，从队头取连续同语言对作业组成批次。
    private func takeBatch() -> [QueuedJob] {
        let now = Date()
        while let first = queue.first, first.deadline < now {
            queue.removeFirst()
            first.continuation.resume(throwing: TranslationEngineError.timeout)
            Task { await stats.recordRejected() }
        }
        guard let first = queue.first else { return [] }

        var batch: [QueuedJob] = []
        var itemCount = 0
        while !queue.isEmpty,
              queue[0].source == first.source,
              queue[0].target == first.target {
            // 批次文本数软上限：首作业始终纳入，其后按剩余容量取整作业
            if itemCount > 0, itemCount + queue[0].items.count > Self.batchItemLimit { break }
            let job = queue.removeFirst()
            itemCount += job.items.count
            batch.append(job)
        }
        return batch
    }

    // MARK: - 批次执行

    private func run(batch: [QueuedJob]) async {
        let source = batch[0].source
        let target = batch[0].target
        let earliestDeadline = batch.map(\.deadline).min() ?? .distantFuture
        let flatItems = batch.flatMap(\.items)

        do {
            let session = try await pool.acquire(source: source, target: target)
            var shouldInvalidate = false
            do {
                // 看门狗：到达最早截止时间时打断在途翻译
                let watchdog = Task {
                    let interval = earliestDeadline.timeIntervalSinceNow
                    if interval > 0 {
                        try? await Task.sleep(for: .seconds(interval))
                    }
                    if !Task.isCancelled {
                        session.cancel()
                    }
                }
                let responses = try await executeChunks(session: session, items: flatItems)
                watchdog.cancel()
                distributeResults(batch: batch, responses: responses)
            } catch {
                shouldInvalidate = TranslationError.internalError ~= error
                let mapped = Self.mapEngineError(error)
                logger.error("翻译失败：\(error.localizedDescription, privacy: .public)")
                for job in batch {
                    job.continuation.resume(throwing: mapped)
                }
                Task { await stats.recordFailed() }
            }
            await pool.release(source: source, target: target, invalidate: shouldInvalidate)
        } catch {
            // 会话获取失败（语言对不支持 / 语言包未安装）
            for job in batch {
                job.continuation.resume(throwing: error)
            }
            Task { await stats.recordFailed() }
        }

        finishSlot()
    }

    /// 分块调用 translations(from:)，保持结果顺序。
    private func executeChunks(
        session: TranslationSession, items: [TranslationItem]
    ) async throws -> [TranslationSession.Response] {
        var responses: [TranslationSession.Response] = []
        for start in stride(from: 0, to: items.count, by: Self.batchItemLimit) {
            let end = min(start + Self.batchItemLimit, items.count)
            let requests = items[start..<end].map {
                TranslationSession.Request(sourceText: $0.text)
            }
            let chunkResponses = try await session.translations(from: requests)
            responses.append(contentsOf: chunkResponses)
        }
        return responses
    }

    /// 将批次结果按作业切分回填；执行完成后才到期的作业按超时处理。
    private func distributeResults(batch: [QueuedJob], responses: [TranslationSession.Response]) {
        var index = 0
        let now = Date()
        var successCount = 0
        for job in batch {
            let count = job.items.count
            if job.deadline < now {
                job.continuation.resume(throwing: TranslationEngineError.timeout)
            } else {
                let slice = responses[index..<index + count].map { response in
                    TranslationResult(
                        text: response.targetText,
                        detectedSourceCode: LanguageCodes.deeplCode(for: response.sourceLanguage))
                }
                job.continuation.resume(returning: Array(slice))
                successCount += 1
            }
            index += count
        }
        if successCount > 0 {
            Task { await stats.recordCompleted(count: successCount) }
        }
    }

    private func finishSlot() {
        running -= 1
        pump()
    }

    private func updateGauges() {
        let currentRunning = running
        let currentQueued = queue.count
        Task { await stats.setGauges(running: currentRunning, queued: currentQueued) }
    }

    /// 将框架错误映射为带 HTTP 语义的引擎错误。
    private static func mapEngineError(_ error: any Error) -> TranslationEngineError {
        if let engineError = error as? TranslationEngineError {
            return engineError
        }
        if error is CancellationError || TranslationError.alreadyCancelled ~= error {
            return .timeout
        }
        if TranslationError.notInstalled ~= error {
            return .languagePackNotInstalled(pair: "")
        }
        if TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error
            || TranslationError.unsupportedLanguagePairing ~= error {
            return .unsupportedPair(message: error.localizedDescription)
        }
        return .engineFailure(message: error.localizedDescription)
    }
}
