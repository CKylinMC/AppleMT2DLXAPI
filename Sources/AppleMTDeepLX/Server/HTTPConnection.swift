import Foundation
import Network
import os

/// 单条 HTTP 连接的处理循环：串行收发、keep-alive、双超时防 slowloris。
/// 所有可变状态仅在连接私有串行队列上访问。
final class HTTPConnection: @unchecked Sendable {
    /// 空闲连接超时（头部完成后）
    private static let idleTimeout: TimeInterval = 30
    /// 头部接收超时（防 slowloris 慢速攻击）
    private static let headerTimeout: TimeInterval = 5
    private static let maxReceiveChunk = 65_536

    private let logger = Logger(subsystem: "in.ckyl.applemtdeeplx", category: "HTTPConn")
    private let connection: NWConnection
    private let router: Router
    private let queue = DispatchQueue(label: "in.ckyl.applemtdeeplx.http.connection")
    private let parser = HTTPRequestParser()
    private let onClosed: @Sendable (HTTPConnection) -> Void
    private var watchdog: DispatchWorkItem?
    private var headerComplete = false
    private var closed = false

    init(
        connection: NWConnection,
        router: Router,
        onClosed: @escaping @Sendable (HTTPConnection) -> Void
    ) {
        self.connection = connection
        self.router = router
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection.start(queue: queue)
    }

    func close() {
        queue.async { self.teardown() }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            scheduleWatchdog(Self.headerTimeout)
            receive()
        case .failed, .cancelled:
            teardown()
        default:
            break
        }
    }

    private func scheduleWatchdog(_ interval: TimeInterval) {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.handleTimeout()
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    private func handleTimeout() {
        guard !closed else { return }
        let response = HTTPResponse.json(
            status: 408,
            Data("{\"code\":408,\"message\":\"request timeout\"}".utf8))
        write(response: response, keepAlive: false)
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReceiveChunk) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                switch self.parser.append(data) {
                case .request(let request, let keepAlive):
                    self.headerComplete = true
                    self.watchdog?.cancel()
                    self.handleRequest(request, keepAlive: keepAlive)
                    return
                case .needMore:
                    self.scheduleWatchdog(self.headerComplete ? Self.idleTimeout : Self.headerTimeout)
                case .failure(let response):
                    self.write(response: response, keepAlive: false)
                    return
                }
            }

            if error != nil || isComplete {
                self.teardown()
                return
            }
            self.receive()
        }
    }

    /// 响应写完后继续处理管道化请求或等待新数据。
    private func continueReading() {
        guard !closed else { return }
        switch parser.append(Data()) {
        case .request(let request, let keepAlive):
            handleRequest(request, keepAlive: keepAlive)
        case .failure(let response):
            write(response: response, keepAlive: false)
        case .needMore:
            receive()
        }
    }

    private func handleRequest(_ request: HTTPRequest, keepAlive: Bool) {
        Task { [router, weak self] in
            let response = await router.handle(request)
            guard let self else { return }
            self.queue.async {
                self.write(response: response, keepAlive: keepAlive)
            }
        }
    }

    private func write(response: HTTPResponse, keepAlive: Bool) {
        guard !closed else { return }
        let payload = response.serialized(keepAlive: keepAlive)
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil || !keepAlive {
                self.teardown()
            } else {
                self.scheduleWatchdog(Self.idleTimeout)
                self.continueReading()
            }
        })
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        watchdog?.cancel()
        watchdog = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed(self)
    }
}
