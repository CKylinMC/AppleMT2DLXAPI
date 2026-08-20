import Foundation

/// 服务运行统计：在途/排队数量为瞬时仪表，其余为累计计数。
actor ServerStats {
    struct Snapshot: Sendable {
        var running = 0
        var queued = 0
        var completed = 0
        var rejected = 0
        var failed = 0
    }

    private var running = 0
    private var queued = 0
    private var completed = 0
    private var rejected = 0
    private var failed = 0

    func setGauges(running: Int, queued: Int) {
        self.running = running
        self.queued = queued
    }

    func recordCompleted(count: Int = 1) {
        completed += count
    }

    func recordRejected() {
        rejected += 1
    }

    func recordFailed() {
        failed += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(running: running, queued: queued, completed: completed, rejected: rejected, failed: failed)
    }
}
