import AgentBarCore
import AppKit
import SwiftUI

struct PanelView: View {
    static let panelWidth: CGFloat = 448

    @Bindable var model: AppModel
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                headerBar
                if model.isSearchVisible && !model.isShowingOverview {
                    searchBar
                }
                if !model.isShowingOverview {
                    statusFilterAndApprovalBar
                }
                if let toast = model.quickBannerToast {
                    Text(toast)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.09, green: 0.48, blue: 0.20))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
                if !model.isShowingOverview && !model.balanceReadings.isEmpty {
                    balancesRow
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(2)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                if newHeight > 60 && abs(model.measuredTopChromeHeight - newHeight) > 0.5 {
                    model.measuredTopChromeHeight = newHeight
                    model.onPreferredHeightChanged?()
                }
            }

            sessionScrollList
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .layoutPriority(0)

            footerBar
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                    if newHeight > 20 && abs(model.measuredFooterHeight - newHeight) > 0.5 {
                        model.measuredFooterHeight = newHeight
                        model.onPreferredHeightChanged?()
                    }
                }
        }
        .frame(width: Self.panelWidth)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .focusEffectDisabled()
        .sheet(item: $model.confirmingHighRiskSession) { target in
            highRiskConfirmationSheet(target)
        }
        .sheet(item: $model.denyingSession) { target in
            denyReasonSheet(target)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("AgentBar")
                .font(.system(size: 15, weight: .bold))

            overviewToggleButton

            if model.demoModeEnabled {
                Text("演示")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(.white.opacity(0.28)))
            }

            Spacer()

            if model.menuBarCounts.completedUnseen > 0 || model.menuBarCounts.failed > 0 {
                Button("全部已读") {
                    model.markAllCompletedSeen()
                }
                .controlSize(.mini)
                .buttonStyle(.glass)
            }

            GlassEffectContainer {
                HStack(spacing: 5) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.isSearchVisible.toggle()
                            if !model.isSearchVisible {
                                model.searchQuery = ""
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("搜索会话或目录")

                    Button {
                        Task { await model.refreshAll(includeBalances: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                            .animation(model.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: model.isRefreshing)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("立即刷新")

                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("设置")
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var overviewToggleButton: some View {
        let todayTok = FormattingHelpers.compactTokens(model.totalAnalytics.todayUsage.totalTokens)
        let label = HStack(spacing: 4) {
            Image(systemName: model.isShowingOverview ? "chevron.left" : "chart.bar.xaxis")
                .font(.system(size: 9.5, weight: .semibold))
            Text(model.isShowingOverview ? "返回会话" : "总数据 · \(todayTok)")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
        }
        if model.isShowingOverview {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.isShowingOverview = false
                }
            } label: {
                label
            }
            .controlSize(.mini)
            .buttonStyle(.glassProminent)
            .help("返回会话列表")
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.isShowingOverview = true
                }
            } label: {
                label
            }
            .controlSize(.mini)
            .buttonStyle(.glass)
            .help("查看会员额度、Dashboard 看板、今日 Token 与全局统计")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索标题、工作目录、工具或模型…", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var statusFilterAndApprovalBar: some View {
        let counts = model.menuBarCounts
        let hostSummaries = model.allHostSummaries
        return VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                    StatusFilterPillView(
                        category: .running,
                        count: counts.activeGenerating,
                        isSelected: model.selectedCategory == .running
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.toggleStatusCategory(.running)
                        }
                    }

                    StatusFilterPillView(
                        category: .completedUnseen,
                        count: counts.completedUnseen,
                        isSelected: model.selectedCategory == .completedUnseen
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.toggleStatusCategory(.completedUnseen)
                        }
                    }

                    StatusFilterPillView(
                        category: .awaitingApproval,
                        count: counts.awaitingApproval,
                        isSelected: model.selectedCategory == .awaitingApproval
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.toggleStatusCategory(.awaitingApproval)
                        }
                    }

                    StatusFilterPillView(
                        category: .failed,
                        count: counts.failed,
                        isSelected: model.selectedCategory == .failed
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.toggleStatusCategory(.failed)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                oneClickApproveButton(pendingCount: counts.awaitingApproval)
                    .padding(.top, 1)
            }
            .padding(.horizontal, 13)

            HStack(alignment: .top, spacing: 6) {
                FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(hostSummaries, id: \.host.storageKey) { item in
                        hostQuickChip(item.host, connection: item.connection, count: item.sessionCount)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    sshServersMenuButton
                    sortMenuButton
                }
                .fixedSize()
            }
            .padding(.horizontal, 13)
        }
        .padding(.bottom, 7)
    }

    private func hostQuickChip(_ host: HostID, connection: HostConnectionState, count: Int) -> some View {
        let isSelected = model.selectedHostFilter == host
        let isProbing = model.probingHostIDs.contains(host)
        let title = host.isLocal ? "本机" : host.displayTitle
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                model.toggleHostFilter(host)
            }
        } label: {
            HStack(spacing: 4) {
                if !host.isLocal {
                    Circle()
                        .fill(isProbing ? Color.accentColor : (connection.isOnline ? Color.green : Color.secondary.opacity(0.45)))
                        .frame(width: 5.5, height: 5.5)
                } else {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.horizontal, 7.5)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.20) : .white.opacity(0.26))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isSelected ? Color.accentColor.opacity(0.85) : .white.opacity(0.48),
                                lineWidth: isSelected ? 1.2 : 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .help(isSelected ? "再次点击显示全部主机" : "点击仅查看 \(host.displayTitle) 的会话")
    }

    @ViewBuilder
    private func oneClickApproveButton(pendingCount: Int) -> some View {
        if pendingCount > 0 {
            Button {
                model.approveAllPending()
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("一键审批 (\(pendingCount))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                }
                .fixedSize()
            }
            .controlSize(.mini)
            .buttonStyle(.glassProminent)
            .help("一键批准当前所有待审批请求（高风险操作仍会二次确认）")
        } else if !model.isHookInstalled {
            Button {
                model.enableOneClickApprovalHooks()
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                    Text("启用一键审批")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .fixedSize()
            }
            .controlSize(.mini)
            .buttonStyle(.glass)
            .help("自动安装 Claude Code 审批 Hook，后续待审批可直接一键放行")
        } else {
            Button {
                model.approveAllPending()
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("一键审批")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .fixedSize()
            }
            .controlSize(.mini)
            .buttonStyle(.glass)
            .disabled(true)
            .help("当前没有待审批请求（Claude Code 一键审批 Hook 已就绪）")
        }
    }

    private var balancesRow: some View {
        let cols = min(3, max(1, model.balanceReadings.count))
        return GlassEffectContainer {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: cols),
                spacing: 7
            ) {
                ForEach(model.balanceReadings) { reading in
                    BalanceCardView(reading: reading, isRefreshing: model.isRefreshingBalances) {
                        model.openDashboardWindow(for: reading)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    private var sshServersMenuButton: some View {
        let enabledCount = model.sshHosts.filter(\.isEnabled).count
        return Menu {
            Section("~/.ssh/config 远程服务器") {
                if model.sshHosts.isEmpty {
                    Text("未在 ~/.ssh/config 发现远程服务器")
                } else {
                    ForEach(model.sshHosts) { cfg in
                        Button {
                            model.toggleSSHHostEnabled(cfg.alias)
                        } label: {
                            let labelText = cfg.connectionSubtitle.map { "\(cfg.alias) (\($0))" } ?? cfg.alias
                            if cfg.isEnabled {
                                Label(labelText, systemImage: "checkmark")
                            } else {
                                Text(labelText)
                            }
                        }
                    }
                }
            }

            if !model.sshHosts.isEmpty {
                Section("在终端打开 SSH（自动共享连接）") {
                    ForEach(model.sshHosts) { cfg in
                        Button("SSH 连接 \(cfg.alias)…") {
                            model.connectAndUnlockSSHHost(cfg.alias)
                        }
                    }
                }
            }

            Divider()

            Button("重新扫描 ~/.ssh/config 并探测") {
                model.discoverAndMergeSSHHosts()
                Task { await model.refreshSSHHosts() }
            }

            Button("管理 SSH 服务器…") {
                model.selectedSettingsTab = 2
                onOpenSettings()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10, weight: .semibold))
                Text(enabledCount > 0 ? "SSH \(enabledCount)" : "SSH")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .menuStyle(.button)
        .controlSize(.small)
        .buttonStyle(.glass)
        .help("查看与切换 ~/.ssh/config 中的远程服务器")
    }

    private var sortMenuButton: some View {
        Menu {
            Section("默认界面排列方式") {
                ForEach(FocusArrangementOrder.allCases) { order in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.focusArrangementOrder = order
                        }
                    } label: {
                        if model.focusArrangementOrder == order {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            }

            Section("所有对话 · 项目（工作目录）排序") {
                ForEach(ProjectSortOrder.allCases) { order in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.projectSortOrder = order
                        }
                    } label: {
                        if model.projectSortOrder == order {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            }

            Section("所有对话 · 服务器（主机）排序") {
                ForEach(HostSortOrder.allCases) { order in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.hostSortOrder = order
                        }
                    } label: {
                        if model.hostSortOrder == order {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            }

            Divider()

            Button("展开全部目录") {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.expandAllGroups()
                }
            }
            Button("折叠全部工作目录") {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.collapseAllDirectories()
                }
            }
            if !model.pinnedGroupIDs.isEmpty {
                Button("清除全部置顶 (\(model.pinnedGroupIDs.count))") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.clearAllPinnedGroups()
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.focusArrangementOrder.shortLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .menuStyle(.button)
        .controlSize(.small)
        .buttonStyle(.glass)
        .help("切换默认界面排列方式（新生成 / 待审批·运行中顺序）及所有对话排序规则")
    }

    private var sessionScrollList: some View {
        let hostGroups = model.filteredHostGroups
        return ScrollView(.vertical, showsIndicators: true) {
            Group {
                if model.isShowingOverview {
                    OverviewDashboardView(model: model) {
                        model.selectedSettingsTab = 3
                        onOpenSettings()
                    }
                } else if model.isDefaultFocusMode {
                    defaultFocusAndArchiveView(allHostGroups: hostGroups)
                } else if hostGroups.isEmpty || (hostGroups.count == 1 && hostGroups[0].host.isLocal && hostGroups[0].isEmpty) {
                    emptyPlaceholder
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hostGroups) { hostGroup in
                            hostSection(hostGroup, trackPanelVisibility: true)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                if newHeight > 20 && abs(model.measuredScrollContentHeight - newHeight) > 0.5 {
                    model.measuredScrollContentHeight = newHeight
                    model.onPreferredHeightChanged?()
                }
            }
        }
        .contentMargins(.zero, for: .scrollContent)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.selectedCategory == nil ? "暂无匹配的 Agent 会话" : "当前没有“\(model.selectedCategory!.title)”状态的会话")
                .font(.system(size: 13, weight: .semibold))
            if model.selectedCategory != nil || model.selectedHostFilter != nil {
                Button("清除筛选查看全部") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.selectedCategory = nil
                        model.selectedHostFilter = nil
                    }
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            } else {
                Text("在终端或桌面启动 Claude Code、Codex、DeepSeek Harness、Cursor 或 Antigravity 后会自动显示在这里。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    @ViewBuilder
    private func defaultFocusAndArchiveView(allHostGroups: [HostSessionGroup]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.focusArrangementOrder == .byHostAndProject {
                let focusGroups = model.focusHostGroups
                focusByProjectHeader
                if focusGroups.isEmpty {
                    Text("当前暂无新生成、待审批或运行中的会话")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(focusGroups) { group in
                            hostSection(group, trackPanelVisibility: true)
                        }
                    }
                }
            } else {
                let sections = model.focusStatusSections
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    focusStatusSectionView(section, showOrderButton: index == 0)
                }
            }

            allConversationsDisclosureSection(allHostGroups: allHostGroups)
        }
        .padding(.bottom, 8)
    }

    private var focusByProjectHeader: some View {
        HStack(spacing: 6) {
            StatusDotView(status: .completed, size: 6.5)
            StatusDotView(status: .generating, size: 6.5)
            Text("需关注与运行中（按项目分组）")
                .font(.system(size: 12, weight: .bold))
            Spacer()
            quickCycleArrangementButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func focusStatusSectionView(_ section: FocusStatusSection, showOrderButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                StatusDotView(status: section.badgeStatus, size: 7)
                if let secondStatus = section.secondaryBadgeStatus {
                    StatusDotView(status: secondStatus, size: 7)
                }
                Text(section.title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)

                Text("\(section.sessions.count)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(section.sessions.isEmpty ? .secondary : StatusPalette.textColor(for: section.badgeStatus))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(section.sessions.isEmpty ? Color.primary.opacity(0.06) : StatusPalette.color(for: section.badgeStatus).opacity(0.18))
                    )

                if section.sessions.isEmpty {
                    Text(section.emptyHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary.opacity(0.82))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if showOrderButton {
                    quickCycleArrangementButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if !section.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(section.sessions) { session in
                        SessionRowView(
                            session: session,
                            isExpanded: model.expandedSessionIDs.contains(session.id),
                            model: model,
                            showLocationContext: true,
                            trackPanelVisibility: true
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var quickCycleArrangementButton: some View {
        Menu {
            ForEach(FocusArrangementOrder.allCases) { order in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.focusArrangementOrder = order
                    }
                } label: {
                    if model.focusArrangementOrder == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 2.5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("排列")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("修改默认界面的分区排列方式")
    }

    @ViewBuilder
    private func allConversationsDisclosureSection(allHostGroups: [HostSessionGroup]) -> some View {
        let totalCount = model.totalConversationCountInScope
        let idleCount = model.inactiveConversationCountInScope
        let titleText: String = {
            if let host = model.selectedHostFilter {
                return "\(host.displayTitle) 的所有对话"
            }
            return "所有对话"
        }()
        let subtitleText: String = {
            if model.isAllConversationsExpanded {
                return "点击收起 · 共 \(totalCount) 个"
            }
            if idleCount > 0 {
                return "点击展开 · 共 \(totalCount) 个（\(idleCount) 个静默）"
            }
            return "点击展开 · 共 \(totalCount) 个"
        }()

        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(duration: 0.22)) {
                    model.isAllConversationsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.isAllConversationsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 11)

                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(titleText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))

                    Spacer(minLength: 6)

                    Text(subtitleText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.white.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(.white.opacity(0.45), lineWidth: 0.6)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 4)

            if model.isAllConversationsExpanded {
                if allHostGroups.isEmpty || (allHostGroups.count == 1 && allHostGroups[0].host.isLocal && allHostGroups[0].isEmpty) {
                    Text("暂无近期对话记录")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(allHostGroups) { hostGroup in
                            hostSection(hostGroup, trackPanelVisibility: false)
                        }
                    }
                }
            }
        }
    }

    private func hostSection(_ hostGroup: HostSessionGroup, trackPanelVisibility: Bool = true) -> some View {
        let isOffline = !hostGroup.connection.isOnline
        let collapsed = model.isGroupCollapsed(hostGroup.id, defaultOffline: false)
        let isPinned = model.isGroupPinned(hostGroup.id)
        let sshSubtitle = model.sshHostConfig(for: hostGroup.host)?.connectionSubtitle
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 11)

                Image(systemName: hostGroup.host.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))

                Text(hostGroup.host.displayTitle)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)

                if let sshSubtitle, !hostGroup.host.isLocal {
                    Text(sshSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                hostRightStatus(hostGroup)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.toggleGroupCollapsed(hostGroup.id, isOfflineHost: isOffline)
                }
            }
            .contextMenu {
                if case .ssh(let alias) = hostGroup.host {
                    Button("在终端打开 SSH 连接（\(alias)）") {
                        model.connectAndUnlockSSHHost(alias)
                    }
                    Button("立即重新探测此服务器") {
                        Task { await model.probeSingleSSHHost(alias: alias) }
                    }
                    Divider()
                }
                Button(isPinned ? "取消置顶此服务器" : "置顶此服务器") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.toggleGroupPinned(hostGroup.id)
                    }
                }
                Button("服务器位置上移") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.moveHost(hostGroup.id, direction: -1)
                    }
                }
                Button("服务器位置下移") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.moveHost(hostGroup.id, direction: 1)
                    }
                }
                Divider()
                Button(collapsed ? "展开此服务器" : "折叠此服务器") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.toggleGroupCollapsed(hostGroup.id, isOfflineHost: isOffline)
                    }
                }
            }

            if !collapsed {
                if hostGroup.isEmpty, case .ssh(let alias) = hostGroup.host {
                    remoteEmptyServerRow(alias: alias, isOnline: hostGroup.connection.isOnline)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hostGroup.directories) { dirGroup in
                            directorySection(dirGroup, trackPanelVisibility: trackPanelVisibility)
                        }
                        if !hostGroup.looseSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(hostGroup.looseSessions) { session in
                                    SessionRowView(
                                        session: session,
                                        isExpanded: model.expandedSessionIDs.contains(session.id),
                                        model: model,
                                        trackPanelVisibility: trackPanelVisibility
                                    )
                                }
                            }
                            .padding(.leading, 14)
                            .padding(.trailing, 8)
                        }
                    }
                    .opacity(isOffline ? 0.58 : 1.0)
                }
            }
        }
    }

    private func remoteEmptyServerRow(alias: String, isOnline: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isOnline ? "terminal" : "key.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(isOnline ? "远端暂无最近活跃的 Agent 会话" : "需在终端完成一次 SSH 登录以共享连接")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(isOnline ? "打开 SSH 终端" : "终端登录解锁") {
                model.connectAndUnlockSSHHost(alias)
            }
            .controlSize(.mini)
            .buttonStyle(.glass)
        }
        .padding(.leading, 30)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func hostRightStatus(_ hostGroup: HostSessionGroup) -> some View {
        if hostGroup.host.isLocal {
            Text("\(hostGroup.totalSessionCount) 个会话")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if model.probingHostIDs.contains(hostGroup.host) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                Text("SSH · 探测中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if hostGroup.connection.isOnline {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                if let ms = hostGroup.connection.latencyMs {
                    Text("SSH · \(ms) ms · \(hostGroup.totalSessionCount) 会话")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("SSH · 在线 · \(hostGroup.totalSessionCount) 会话")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 1.2)
                    .frame(width: 6, height: 6)
                Text("离线 · \(hostGroup.connection.errorMessage ?? "不可达")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .ssh(let alias) = hostGroup.host {
                    Button("终端登录") {
                        model.connectAndUnlockSSHHost(alias)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                Button("重连") {
                    if case .ssh(let alias) = hostGroup.host {
                        Task { await model.probeSingleSSHHost(alias: alias) }
                    } else {
                        Task { await model.refreshSSHHosts() }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func directorySection(_ dirGroup: DirectorySessionGroup, trackPanelVisibility: Bool = true) -> some View {
        let collapsed = model.isGroupCollapsed(dirGroup.id)
        let isPinned = model.isGroupPinned(dirGroup.id)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                if dirGroup.directory != nil {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.25, green: 0.62, blue: 0.96))
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Text(dirGroup.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                }

                Text(dirGroup.abbreviatedPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                directoryMiniCounts(dirGroup.sessions)
            }
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.toggleGroupCollapsed(dirGroup.id)
                }
            }
            .contextMenu {
                if dirGroup.directory != nil {
                    Button(isPinned ? "取消置顶此项目" : "置顶此项目") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            model.toggleGroupPinned(dirGroup.id)
                        }
                    }
                    Button("在 Finder 中打开目录") {
                        if let path = dirGroup.directory {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                    Divider()
                }
                Button(collapsed ? "展开此目录" : "折叠此目录") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.toggleGroupCollapsed(dirGroup.id)
                    }
                }
            }

            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(dirGroup.sessions) { session in
                        SessionRowView(
                            session: session,
                            isExpanded: model.expandedSessionIDs.contains(session.id),
                            model: model,
                            trackPanelVisibility: trackPanelVisibility
                        )
                    }
                }
                .padding(.leading, 22)
                .padding(.trailing, 8)
            }
        }
    }

    private func directoryMiniCounts(_ list: [AgentSession]) -> some View {
        let failCount = list.filter { $0.status == .failed }.count
        let appCount = list.filter { $0.status == .awaitingApproval }.count
        let doneCount = list.filter { $0.status == .completed }.count
        let genCount = list.filter { $0.status.isActiveWork && $0.status != .awaitingApproval }.count
        let restCount = list.count - failCount - appCount - doneCount - genCount

        return HStack(spacing: 5) {
            if failCount > 0 { miniDotCount(.failed, count: failCount) }
            if appCount > 0 { miniDotCount(.awaitingApproval, count: appCount) }
            if doneCount > 0 { miniDotCount(.completed, count: doneCount) }
            if genCount > 0 { miniDotCount(.generating, count: genCount) }
            if restCount > 0 && failCount == 0 && appCount == 0 && doneCount == 0 && genCount == 0 {
                miniDotCount(list.first?.status ?? .waitingForInput, count: restCount)
            }
        }
    }

    private func miniDotCount(_ status: SessionStatus, count: Int) -> some View {
        HStack(spacing: 2.5) {
            StatusDotView(status: status, size: 6)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var footerBar: some View {
        HStack {
            Text(model.todaySummaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(model.todaySummaryTooltip)

            Spacer()

            Button("设置") {
                onOpenSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }

    private func highRiskConfirmationSheet(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 20))
                Text("确认批准高风险操作？")
                    .font(.system(size: 14, weight: .bold))
            }
            Text("命中规则：\(session.pendingApproval?.highRiskMatchedRule ?? "")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(session.pendingApproval?.commandOrSummary ?? session.overview)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            HStack {
                Spacer()
                Button("取消") {
                    model.confirmingHighRiskSession = nil
                }
                .buttonStyle(.glass)
                Button("确认批准一次") {
                    model.requestApprove(session, bypassHighRiskCheck: true)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func denyReasonSheet(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("拒绝并向 Agent 说明原因")
                .font(.system(size: 14, weight: .bold))
            TextField("可选：例如“不要删除 .build，直接增量编译”", text: $model.denyReasonDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") {
                    model.denyingSession = nil
                }
                .buttonStyle(.glass)
                Button("发送拒绝") {
                    let reason = model.denyReasonDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.requestDeny(session, reason: reason.isEmpty ? nil : reason)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}
