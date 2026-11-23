import AgentBarCore
import SwiftUI

struct SessionRowView: View {
    let session: AgentSession
    let isExpanded: Bool
    let model: AppModel
    var showLocationContext: Bool = false
    var trackPanelVisibility: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if isExpanded {
                expandedDetail
                    .padding(.leading, 48)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.36))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.vertical, isExpanded ? 3 : 0.5)
        .onScrollVisibilityChange(threshold: 0.6) { isVisible in
            guard trackPanelVisibility else { return }
            model.sessionRowScrollVisibilityChanged(sessionID: session.id, isVisible: isVisible)
        }
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentLogoView(kind: session.kind, size: 32)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(session.overview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(metaSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)

                if session.status == .awaitingApproval {
                    quickApprovalButtons
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button {
                    model.markSessionSeen(session.id)
                    JumpService.jump(to: session)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 21, height: 21)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(jumpButtonTitle)

                StatusPillView(status: session.status, isInferred: session.statusIsInferred)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) || flags.contains(.option) {
                model.markSessionSeen(session.id)
                JumpService.jump(to: session)
                return
            }
            withAnimation(.spring(duration: 0.22)) {
                model.toggleSessionExpanded(session)
            }
        }
        .contextMenu {
            Button(jumpButtonTitle) {
                model.markSessionSeen(session.id)
                JumpService.jump(to: session)
            }
            if session.host.isLocal, (session.kind == .codexDesktop || session.kind == .codexCLI) {
                Button("在 Codex 桌面端打开此线程") {
                    model.markSessionSeen(session.id)
                    JumpService.openInCodexThread(sessionID: session.rawSessionID)
                }
            }
            if case .ssh(let alias) = session.host {
                if JumpService.canOpenRemoteIDE() {
                    Button("在 VS Code Remote-SSH 中打开") {
                        model.markSessionSeen(session.id)
                        _ = JumpService.openInRemoteIDE(alias: alias, cwd: session.cwd, preferCursor: false)
                    }
                }
                Button("在终端 SSH 打开并恢复会话") {
                    model.markSessionSeen(session.id)
                    JumpService.openSSHInTerminal(
                        alias: alias,
                        cwd: session.cwd,
                        resumeCommand: session.resumeCommand,
                        autoExecuteResume: true
                    )
                }
            }
            if let cwd = session.cwd, session.host.isLocal {
                Button("在 Finder 中显示目录") {
                    JumpService.openDirectory(cwd)
                }
            }
            if let resume = session.resumeCommand {
                Divider()
                Button("复制恢复命令（\(resume)）") {
                    JumpService.copyToPasteboard(resume)
                }
            }
        }
    }

    private var quickApprovalButtons: some View {
        HStack(spacing: 6) {
            if session.pendingApproval?.canRespondViaHook == true {
                Button("批准") {
                    model.requestApprove(session)
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)

                Button("拒绝") {
                    model.requestDeny(session)
                }
                .controlSize(.small)
                .buttonStyle(.glass)

                Button(nativeApprovalHandleTitle) {
                    model.requestHandleInTerminal(session)
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            } else {
                Button(passiveApprovalJumpTitle) {
                    JumpService.jump(to: session)
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
            }
        }
    }

    private var nativeApprovalTargetName: String {
        if !session.host.isLocal {
            return "终端"
        }
        switch session.launchEnvironment {
        case .codexApp:
            return "Codex"
        case .vscodeExtension:
            return "VS Code"
        case .cursorExtension:
            return "Cursor"
        case .deepseekHarnessApp:
            return "DeepSeek Harness"
        default:
            break
        }
        if session.kind.isCLI {
            return "终端"
        }
        return session.kind.displayName
    }

    private var nativeApprovalHandleTitle: String {
        "在 \(nativeApprovalTargetName) 处理"
    }

    private var passiveApprovalJumpTitle: String {
        let isQuestion = session.pendingApproval.map {
            $0.toolName == "request_user_input"
                || $0.toolName == "ask_user_question"
                || $0.toolName == "AskUserQuestion"
        } ?? false
        let actionWord = isQuestion ? "回答" : "审批"
        return "跳转到 \(nativeApprovalTargetName) \(actionWord)"
    }

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = session.errorBanner {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.72, green: 0.12, blue: 0.10))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.12))
                    )
            }

            if let rule = session.pendingApproval?.highRiskMatchedRule {
                Text("⚠︎ 命中高风险规则 \(rule)：点“批准”后需要二次确认")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.64, green: 0.34, blue: 0.0))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.orange.opacity(0.16))
                    )
            }

            keyValueGrid

            if session.usage.totalTokens > 0 {
                tokenBoxes
            }

            if let used = session.contextUsedTokens, let win = session.contextWindow, win > 0 {
                contextProgressBar(used: used, window: win)
            }

            metricsChips

            if !session.recentTools.isEmpty {
                toolTimeline
            }

            if let md = session.lastOutputMarkdown, !md.isEmpty,
               (session.status == .completed || session.status == .waitingForInput) {
                markdownPreviewSection(md: md)
            }

            detailActionButtons
        }
    }

    private var keyValueGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3.5) {
            if let tool = session.currentTool {
                GridRow {
                    Text("当前工具").foregroundStyle(.secondary)
                    Text("\(tool.name) · \(tool.summary)")
                        .fontWeight(.medium)
                }
            }
            if let approval = session.pendingApproval {
                GridRow {
                    Text("已等待").foregroundStyle(.secondary)
                    Text(FormattingHelpers.elapsedString(since: approval.requestedAt))
                        .fontWeight(.medium)
                }
            }
            if let cwd = session.cwd {
                GridRow {
                    Text("工作目录").foregroundStyle(.secondary)
                    Text(FormattingHelpers.abbreviateHome(cwd))
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }
            }
            if session.provider != nil || session.model != nil {
                GridRow {
                    Text("供应商/模型").foregroundStyle(.secondary)
                    Text(providerAndModelText)
                        .fontWeight(.medium)
                }
            }
        }
        .font(.system(size: 11.5))
    }

    private var tokenBoxes: some View {
        HStack(spacing: 5) {
            tokenCell(title: "输入", value: FormattingHelpers.compactTokens(session.usage.input))
            tokenCell(title: "输出", value: FormattingHelpers.compactTokens(session.usage.output))
            tokenCell(title: "缓存读", value: FormattingHelpers.compactTokens(session.usage.cacheRead))
            if session.usage.reasoning > 0 && session.usage.cacheWrite == 0 {
                tokenCell(title: "推理", value: FormattingHelpers.compactTokens(session.usage.reasoning))
            } else {
                tokenCell(title: "缓存写", value: FormattingHelpers.compactTokens(session.usage.cacheWrite))
            }
        }
    }

    private func tokenCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.65), lineWidth: 0.5)
                )
        )
    }

    private func contextProgressBar(used: Int, window: Int) -> some View {
        let ratio = min(1.0, max(0.0, Double(used) / Double(window)))
        let pct = Int((ratio * 100.0).rounded())
        return HStack(spacing: 8) {
            Text("上下文")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(ratio > 0.85 ? Color.orange : Color.accentColor)
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 5)
            Text("\(FormattingHelpers.compactTokens(used)) / \(FormattingHelpers.compactTokens(window)) · \(pct)%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
    }

    private var metricsChips: some View {
        var items: [String] = []
        if let hit = session.usage.cacheHitRate {
            items.append(String(format: "缓存命中 %.0f%%", hit * 100.0))
        }
        if let proc = session.process {
            items.append("内存 \(FormattingHelpers.memoryString(proc.memoryBytes))")
            items.append(String(format: "CPU %.0f%%", proc.cpuPercent))
        }
        if session.totalToolCalls > 0 {
            items.append("工具成功 \(session.successfulToolCalls)/\(session.totalToolCalls)")
        }
        if let tps = session.outputTokensPerSecond, tps > 0 {
            items.append(String(format: "%.0f tok/s", tps))
        }
        if session.turnCount > 0 {
            items.append("第 \(session.turnCount) 轮")
        }
        if session.compactCount > 0 {
            items.append("压缩 \(session.compactCount) 次")
        }
        if let cost = PricingCatalog.estimatedCostUSD(for: session) {
            items.append(String(format: "预估 $%.2f", cost))
        }
        return FlowChipsLayout(spacing: 4) {
            ForEach(items, id: \.self) { label in
                MetricChipView(text: label)
            }
        }
    }

    private var toolTimeline: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(session.recentTools) { tool in
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.45)))
                    Text(tool.summary)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(tool.isError ? Color.red : .primary.opacity(0.85))
                    Spacer()
                    Text(toolStatusRightText(tool))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(tool.isError ? Color.red : .secondary)
                }
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 2)
        }
    }

    private func toolStatusRightText(_ tool: ToolCallRecord) -> String {
        if let dur = tool.durationSeconds {
            let s = String(format: "%.1fs", dur)
            return tool.isError ? "失败 · \(s)" : s
        }
        if session.status == .awaitingApproval {
            return "待审批"
        }
        return "运行中"
    }

    private func markdownPreviewSection(md: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("最终输出")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制 Markdown") {
                    JumpService.copyToPasteboard(md)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)

                Button("在窗口中打开") {
                    StandaloneMarkdownWindowManager.shared.open(session: session)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 6)
            }

            ScrollView {
                MarkdownDocumentView(markdown: md, fontSize: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 340)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.52))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(.white.opacity(0.72), lineWidth: 0.5)
                    )
            )
        }
    }

    private var detailActionButtons: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            if session.status == .awaitingApproval, session.pendingApproval?.canRespondViaHook == true {
                Button("批准一次") {
                    model.requestApprove(session)
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)

                Button("拒绝并说明原因…") {
                    model.denyReasonDraft = ""
                    model.denyingSession = session
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            }

            if session.status == .awaitingApproval {
                Button(jumpButtonTitle) {
                    model.markSessionSeen(session.id)
                    JumpService.jump(to: session)
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            } else {
                Button(jumpButtonTitle) {
                    model.markSessionSeen(session.id)
                    JumpService.jump(to: session)
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
            }

            if case .ssh(let alias) = session.host {
                Button("终端 SSH 恢复") {
                    model.markSessionSeen(session.id)
                    JumpService.openSSHInTerminal(
                        alias: alias,
                        cwd: session.cwd,
                        resumeCommand: session.resumeCommand,
                        autoExecuteResume: true
                    )
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            }

            if let cwd = session.cwd, session.host.isLocal {
                Button("打开目录") {
                    JumpService.openDirectory(cwd)
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            }

            if let resume = session.resumeCommand {
                Button("复制恢复命令") {
                    JumpService.copyToPasteboard(resume)
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            }
        }
    }

    private var jumpButtonTitle: String {
        switch session.host {
        case .ssh(let alias):
            if session.launchEnvironment == .cursorExtension {
                return "在 Cursor SSH (\(alias)) 打开"
            }
            if session.launchEnvironment == .vscodeExtension && JumpService.canOpenRemoteIDE() {
                return "在 VS Code SSH (\(alias)) 打开"
            }
            return "SSH 跳转到 \(alias)"
        case .local:
            switch session.launchEnvironment {
            case .codexApp:
                return "在 Codex 打开此对话"
            case .vscodeExtension:
                return "在 VS Code 打开此窗口"
            case .cursorExtension:
                return "在 Cursor 打开此窗口"
            default:
                break
            }
            if session.kind.isCLI {
                if let tty = session.process?.tty {
                    return "跳转到终端 (\(tty))"
                }
                return "在终端恢复此会话"
            }
            return "打开 \(session.kind.displayName)"
        }
    }

    private var providerAndModelText: String {
        var parts: [String] = []
        if let p = session.provider, !p.isEmpty { parts.append(p) }
        if let m = session.model, !m.isEmpty {
            if let eff = session.reasoningEffort, !eff.isEmpty {
                parts.append("\(m)（推理 \(eff)）")
            } else {
                parts.append(m)
            }
        }
        return parts.joined(separator: " · ")
    }

    private var metaSubtitle: String {
        var parts: [String] = []
        if showLocationContext {
            parts.append(model.locationContextLabel(for: session))
        }
        parts.append(session.kind.displayName)
        if let m = session.model, !m.isEmpty {
            parts.append(m)
        }
        parts.append(FormattingHelpers.relativeDuration(since: session.lastActivityAt))
        return parts.joined(separator: " · ")
    }
}

struct FlowChipsLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}
