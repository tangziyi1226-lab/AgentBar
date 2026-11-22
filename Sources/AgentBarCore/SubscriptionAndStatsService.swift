import Foundation

public struct QuotaWindowReading: Codable, Hashable, Sendable {
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct SubscriptionCardItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: AgentKind
    public var providerTitle: String
    public var planBadge: String
    public var subtitle: String
    public var quotas: [QuotaWindowReading]
    public var todayTokens: Int

    public init(
        id: String,
        kind: AgentKind,
        providerTitle: String,
        planBadge: String,
        subtitle: String,
        quotas: [QuotaWindowReading] = [],
        todayTokens: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.providerTitle = providerTitle
        self.planBadge = planBadge
        self.subtitle = subtitle
        self.quotas = quotas
        self.todayTokens = todayTokens
    }
}

public struct ToolBreakdownItem: Identifiable, Sendable {
    public var id: AgentKind { kind }
    public var kind: AgentKind
    public var sessionCount: Int
    public var totalTokens: Int
    public var share: Double
    public var estimatedCostUSD: Double
}

public struct ModelBreakdownItem: Identifiable, Sendable {
    public var id: String { modelName }
    public var modelName: String
    public var provider: String?
    public var sessionCount: Int
    public var totalTokens: Int
    public var cacheHitRate: Double?
    public var share: Double
}

public struct ProjectBreakdownItem: Identifiable, Sendable {
    public var id: String
    public var projectName: String
    public var abbreviatedPath: String
    public var hostTitle: String
    public var sessionCount: Int
    public var totalTokens: Int
    public var estimatedCostUSD: Double
    public var share: Double
}

public struct TotalAnalyticsSnapshot: Sendable {
    public var todayUsage: TokenUsage
    public var todaySessionCount: Int
    public var todayTurnCount: Int
    public var todayCostUSD: Double

    public var allUsage: TokenUsage
    public var allSessionCount: Int
    public var allTurnCount: Int
    public var allCostUSD: Double
    public var estimatedCacheSavingsUSD: Double
    public var totalToolCalls: Int
    public var successfulToolCalls: Int
    public var averageTokensPerSecond: Double?
    public var activeMemoryBytes: UInt64
    public var activeCPUPercent: Double
    public var activeProcessCount: Int

    public var byTool: [ToolBreakdownItem]
    public var byModel: [ModelBreakdownItem]
    public var byProject: [ProjectBreakdownItem]

    public var toolSuccessRate: Double? {
        guard totalToolCalls > 0 else { return nil }
        return Double(successfulToolCalls) / Double(totalToolCalls)
    }
}

public enum SubscriptionAndStatsService {
    public static func detectLocalSubscriptions(
        homeDirectory: String = NSHomeDirectory(),
        sessions: [AgentSession],
        antigravityPlan: String? = nil,
        antigravityQuotas: [QuotaWindowReading] = [],
        deepSeekAccount: DeepSeekAccountSnapshot? = nil
    ) -> [SubscriptionCardItem] {
        let uniqueSessions = SessionDeduplicator.deduplicate(sessions)
        let dayCutoff = Calendar.current.startOfDay(for: Date())
        let todaySessions = uniqueSessions.filter {
            $0.lastActivityAt >= dayCutoff || $0.effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens > 0
        }
        var items: [SubscriptionCardItem] = []

        if let codexCard = detectCodexSubscription(homeDirectory: homeDirectory, todaySessions: todaySessions, dayCutoff: dayCutoff) {
            items.append(codexCard)
        }
        if let claudeCard = detectClaudeSubscription(homeDirectory: homeDirectory, todaySessions: todaySessions, dayCutoff: dayCutoff) {
            items.append(claudeCard)
        }
        if let dshCard = detectDeepSeekSubscription(
            homeDirectory: homeDirectory,
            todaySessions: todaySessions,
            account: deepSeekAccount,
            dayCutoff: dayCutoff
        ) {
            items.append(dshCard)
        }
        if let antigravityCard = detectAntigravityCard(sessions: uniqueSessions, plan: antigravityPlan, quotas: antigravityQuotas) {
            items.append(antigravityCard)
        }
        return items
    }

