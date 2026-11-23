import AgentBarCore
import AppKit
import SwiftUI

struct SettingsWindowView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedSettingsTab) {
            generalTab
                .tabItem { Label("通用与外观", systemImage: "slider.horizontal.3") }
                .tag(0)

            hooksApprovalTab
                .tabItem { Label("一键审批 Hooks", systemImage: "checkmark.shield") }
                .tag(1)

            sshHostsTab
                .tabItem { Label("SSH 服务器", systemImage: "server.rack") }
                .tag(2)

            balancesTab
                .tabItem { Label("余额 Dashboard", systemImage: "creditcard") }
                .tag(3)

            PricingSettingsView(model: model)
                .tabItem { Label("模型计费", systemImage: "dollarsign.circle") }
                .tag(4)
        }
        .padding(16)
        .frame(width: 650, height: 520)
    }

    private var generalTab: some View {
        Form {
            Section("菜单栏与液态玻璃面板") {
                Picker("菜单栏图标样式", selection: $model.menuBarStyle) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }

                Picker("默认界面排列方式", selection: $model.focusArrangementOrder) {
                    ForEach(FocusArrangementOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }

                Picker("默认项目排序", selection: $model.projectSortOrder) {
                    ForEach(ProjectSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }

                Picker("默认服务器排序", selection: $model.hostSortOrder) {
                    ForEach(HostSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }

                Toggle("使用演示数据预览完整状态（含待审批/SSH/余额卡片）", isOn: $model.demoModeEnabled)
                Toggle("显示内部子代理会话（Codex / Claude Subagents）", isOn: $model.includeSubagents)
                    .onChange(of: model.includeSubagents) { _, _ in
                        Task { await model.refreshAll(includeBalances: false) }
                    }
                Toggle("会话待审批 / 完成时发送系统通知", isOn: $model.notificationsEnabled)
                Toggle(
                    "登录 macOS 时自动启动 AgentBar",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.launchAtLoginEnabled = $0 }
                    )
                )
            }

            Section("历史会话扫描范围") {
                HStack {
                    Text("显示最近活跃会话")
                    Slider(value: $model.lookbackHours, in: 6...168, step: 6)
                    Text("\(Int(model.lookbackHours)) 小时内")
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hooksApprovalTab: some View {
        let hookPath = HookApprovalManager.hookBinaryPath()
        return VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code 一键审批与实时状态 Hook")
                .font(.system(size: 14, weight: .bold))

            Text("安装后，当 Claude Code 请求执行工具时，会通过内置的 agentbar-hook 将请求实时投递到菜单栏面板与系统通知，支持直接点击“批准 / 拒绝 / 在终端处理”（超过 120 秒未操作将自动交回终端原生提示）。写入前会自动备份原配置文件为 settings.json.agentbar-bak。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("将合并写入 ~/.claude/settings.json 的配置预览：")
                .font(.system(size: 11.5, weight: .semibold))

            ScrollView {
                Text(HookApprovalManager.previewClaudeHooksJSON(hookExecutablePath: hookPath))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            HStack(spacing: 10) {
                Button("备份并安装 Claude Code Hooks") {
                    do {
                        let savedPath = try HookApprovalManager.installClaudeHooks(hookExecutablePath: hookPath)
                        model.hookInstallMessage = "✓ 已安装至 \(savedPath)"
                    } catch {
                        model.hookInstallMessage = "安装失败：\(error.localizedDescription)"
                    }
                }
                .buttonStyle(.glassProminent)

                Button("打开审批审计日志") {
                    let url = HookApprovalManager.auditLogURL
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.glass)

                if let msg = model.hookInstallMessage {
                    Text(msg)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(msg.hasPrefix("✓") ? .green : .red)
                }
            }
        }
        .padding(8)
    }

    private var sshHostsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("从 ~/.ssh/config 发现的主机与自定义服务器（远端零部署，仅使用 BatchMode SSH）")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新扫描 ~/.ssh/config") {
                    model.discoverAndMergeSSHHosts()
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            }

            List {
                ForEach(Array($model.sshHosts.enumerated()), id: \.element.id) { idx, $hostCfg in
                    HStack {
                        Toggle(isOn: $hostCfg.isEnabled) {
                            HStack(spacing: 6) {
                                Text(hostCfg.alias)
                                    .font(.system(size: 13, weight: .semibold))
                                if let sub = hostCfg.connectionSubtitle {
                                    Text(sub)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Button("终端登录") {
                            model.connectAndUnlockSSHHost(hostCfg.alias)
                        }
                        .controlSize(.small)
                        .buttonStyle(.glass)

                        Toggle("允许远程审批", isOn: $hostCfg.approvalEnabled)
                            .controlSize(.small)
                            .disabled(!hostCfg.isEnabled)

                        Button {
                            model.moveSSHConfig(at: idx, direction: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(idx == 0)
                        .help("上移服务器顺序")

                        Button {
                            model.moveSSHConfig(at: idx, direction: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(idx == model.sshHosts.count - 1)
                        .help("下移服务器顺序")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                TextField("手动添加 SSH Host 别名或 user@host…", text: $model.newSSHAliasDraft)
                    .textFieldStyle(.roundedBorder)
                Button("添加主机") {
                    let trimmed = model.newSSHAliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !model.sshHosts.contains(where: { $0.alias == trimmed }) else { return }
                    model.sshHosts.append(SSHHostConfig(alias: trimmed, isEnabled: true, approvalEnabled: true))
                    model.newSSHAliasDraft = ""
                    Task { await model.refreshSSHHosts() }
                }
                .buttonStyle(.glassProminent)

                Button("立即探测所选主机") {
                    Task { await model.refreshSSHHosts() }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(8)
    }

    private var balancesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("支持内部 SSO 网页提取、JSON API 与自定义脚本")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("自动刷新", selection: $model.dashboardRefreshIntervalSeconds) {
                    Text("每 1 分钟").tag(60.0)
                    Text("每 3 分钟").tag(180.0)
                    Text("每 5 分钟").tag(300.0)
                    Text("每 15 分钟").tag(900.0)
                }
                .frame(width: 155)

                Menu("+ 添加 DeepSeek 看板") {
                    Button("DeepSeek Harness 账号（自动读取本机登录态）") {
                        if let idx = model.balanceSources.firstIndex(where: { $0.type == .deepSeekHarness }) {
                            model.balanceSources[idx].isEnabled = true
                        } else {
                            var preset = BalanceSourceConfig.deepSeekHarnessPreset
                            if model.balanceSources.contains(where: { $0.id == preset.id }) {
                                preset.id = UUID()
                            }
                            model.balanceSources.append(preset)
                        }
                        Task { await model.refreshBalances() }
                    }
                    Button("DeepSeek 开放平台 API Key") {
                        model.balanceSources.append(.deepSeekPreset)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.glass)

                Button("+ 添加 SSO 网页 Dashboard") {
                    model.balanceSources.append(BalanceSourceConfig(
                        name: "内部 SSO Dashboard",
                        type: .webExtract,
                        urlOrCommand: "https://",
                        extractorOrJSONPath: "",
                        currencySymbol: "$",
                        lowBalanceThreshold: 200
                    ))
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($model.balanceSources) { $source in
                        balanceSourceEditorCard(source: $source)
                    }
                }
            }
        }
        .padding(8)
    }

    private func balanceSourceEditorCard(source: Binding<BalanceSourceConfig>) -> some View {
        let item = source.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: source.isEnabled)
                    .labelsHidden()
                TextField("名称", text: source.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Picker("", selection: source.type) {
                    ForEach(BalanceSourceType.allCases, id: \.self) { t in
                        Text(t.title).tag(t)
                    }
                }
                .frame(width: 180)
                TextField("货币", text: source.currencySymbol)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                Spacer()
                Button(role: .destructive) {
                    model.balanceSources.removeAll { $0.id == item.id }
                    Task { await model.refreshBalances() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            if item.type == .deepSeekHarness {
                Text("自动读取本机 ~/.dsh/.credentials.yaml 中的 DeepSeek Harness 登录态，实时同步充值余额、赠金与累计消耗（无需手动填写 Token）。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(item.type == .command ? "Shell 命令" : "URL 地址")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    TextField(item.type == .command ? "例如：curl -s ... | jq .balance" : "https://...", text: source.urlOrCommand)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if item.type == .jsonAPI || item.type == .webExtract {
                HStack {
                    Text(item.type == .jsonAPI ? "JSON 路径" : "提取规则")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    TextField(
                        item.type == .jsonAPI ? "balance_infos.0.total_balance" : "留空智能识别页面额度，或填 CSS 选择器 / JS 表达式",
                        text: source.extractorOrJSONPath
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 8) {
                if item.type == .jsonAPI {
                    SecureField(
                        "API Token（存入钥匙串）",
                        text: Binding(
                            get: { model.tokenInputs[item.id] ?? (KeychainStore.loadToken(for: item.id) ?? "") },
                            set: { val in
                                model.tokenInputs[item.id] = val
                                KeychainStore.saveToken(val, for: item.id)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                } else if item.type == .webExtract {
                    Button("打开看板 / SSO 登录") {
                        model.openDashboardWindow(for: source.wrappedValue)
                    }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                } else if item.type == .deepSeekHarness {
                    Button("打开 DeepSeek 用量看板") {
                        model.openDashboardWindow(for: source.wrappedValue)
                    }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                }

                Button("测试提取") {
                    let snapshot = source.wrappedValue
                    Task {
                        let res = await BalanceService.fetchReading(for: snapshot) { url, expr in
                            try await WebBalanceExtractor.shared.evaluateOnPage(url: url, jsOrSelector: expr)
                        }
                        model.balanceTestMessage[snapshot.id] = "结果：\(res.formattedValue)（\(res.footnote)）"
                        await model.refreshBalances()
                    }
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)

                if let msg = model.balanceTestMessage[item.id] {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

}
