import AppKit
import Foundation
import Observation

/// 应用编排层：组合各模块，负责"配置变更 → 服务热重启 / 调度器热更新"。
@MainActor
@Observable
final class AppState {
    let store: SettingsStore
    let stats: ServerStats
    let scheduler: TranslationScheduler
    let server: HTTPServer

    /// 当前服务状态（供 UI 展示）
    var serverState: ServerState = .stopped
    /// 实际监听端口（自动选端口时可能与配置不同）
    var activePort: UInt16 = AppSettings.defaultPort
    /// 全局错误提示（设置校验失败等）
    var errorMessage: String?

    /// 已应用到服务器的配置快照，用于避免回写端口引发的重启循环
    @ObservationIgnored
    private var appliedServerSnapshot: AppSettings?
    @ObservationIgnored
    private let pool: TranslationSessionPool

    init() {
        let store = SettingsStore()
        let stats = ServerStats()
        let pool = TranslationSessionPool()
        let scheduler = TranslationScheduler(pool: pool, stats: stats)
        let handler = DeepLXHandler(scheduler: scheduler, store: store)
        let authGuard = AuthGuard(store: store)
        let router = Router(handler: handler, authGuard: authGuard)
        let server = HTTPServer(router: router)

        self.store = store
        self.stats = stats
        self.pool = pool
        self.scheduler = scheduler
        self.server = server

        server.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.applyServerState(state)
            }
        }
        store.onChange = { [weak self] settings in
            self?.handleSettingsChanged(settings)
        }

        applySchedulerConfig(store.settings)
        if store.settings.serviceEnabled {
            startServer(with: store.settings)
        }
    }

    // MARK: - 对外操作

    var isServiceRunning: Bool {
        if case .running = serverState { return true }
        return false
    }

    /// 对外展示的翻译端点地址。
    var serviceURL: String {
        "http://127.0.0.1:\(activePort)/translate"
    }

    /// 菜单栏"启动/关闭"切换。
    func toggleService() {
        setServiceEnabled(!store.settings.serviceEnabled)
    }

    func setServiceEnabled(_ enabled: Bool) {
        do {
            try store.update { $0.serviceEnabled = enabled }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 复制访问 URL 到剪贴板。
    func copyServiceURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(serviceURL, forType: .string)
    }

    // MARK: - 内部编排

    private func handleSettingsChanged(_ settings: AppSettings) {
        applySchedulerConfig(settings)

        let serverChanged = appliedServerSnapshot.map { !$0.serverEquals(settings) } ?? true
        guard serverChanged else { return }

        if settings.serviceEnabled {
            startServer(with: settings)
        } else {
            stopServer()
        }
    }

    private func startServer(with settings: AppSettings) {
        appliedServerSnapshot = settings
        serverState = .stopped
        server.start(port: settings.port, allowLAN: settings.allowLAN, autoSelect: settings.autoSelectPort)
    }

    private func stopServer() {
        appliedServerSnapshot = nil
        server.stop()
    }

    private func applySchedulerConfig(_ settings: AppSettings) {
        Task { [scheduler] in
            await scheduler.updateConfig(
                maxConcurrency: settings.maxConcurrency,
                timeoutSeconds: settings.timeoutSeconds)
        }
    }

    private func applyServerState(_ state: ServerState) {
        serverState = state
        if case .running(let port) = state {
            activePort = port
            // 自动选端口后回写实际端口（先更新快照，避免触发重启）
            if var snapshot = appliedServerSnapshot, snapshot.port != port {
                snapshot.port = port
                appliedServerSnapshot = snapshot
                if store.settings.port != port {
                    store.forceUpdate { $0.port = port }
                }
            }
        }
    }
}
