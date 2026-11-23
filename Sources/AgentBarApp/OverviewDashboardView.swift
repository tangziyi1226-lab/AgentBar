import AgentBarCore
import SwiftUI

struct OverviewDashboardView: View {
    @Bindable var model: AppModel
    let onOpenDashboardSettings: () -> Void

    var body: some View {
        let stats = model.totalAnalytics
        return VStack(alignment: .leading, spacing: 12) {
            subscriptionsAndDashboardsSection
            todayHeroCard(stats)
            efficiencyGrid(stats)
            if !stats.byModel.isEmpty {
                modelBreakdownSection(stats.byModel)
            }
            if !stats.byProject.isEmpty {
                projectBreakdownSection(stats.byProject)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var subscriptionsAndDashboardsSection: some View {
        let mins = Int(max(1, round(model.dashboardRefreshIntervalSeconds / 60.0)))
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("订阅会员 & Dashboard", systemImage: "sparkles.tv")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Menu {
                    Section("Dashboard 自动刷新频率") {
                        ForEach([60.0, 180.0, 300.0, 900.0], id: \.self) { sec in
                            let label = "每 \(Int(sec / 60)) 分钟自动刷新"
                            Button {
                                model.dashboardRefreshIntervalSeconds = sec
                            } label: {
                                if abs(model.dashboardRefreshIntervalSeconds - sec) < 1 {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("立即刷新 Dashboard 额度") {
                        Task { await model.refreshBalances(silent: false) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: model.isRefreshingBalances ? "arrow.trianglehead.2.clockwise" : "clock.arrow.circlepath")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(model.isRefreshingBalances ? "刷新中…" : "自动 \(mins)m")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                .menuStyle(.button)
                .controlSize(.mini)
                .buttonStyle(.glass)
                .help("后台每 \(mins) 分钟自动刷新一次 Dashboard 额度，点击可调整频率或立即刷新")

                Button {
                    onOpenDashboardSettings()
                } label: {
                    Text("+ 配置看板")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .controlSize(.mini)
                .buttonStyle(.glass)
            }

            if !model.balanceReadings.isEmpty {
                let cols = min(2, max(1, model.balanceReadings.count))
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

            if !model.subscriptionCards.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.subscriptionCards) { sub in
                        subscriptionRowCard(sub)
                    }
                }
            }
        }
    }

    private func subscriptionRowCard(_ sub: SubscriptionCardItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentLogoView(kind: sub.kind, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(sub.providerTitle)
                            .font(.system(size: 12, weight: .semibold))
                        Text(sub.planBadge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                    Text(sub.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if sub.todayTokens > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("今日")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        Text(FormattingHelpers.compactTokens(sub.todayTokens))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }

            if !sub.quotas.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(sub.quotas.enumerated()), id: \.offset) { _, quota in
                        quotaProgressBar(quota, labelWidth: sub.kind == .antigravity ? 142 : 58)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    private func quotaProgressBar(_ quota: QuotaWindowReading, labelWidth: CGFloat) -> some View {
        let frac = min(1.0, max(0.0, quota.usedPercent / 100.0))
        let resetText = quota.resetsAt.map { formatResetTime($0) } ?? ""
        return HStack(spacing: 7) {
            Text(quota.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(quota.label)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(frac > 0.8 ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 4.5)
            Text(String(format: "已用 %.0f%%", quota.usedPercent) + (resetText.isEmpty ? "" : " · \(resetText)"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func todayHeroCard(_ stats: TotalAnalyticsSnapshot) -> some View {
        let hitText = stats.todayUsage.cacheHitRate.map { String(format: "%.0f%%", $0 * 100.0) } ?? "—"
        let netIO = FormattingHelpers.compactTokens(stats.todayUsage.uncachedInputOutputTokens)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日会话日志（净输入+输出 \(netIO)）")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(FormattingHelpers.compactTokens(stats.todayUsage.totalTokens))
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("tokens（含缓存）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "API 等值 $%.2f", stats.todayCostUSD))
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("\(stats.todaySessionCount) 个活跃会话 · \(stats.todayTurnCount) 轮 · 缓存 \(hitText)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 5) {
                miniStatPill(label: "输入", value: FormattingHelpers.compactTokens(stats.todayUsage.input))
                miniStatPill(label: "输出", value: FormattingHelpers.compactTokens(stats.todayUsage.output))
                miniStatPill(label: "缓存读", value: FormattingHelpers.compactTokens(stats.todayUsage.cacheRead))
                miniStatPill(
                    label: stats.todayUsage.cacheWrite > 0 ? "缓存写" : "推理",
                    value: FormattingHelpers.compactTokens(
                        stats.todayUsage.cacheWrite > 0 ? stats.todayUsage.cacheWrite : stats.todayUsage.reasoning
                    )
                )
            }
        }
        .padding(11)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func miniStatPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.36)))
    }

    private func efficiencyGrid(_ stats: TotalAnalyticsSnapshot) -> some View {
        let allHit = stats.allUsage.cacheHitRate.map { String(format: "%.0f%%", $0 * 100.0) } ?? "—"
        let toolRate = stats.toolSuccessRate.map { String(format: "%.1f%%", $0 * 100.0) } ?? "—"
        let tpsText = stats.averageTokensPerSecond.map { String(format: "均速 %.0f tok/s", $0) } ?? "暂无速率采样"
        let memText = stats.activeMemoryBytes > 0 ? FormattingHelpers.memoryString(stats.activeMemoryBytes) : "0 MB"

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
            kpiTile(
                title: "近期活跃会话的历史总量",
                value: FormattingHelpers.compactTokens(stats.allUsage.totalTokens),
                subtitle: String(
                    format: "净 %@ · %d 会话 · $%.2f",
                    FormattingHelpers.compactTokens(stats.allUsage.uncachedInputOutputTokens),
                    stats.allSessionCount,
                    stats.allCostUSD
                )
            )
            kpiTile(
                title: "Prompt 缓存节省",
                value: String(format: "$%.2f", stats.estimatedCacheSavingsUSD),
                subtitle: "全局缓存命中率 \(allHit)"
            )
            kpiTile(
                title: "工具调用成功率",
                value: toolRate,
                subtitle: "\(stats.successfulToolCalls)/\(stats.totalToolCalls) 次 · \(tpsText)"
            )
            kpiTile(
                title: "活跃 Agent 资源占用",
                value: memText,
                subtitle: String(format: "%d 个运行进程 · CPU %.1f%%", stats.activeProcessCount, stats.activeCPUPercent)
            )
        }
    }

    private func kpiTile(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.48), lineWidth: 0.5)
                )
        )
    }

    private func modelBreakdownSection(_ items: [ModelBreakdownItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("模型排行 · 活跃会话历史总量", systemImage: "cube.transparent")
                .font(.system(size: 12, weight: .bold))

            VStack(spacing: 5) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Text(item.modelName)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if let hit = item.cacheHitRate {
                            Text(String(format: "缓存 %.0f%%", hit * 100.0))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(FormattingHelpers.compactTokens(item.totalTokens))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.26)))
        }
    }

    private func projectBreakdownSection(_ items: [ProjectBreakdownItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("目录排行 · 活跃会话历史总量", systemImage: "folder.badge.gearshape")
                .font(.system(size: 12, weight: .bold))

            VStack(spacing: 5) {
                ForEach(items) { item in
                    HStack(spacing: 7) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.25, green: 0.62, blue: 0.96))
                        Text(item.projectName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        Text("· \(item.hostTitle)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(item.sessionCount) 会话")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(FormattingHelpers.compactTokens(item.totalTokens))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.26)))
        }
    }

    private func formatResetTime(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "即将重置" }
        if diff < 3600 {
            return "\(max(1, Int(diff / 60)))m 后重置"
        }
        if diff < 24 * 3600 {
            return "\(Int(diff / 3600))h 后重置"
        }
        let df = DateFormatter()
        df.dateFormat = "MM/dd 重置"
        return df.string(from: date)
    }
}