    private static func detectAntigravityCard(
        sessions: [AgentSession], plan: String?, quotas: [QuotaWindowReading]
    ) -> SubscriptionCardItem? {
        let kind = AgentKind.antigravity
        let localSessions = sessions.filter { $0.host.isLocal && $0.kind == kind }
        let isInstalled = kind.fallbackAppPaths.contains { FileManager.default.fileExists(atPath: $0) }
        guard isInstalled || !localSessions.isEmpty || !quotas.isEmpty || plan != nil else { return nil }

        let recentCount = localSessions.count { $0.status != .runningProcessOnly }
        let status = recentCount > 0 ? "\(recentCount) 个近期会话" : "暂无近期会话摘要"
        return SubscriptionCardItem(
            id: "sub:antigravity",
            kind: kind,
            providerTitle: "Google · Antigravity",
            planBadge: plan ?? "本机",
            subtitle: quotas.isEmpty ? "\(status) · 暂无额度数据" : status,
            quotas: quotas
        )
    }

    private static func detectCodexSubscription(
        homeDirectory: String,
        todaySessions: [AgentSession],
        dayCutoff: Date
    ) -> SubscriptionCardItem? {
        let authPath = (homeDirectory as NSString).appendingPathComponent(".codex/auth.json")
        var planBadge: String?
        var activeUntilText: String?

        if let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let tokens = obj["tokens"] as? [String: Any],
               let idToken = tokens["id_token"] as? String,
               let claims = decodeJWTPayload(idToken) {
                let oa = claims["https://api.openai.com/auth"] as? [String: Any]
                if let rawPlan = (oa?["chatgpt_plan_type"] as? String)?.lowercased(), !rawPlan.isEmpty {
                    planBadge = formatChatGPTPlan(rawPlan)
                }
                if let untilStr = oa?["chatgpt_subscription_active_until"] as? String {
                    activeUntilText = formatShortRenewal(untilStr)
                }
            }
            if planBadge == nil, let apiKey = obj["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
                planBadge = "API Key"
            }
        }

        let quotas = readLatestCodexRateLimits(homeDirectory: homeDirectory)
        let codexTodayTokens = todaySessions
            .filter { $0.kind == .codexDesktop || $0.kind == .codexCLI }
            .reduce(0) { $0 + $1.effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens }

        guard planBadge != nil || !quotas.isEmpty || codexTodayTokens > 0 else {
            return nil
        }

        let defaultProvider = CodexAdapter.detectDefaultProvider(homeDirectory: homeDirectory)
        var subtitleParts: [String] = []
        if defaultProvider != "OpenAI" {
            subtitleParts.append("当前路由：\(defaultProvider)")
        }
        if let activeUntilText {
            subtitleParts.append("有效期至 \(activeUntilText)")
        }
        if subtitleParts.isEmpty {
            subtitleParts.append("今日 \(FormattingHelpers.compactTokens(codexTodayTokens)) tokens")
        }

