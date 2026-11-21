import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case claudeDesktop
    case codexCLI
    case codexDesktop
    case deepseekHarness
    case deepseekChat
    case doubao
    case cursor
    case trae
    case antigravity
    case generic

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code CLI"
        case .claudeDesktop: return "Claude 桌面版"
        case .codexCLI: return "Codex CLI"
        case .codexDesktop: return "Codex 桌面版"
        case .deepseekHarness: return "DeepSeek Harness"
        case .deepseekChat: return "DeepSeek 对话"
        case .doubao: return "豆包"
        case .cursor: return "Cursor"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .generic: return "Agent"
        }
    }

    public var isCLI: Bool {
        switch self {
        case .claudeCode, .codexCLI:
            return true
        default:
            return false
        }
    }

    public var isChatOnly: Bool {
        switch self {
        case .doubao, .deepseekChat:
            return true
        default:
            return false
        }
    }

    public var preferredBundleIdentifiers: [String] {
        switch self {
        case .claudeCode, .claudeDesktop:
            return ["com.anthropic.claudefordesktop"]
        case .codexCLI, .codexDesktop:
            return ["com.openai.codex", "com.openai.chat"]
        case .deepseekHarness, .deepseekChat:
            return ["com.deepseek.dsh", "com.deepseek.chat"]
        case .doubao:
            return ["com.bot.neotix.doubao", "com.bytedance.doubao"]
        case .cursor:
            return ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
        case .trae:
            return ["com.bytedance.trae", "cn.trae.app", "com.marscode.ide"]
        case .antigravity:
            return ["com.google.antigravity"]
        case .generic:
            return ["com.apple.Terminal"]
        }
    }

    public var fallbackAppPaths: [String] {
        switch self {
        case .claudeCode, .claudeDesktop:
            return ["/Applications/Claude.app"]
        case .codexCLI, .codexDesktop:
            return ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
        case .deepseekHarness, .deepseekChat:
            return ["/Applications/DeepSeek Harness.app", "/Applications/DeepSeek.app"]
        case .doubao:
            return ["/Applications/Doubao.app", "/Applications/豆包.app"]
        case .cursor:
            return ["/Applications/Cursor.app"]
        case .trae:
            return ["/Applications/Trae.app", "/Applications/Trae CN.app"]
        case .antigravity:
            return ["/Applications/Antigravity.app"]
        case .generic:
            return ["/System/Applications/Utilities/Terminal.app"]
        }
    }

    public var fallbackMonogram: String {
        switch self {
        case .claudeCode, .claudeDesktop: return "C"
        case .codexCLI, .codexDesktop: return "Cx"
        case .deepseekHarness, .deepseekChat: return "DS"
        case .doubao: return "豆"
        case .cursor: return "Cu"
        case .trae: return "T"
        case .antigravity: return "AG"
        case .generic: return ">_"
        }
    }
}

public enum SessionLaunchEnvironment: String, Codable, Hashable, Sendable {
    case auto
    case terminalCLI
    case codexApp
    case vscodeExtension
    case cursorExtension
    case traeExtension
    case deepseekHarnessApp
}

public enum HostID: Hashable, Codable, Sendable {
    case local
    case ssh(alias: String)

    public var storageKey: String {
        switch self {
        case .local: return "local"
        case .ssh(let alias): return "ssh:\(alias)"
        }
    }

    public var displayTitle: String {
        switch self {
        case .local:
            if ProcessInfo.processInfo.environment["AGENTBAR_GENERIC_HOSTNAME"] == "1" {
                return "本机 · MacBook Pro"
            }
            let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            return "本机 · \(host)"
        case .ssh(let alias):
            return alias
        }
    }

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

public struct HostConnectionState: Codable, Hashable, Sendable {
    public var host: HostID
    public var isOnline: Bool
    public var latencyMs: Int?
    public var errorMessage: String?
    public var updatedAt: Date

