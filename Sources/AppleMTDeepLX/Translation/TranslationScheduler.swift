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
/// - 队列满（256）时先清扫全队已到期作业，仍满则立即拒绝 → 429
/// - 超时覆盖完整生命周期：排队等待超时在出队时判定；会话获取等待超时由
///   会话池 deadline 约束；执行超时由看门狗弃用批次（终止作业、丢弃会话、释放槽位），
///   单槽占用上界 = 超时秒数，队列积压不可能永久化
/// - 出队时把队头连续同语言对作业合并为一个批次（上限 16 条文本），
///   一次 translations(from:) 调用完成，摊薄框架开销
/// - 服务重启（resetAll）终止全部排队与在途作业并清空会话池；后续残余回调经
///   批次登记校验后全部无操作，杜绝双重 resume 与槽位错乱
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

    /// 在途批次登记：登记存在 = 作业未被处置；jobsResolved 防止跨上下文重复 resume。
    private struct BatchRecord: Sendable {
        let jobs: [QueuedJob]
        var jobsResolved = false
    }

    /// 单批次最多合并的文本条数
    private static let batchItemLimit = 16

    private let logger = Logger(subsystem: "in.ckyl.applemtdeeplx", category: "Scheduler")
    private let pool: TranslationSessionPool
    private let stats: ServerStats
    private var config = Config()
    private var running = 0
    private var queue: [QueuedJob] = []
    private var activeBatches: [UUID: BatchRecord] = [:]

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

    /// 清空排队中的作业（在途批次不受影响），已排队请求以 429 终止。
    func clearQueue() {
        let flushed = queue
        queue.removeAll()
        for job in flushed {
            job.continuation.resume(throwing: TranslationEngineError.queueFlushed)
        }
        if !flushed.isEmpty {
            logger.notice("清空队列 \(flushed.count) 个待处理作业")
        }
        updateGauges()
    }

    /// 服务重启重置：清空队列、终止全部在途批次、重置槽位与会话池。
    /// 统计（累计完成/拒绝/失败）由调用方（AppState）保留，不在此归零。
    func resetAll() {
        let flushed = queue
        queue.removeAll()
        for job in flushed {
            job.continuation.resume(throwing: TranslationEngineError.queueFlushed)
        }
        let abandonedJobs = activeBatches.values.flatMap(\.jobs)
        activeBatches.removeAll()
        for job in abandonedJobs {
            job.continuation.resume(throwing: TranslationEngineError.queueFlushed)
        }
        running = 0
        Task { await pool.resetAll() }
        if !flushed.isEmpty || !abandonedJobs.isEmpty {
            logger.notice("服务重置：终止排队 \(flushed.count) 个、在途 \(abandonedJobs.count) 个作业")
        }
        updateGauges()
    }

    // MARK: - 排队与调度

    private func enqueue(_ job: QueuedJob) {
        if queue.count >= config.maxQueueSize {
            // 队列已满时先清扫全队已到期作业腾出空间，再决定拒绝
            purgeExpired()
        }
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

    /// 丢弃全部已到期作业后，从队头取连续同语言对作业组成批次。
    private func takeBatch() -> [QueuedJob] {
        purgeExpired()
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

    /// 清扫整条队列中已到期的作业（不限于队头），逐个按超时终止。
    private func purgeExpired() {
        guard !queue.isEmpty else { return }
        let now = Date()
        queue.removeAll { job in
            guard job.deadline < now else { return false }
            job.continuation.resume(throwing: TranslationEngineError.timeout)
            Task { await stats.recordRejected() }
            return true
        }
    }

    // MARK: - 批次执行

    private func run(batch: [QueuedJob]) async {
        let id = UUID()
        let source = batch[0].source
        let target = batch[0].target
        let earliestDeadline = batch.map(\.deadline).min() ?? .distantFuture
        let flatItems = batch.flatMap(\.items)
        activeBatches[id] = BatchRecord(jobs: batch)

        var watchdog: Task<Void, Never>?
        do {
            // 会话获取（含等待）受 deadline 约束：超时由会话池抛 .timeout
            let session = try await pool.acquire(source: source, target: target, deadline: earliestDeadline)
            guard activeBatches[id] != nil else {
                // 等待期间批次已被处置（服务重置）：无后续义务
                return
            }
            // 看门狗：到达最早截止时间时若批次仍未完成，弃用批次（终止作业、
            // 丢弃可能已损坏的会话、释放槽位），即使框架调用不返回也能解堵队列
            watchdog = Task {
                let interval = earliestDeadline.timeIntervalSinceNow
                if interval > 0 {
                    try? await Task.sleep(for: .seconds(interval))
                }
                if !Task.isCancelled {
                    await self.expireBatch(id: id, source: source, target: target)
                }
            }

            var shouldInvalidate = false
            do {
                let responses = try await executeChunks(session: session, items: flatItems)
                watchdog?.cancel()
                // 执行跨过截止时间被看门狗处置 → 跳过回填（作业已按超时终止）
                guard markJobsResolved(id: id) else { return }
                distributeResults(batch: batch, responses: responses)
            } catch {
                watchdog?.cancel()
                // 已被看门狗处置 → 槽位与会话由其负责，直接退出
                guard markJobsResolved(id: id, throwing: Self.mapEngineError(error)) else { return }
                shouldInvalidate = TranslationError.internalError ~= error
                logger.error("翻译失败：\(error.localizedDescription, privacy: .public)")
                Task { await stats.recordFailed() }
            }
            await pool.release(source: source, target: target, invalidate: shouldInvalidate)
        } catch {
            // 会话获取失败（语言对不支持 / 语言包未安装 / 等待超时 / 服务重置）
            guard markJobsResolved(id: id, throwing: error) else { return }
            Task { await stats.recordFailed() }
        }
        finishSlot(id: id)
    }

    /// 看门狗到期处置：批次未完成时终止全部作业、弃用会话并释放槽位。
    private func expireBatch(id: UUID, source: Locale.Language, target: Locale.Language) async {
        guard activeBatches[id] != nil else { return }
        guard markJobsResolved(id: id, throwing: TranslationEngineError.timeout) else { return }
        logger.warning("批次超时弃用（在途 \(self.running) 槽位中，排队 \(self.queue.count)）")
        await pool.release(source: source, target: target, invalidate: true)
        finishSlot(id: id)
    }

    /// 标记批次作业已处置并终止全部作业；返回 false 表示已有处置方（防双重 resume）。
    private func markJobsResolved(id: UUID, throwing error: Error) -> Bool {
        guard var record = activeBatches[id], !record.jobsResolved else { return false }
        record.jobsResolved = true
        activeBatches[id] = record
        for job in record.jobs {
            job.continuation.resume(throwing: error)
        }
        return true
    }

    /// 标记批次成功回填（执行完成后回填前调用，防看门狗在收尾窗口重复处置）。
    private func markJobsResolved(id: UUID) -> Bool {
        guard var record = activeBatches[id], !record.jobsResolved else { return false }
        record.jobsResolved = true
        activeBatches[id] = record
        return true
    }

    private func finishSlot(id: UUID) {
        guard activeBatches.removeValue(forKey: id) != nil else { return }
        running = max(0, running - 1)
        pump()
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
