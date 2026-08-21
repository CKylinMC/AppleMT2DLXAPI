import SwiftUI

/// 设置窗口内容：按侧栏选中页面渲染服务、网络、翻译、语言、鉴权、通用分区或关于页。
struct SettingsView: View {
    let page: SettingsPage

    @Environment(AppState.self) private var appState
    @Environment(UpdaterAccess.self) private var updaterAccess
    @State private var showLoginApprovalAlert = false
    /// 系统语言包安装状态探测结果（仅 UI 提示）
    @State private var supportStatuses: [String: LanguageSupportStatus] = [:]
    /// 字段级校验错误（最近一次被拒绝的写入）
    @State private var fieldErrors: [AppSettings.SettingsField: AppSettings.ValidationIssue] = [:]

    private var settings: AppSettings {
        appState.store.settings
    }

    var body: some View {
        content
            .task { supportStatuses = await LanguageSupportProbe.scan(codes: LanguageCodes.validTargetCodes) }
            .alert("配置错误", isPresented: errorAlertBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(appState.errorMessage ?? "")
            }
            .alert("需要批准", isPresented: $showLoginApprovalAlert) {
                Button("打开系统设置") {
                    LoginItemManager.openSystemSettings()
                }
                Button("稍后", role: .cancel) {}
            } message: {
                Text("开机自启动已注册，请在“系统设置 → 通用 → 登录项与扩展”中批准本应用。")
            }
    }