    public init(
        host: HostID,
        isOnline: Bool = true,
        latencyMs: Int? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.host = host
        self.isOnline = isOnline
        self.latencyMs = latencyMs
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

public enum SessionStatus: Int, Codable, CaseIterable, Sendable, Comparable {
    case failed = 0
    case awaitingApproval = 1
    case completed = 2
    case runningTool = 3
    case generating = 4
    case waitingForInput = 5
    case runningProcessOnly = 6
    case idle = 7
    case offline = 8

    public static func < (lhs: SessionStatus, rhs: SessionStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .failed: return "失败"
        case .awaitingApproval: return "待审批"
        case .completed: return "已完成"
        case .runningTool: return "运行工具"
        case .generating: return "生成中"
        case .waitingForInput: return "等待输入"
        case .runningProcessOnly: return "运行中"
        case .idle: return "空闲"
        case .offline: return "离线"
        }
    }

    public var isActiveWork: Bool {
        switch self {
        case .generating, .runningTool, .awaitingApproval:
            return true
        default:
            return false
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .failed, .awaitingApproval:
            return true
        default:
            return false
        }
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public var totalPromptTokens: Int {
        input + cacheRead + cacheWrite
    }

    public var totalTokens: Int {
        input + output + cacheRead + cacheWrite
    }

    public var uncachedInputOutputTokens: Int {
        input + output
    }

    public var cacheHitRate: Double? {
        let denom = input + cacheRead + cacheWrite
        guard denom > 0 else { return nil }
        return Double(cacheRead) / Double(denom)
    }

    public func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: input + other.input,
            output: output + other.output,
            cacheRead: cacheRead + other.cacheRead,
            cacheWrite: cacheWrite + other.cacheWrite,
            reasoning: reasoning + other.reasoning
        )
    }

    public func subtractingClamped(_ baseline: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(0, input - baseline.input),
            output: max(0, output - baseline.output),
            cacheRead: max(0, cacheRead - baseline.cacheRead),
            cacheWrite: max(0, cacheWrite - baseline.cacheWrite),
            reasoning: max(0, reasoning - baseline.reasoning)
        )
    }

    public static func componentMax(_ lhs: TokenUsage, _ rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(lhs.input, rhs.input),
            output: max(lhs.output, rhs.output),
            cacheRead: max(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: max(lhs.cacheWrite, rhs.cacheWrite),
            reasoning: max(lhs.reasoning, rhs.reasoning)
        )
    }
}

public struct ToolCallRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var summary: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var isError: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isError = isError
    }

    public var durationSeconds: TimeInterval? {
        guard let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }
}

public struct ProcessStats: Codable, Hashable, Sendable {
    public var pid: Int32
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    public var tty: String?
    public var cwd: String?
    public var command: String
    public var sessionID: String?
    public var entrypoint: String?
    public var tmuxTarget: String?

    public init(
        pid: Int32,
        memoryBytes: UInt64,
        cpuPercent: Double,
        tty: String? = nil,
        cwd: String? = nil,
        command: String = "",
        sessionID: String? = nil,
        entrypoint: String? = nil,
        tmuxTarget: String? = nil
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.entrypoint = entrypoint
        self.tmuxTarget = tmuxTarget
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.tty = tty
        self.cwd = cwd
        self.command = command
    }
}

public struct PendingApproval: Codable, Hashable, Sendable {
    public var requestID: String
    public var sessionID: String?
    public var host: HostID
    public var toolName: String
    public var commandOrSummary: String
    public var cwd: String?
    public var requestedAt: Date
    public var canRespondViaHook: Bool
    public var highRiskMatchedRule: String?

    public init(
        requestID: String,
        sessionID: String? = nil,
        host: HostID = .local,
        toolName: String,
        commandOrSummary: String,
        cwd: String? = nil,
        requestedAt: Date = Date(),
        canRespondViaHook: Bool = true,
        highRiskMatchedRule: String? = nil
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.host = host
        self.toolName = toolName
        self.commandOrSummary = commandOrSummary
        self.cwd = cwd
        self.requestedAt = requestedAt
        self.canRespondViaHook = canRespondViaHook
        self.highRiskMatchedRule = highRiskMatchedRule
    }
}

public struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var rawSessionID: String
    public var kind: AgentKind
    public var host: HostID
    public var title: String
    public var overview: String
    public var status: SessionStatus
    public var statusIsInferred: Bool
    public var cwd: String?
    public var groupDirectory: String?
    public var provider: String?
    public var model: String?
    public var reasoningEffort: String?
    public var usage: TokenUsage
    public var todayUsage: TokenUsage?
    public var modelUsages: [String: TokenUsage]?
    public var todayModelUsages: [String: TokenUsage]?
    public var isForkedCodex: Bool?
    public var hasShardScopedToday: Bool?
    public var mergedShardPaths: Set<String>?
    public var contextUsedTokens: Int?
    public var contextWindow: Int?
    public var currentTool: ToolCallRecord?
    public var recentTools: [ToolCallRecord]
    public var totalToolCalls: Int
    public var successfulToolCalls: Int
    public var turnCount: Int
    public var compactCount: Int
    public var outputTokensPerSecond: Double?
    public var process: ProcessStats?
    public var pendingApproval: PendingApproval?
    public var lastOutputMarkdown: String?
    public var errorBanner: String?
    public var sourceFilePath: String?
    public var launchEnvironment: SessionLaunchEnvironment
    public var startedAt: Date
    public var lastActivityAt: Date
    public var isSeen: Bool
    /// Time of the latest assistant output; unseen state is judged against this rather than file mtime.
    public var lastGeneratedAt: Date?

    public init(
        id: String,
        rawSessionID: String,
        kind: AgentKind,
        host: HostID = .local,
        title: String,
        overview: String,
        status: SessionStatus,
        statusIsInferred: Bool = false,
        cwd: String? = nil,
        groupDirectory: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        usage: TokenUsage = TokenUsage(),
        todayUsage: TokenUsage? = nil,
        modelUsages: [String: TokenUsage]? = nil,
        todayModelUsages: [String: TokenUsage]? = nil,
        isForkedCodex: Bool? = nil,
        hasShardScopedToday: Bool? = nil,
        mergedShardPaths: Set<String>? = nil,
        contextUsedTokens: Int? = nil,
        contextWindow: Int? = nil,
        currentTool: ToolCallRecord? = nil,
        recentTools: [ToolCallRecord] = [],
        totalToolCalls: Int = 0,
        successfulToolCalls: Int = 0,
        turnCount: Int = 0,
        compactCount: Int = 0,
        outputTokensPerSecond: Double? = nil,
        process: ProcessStats? = nil,
        pendingApproval: PendingApproval? = nil,
        lastOutputMarkdown: String? = nil,
        errorBanner: String? = nil,
        sourceFilePath: String? = nil,
        launchEnvironment: SessionLaunchEnvironment = .auto,
        startedAt: Date = Date(),
        lastActivityAt: Date = Date(),
        isSeen: Bool = false,
        lastGeneratedAt: Date? = nil
    ) {
        self.id = id
        self.rawSessionID = rawSessionID
        self.kind = kind
        self.host = host
        self.title = title
        self.overview = overview
        self.status = status
        self.statusIsInferred = statusIsInferred
        self.cwd = cwd
        self.groupDirectory = groupDirectory
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.usage = usage
        self.todayUsage = todayUsage
        self.modelUsages = modelUsages
        self.todayModelUsages = todayModelUsages
        self.isForkedCodex = isForkedCodex
        self.hasShardScopedToday = hasShardScopedToday
        self.mergedShardPaths = mergedShardPaths
        self.contextUsedTokens = contextUsedTokens
        self.contextWindow = contextWindow
        self.currentTool = currentTool
        self.recentTools = recentTools
        self.totalToolCalls = totalToolCalls
        self.successfulToolCalls = successfulToolCalls
        self.turnCount = turnCount
        self.compactCount = compactCount
        self.outputTokensPerSecond = outputTokensPerSecond
        self.process = process
        self.pendingApproval = pendingApproval
        self.lastOutputMarkdown = lastOutputMarkdown
        self.errorBanner = errorBanner
        self.sourceFilePath = sourceFilePath
        self.launchEnvironment = launchEnvironment
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.isSeen = isSeen
        self.lastGeneratedAt = lastGeneratedAt
    }

    public var seenBaselineAt: Date {
        lastGeneratedAt ?? lastActivityAt
    }

    public func effectiveTodayUsage(
        dayCutoff: Date = Calendar.current.startOfDay(for: Date()),
        demoMode: Bool = false
    ) -> TokenUsage {
        if demoMode {
            return usage
        }
        if let todayUsage {
            return todayUsage
        }
        return lastActivityAt >= dayCutoff ? usage : TokenUsage()
    }

    public mutating func rollUpChildUsage(
        _ child: AgentSession,
        dayCutoff: Date = Calendar.current.startOfDay(for: Date())
    ) {
        guard child.usage.totalTokens > 0 else { return }
        let parentToday = effectiveTodayUsage(dayCutoff: dayCutoff)
        let childToday = child.effectiveTodayUsage(dayCutoff: dayCutoff)

        let seededParentModels: [String: TokenUsage]? = {
            if let modelUsages, !modelUsages.isEmpty { return modelUsages }
            if let m = model, !m.isEmpty, usage.totalTokens > 0 { return [m: usage] }
            return nil
        }()
        let seededChildModels: [String: TokenUsage]? = {
            if let mMap = child.modelUsages, !mMap.isEmpty { return mMap }
            if let m = child.model, !m.isEmpty, child.usage.totalTokens > 0 { return [m: child.usage] }
            return nil
        }()
        let seededParentTodayModels: [String: TokenUsage]? = {
            if let todayModelUsages, !todayModelUsages.isEmpty { return todayModelUsages }
            if let m = model, !m.isEmpty, parentToday.totalTokens > 0 { return [m: parentToday] }
            return nil
        }()
        let seededChildTodayModels: [String: TokenUsage]? = {
            if let mMap = child.todayModelUsages, !mMap.isEmpty { return mMap }
            if let m = child.model, !m.isEmpty, childToday.totalTokens > 0 { return [m: childToday] }
            return nil
        }()

        usage = usage.adding(child.usage)
        todayUsage = parentToday.adding(childToday)
        modelUsages = SessionDeduplicator.mergeModelUsageMaps(seededParentModels, seededChildModels, additive: true)
        todayModelUsages = SessionDeduplicator.mergeModelUsageMaps(
            seededParentTodayModels,
            seededChildTodayModels,
            additive: true
        )
    }

    public var contextRatio: Double? {
        guard let used = contextUsedTokens, let window = contextWindow, window > 0 else {
            return nil
        }
        return min(1.0, max(0.0, Double(used) / Double(window)))
    }

    public var resumeCommand: String? {
        switch kind {
        case .claudeCode:
            return "claude --resume \(rawSessionID)"
        case .codexCLI, .codexDesktop:
            return "codex resume \(rawSessionID)"
        default:
            return nil
        }
    }
}