        return SubscriptionCardItem(
            id: "sub:codex",
            kind: .codexDesktop,
            providerTitle: "OpenAI · Codex",
            planBadge: planBadge ?? "已配置",
            subtitle: subtitleParts.joined(separator: " · "),
            quotas: quotas,
            todayTokens: codexTodayTokens
        )
    }

    private static func readLatestCodexRateLimits(homeDirectory: String) -> [QuotaWindowReading] {
        let sessionsRoot = (homeDirectory as NSString).appendingPathComponent(".codex/sessions")
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let recentFiles = ClaudeCodeAdapter.collectRecentJSONLFiles(rootPath: sessionsRoot, cutoff: cutoff)

        for file in recentFiles.prefix(20) {
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { continue }
            let slice = data.suffix(120_000)
            let tailText = String(decoding: slice, as: UTF8.self)
            for line in tailText.split(whereSeparator: \.isNewline).reversed() {
                guard line.contains("\"rate_limits\""),
                      let lineData = String(line).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any] else {
                    continue
                }
                var windows: [QuotaWindowReading] = []
                if let primary = rl["primary"] as? [String: Any],
                   let pct = (primary["used_percent"] as? NSNumber)?.doubleValue {
                    let mins = (primary["window_minutes"] as? NSNumber)?.intValue ?? 300
                    let resetTS = (primary["resets_at"] as? NSNumber)?.doubleValue
                    let label = mins == 300 ? "5h 窗口" : "\(max(1, mins / 60))h 窗口"
                    windows.append(QuotaWindowReading(
                        label: label,
                        usedPercent: pct,
                        resetsAt: resetTS.map { Date(timeIntervalSince1970: $0) }
                    ))
                }
                if let secondary = rl["secondary"] as? [String: Any],
                   let pct = (secondary["used_percent"] as? NSNumber)?.doubleValue {
                    let mins = (secondary["window_minutes"] as? NSNumber)?.intValue ?? 10080
                    let resetTS = (secondary["resets_at"] as? NSNumber)?.doubleValue
                    let label = mins >= 10000 ? "7d 周额度" : "\(max(1, mins / 60))h 额度"
                    windows.append(QuotaWindowReading(
                        label: label,
                        usedPercent: pct,
                        resetsAt: resetTS.map { Date(timeIntervalSince1970: $0) }
                    ))
                }
                if !windows.isEmpty {
                    return windows
                }
            }
        }
        return []
    }

    private static func detectClaudeSubscription(
        homeDirectory: String,
        todaySessions: [AgentSession],
        dayCutoff: Date
    ) -> SubscriptionCardItem? {
        let claudeJSONPath = (homeDirectory as NSString).appendingPathComponent(".claude.json")
        let settingsPath = (homeDirectory as NSString).appendingPathComponent(".claude/settings.json")

        var planBadge: String?
        var endpointHost: String?
        var configuredModel: String?

        if let data = try? Data(contentsOf: URL(fileURLWithPath: claudeJSONPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let oauth = obj["oauthAccount"] as? [String: Any] {
                if let sub = oauth["subscriptionType"] as? String, !sub.isEmpty {
                    planBadge = "Claude \(sub.capitalized)"
                } else if let tier = oauth["rateLimitTier"] as? String, !tier.isEmpty {
                    planBadge = tier.contains("max") ? "Claude Max" : "Claude Pro"
                }
            }
            if let m = obj["model"] as? String, !m.isEmpty {
                configuredModel = m
            }
        }

        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = obj["model"] as? String, !m.isEmpty {
                configuredModel = m
            }
            if let env = obj["env"] as? [String: Any],
               let baseURL = env["ANTHROPIC_BASE_URL"] as? String,
               let host = URL(string: baseURL)?.host {
                endpointHost = host
                if planBadge == nil {
                    planBadge = "API Gateway"
                }
            }
        }

        let claudeTodayTokens = todaySessions
            .filter { $0.kind == .claudeCode || $0.kind == .claudeDesktop }
            .reduce(0) { $0 + $1.effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens }

        guard planBadge != nil || configuredModel != nil || claudeTodayTokens > 0 else {
            return nil
        }

        var subParts: [String] = []
        if let configuredModel {
            subParts.append(configuredModel)
        }
        if let endpointHost {
            subParts.append(endpointHost)
        }
        if subParts.isEmpty {
            subParts.append("今日 \(FormattingHelpers.compactTokens(claudeTodayTokens)) tokens")
        }

        return SubscriptionCardItem(
            id: "sub:claude",
            kind: .claudeCode,
            providerTitle: "Anthropic · Claude",
            planBadge: planBadge ?? "Claude Code",
            subtitle: subParts.joined(separator: " · "),
            quotas: [],
            todayTokens: claudeTodayTokens
        )
    }

    private static func detectDeepSeekSubscription(
        homeDirectory: String,
        todaySessions: [AgentSession],
        account: DeepSeekAccountSnapshot? = nil,
        dayCutoff: Date
    ) -> SubscriptionCardItem? {
        let dshDir = DeepSeekAccountUsageService.resolveDSHHome(homeDirectory: homeDirectory)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dshDir, isDirectory: &isDir) && isDir.boolValue
        let hasStoredCreds = DeepSeekAccountUsageService.hasStoredCredentials(homeDirectory: homeDirectory)
        let dshTodayTokens = todaySessions
            .filter { $0.kind == .deepseekHarness || $0.kind == .deepseekChat }
            .reduce(0) { $0 + $1.effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens }
        guard exists || hasStoredCreds || dshTodayTokens > 0 || account != nil else { return nil }

        var planBadge = hasStoredCreds ? "DeepSeek 账号" : "API 计费"
        var subtitle = "今日 \(FormattingHelpers.compactTokens(dshTodayTokens)) tokens"
        var quotas: [QuotaWindowReading] = []

        if let account {
            switch account.status {
            case .ready:
                let balText = account.primaryFormattedBalance
                planBadge = account.isZeroOrNegativeBalance ? "无可用余额" : "余额 \(balText)"
                if let primary = account.primaryWallet {
                    var parts: [String] = []
                    let normStr = DeepSeekAccountUsageService.formatBalance(primary.normalBalance, symbol: primary.symbol)
                    parts.append("充值 \(normStr)")
                    if primary.bonusBalance > 0 {
                        let bonusStr = DeepSeekAccountUsageService.formatBalance(primary.bonusBalance, symbol: primary.symbol)
                        parts.append("赠金 \(bonusStr)")
                    }
                    if primary.totalCost > 0 {
                        let costStr = DeepSeekAccountUsageService.formatBalance(primary.totalCost, symbol: primary.symbol)
                        parts.append("累计消耗 \(costStr)")
                    }
                    subtitle = parts.joined(separator: " · ")
                }
                if let usedFrac = account.primaryUsedFraction {
                    quotas = [QuotaWindowReading(label: "账户消耗", usedPercent: usedFrac * 100.0)]
                }
            case .expired:
                planBadge = "登录已过期"
                subtitle = "请在 DeepSeek Harness 重新登录以同步余额"
            case .signedOut:
                planBadge = "未登录账号"
                subtitle = dshTodayTokens > 0
                    ? "今日 \(FormattingHelpers.compactTokens(dshTodayTokens)) tokens · 登录后显示余额"
                    : "在 DeepSeek Harness 登录后自动同步余额"
            case .failed:
                break
            }
        }

        return SubscriptionCardItem(
            id: "sub:deepseek",
            kind: .deepseekHarness,
            providerTitle: "DeepSeek · Harness",
            planBadge: planBadge,
            subtitle: subtitle,
            quotas: quotas,
            todayTokens: dshTodayTokens
        )
    }

    public static func buildAnalytics(
        sessions: [AgentSession],
        demoMode: Bool = false,
        homeByHost: [HostID: String] = [:]
    ) -> TotalAnalyticsSnapshot {
        let uniqueSessions = SessionDeduplicator.deduplicate(sessions)
        let dayCutoff = Calendar.current.startOfDay(for: Date())
        var todayUsage = TokenUsage()
        var todaySessionCount = 0
        var todayTurnCount = 0
        var todayCost = 0.0

        var allUsage = TokenUsage()
        var allTurnCount = 0
        var allCost = 0.0
        var cacheSavings = 0.0
        var totalTools = 0
        var okTools = 0
        var tpsSum = 0.0
        var tpsCount = 0

        var seenPIDs: Set<Int32> = []
        var activeMem: UInt64 = 0
        var activeCPU = 0.0

        var toolBuckets: [AgentKind: (count: Int, tok: Int, cost: Double)] = [:]
        var modelBuckets: [String: (provider: String?, count: Int, usage: TokenUsage)] = [:]
        var projBuckets: [String: (name: String, abbr: String, hostTitle: String, count: Int, tok: Int, cost: Double)] = [:]

        for s in uniqueSessions {
            let sCost = PricingCatalog.estimatedCostUSD(for: s) ?? 0
            if let perModel = s.modelUsages, !perModel.isEmpty {
                var attributed = TokenUsage()
                for (mName, mUsage) in perModel {
                    attributed = attributed.adding(mUsage)
                    if mUsage.cacheRead > 0, let mRule = PricingCatalog.rule(for: mName, provider: s.provider) {
                        cacheSavings += (Double(mUsage.cacheRead) / 1_000_000.0) * max(0, mRule.inputPerMillionUSD - mRule.cacheReadPerMillionUSD)
                    }
                }
                let rem = s.usage.subtractingClamped(attributed)
                if rem.cacheRead > 0, let remRule = PricingCatalog.rule(for: s.model, provider: s.provider) {
                    cacheSavings += (Double(rem.cacheRead) / 1_000_000.0) * max(0, remRule.inputPerMillionUSD - remRule.cacheReadPerMillionUSD)
                }
            } else if let rule = PricingCatalog.rule(for: s.model, provider: s.provider), s.usage.cacheRead > 0 {
                let saved = (Double(s.usage.cacheRead) / 1_000_000.0) * max(0, rule.inputPerMillionUSD - rule.cacheReadPerMillionUSD)
                cacheSavings += saved
            }

            allUsage.input += s.usage.input
            allUsage.output += s.usage.output
            allUsage.cacheRead += s.usage.cacheRead
            allUsage.cacheWrite += s.usage.cacheWrite
            allUsage.reasoning += s.usage.reasoning
            allTurnCount += s.turnCount
            allCost += sCost
            totalTools += s.totalToolCalls
            okTools += s.successfulToolCalls

            if let tps = s.outputTokensPerSecond, tps > 0 {
                tpsSum += tps
                tpsCount += 1
            }
            if let proc = s.process, seenPIDs.insert(proc.pid).inserted {
                activeMem += proc.memoryBytes
                activeCPU += proc.cpuPercent
            }

            let sToday = s.effectiveTodayUsage(dayCutoff: dayCutoff, demoMode: demoMode)
            if demoMode || sToday.totalTokens > 0 || s.lastActivityAt >= dayCutoff {
                todaySessionCount += 1
                todayTurnCount += demoMode ? s.turnCount : (s.todayTurnCount ?? (s.startedAt >= dayCutoff ? s.turnCount : 0))
                todayCost += PricingCatalog.estimatedTodayCostUSD(for: s, dayCutoff: dayCutoff, demoMode: demoMode) ?? 0
                todayUsage = todayUsage.adding(sToday)
            }

            var tb = toolBuckets[s.kind] ?? (0, 0, 0)
            tb.count += 1
            tb.tok += s.usage.totalTokens
            tb.cost += sCost
            toolBuckets[s.kind] = tb

            if let perModel = s.modelUsages, !perModel.isEmpty {
                var attributed = TokenUsage()
                for (mName, mUsage) in perModel where !mName.isEmpty && mUsage.totalTokens > 0 {
                    attributed = attributed.adding(mUsage)
                    var mb = modelBuckets[mName] ?? (s.provider, 0, TokenUsage())
                    mb.count += 1
                    mb.usage = mb.usage.adding(mUsage)
                    modelBuckets[mName] = mb
                }
                let rem = s.usage.subtractingClamped(attributed)
                if rem.totalTokens > 0, let rawModel = s.model, !rawModel.isEmpty {
                    var mb = modelBuckets[rawModel] ?? (s.provider, 0, TokenUsage())
                    if perModel[rawModel] == nil { mb.count += 1 }
                    mb.usage = mb.usage.adding(rem)
                    modelBuckets[rawModel] = mb
                }
            } else if let rawModel = s.model, !rawModel.isEmpty {
                var mb = modelBuckets[rawModel] ?? (s.provider, 0, TokenUsage())
                mb.count += 1
                mb.usage = mb.usage.adding(s.usage)
                modelBuckets[rawModel] = mb
            }

            if let dir = s.groupDirectory ?? s.cwd, !dir.isEmpty {
                let key = "\(s.host.storageKey)::\(dir)"
                let hostHome = s.host.isLocal ? NSHomeDirectory() : (homeByHost[s.host] ?? "")
                let name = URL(fileURLWithPath: dir).lastPathComponent
                let abbr = hostHome.isEmpty ? dir : FormattingHelpers.abbreviateHome(dir, home: hostHome)
                let shortHost = s.host.isLocal ? "本机" : s.host.displayTitle
                var pb = projBuckets[key] ?? (name, abbr, shortHost, 0, 0, 0)
                pb.count += 1
                pb.tok += s.usage.totalTokens
                pb.cost += sCost
                projBuckets[key] = pb
            }
        }

        let grandTok = max(1, allUsage.totalTokens)
        let byTool = toolBuckets.map { kind, val in
            ToolBreakdownItem(
                kind: kind,
                sessionCount: val.count,
                totalTokens: val.tok,
                share: Double(val.tok) / Double(grandTok),
                estimatedCostUSD: val.cost
            )
        }.sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.sessionCount > rhs.sessionCount
        }

        let byModel = modelBuckets.map { modelName, val in
            ModelBreakdownItem(
                modelName: modelName,
                provider: val.provider,
                sessionCount: val.count,
                totalTokens: val.usage.totalTokens,
                cacheHitRate: val.usage.cacheHitRate,
                share: Double(val.usage.totalTokens) / Double(grandTok)
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        let byProject = projBuckets.map { key, val in
            ProjectBreakdownItem(
                id: key,
                projectName: val.name,
                abbreviatedPath: val.abbr,
                hostTitle: val.hostTitle,
                sessionCount: val.count,
                totalTokens: val.tok,
                estimatedCostUSD: val.cost,
                share: Double(val.tok) / Double(grandTok)
            )
        }.sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.sessionCount > rhs.sessionCount
        }

        return TotalAnalyticsSnapshot(
            todayUsage: todayUsage,
            todaySessionCount: todaySessionCount,
            todayTurnCount: todayTurnCount,
            todayCostUSD: todayCost,
            allUsage: allUsage,
            allSessionCount: uniqueSessions.count,
            allTurnCount: allTurnCount,
            allCostUSD: allCost,
            estimatedCacheSavingsUSD: cacheSavings,
            totalToolCalls: totalTools,
            successfulToolCalls: okTools,
            averageTokensPerSecond: tpsCount > 0 ? (tpsSum / Double(tpsCount)) : nil,
            activeMemoryBytes: activeMem,
            activeCPUPercent: activeCPU,
            activeProcessCount: seenPIDs.count,
            byTool: byTool,
            byModel: Array(byModel.prefix(6)),
            byProject: Array(byProject.prefix(6))
        )
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func formatChatGPTPlan(_ raw: String) -> String {
        switch raw {
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "team": return "ChatGPT Team"
        case "enterprise": return "ChatGPT Enterprise"
        case "edu": return "ChatGPT Edu"
        case "free": return "ChatGPT Free"
        default: return "ChatGPT \(raw.capitalized)"
        }
    }

    private static func formatShortRenewal(_ isoString: String) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString)
        guard let date else { return nil }
        let df = DateFormatter()
        df.dateFormat = "MM-dd"
        return df.string(from: date)
    }
}