    /// 当前页面内容。detail 区始终由本视图承载，切换页面时 @State（探测结果、弹窗）得以保留。
    @ViewBuilder
    private var content: some View {
        if page == .about {
            AboutView()
        } else {
            Form {
                switch page {
                case .service:
                    serviceSection
                    Section("运行状态") {
                        StatusPanelView(stats: appState.stats)
                    }
                case .network:
                    networkSection
                case .translation:
                    translationSection
                case .language:
                    languageSection
                case .auth:
                    authSection
                case .general:
                    generalSection
                case .about:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - 分区

    private var serviceSection: some View {
        Section("服务") {
            Toggle("启动服务", isOn: binding(\.serviceEnabled))
            LabeledContent("状态") {
                Text(statusDescription)
                    .foregroundStyle(statusColor)
            }
            LabeledContent("访问地址") {
                HStack {
                    Text(appState.serviceURL)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("复制") {
                        appState.copyServiceURL()
                    }
                }
            }
        }
    }

    private var networkSection: some View {
        Section("网络") {
            TextField("端口", value: binding(\.port), format: IntegerFormatStyle<UInt16>().grouping(.never))
            Toggle("自动选择端口（端口被占用时向上探测）", isOn: binding(\.autoSelectPort))
            Toggle("允许局域网访问（监听 0.0.0.0）", isOn: binding(\.allowLAN))
            if settings.allowLAN {
                Text("局域网内其他设备可访问本服务，建议同时开启鉴权。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var translationSection: some View {
        Section("翻译") {
            Stepper("并发任务数：\(settings.maxConcurrency)", value: binding(\.maxConcurrency), in: 1...50)
            Stepper(
                "翻译超时：\(Int(settings.timeoutSeconds)) 秒",
                value: binding(\.timeoutSeconds), in: 1...60, step: 1)
            Text("超出并发的请求将排队等待（队列上限 256），队列满或超时返回 429。首次使用某语言对时，系统可能提示下载语言包。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var languageSection: some View {
        Section("语言") {
            Picker("默认输入语言", selection: defaultLanguageBinding(\.defaultSourceCode)) {
                Text("未设置").tag(String?.none)
                ForEach(supportedLanguageCodes, id: \.self) { code in
                    Text("\(LanguageCodes.displayName(for: code))（\(code)）").tag(String?.some(code))
                }
            }
            fieldError(.defaultSourceLanguage)
            if defaultLanguageUnsupported(settings.defaultSourceCode) {
                unsupportedDefaultHint("输入")
            }
            Picker("默认输出语言", selection: defaultLanguageBinding(\.defaultTargetCode)) {
                Text("未设置").tag(String?.none)
                ForEach(supportedLanguageCodes, id: \.self) { code in
                    Text("\(LanguageCodes.displayName(for: code))（\(code)）").tag(String?.some(code))
                }
            }
            fieldError(.defaultTargetLanguage)
            if defaultLanguageUnsupported(settings.defaultTargetCode) {
                unsupportedDefaultHint("输出")
            }
            Toggle("强制使用默认输入语言", isOn: binding(\.forceDefaultSource))
                .disabled(settings.defaultSourceCode == nil)
            Toggle("强制使用默认输出语言", isOn: binding(\.forceDefaultTarget))
                .disabled(settings.defaultTargetCode == nil)

            DisclosureGroup("启用语言（已勾选 \(enabledLanguageCount)/\(supportedLanguageCodes.count)）") {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        ForEach(supportedLanguageCodes, id: \.self) { code in
                            languageRow(code)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 240)
            }
            fieldError(.defaultSourceLanguage, .defaultTargetLanguage)

            Text("未勾选任何语言 = 全部启用；设置默认语言会自动勾选到启用列表。未指定输出语言或输出与输入相同时使用默认输出语言；自动检测的输入语言不可用时使用默认输入语言。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 可展示的语言：过滤系统不支持的语言（探测未完成时全部放行，避免异步竞态）。
    private var supportedLanguageCodes: [String] {
        LanguageCodes.validTargetCodes.filter { supportStatuses[$0] != .unsupported }
    }

    /// 当前默认语言是否被探测为系统不支持（探测属 UI 启发式，不进 validationIssues）。
    private func defaultLanguageUnsupported(_ code: String?) -> Bool {
        guard let code else { return false }
        return supportStatuses[code] == .unsupported
    }

    /// 默认语言不受支持的提示。
    private func unsupportedDefaultHint(_ direction: String) -> some View {
        Text("该语言不受系统支持，请更换默认\(direction)语言")
            .font(.footnote)
            .foregroundStyle(.red)
    }

    /// 启用语言勾选行：本地化名 + 码 + 系统安装状态徽标。
    private func languageRow(_ code: String) -> some View {
        Toggle(isOn: languageBinding(code)) {
            HStack(spacing: 4) {
                Text("\(LanguageCodes.displayName(for: code))（\(code)）")
                    .lineLimit(1)
                supportBadge(for: code)
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
    }

    /// 安装状态徽标：“未安装”为启发式提示（按参考语言对探测）；
    /// 不受支持的语言已从列表过滤，不再展示。
    @ViewBuilder
    private func supportBadge(for code: String) -> some View {
        switch supportStatuses[code] {
        case .notInstalled:
            Text("未安装")
                .font(.caption2)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    /// 已勾选的语言数（空集语义为全部启用，此处仅展示勾选数）。
    private var enabledLanguageCount: Int {
        settings.enabledLanguages.count
    }

    private var authSection: some View {
        Section("鉴权") {
            Toggle("启用鉴权", isOn: authEnabledBinding)
            if settings.authEnabled {
                HStack {
                    TextField("API 密钥", text: binding(\.apiKey))
                        .textSelection(.enabled)
                    Button {
                        commit { $0.apiKey = AppSettings.generateAPIKey() }
                    } label: {
                        Image(systemName: "dice")
                    }
                    .help("随机生成新密钥")
                }
                fieldError(.apiKey)
                Text("客户端可通过 Authorization: Bearer、DeepL-Auth-Key 头或 ?token= 参数携带密钥。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Section("通用") {
            Toggle("开机自启动", isOn: loginBinding)
            if !LoginItemManager.isAtStablePath {
                Text("提示：将应用移动到“应用程序”文件夹后，开机自启动更可靠。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        Section("软件更新") {
            Toggle("自动检查更新", isOn: automaticChecksBinding)
            Toggle("接收测试版更新", isOn: betaChannelBinding)
        }
    }

    /// 自动检查更新绑定：直连 Sparkle 偏好（Sparkle 自带 UserDefaults 存储，不进 AppSettings）。
    /// 属性变更后 Sparkle 会自动重置检查周期，无需手动调用。
    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { updaterAccess.updater.automaticallyChecksForUpdates },
            set: { updaterAccess.updater.automaticallyChecksForUpdates = $0 })
    }

    /// 测试版通道绑定：写入 UserDefaults 后重启检查周期使通道即时生效（UpdaterAccess 代理读取同一 key）。
    private var betaChannelBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "receiveBetaUpdates") },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: "receiveBetaUpdates")
                updaterAccess.updater.resetUpdateCycle()
            })
    }

    // MARK: - 绑定

    /// 经校验写入的配置绑定；错误走字段级内联展示。
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { appState.store.settings[keyPath: keyPath] },
            set: { newValue in
                commit { $0[keyPath: keyPath] = newValue }
            })
    }

    /// 默认语言绑定：同一事务内写默认码并自动加入启用列表；选“未设置”仅清默认码，
    /// 不反向移除已勾选语言。
    private func defaultLanguageBinding(_ keyPath: WritableKeyPath<AppSettings, String?>) -> Binding<String?> {
        Binding(
            get: { appState.store.settings[keyPath: keyPath] },
            set: { newValue in
                // 二次防御：不允许把不受支持的语言设为默认
                if let code = newValue, supportStatuses[code] == .unsupported { return }
                commit {
                    $0[keyPath: keyPath] = newValue
                    if let code = newValue {
                        $0.enabledLanguages.insert(code)
                    }
                }
            })
    }

    /// 鉴权开关绑定：开启时若密钥为空则同事务自动生成随机密钥；关闭时保留已有密钥。
    private var authEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.store.settings.authEnabled },
            set: { enabled in
                commit {
                    $0.authEnabled = enabled
                    if enabled && $0.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                        $0.apiKey = AppSettings.generateAPIKey()
                    }
                }
            })
    }

    /// 启用语言成员资格绑定：勾选/取消经校验通道写回（如取消勾选当前默认语言会被拒绝并回弹）。
    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { appState.store.settings.enabledLanguages.contains(code) },
            set: { enabled in
                commit {
                    if enabled {
                        $0.enabledLanguages.insert(code)
                    } else {
                        $0.enabledLanguages.remove(code)
                    }
                }
            })
    }

    /// 统一写入入口：成功时清空字段错误；校验失败时记录字段错误供内联展示。
    private func commit(_ mutate: (inout AppSettings) -> Void) {
        do {
            try appState.store.update(mutate)
            fieldErrors = [:]
        } catch let error as SettingsError {
            if case .invalid(let issues) = error {
                fieldErrors = issues
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    /// 对应字段下方的内联错误：优先最近一次被拒绝的错误，
    /// 其次由当前配置派生（覆盖旧存档加载的既有非法状态）。
    @ViewBuilder
    private func fieldError(_ fields: AppSettings.SettingsField...) -> some View {
        let derived = settings.validationIssues()
        if let issue = fields.lazy.compactMap({ fieldErrors[$0] ?? derived[$0] }).first {
            Text(issue.rawValue)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    /// 开机自启动绑定：调用 SMAppService，并处理批准流程。
    private var loginBinding: Binding<Bool> {
        Binding(
            get: { appState.store.settings.launchAtLogin },
            set: { newValue in
                do {
                    let state = try LoginItemManager.setEnabled(newValue)
                    try? appState.store.update { $0.launchAtLogin = newValue }
                    if state == .requiresApproval {
                        showLoginApprovalAlert = true
                    }
                } catch {
                    appState.errorMessage = "设置开机自启动失败：\(error.localizedDescription)"
                }
            })
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } })
    }

    // MARK: - 状态展示

    private var statusDescription: String {
        switch appState.serverState {
        case .running(let port): "运行中（端口 \(port)）"
        case .failed(let message): "异常：\(message)"
        case .stopped: "已停止"
        }
    }

    private var statusColor: Color {
        switch appState.serverState {
        case .running: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