public struct DirectorySessionGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var host: HostID
    public var directory: String?
    public var displayName: String
    public var abbreviatedPath: String
    public var sessions: [AgentSession]

    public init(
        host: HostID,
        directory: String?,
        displayName: String,
        abbreviatedPath: String,
        sessions: [AgentSession]
    ) {
        self.id = "\(host.storageKey)::\(directory ?? "__chat__")"
        self.host = host
        self.directory = directory
        self.displayName = displayName
        self.abbreviatedPath = abbreviatedPath
        self.sessions = sessions
    }

    public var mostUrgentStatus: SessionStatus {
        sessions.map(\.status).min() ?? .idle
    }

    public var lastActivityAt: Date {
        sessions.map(\.lastActivityAt).max() ?? .distantPast
    }

    public var totalTokens: Int {
        sessions.reduce(0) { $0 + $1.usage.totalTokens }
    }
}

public struct HostSessionGroup: Identifiable, Hashable, Sendable {
    public var id: String { host.storageKey }
    public var host: HostID
    public var connection: HostConnectionState
    public var directories: [DirectorySessionGroup]
    public var looseSessions: [AgentSession]

    public init(
        host: HostID,
        connection: HostConnectionState,
        directories: [DirectorySessionGroup],
        looseSessions: [AgentSession] = []
    ) {
        self.host = host
        self.connection = connection
        self.directories = directories
        self.looseSessions = looseSessions
    }

    public var isEmpty: Bool {
        directories.isEmpty && looseSessions.isEmpty
    }

    public var totalSessionCount: Int {
        directories.reduce(0) { $0 + $1.sessions.count } + looseSessions.count
    }

    public var mostUrgentStatus: SessionStatus {
        let dirMin = directories.map(\.mostUrgentStatus).min()
        let looseMin = looseSessions.map(\.status).min()
        switch (dirMin, looseMin) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return .idle
        }
    }

    public var lastActivityAt: Date {
        let dirMax = directories.map(\.lastActivityAt).max() ?? .distantPast
        let looseMax = looseSessions.map(\.lastActivityAt).max() ?? .distantPast
        return max(dirMax, looseMax)
    }

    public var totalTokens: Int {
        directories.reduce(0) { $0 + $1.totalTokens } + looseSessions.reduce(0) { $0 + $1.usage.totalTokens }
    }
}

