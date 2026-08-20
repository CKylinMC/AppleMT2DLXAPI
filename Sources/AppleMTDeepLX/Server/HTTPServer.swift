import Foundation
import Network
import os

/// HTTP 服务状态。
enum ServerState: Equatable, Sendable {
    case stopped
    case running(port: UInt16)
    case failed(message: String)
}

/// 基于 Network.framework NWListener 的轻量 HTTP 服务。
///
/// - allowLAN=false 时通过 `acceptLocalOnly` 原生限定仅回环连接
/// - `allowLocalEndpointReuse` + cancel 完成后重建，缓解重启时 Address already in use
/// - 端口被占用且开启自动选择时向上探测（最多 20 次）
/// - 连接总数上限 128，超限直接拒绝
final class HTTPServer: @unchecked Sendable {
    static let maxConnections = 128
    private static let maxProbeAttempts = 20

    private let logger = Logger(subsystem: "in.ckyl.applemtdeeplx", category: "HTTPServer")
    private let queue = DispatchQueue(label: "in.ckyl.applemtdeeplx.http.server")
    private let router: Router
    private var listener: NWListener?
    private var connections: [HTTPConnection] = []
    private var allowLAN = false
    private var autoSelect = false
    private var probeAttempts = 0

    /// 状态变更回调（在服务器队列上触发，接收方需自行切回主线程）。
    var onStateChange: (@Sendable (ServerState) -> Void)?

    init(router: Router) {
        self.router = router
    }

    /// 启动监听。会先停止既有监听（若存在）。
    func start(port: UInt16, allowLAN: Bool, autoSelect: Bool) {
        queue.async {
            self.stopLocked(notifyState: false)
            self.allowLAN = allowLAN
            self.autoSelect = autoSelect
            self.probeAttempts = 0
            self.bind(port: port)
        }
    }

    func stop() {
        queue.async {
            self.stopLocked(notifyState: true)
        }
    }

    // MARK: - 内部实现（仅 queue 上调用）

    private func bind(port: UInt16) {
        guard port > 0 else {
            notify(.failed(message: "端口无效"))
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if !allowLAN {
            parameters.acceptLocalOnly = true
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let newListener = try? NWListener(using: parameters, on: nwPort) else {
            notify(.failed(message: "无法创建监听（端口 \(port)）"))
            return
        }
        listener = newListener
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handleListenerState(state, requestedPort: port)
            }
        }
        newListener.newConnectionHandler = { [weak self] nwConnection in
            guard let self else { return }
            self.queue.async {
                self.accept(nwConnection)
            }
        }
        newListener.start(queue: queue)
        logger.info("尝试监听端口 \(port)，局域网访问 \(self.allowLAN ? "开" : "关")")
    }

    private func handleListenerState(_ state: NWListener.State, requestedPort: UInt16) {
        guard listener != nil else { return }
        switch state {
        case .ready:
            probeAttempts = 0
            let actual = listener?.port?.rawValue ?? requestedPort
            logger.notice("HTTP 服务已在端口 \(actual) 启动")
            notify(.running(port: actual))
        case .failed(let error):
            listener?.cancel()
            listener = nil
            if autoSelect, isAddressInUse(error), probeAttempts < Self.maxProbeAttempts {
                probeAttempts += 1
                let nextPort = UInt32(requestedPort) + UInt32(probeAttempts)
                if nextPort <= 65_535 {
                    logger.warning("端口 \(requestedPort) 被占用，尝试 \(nextPort)")
                    bind(port: UInt16(nextPort))
                    return
                }
            }
            notify(.failed(message: "监听失败：\(error.localizedDescription)"))
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard listener != nil else {
            nwConnection.cancel()
            return
        }
        if connections.count >= Self.maxConnections {
            logger.warning("连接数达到上限 \(Self.maxConnections)，拒绝新连接")
            nwConnection.cancel()
            return
        }
        let httpConnection = HTTPConnection(
            connection: nwConnection,
            router: router
        ) { [weak self] closedConnection in
            guard let self else { return }
            self.queue.async {
                self.connections.removeAll { $0 === closedConnection }
            }
        }
        connections.append(httpConnection)
        httpConnection.start()
    }

    private func stopLocked(notifyState: Bool) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.close()
        }
        connections.removeAll()
        if notifyState {
            logger.notice("HTTP 服务已停止")
            notify(.stopped)
        }
    }

    private func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return true
        }
        return false
    }

    private func notify(_ state: ServerState) {
        onStateChange?(state)
    }
}
