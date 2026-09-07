import SwiftUI

/// 自动语言规则编辑器：target_lang=auto/AUTO 时的输出语言规则池（自上而下首条命中）。
/// 行编辑全部经 onCommit 走设置事务通道：校验失败不落盘，父级以行内红字提示。
/// 空规则列表 = 使用内置默认规则（中文（简/繁）→ 英语、其余 → 中文）。
struct AutoRulesSection: View {
    let settings: AppSettings
    /// 系统支持且可展示的语言码（探测为不支持的语言已过滤）
    let supportedCodes: [String]
    /// 顶层校验错误文案（最近一次被拒绝的写入或当前配置派生错误）
    let topErrorText: String?
    /// 规则列表整体提交（父级经设置事务通道写入并校验）
    let commitAction: @MainActor ([AutoTargetRule]) -> Void

    private var rules: [AutoTargetRule] { settings.autoTargetRules }
    private var policy: LanguagePolicy { LanguagePolicy(settings: settings) }

    var body: some View {
        Section {
            Text("仅当请求 target_lang 显式为 auto 或 AUTO 时生效：按自上而下顺序匹配第一条规则决定输出语言。规则列表为空时使用默认规则：中文（简/繁）→ 英语、其余语言 → 中文。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if rules.isEmpty {
                defaultSummary
            }
        }
        Section("规则列表（自上而下匹配，可增删与排序）") {
            if rules.isEmpty {
                Text("当前未配置自定义规则，生效中为上方默认规则。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }
            HStack {
                Button {
                    addRule()
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                Spacer()
                Button("恢复默认规则") {
                    commitRules { $0 = [] }
                }
                .disabled(rules.isEmpty)
                .help("清空自定义规则，恢复内置默认规则")
            }
            if let topErrorText {
                Text(topErrorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    /// 默认规则摘要（与 AutoTargetRule.defaultRules 文案保持一致）。
    private var defaultSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("默认规则：")
                .font(.footnote)
            Text("1. 源为中文（简体/繁体，允许自动检测）→ 英语")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("2. 任意语言 → 中文")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 单条规则行

    private func ruleRow(_ rule: AutoTargetRule) -> some View {
        let index = rules.firstIndex { $0.id == rule.id } ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("条件", selection: modeBinding(rule.id)) {
                    Text("任意语言").tag(AutoTargetRule.Mode.any)
                    Text("指定语言").tag(AutoTargetRule.Mode.languages)
                    Text("正则匹配 source_lang").tag(AutoTargetRule.Mode.pattern)
                }
                .fixedSize()
                Text("翻译为")
                    .foregroundStyle(.secondary)
                Picker("输出语言", selection: targetBinding(rule.id)) {
                    ForEach(supportedCodes, id: \.self) { code in
                        Text("\(LanguageCodes.displayName(for: code))（\(code)）").tag(code)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                moveButtons(rule: rule, index: index)
                Button {
                    commitRules { $0.removeAll { $0.id == rule.id } }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("删除该规则")
            }

            switch rule.mode {
            case .languages:
                VStack(alignment: .leading, spacing: 6) {
                    languageGrid(rule)
                    Toggle("未提供 source_lang 时允许自动判断源语言", isOn: autoDetectBinding(rule.id))
                        .toggleStyle(.checkbox)
                        .font(.footnote)
                }
            case .pattern:
                TextField("正则表达式（直接匹配 source_lang 原始字符串，如 ^zh|^ZH 或 en-us）",
                          text: patternBinding(rule.id))
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
            case .any:
                EmptyView()
            }

            if let issue = rule.validationIssue(policy: policy) {
                Text(issue)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 指定语言条件的选择网格（两列滚动勾选，样式同语言页启用列表）。
    private func languageGrid(_ rule: AutoTargetRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup("条件语言（已选 \(rule.languages.count)）") {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        ForEach(supportedCodes, id: \.self) { code in
                            Toggle(isOn: languageBinding(rule.id, code)) {
                                Text("\(LanguageCodes.displayName(for: code))（\(code)）")
                                    .lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 140)
            }
            .font(.footnote)
            Text("条件按语言族匹配：EN 覆盖 EN-US/EN-GB，简体 ZH 与 ZH-HANS 同族，繁体 ZH-HANT 单独成族。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 上移/下移按钮（规则顺序决定匹配优先级）。
    private func moveButtons(rule: AutoTargetRule, index: Int) -> some View {
        HStack(spacing: 2) {
            Button {
                moveRule(from: index, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("上移（提高匹配优先级）")
            Button {
                moveRule(from: index, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == rules.count - 1)
            .help("下移（降低匹配优先级）")
        }
    }

    // MARK: - 行级变更

    private func updateRule(_ id: UUID, _ mutate: (inout AutoTargetRule) -> Void) {
        commitRules { ruleList in
            guard let idx = ruleList.firstIndex(where: { $0.id == id }) else { return }
            mutate(&ruleList[idx])
        }
    }

    private func modeBinding(_ id: UUID) -> Binding<AutoTargetRule.Mode> {
        Binding(
            get: { rules.first { $0.id == id }?.mode ?? .any },
            set: { newValue in
                updateRule(id) { rule in
                    rule.mode = newValue
                    // 切换到需要参数的模式时预填合法默认值，避免空状态被事务校验拒绝
                    if newValue == .languages, rule.languages.isEmpty {
                        rule.languages = ["ZH"]
                    }
                    if newValue == .pattern, rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                        rule.pattern = ".*"
                    }
                }
            })
    }

    private func targetBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { rules.first { $0.id == id }?.targetCode ?? "ZH" },
            set: { newValue in
                updateRule(id) { $0.targetCode = newValue.trimmingCharacters(in: .whitespaces).uppercased() }
            })
    }

    private func languageBinding(_ id: UUID, _ code: String) -> Binding<Bool> {
        Binding(
            get: { rules.first { $0.id == id }?.languages.contains(code) ?? false },
            set: { enabled in
                updateRule(id) { rule in
                    if enabled {
                        rule.languages.insert(code)
                    } else {
                        rule.languages.remove(code)
                    }
                }
            })
    }

    private func autoDetectBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { rules.first { $0.id == id }?.allowAutoDetect ?? true },
            set: { newValue in
                updateRule(id) { $0.allowAutoDetect = newValue }
            })
    }

    private func patternBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { rules.first { $0.id == id }?.pattern ?? "" },
            set: { newValue in
                updateRule(id) { $0.pattern = newValue }
            })
    }

    // MARK: - 列表级变更

    private func addRule() {
        // 预填首条可用目标语言，避免默认 ZH 被启用列表禁用时无法新增
        let target = rules.first?.targetCode
            ?? supportedCodes.first { policy.isEnabled($0) }
            ?? rules.last?.targetCode
            ?? "ZH"
        var rule = AutoTargetRule()
        rule.mode = .any
        rule.targetCode = target.uppercased()
        commitRules { $0.append(rule) }
    }

    private func moveRule(from index: Int, by offset: Int) {
        let targetIndex = index + offset
        guard rules.indices.contains(index), rules.indices.contains(targetIndex) else { return }
        commitRules { ruleList in
            let rule = ruleList.remove(at: index)
            ruleList.insert(rule, at: targetIndex)
        }
    }

    /// 组装新规则列表并经事务通道提交（父级负责校验与错误展示）。
    private func commitRules(_ transform: (inout [AutoTargetRule]) -> Void) {
        var newList = rules
        transform(&newList)
        commitAction(newList)
    }
}