public enum StatusCategoryFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case running
    case completedUnseen
    case awaitingApproval
    case failed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .running: return "运行中"
        case .completedUnseen: return "新生成"
        case .awaitingApproval: return "待审批"
        case .failed: return "错误"
        }
    }

    public var representativeStatus: SessionStatus {
        switch self {
        case .running: return .generating
        case .completedUnseen: return .completed
        case .awaitingApproval: return .awaitingApproval
        case .failed: return .failed
        }
    }

    public func matches(_ session: AgentSession) -> Bool {
        switch self {
        case .running:
            return session.status == .generating
                || session.status == .runningTool
                || session.status == .runningProcessOnly
        case .completedUnseen:
            return session.status == .completed && !session.isSeen
        case .awaitingApproval:
            return session.status == .awaitingApproval
        case .failed:
            return session.status == .failed
        }
    }
}

public enum ProjectSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case priorityAndRecent
    case recentActivity
    case tokenUsage
    case sessionCount
    case alphabetical

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .priorityAndRecent: return "状态优先（待审批/生成中置顶）"
        case .recentActivity: return "最近活跃时间"
        case .tokenUsage: return "Token 消耗从高到低"
        case .sessionCount: return "会话数量从多到少"
        case .alphabetical: return "项目名称 (A → Z)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .priorityAndRecent: return "状态优先"
        case .recentActivity: return "最近活跃"
        case .tokenUsage: return "按 Token"
        case .sessionCount: return "按会话数"
        case .alphabetical: return "按名称"
        }
    }
}

public enum HostSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case localFirst
    case urgentFirst
    case sessionCount
    case customOrder

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .localFirst: return "本机置顶（默认）"
        case .urgentFirst: return "待处理 / 活跃服务器优先"
        case .sessionCount: return "按会话数量排序"
        case .customOrder: return "自定义服务器顺序"
        }
    }
}

public enum FocusArrangementOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case newGeneratedFirst
    case approvalAndRunningFirst
    case splitThreeSections
    case byHostAndProject

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newGeneratedFirst:
            return "新生成 → 待审批 / 运行中（默认）"
        case .approvalAndRunningFirst:
            return "待审批 / 运行中 → 新生成"
        case .splitThreeSections:
            return "待审批 → 新生成 → 运行中（独立三栏）"
        case .byHostAndProject:
            return "按服务器 / 项目目录分组（仅需关注）"
        }
    }

    public var shortLabel: String {
        switch self {
        case .newGeneratedFirst: return "新生成优先"
        case .approvalAndRunningFirst: return "运行中优先"
        case .splitThreeSections: return "三栏分组"
        case .byHostAndProject: return "按项目排"
        }
    }
}

public struct FocusStatusSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let emptyHint: String
    public let badgeStatus: SessionStatus
    public let secondaryBadgeStatus: SessionStatus?
    public let sessions: [AgentSession]

    public init(
        id: String,
        title: String,
        emptyHint: String,
        badgeStatus: SessionStatus,
        secondaryBadgeStatus: SessionStatus? = nil,
        sessions: [AgentSession]
    ) {
        self.id = id
        self.title = title
        self.emptyHint = emptyHint
        self.badgeStatus = badgeStatus
        self.secondaryBadgeStatus = secondaryBadgeStatus
        self.sessions = sessions
    }
}

public enum MenuBarIconStyle: String, Codable, CaseIterable, Sendable {
    case multiDot = "multiDot"
    case singlePriority = "singlePriority"

    public var title: String {
        switch self {
        case .multiDot: return "样式 B：多点计数（默认）"
        case .singlePriority: return "样式 A：总数 + 单个状态点"
        }
    }
}

public struct MenuBarCounts: Equatable, Sendable {
    public var failed: Int = 0
    public var awaitingApproval: Int = 0
    public var completedUnseen: Int = 0
    public var activeGenerating: Int = 0

