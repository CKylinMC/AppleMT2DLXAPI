import SwiftUI

/// 设置窗口：服务、网络、翻译、鉴权、通用五个分区 + 运行状态面板。
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showLoginApprovalAlert = false
    /// 系统语言包安装状态探测结果（仅 UI 提示）
    @State private var supportStatuses: [String: LanguageSupportStatus] = [:]

    private var settings: AppSettings {
        appState.store.settings
    }

    var body: some View {
        Form {
            serviceSection
            networkSection
            translationSection
            languageSection
            authSection
            generalSection

            Section("运行状态") {
                StatusPanelView(stats: appState.stats)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
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
            TextField("端口", value: binding(\.port), format: .number)
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
            Picker("默认输入语言", selection: binding(\.defaultSourceCode)) {
                Text("未设置").tag(String?.none)
                ForEach(LanguageCodes.validTargetCodes, id: \.self) { code in
                    Text("\(LanguageCodes.displayName(for: code))（\(code)）").tag(String?.some(code))
                }
            }
            Picker("默认输出语言", selection: binding(\.defaultTargetCode)) {
                Text("未设置").tag(String?.none)
                ForEach(LanguageCodes.validTargetCodes, id: \.self) { code in
                    Text("\(LanguageCodes.displayName(for: code))（\(code)）").tag(String?.some(code))
                }
            }
            Toggle("强制使用默认输入语言", isOn: binding(\.forceDefaultSource))
                .disabled(settings.defaultSourceCode == nil)
            Toggle("强制使用默认输出语言", isOn: binding(\.forceDefaultTarget))
                .disabled(settings.defaultTargetCode == nil)

            DisclosureGroup("启用语言（已勾选 \(enabledLanguageCount)/\(LanguageCodes.validTargetCodes.count)）") {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        ForEach(LanguageCodes.validTargetCodes, id: \.self) { code in
                            languageRow(code)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 240)
            }

            Text("未勾选任何语言 = 全部启用；默认语言需包含在启用列表内。未指定输出语言或输出与输入相同时使用默认输出语言；自动检测的输入语言不可用时使用默认输入语言。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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

    /// 安装状态徽标：“未安装”为启发式提示（按参考语言对探测）。
    @ViewBuilder
    private func supportBadge(for code: String) -> some View {
        switch supportStatuses[code] {
        case .notInstalled:
            Text("未安装")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .unsupported:
            Text("不受支持")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            Toggle("启用鉴权", isOn: binding(\.authEnabled))
            if settings.authEnabled {
                SecureField("API 密钥", text: binding(\.apiKey))
                Text("客户端可通过 Authorization: Bearer、DeepL-Auth-Key 头或 ?token= 参数携带密钥。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generalSection: some View {
        Section("通用") {
            Toggle("开机自启动", isOn: loginBinding)
            if !LoginItemManager.isAtStablePath {
                Text("提示：将应用移动到“应用程序”文件夹后，开机自启动更可靠。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 绑定

    /// 经校验写入的配置绑定。
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { appState.store.settings[keyPath: keyPath] },
            set: { newValue in
                do {
                    try appState.store.update { $0[keyPath: keyPath] = newValue }
                    appState.errorMessage = nil
                } catch {
                    appState.errorMessage = error.localizedDescription
                }
            })
    }

    /// 启用语言成员资格绑定：勾选/取消经校验通道写回（如取消勾选当前默认语言会被拒绝并回弹）。
    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { appState.store.settings.enabledLanguages.contains(code) },
            set: { enabled in
                do {
                    try appState.store.update {
                        if enabled {
                            $0.enabledLanguages.insert(code)
                        } else {
                            $0.enabledLanguages.remove(code)
                        }
                    }
                    appState.errorMessage = nil
                } catch {
                    appState.errorMessage = error.localizedDescription
                }
            })
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