    public init(
        failed: Int = 0,
        awaitingApproval: Int = 0,
        completedUnseen: Int = 0,
        activeGenerating: Int = 0
    ) {
        self.failed = failed
        self.awaitingApproval = awaitingApproval
        self.completedUnseen = completedUnseen
        self.activeGenerating = activeGenerating
    }

    public var totalHighlighted: Int {
        failed + awaitingApproval + completedUnseen + activeGenerating
    }
}

public enum SessionDeduplicator {
    /// Deduplicates sessions by `session.id`, preserving the newest shard's live status and overview
    /// while backfilling earliest `startedAt`, thread-cumulative `usage`, and per-shard counts when
    /// distinct rollout/transcript shard files share the same session ID.
    public static func deduplicate(_ sessions: [AgentSession]) -> [AgentSession] {
        guard sessions.count > 1 else { return sessions }
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(sessions.count)
        var merged: [AgentSession] = []
        merged.reserveCapacity(sessions.count)

        for candidate in sessions {
            if let existingIdx = indexByID[candidate.id] {
                merged[existingIdx] = merge(merged[existingIdx], candidate)
            } else {
                indexByID[candidate.id] = merged.count
                merged.append(candidate)
            }
        }
        return merged
    }

    public static func merge(_ lhs: AgentSession, _ rhs: AgentSession) -> AgentSession {
        let newer: AgentSession
        let older: AgentSession
        if lhs.lastActivityAt != rhs.lastActivityAt {
            if lhs.lastActivityAt > rhs.lastActivityAt {
                newer = lhs
                older = rhs
            } else {
                newer = rhs
                older = lhs
            }
        } else if lhs.usage.totalTokens >= rhs.usage.totalTokens {
            newer = lhs
            older = rhs
        } else {
            newer = rhs
            older = lhs
        }

        var out = newer
        out.startedAt = min(newer.startedAt, older.startedAt)
        out.lastActivityAt = max(newer.lastActivityAt, older.lastActivityAt)
        out.isSeen = newer.isSeen
        out.lastGeneratedAt = [newer.lastGeneratedAt, older.lastGeneratedAt].compactMap { $0 }.max()

        if isGenericFallbackTitle(newer.title) && !isGenericFallbackTitle(older.title) && !older.title.isEmpty {
            out.title = older.title
        }
        if out.overview == "等待你的下一条消息" && older.overview != "等待你的下一条消息" && !older.overview.isEmpty {
            out.overview = older.overview
        }

        if out.cwd == nil { out.cwd = older.cwd }
        if out.groupDirectory == nil { out.groupDirectory = older.groupDirectory }
        if out.model == nil { out.model = older.model }
        if out.reasoningEffort == nil { out.reasoningEffort = older.reasoningEffort }
        if out.contextUsedTokens == nil { out.contextUsedTokens = older.contextUsedTokens }
        if out.contextWindow == nil { out.contextWindow = older.contextWindow }
        if out.lastOutputMarkdown == nil { out.lastOutputMarkdown = older.lastOutputMarkdown }
        if out.outputTokensPerSecond == nil { out.outputTokensPerSecond = older.outputTokensPerSecond }
        if out.process == nil { out.process = older.process }
        if out.pendingApproval == nil { out.pendingApproval = older.pendingApproval }

        let newerShards: Set<String> = {
            if let set = newer.mergedShardPaths, !set.isEmpty { return set }
            if let p = newer.sourceFilePath, !p.isEmpty { return [p] }
            return []
        }()
        let olderShards: Set<String> = {
            if let set = older.mergedShardPaths, !set.isEmpty { return set }
            if let p = older.sourceFilePath, !p.isEmpty { return [p] }
            return []
        }()
        let isDistinctShardFile = !newerShards.isEmpty && !olderShards.isEmpty && newerShards.isDisjoint(with: olderShards)
        let combinedShards = newerShards.union(olderShards)
        if !combinedShards.isEmpty {
            out.mergedShardPaths = combinedShards
        }

        let isForked = (newer.isForkedCodex == true) || (older.isForkedCodex == true)
        out.isForkedCodex = isForked ? true : (newer.isForkedCodex ?? older.isForkedCodex)
        let shardScoped = (newer.hasShardScopedToday == true) || (older.hasShardScopedToday == true)
        out.hasShardScopedToday = shardScoped ? true : (newer.hasShardScopedToday ?? older.hasShardScopedToday)
        let bothShardScoped = (newer.isForkedCodex == true || newer.hasShardScopedToday == true)
            && (older.isForkedCodex == true || older.hasShardScopedToday == true)

        if isDistinctShardFile && bothShardScoped {
            out.usage = newer.usage.adding(older.usage)
            if newer.todayUsage != nil || older.todayUsage != nil {
                out.todayUsage = (newer.todayUsage ?? TokenUsage()).adding(older.todayUsage ?? TokenUsage())
            }
            out.modelUsages = mergeModelUsageMaps(newer.modelUsages, older.modelUsages, additive: true)
            out.todayModelUsages = mergeModelUsageMaps(newer.todayModelUsages, older.todayModelUsages, additive: true)
        } else {
            // Non-forked Codex rollout shards record thread-cumulative `total_token_usage`; never sum shards.
            var mergedUsage = older.usage.totalTokens > newer.usage.totalTokens ? older.usage : newer.usage
            if isDistinctShardFile, (newer.todayUsage != nil || older.todayUsage != nil) {
                if shardScoped {
                    let summedToday = (newer.todayUsage ?? TokenUsage()).adding(older.todayUsage ?? TokenUsage())
                    out.todayUsage = summedToday
                    mergedUsage = TokenUsage.componentMax(mergedUsage, summedToday)
                } else {
                    let newerPreToday = newer.usage.subtractingClamped(newer.todayUsage ?? TokenUsage())
                    let olderPreToday = older.usage.subtractingClamped(older.todayUsage ?? TokenUsage())
                    let combinedPreToday = TokenUsage.componentMax(newerPreToday, olderPreToday)
                    out.todayUsage = mergedUsage.subtractingClamped(combinedPreToday)
                }
            } else if out.todayUsage == nil {
                out.todayUsage = older.todayUsage
            }
            let additiveModels = isDistinctShardFile && shardScoped
            out.modelUsages = mergeModelUsageMaps(newer.modelUsages, older.modelUsages, additive: additiveModels)
            out.todayModelUsages = mergeModelUsageMaps(newer.todayModelUsages, older.todayModelUsages, additive: additiveModels)
            if let perModel = out.modelUsages, !perModel.isEmpty {
                let sumModels = perModel.values.reduce(TokenUsage()) { $0.adding($1) }
                mergedUsage = TokenUsage.componentMax(mergedUsage, sumModels)
            }
            out.usage = mergedUsage
        }

        if isDistinctShardFile {
            out.turnCount = newer.turnCount + older.turnCount
            out.totalToolCalls = newer.totalToolCalls + older.totalToolCalls
            out.successfulToolCalls = newer.successfulToolCalls + older.successfulToolCalls
            out.compactCount = newer.compactCount + older.compactCount

            var seenToolIDs = Set(newer.recentTools.map(\.id))
            var combinedTools = newer.recentTools
            for tool in older.recentTools where seenToolIDs.insert(tool.id).inserted {
                combinedTools.append(tool)
            }
            out.recentTools = Array(combinedTools.prefix(5))
        }

        return out
    }

    static func mergeModelUsageMaps(
        _ primary: [String: TokenUsage]?,
        _ secondary: [String: TokenUsage]?,
        additive: Bool
    ) -> [String: TokenUsage]? {
        guard primary != nil || secondary != nil else { return nil }
        var result = primary ?? [:]
        for (modelKey, secUsage) in (secondary ?? [:]) {
            if let existing = result[modelKey] {
                result[modelKey] = additive
                    ? existing.adding(secUsage)
                    : TokenUsage.componentMax(existing, secUsage)
            } else {
                result[modelKey] = secUsage
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func isGenericFallbackTitle(_ title: String) -> Bool {
        title.hasSuffix(" 会话") || title == "Codex 会话" || title == "Claude 会话"
    }
}

public enum SeenSessionLookup {
    /// Returns true if the session's latest activity was already viewed (with 2s clock/mtime tolerance).
    public static func isSeen(
        sessionID: String,
        lastActivityAt: Date,
        seenAtByID: [String: TimeInterval]
    ) -> Bool {
        guard let seenTS = seenAtByID[sessionID] else { return false }
        return seenTS + 2.0 >= lastActivityAt.timeIntervalSince1970
    }
}
