import Foundation

public struct CodexReadState: Sendable {
    public var hasReadState: Bool
    public var unreadThreadIDs: Set<String>
    public var userActivityAtByThreadID: [String: TimeInterval]
    public var stateFileUpdatedAt: Date?

    public init(
        hasReadState: Bool = false,
        unreadThreadIDs: Set<String> = [],
        userActivityAtByThreadID: [String: TimeInterval] = [:],
        stateFileUpdatedAt: Date? = nil
    ) {
        self.hasReadState = hasReadState
        self.unreadThreadIDs = unreadThreadIDs
        self.userActivityAtByThreadID = userActivityAtByThreadID
        self.stateFileUpdatedAt = stateFileUpdatedAt
    }
}

public enum CodexAdapter {
    private struct CachedRolloutEntry {
        var mtime: TimeInterval
        var fileSize: Int
        var dayCutoff: TimeInterval
        var result: ParsedRolloutResult?
    }

    private static let rolloutCacheLock = NSLock()
    nonisolated(unsafe) private static var rolloutCache: [String: CachedRolloutEntry] = [:]

    public static func loadReadState(homeDirectory: String = NSHomeDirectory()) -> CodexReadState {
        let path = (homeDirectory as NSString).appendingPathComponent(".codex/.codex-global-state.json")
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexReadState()
        }
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        var hasReadState = false
        var unreadIDs: Set<String> = []
        if let readState = root["electron-thread-read-state-v1"] as? [String: Any],
           let unreadByIdentity = readState["unreadByIdentity"] as? [String: Any] {
            hasReadState = true
            for (_, hostDictAny) in unreadByIdentity {
                guard let hostDict = hostDictAny as? [String: Any] else { continue }
                for (_, arrAny) in hostDict {
                    guard let arr = arrAny as? [String] else { continue }
                    unreadIDs.formUnion(arr)
                }
            }
        }

        var activityByThread: [String: TimeInterval] = [:]
        for (key, val) in root where key.hasPrefix("electron-owner-atoms:") {
            guard let atoms = val as? [String: Any],
                  let activityMap = atoms["thread-user-activity-times-v1"] as? [String: Any] else {
                continue
            }
            for (tupleJSON, rawTS) in activityMap {
                let numVal: Double?
                if let d = rawTS as? Double {
                    numVal = d
                } else if let i = rawTS as? Int {
                    numVal = Double(i)
                } else if let n = rawTS as? NSNumber {
                    numVal = n.doubleValue
                } else {
                    numVal = nil
                }
                guard let raw = numVal, raw > 0 else { continue }
                let sec = raw > 10_000_000_000 ? (raw / 1000.0) : raw
                if let keyData = tupleJSON.data(using: .utf8),
                   let tuple = try? JSONSerialization.jsonObject(with: keyData) as? [Any],
                   tuple.count >= 2,
                   let threadID = tuple[1] as? String,
                   !threadID.isEmpty {
                    activityByThread[threadID] = max(activityByThread[threadID] ?? 0, sec)
                }
            }
        }

        return CodexReadState(
            hasReadState: hasReadState,
            unreadThreadIDs: unreadIDs,
            userActivityAtByThreadID: activityByThread,
            stateFileUpdatedAt: mtime
        )
    }

    public static func loadThreadIndex(homeDirectory: String = NSHomeDirectory()) -> [String: String] {
        let path = (homeDirectory as NSString).appendingPathComponent(".codex/session_index.jsonl")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String,
                  !name.isEmpty else {
                continue
            }
            map[id] = cleanThreadTitle(name)
        }
        return map
    }

    public static func cleanThreadTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("*") || s.hasPrefix("#") {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        if s.hasSuffix("**") {
            s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? raw : s
    }

    public static func detectDefaultProvider(homeDirectory: String = NSHomeDirectory()) -> String {
        let path = (homeDirectory as NSString).appendingPathComponent(".codex/config.toml")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "OpenAI"
        }
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider") && trimmed.contains("=") {
                let rhs = trimmed.split(separator: "=", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let rhs, !rhs.isEmpty {
                    return FormattingHelpers.providerDisplay(from: rhs) ?? rhs
                }
            }
        }
        return "OpenAI"
    }

    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 72,
        includeSubagents: Bool = false,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> [AgentSession] {
        let sessionsRoot = (homeDirectory as NSString).appendingPathComponent(".codex/sessions")
        let archivedRoot = (homeDirectory as NSString).appendingPathComponent(".codex/archived_sessions")
        let indexMap = loadThreadIndex(homeDirectory: homeDirectory)
        let readState = loadReadState(homeDirectory: homeDirectory)
        let defaultProvider = detectDefaultProvider(homeDirectory: homeDirectory)
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)
        var candidates = ClaudeCodeAdapter.collectRecentJSONLFiles(rootPath: sessionsRoot, cutoff: cutoff)
        let archivedCandidates = ClaudeCodeAdapter.collectRecentJSONLFiles(rootPath: archivedRoot, cutoff: cutoff)
        if !archivedCandidates.isEmpty {
            candidates.append(contentsOf: archivedCandidates)
            candidates.sort { $0.mtime > $1.mtime }
        }

        let maxUniqueSessions = 1000
        let maxCandidateScan = 2500
        var parsedSessions: [AgentSession] = []
        var subagentRollups: [(parentThreadID: String, session: AgentSession)] = []
        var acceptedIDs: Set<String> = []
        let now = Date()
        let dayCutoff = Calendar.current.startOfDay(for: now)
        let dayCutoffTS = dayCutoff.timeIntervalSince1970

        for item in candidates.prefix(maxCandidateScan) {
            let fileAge = now.timeIntervalSince(item.mtime)
            let filePath = item.url.path
            let fileSize = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let mtimeTS = item.mtime.timeIntervalSince1970
            let parsedOpt: ParsedRolloutResult?

            if fileAge > 1800,
               let cached = lookupCachedRollout(path: filePath, mtime: mtimeTS, size: fileSize, dayCutoff: dayCutoffTS) {
                parsedOpt = cached
            } else {
                let tailCap = fileAge > 1800 ? 98_304 : 2_500_000
                guard let content = readTailUTF8(url: item.url, maxBytes: tailCap, dayCutoff: dayCutoff) else { continue }
                let fresh = parseRolloutInternal(
                    jsonl: content,
                    filePath: filePath,
                    fileModificationDate: item.mtime,
                    host: .local,
                    threadTitles: indexMap,
                    defaultProvider: defaultProvider,
                    allowSubagents: true,
                    readState: readState,
                    seenAtByID: seenAtByID,
                    dayCutoff: dayCutoff
                )
                if fileAge > 1800 {
                    storeCachedRollout(path: filePath, mtime: mtimeTS, size: fileSize, dayCutoff: dayCutoffTS, result: fresh)
                }
                parsedOpt = fresh
            }

            if let parsed = parsedOpt {
                if parsed.isSubagent && !includeSubagents {
                    if let parentID = parsed.parentThreadID, !parentID.isEmpty {
                        subagentRollups.append((parentID, parsed.session))
                    }
                    continue
                }
                var session = parsed.session
                if !acceptedIDs.contains(session.id) {
                    guard acceptedIDs.count < maxUniqueSessions || item.mtime >= dayCutoff else { continue }
                    acceptedIDs.insert(session.id)
                }
                session.groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: session.cwd)
                parsedSessions.append(session)
            }
        }
        var deduped = SessionDeduplicator.deduplicate(parsedSessions)
        if !includeSubagents && !subagentRollups.isEmpty {
            let subSessionsByParent = Dictionary(grouping: subagentRollups, by: \.parentThreadID)
            for idx in deduped.indices {
                if let items = subSessionsByParent[deduped[idx].rawSessionID] {
                    let dedupedSubs = SessionDeduplicator.deduplicate(items.map(\.session))
                    for sub in dedupedSubs {
                        deduped[idx].rollUpChildUsage(sub, dayCutoff: dayCutoff)
                    }
                }
            }
        }
        return deduped
    }

    private static func lookupCachedRollout(
        path: String,
        mtime: TimeInterval,
        size: Int,
        dayCutoff: TimeInterval
    ) -> ParsedRolloutResult?? {
        rolloutCacheLock.lock()
        defer { rolloutCacheLock.unlock() }
        guard let entry = rolloutCache[path],
              entry.mtime == mtime,
              entry.fileSize == size,
              entry.dayCutoff == dayCutoff else {
            return nil
        }
        return entry.result
    }

    private static func storeCachedRollout(
        path: String,
        mtime: TimeInterval,
        size: Int,
        dayCutoff: TimeInterval,
        result: ParsedRolloutResult?
    ) {
        rolloutCacheLock.lock()
        defer { rolloutCacheLock.unlock() }
        if rolloutCache.count > 3000 {
            rolloutCache.removeAll(keepingCapacity: true)
        }
        rolloutCache[path] = CachedRolloutEntry(mtime: mtime, fileSize: size, dayCutoff: dayCutoff, result: result)
    }

    private static func readTailUTF8(
        url: URL,
        maxBytes: Int,
        dayCutoff: Date = Calendar.current.startOfDay(for: Date())
    ) -> String? {
        _ = dayCutoff
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if data.count <= maxBytes {
            return String(data: data, encoding: .utf8)
        }
        let newline: UInt8 = 0x0A
        let firstNewline = data.firstIndex(of: newline) ?? data.endIndex
        let firstLine = String(decoding: data[data.startIndex..<firstNewline], as: UTF8.self)
        let afterFirstLine = firstNewline < data.endIndex ? data.index(after: firstNewline) : data.endIndex

        let rawTailStart = max(afterFirstLine, data.count - maxBytes)
        let tailLineStart: Int
        if let nlInTail = data[rawTailStart..<data.endIndex].firstIndex(of: newline) {
            tailLineStart = data.index(after: nlInTail)
        } else {
            tailLineStart = data.endIndex
        }

        var segments: [String] = [firstLine]
        if afterFirstLine < tailLineStart {
            var anchorLines = extractMetricAndContextLines(in: data, range: afterFirstLine..<tailLineStart)
            if let lifecycle = latestLifecycleEventLine(in: data, range: afterFirstLine..<tailLineStart),
               !anchorLines.contains(where: { $0.offset == lifecycle.offset }) {
                anchorLines.append(lifecycle)
                anchorLines.sort { $0.offset < $1.offset }
            }
            segments.append(contentsOf: anchorLines.map(\.line))
        }
        if tailLineStart < data.endIndex {
            segments.append(String(decoding: data[tailLineStart..<data.endIndex], as: UTF8.self))
        }
        return segments.joined(separator: "\n")
    }

    private static let tokenCountNeedle = Data("\"token_count\"".utf8)
    private static let turnContextTypeNeedle = Data("\"type\":\"turn_context\"".utf8)
    private static let threadSettingsNeedle = Data("\"thread_settings_applied\"".utf8)
    private static let responseItemTypeNeedle = Data("\"type\":\"response_item\"".utf8)

    private static func extractMetricAndContextLines(
        in data: Data,
        range: Range<Int>
    ) -> [(offset: Int, line: String)] {
        let newline: UInt8 = 0x0A
        var seenOffsets: Set<Int> = []
        var collected: [(offset: Int, line: String)] = []

        for needle in [tokenCountNeedle, turnContextTypeNeedle, threadSettingsNeedle, Data("\"task_started\"".utf8)] {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                guard let hit = data.range(of: needle, in: cursor..<range.upperBound) else { break }
                let lineStart: Int
                if let prevNL = data[range.lowerBound..<hit.lowerBound].lastIndex(of: newline) {
                    lineStart = prevNL + 1
                } else {
                    lineStart = range.lowerBound
                }
                let lineEnd = data[hit.upperBound..<range.upperBound].firstIndex(of: newline) ?? range.upperBound
                cursor = min(range.upperBound, lineEnd + 1)
                guard lineEnd - lineStart <= 32_768, seenOffsets.insert(lineStart).inserted else {
                    continue
                }
                let lineData = data[lineStart..<lineEnd]
                if lineData.range(of: responseItemTypeNeedle) != nil {
                    continue
                }
                collected.append((lineStart, String(decoding: lineData, as: UTF8.self)))
            }
        }
        collected.sort { $0.offset < $1.offset }
        return collected
    }

    private static let lifecycleNeedles: [Data] = [
        Data("\"task_started\"".utf8),
        Data("\"task_complete\"".utf8),
        Data("\"turn_aborted\"".utf8),
        Data("\"type\":\"error\"".utf8)
    ]

    private static let lifecycleEventTypes: Set<String> = [
        "task_started",
        "task_complete",
        "turn_aborted",
        "error"
    ]

    private static func latestLifecycleEventLine(in data: Data, range: Range<Int>) -> (offset: Int, line: String)? {
        let newline: UInt8 = 0x0A
        var bestStart = -1
        var bestLine: String?

        for needle in lifecycleNeedles {
            var searchUpper = range.upperBound
            var attempts = 0
            while searchUpper > range.lowerBound && attempts < 12 {
                attempts += 1
                guard let hit = data.range(of: needle, options: .backwards, in: range.lowerBound..<searchUpper) else {
                    break
                }
                let lineStart: Int
                if let prevNL = data[range.lowerBound..<hit.lowerBound].lastIndex(of: newline) {
                    lineStart = prevNL + 1
                } else {
                    lineStart = range.lowerBound
                }
                if lineStart <= bestStart {
                    break
                }
                let lineEnd = data[hit.upperBound..<range.upperBound].firstIndex(of: newline) ?? range.upperBound
                let lineData = data[lineStart..<lineEnd]
                if let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                   (obj["type"] as? String) == "event_msg",
                   let payload = obj["payload"] as? [String: Any],
                   let ptype = payload["type"] as? String,
                   lifecycleEventTypes.contains(ptype) {
                    bestStart = lineStart
                    bestLine = String(decoding: lineData, as: UTF8.self)
                    break
                }
                searchUpper = lineStart > range.lowerBound ? (lineStart - 1) : range.lowerBound
            }
        }
        guard let bestLine, bestStart >= 0 else { return nil }
        return (bestStart, bestLine)
    }

    public static func parseRollout(
        jsonl: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID,
        threadTitles: [String: String] = [:],
        defaultProvider: String = "OpenAI",
        includeSubagents: Bool = false,
        readState: CodexReadState = CodexReadState(),
        seenAtByID: [String: TimeInterval] = [:],
        dayCutoff: Date = Calendar.current.startOfDay(for: Date())
    ) -> AgentSession? {
        parseRolloutInternal(
            jsonl: jsonl,
            filePath: filePath,
            fileModificationDate: fileModificationDate,
            host: host,
            threadTitles: threadTitles,
            defaultProvider: defaultProvider,
            allowSubagents: includeSubagents,
            readState: readState,
            seenAtByID: seenAtByID,
            dayCutoff: dayCutoff
        )?.session
    }

    private struct ParsedRolloutResult {
        var session: AgentSession
        var isSubagent: Bool
        var parentThreadID: String?
    }

    private static func parseRolloutInternal(
        jsonl: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID,
        threadTitles: [String: String] = [:],
        defaultProvider: String = "OpenAI",
        allowSubagents: Bool = false,
        readState: CodexReadState = CodexReadState(),
        seenAtByID: [String: TimeInterval] = [:],
        dayCutoff: Date = Calendar.current.startOfDay(for: Date())
    ) -> ParsedRolloutResult? {
        var rawID = URL(fileURLWithPath: filePath ?? "codex").deletingPathExtension().lastPathComponent
        if let uuidRange = rawID.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression
        ) {
            rawID = String(rawID[uuidRange])
        }
        var kind: AgentKind = .codexCLI
        var launchEnv: SessionLaunchEnvironment = .terminalCLI
        var cwd: String?
        var provider = defaultProvider
        var model: String?
        var reasoningEffort: String?
        var usage = TokenUsage()
        var isForkedThread = false
        var isSubagent = false
        var parentThreadID: String?
        var sawFirstTokenCount = false
        var hasShardScopedToday = false
        var hasGenuineShardStart = false
        var shardBaseline = TokenUsage()
        var prevShardOwn = TokenUsage()
        var prevThreadTotal = TokenUsage()
        var preTodayShardOwn = TokenUsage()
        var latestTodayShardOwn = TokenUsage()
        var sawPreTodayTokenCount = false
        var sawTodayTokenCount = false
        var modelUsages: [String: TokenUsage] = [:]
        var todayModelUsages: [String: TokenUsage] = [:]
        var longInputUsages: [String: TokenUsage] = [:]
        var todayLongInputUsages: [String: TokenUsage] = [:]
        var contextUsed: Int?
        var contextWindow: Int?
        var firstUserMessage: String?
        var lastAssistantMessage: String?
        var openTools: [String: ToolCallRecord] = [:]
        var openToolOrder: [String] = []
        var completedTools: [ToolCallRecord] = []
        var totalTools = 0
        var failedTools = 0
        var turnOpen = false
        var turnCount = 0
        var todayTurnCount = 0
        var compactCount = 0
        var lastDurationMs: Double?
        var lastTurnOutputTokens: Int?
        var errorBanner: String?
        var startedAt: Date?
        var lastActivityAt = fileModificationDate

        func markInTurnActivity() {
            if !turnOpen {
                turnOpen = true
                errorBanner = nil
            }
        }

        for lineSub in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = lineSub.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let ts = ClaudeCodeAdapter.parseISODate(obj["timestamp"] as? String)
            if let ts {
                if startedAt == nil { startedAt = ts }
                if ts > lastActivityAt { lastActivityAt = ts }
            }
            let type = (obj["type"] as? String) ?? ""
            let payload = obj["payload"] as? [String: Any]

            switch type {
            case "session_meta":
                guard let payload else { continue }
                let sourceObj = payload["source"] as? [String: Any]
                let isSubagentMeta = sourceObj?["subagent"] != nil
                    || (payload["thread_source"] as? String) == "subagent"
                if isSubagentMeta {
                    if !allowSubagents {
                        return nil
                    }
                    isSubagent = true
                    isForkedThread = true
                    let spawnParent = ((sourceObj?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String
                    parentThreadID = (payload["parent_thread_id"] as? String)
                        ?? spawnParent
                        ?? (payload["forked_from_id"] as? String)
                        ?? (payload["session_id"] as? String)
                }
                if let id = payload["id"] as? String, !id.isEmpty {
                    rawID = id
                }
                if !isSubagentMeta, let sid = payload["session_id"] as? String, !sid.isEmpty {
                    rawID = sid
                }
                if let forkedFrom = payload["forked_from_id"] as? String, !forkedFrom.isEmpty {
                    isForkedThread = true
                }
                if (payload["attached_thread"] as? Bool) == true {
                    isForkedThread = true
                }
                if let dir = payload["cwd"] as? String, !dir.isEmpty {
                    cwd = dir
                }
                if let mp = payload["model_provider"] as? String, !mp.isEmpty {
                    provider = FormattingHelpers.providerDisplay(from: mp) ?? mp
                }
                if let cw = payload["context_window"] as? Int, cw > 0 {
                    contextWindow = cw
                }
                let originator = (payload["originator"] as? String) ?? ""
                let sourceStr = (payload["source"] as? String) ?? ""
                if originator.localizedCaseInsensitiveContains("desktop") {
                    kind = .codexDesktop
                    launchEnv = host.isLocal ? .codexApp : .vscodeExtension
                } else if originator.localizedCaseInsensitiveContains("cursor") {
                    kind = .codexDesktop
                    launchEnv = .cursorExtension
                } else if originator.localizedCaseInsensitiveContains("vscode") || sourceStr == "vscode" {
                    kind = .codexDesktop
                    launchEnv = .vscodeExtension
                } else {
                    kind = .codexCLI
                    launchEnv = .terminalCLI
                }

            case "turn_context":
                markInTurnActivity()
                guard let payload else { continue }
                if let dir = payload["cwd"] as? String, !dir.isEmpty {
                    cwd = dir
                }
                if let m = payload["model"] as? String, !m.isEmpty {
                    model = m
                }
                if let eff = payload["effort"] as? String, !eff.isEmpty {
                    reasoningEffort = eff
                }

            case "compacted":
                markInTurnActivity()
                compactCount += 1
                if model == nil,
                   let resumeMeta = payload?["resume_metadata"] as? [String: Any],
                   let prevSettings = resumeMeta["previous_turn_settings"] as? [String: Any],
                   let m = prevSettings["model"] as? String,
                   !m.isEmpty {
                    model = m
                }

            case "event_msg":
                guard let payload else { continue }
                let ptype = (payload["type"] as? String) ?? ""
                switch ptype {
                case "thread_settings_applied":
                    if let settings = payload["thread_settings"] as? [String: Any] {
                        if let m = settings["model"] as? String, !m.isEmpty { model = m }
                        if let mp = settings["model_provider_id"] as? String, !mp.isEmpty {
                            provider = FormattingHelpers.providerDisplay(from: mp) ?? mp
                        }
                        if let eff = settings["reasoning_effort"] as? String, !eff.isEmpty {
                            reasoningEffort = eff
                        }
                        if let dir = settings["cwd"] as? String, !dir.isEmpty {
                            cwd = dir
                        }
                    }
                case "task_started":
                    turnOpen = true
                    turnCount += 1
                    if let ts, ts >= dayCutoff { todayTurnCount += 1 }
                    errorBanner = nil
                    if let cw = payload["model_context_window"] as? Int, cw > 0 {
                        contextWindow = cw
                    }
                case "task_complete":
                    turnOpen = false
                    openTools.removeAll()
                    openToolOrder.removeAll()
                    if let dur = payload["duration_ms"] as? Double, dur > 0 {
                        lastDurationMs = dur
                    } else if let durInt = payload["duration_ms"] as? Int, durInt > 0 {
                        lastDurationMs = Double(durInt)
                    }
                    if let msg = payload["last_agent_message"] as? String,
                       !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lastAssistantMessage = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case "token_count":
                    if let info = payload["info"] as? [String: Any] {
                        if let cw = info["model_context_window"] as? Int, cw > 0 {
                            contextWindow = cw
                        }
                        var curLastUsage: TokenUsage?
                        if let last = info["last_token_usage"] as? [String: Any] {
                            let lastIn = (last["input_tokens"] as? Int) ?? 0
                            let lastCached = (last["cached_input_tokens"] as? Int) ?? 0
                            let lastCW = (last["cache_write_input_tokens"] as? Int) ?? 0
                            let lastOut = (last["output_tokens"] as? Int) ?? 0
                            let lastReas = (last["reasoning_output_tokens"] as? Int) ?? 0
                            if lastIn > 0 {
                                contextUsed = lastIn
                            }
                            if lastOut > 0 || last["output_tokens"] != nil {
                                lastTurnOutputTokens = (last["output_tokens"] as? Int)
                            }
                            if lastIn > 0 || lastOut > 0 || lastCW > 0 {
                                curLastUsage = TokenUsage(
                                    input: netInput(raw: lastIn, cached: lastCached, written: lastCW, output: lastOut, reportedTotal: last["total_tokens"] as? Int),
                                    output: lastOut,
                                    cacheRead: lastCached,
                                    cacheWrite: lastCW,
                                    reasoning: lastReas
                                )
                            }
                        }
                        if let total = info["total_token_usage"] as? [String: Any] {
                            let rawInput = (total["input_tokens"] as? Int) ?? 0
                            let cached = (total["cached_input_tokens"] as? Int) ?? 0
                            let cacheWrite = (total["cache_write_input_tokens"] as? Int) ?? 0
                            let output = (total["output_tokens"] as? Int) ?? 0
                            let reasoning = (total["reasoning_output_tokens"] as? Int) ?? 0
                            let curTotal = TokenUsage(
                                input: netInput(raw: rawInput, cached: cached, written: cacheWrite, output: output, reportedTotal: total["total_tokens"] as? Int),
                                output: output,
                                cacheRead: cached,
                                cacheWrite: cacheWrite,
                                reasoning: reasoning
                            )
                            if curTotal.totalTokens > 0 {
                                let eventDate = ts ?? fileModificationDate
                                if !sawFirstTokenCount {
                                    sawFirstTokenCount = true
                                    if isForkedThread, curLastUsage == nil,
                                       let last = info["last_token_usage"] as? [String: Any],
                                       last["input_tokens"] as? Int == 0, last["output_tokens"] as? Int == 0 {
                                        shardBaseline = curTotal
                                    }
                                    if let curLastUsage, curLastUsage.totalTokens > 0 {
                                        hasShardScopedToday = true
                                        if totalTools <= 5 {
                                            hasGenuineShardStart = true
                                        }
                                        if curTotal.totalTokens > curLastUsage.totalTokens {
                                            shardBaseline = curTotal.subtractingClamped(curLastUsage)
                                        }
                                    }
                                }

                                let shardOwn = curTotal.subtractingClamped(shardBaseline)
                                let stepDelta = shardOwn.subtractingClamped(prevShardOwn)
                                prevShardOwn = TokenUsage.componentMax(prevShardOwn, shardOwn)
                                prevThreadTotal = TokenUsage.componentMax(prevThreadTotal, curTotal)
                                usage = (isForkedThread || hasGenuineShardStart) ? prevShardOwn : prevThreadTotal

                                let longRequest = curLastUsage == stepDelta && stepDelta.totalPromptTokens > LongInputRates.threshold

                                if let activeModel = model, !activeModel.isEmpty, stepDelta.totalTokens > 0 {
                                    modelUsages[activeModel] = (modelUsages[activeModel] ?? TokenUsage()).adding(stepDelta)
                                    if longRequest {
                                        longInputUsages[activeModel] = (longInputUsages[activeModel] ?? TokenUsage()).adding(stepDelta)
                                    }
                                }

                                if eventDate < dayCutoff {
                                    sawPreTodayTokenCount = true
                                    preTodayShardOwn = TokenUsage.componentMax(preTodayShardOwn, shardOwn)
                                } else {
                                    if !sawTodayTokenCount && !sawPreTodayTokenCount,
                                       (startedAt ?? eventDate) < dayCutoff,
                                       let curLastUsage,
                                       shardOwn.totalTokens > curLastUsage.totalTokens {
                                        preTodayShardOwn = shardOwn.subtractingClamped(curLastUsage)
                                    }
                                    sawTodayTokenCount = true
                                    let prevTodayLevel = TokenUsage.componentMax(preTodayShardOwn, latestTodayShardOwn)
                                    let todayDelta = shardOwn.subtractingClamped(prevTodayLevel)
                                    latestTodayShardOwn = TokenUsage.componentMax(latestTodayShardOwn, shardOwn)
                                    if let activeModel = model, !activeModel.isEmpty, todayDelta.totalTokens > 0 {
                                        todayModelUsages[activeModel] = (todayModelUsages[activeModel] ?? TokenUsage()).adding(todayDelta)
                                        if longRequest && todayDelta == stepDelta {
                                            todayLongInputUsages[activeModel] = (todayLongInputUsages[activeModel] ?? TokenUsage()).adding(todayDelta)
                                        }
                                    }
                                }
                            }
                        }
                    }
                case "context_compacted":
                    markInTurnActivity()
                    compactCount += 1
                case "error", "turn_aborted":
                    turnOpen = false
                    openTools.removeAll()
                    openToolOrder.removeAll()
                    if let message = payload["message"] as? String, !message.isEmpty {
                        errorBanner = ClaudeCodeAdapter.firstSingleLine(message, maxLength: 140)
                    }
                default:
                    break
                }

            case "response_item":
                guard let payload else { continue }
                let rtype = (payload["type"] as? String) ?? ""
                switch rtype {
                case "reasoning":
                    markInTurnActivity()
                case "function_call", "custom_tool_call":
                    markInTurnActivity()
                    let callID = (payload["call_id"] as? String) ?? UUID().uuidString
                    let name = (payload["name"] as? String) ?? "tool"
                    let args = payload["arguments"] ?? payload["input"]
                    let summary = ClaudeCodeAdapter.summarizeToolInput(name: name, input: args)
                    let record = ToolCallRecord(
                        id: callID,
                        name: name,
                        summary: summary,
                        startedAt: ts ?? lastActivityAt
                    )
                    openTools[callID] = record
                    openToolOrder.append(callID)
                    totalTools += 1
                case "function_call_output", "custom_tool_call_output":
                    markInTurnActivity()
                    let callID = (payload["call_id"] as? String) ?? ""
                    let outStr = (payload["output"] as? String) ?? ""
                    let isErr = outStr.contains("Process exited with code 1")
                        || outStr.contains("Exit code: 1")
                        || outStr.contains("error:")
                    if isErr { failedTools += 1 }
                    if var record = openTools.removeValue(forKey: callID) {
                        openToolOrder.removeAll { $0 == callID }
                        record.finishedAt = ts ?? lastActivityAt
                        record.isError = isErr
                        completedTools.append(record)
                    }
                case "message":
                    let role = (payload["role"] as? String) ?? ""
                    let text = extractCodexMessageText(content: payload["content"])
                    if role == "user", !text.isEmpty {
                        let cleaned = cleanCodexUserText(text)
                        if !cleaned.isEmpty && firstUserMessage == nil {
                            firstUserMessage = cleaned
                        }
                    } else if role == "assistant", !text.isEmpty {
                        lastAssistantMessage = text
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        let hasRealActivity = turnOpen
            || !openTools.isEmpty
            || totalTools > 0
            || lastAssistantMessage != nil
            || usage.totalTokens > 0

        let title = threadTitles[rawID]
            ?? firstUserMessage.map { ClaudeCodeAdapter.firstSingleLine($0, maxLength: 44) }
            ?? (hasRealActivity ? cwd.map { "\(URL(fileURLWithPath: $0).lastPathComponent) 会话" } : nil)
            ?? (hasRealActivity ? "Codex 会话" : nil)

        guard let title, !title.isEmpty else {
            return nil
        }

        var tokPerSec: Double?
        if let durMs = lastDurationMs, durMs > 200, let outTok = lastTurnOutputTokens, outTok > 0 {
            tokPerSec = Double(outTok) / (durMs / 1000.0)
        }

        let currentTool = openToolOrder.last.flatMap { openTools[$0] }
        var recent = completedTools
        if let currentTool { recent.append(currentTool) }
        let recentTail = Array(recent.suffix(5).reversed())

        let sessionID = "\(host.storageKey):codex:\(rawID)"
        let age = Date().timeIntervalSince(lastActivityAt)
        let seenInAgentBar = SeenSessionLookup.isSeen(
            sessionID: sessionID,
            lastActivityAt: lastActivityAt,
            seenAtByID: seenAtByID
        )
        let isCodexAppLocal = host.isLocal && (kind == .codexDesktop || launchEnv == .codexApp)
        let seenByActivityTime = isCodexAppLocal
            && (readState.userActivityAtByThreadID[rawID].map { $0 + 2.0 >= lastActivityAt.timeIntervalSince1970 } ?? false)
        let stateFileSettled: Bool = {
            if age >= 3.0 { return true }
            guard let stateMtime = readState.stateFileUpdatedAt else { return false }
            return stateMtime.timeIntervalSince(lastActivityAt) >= -1.5
        }()
        let seenByNativeUnread = isCodexAppLocal
            && readState.hasReadState
            && stateFileSettled
            && !readState.unreadThreadIDs.contains(rawID)
        let isArchivedFile = (filePath ?? "").contains("/archived_sessions/")
        let isSeen = isArchivedFile || seenInAgentBar || seenByActivityTime || seenByNativeUnread

        let status: SessionStatus
        if errorBanner != nil && age < 7200 {
            status = .failed
        } else if currentTool != nil && age < 900 {
            status = .runningTool
        } else if turnOpen && age < 600 {
            status = .generating
        } else if !isSeen && age < 1800 && lastAssistantMessage != nil {
            status = .completed
        } else {
            status = .waitingForInput
        }

        let overview: String
        if let err = errorBanner {
            overview = err
        } else if let tool = currentTool {
            overview = "\(tool.name)：\(tool.summary)"
        } else if let msg = lastAssistantMessage {
            overview = ClaudeCodeAdapter.firstSingleLine(msg, maxLength: 80)
        } else if let prompt = firstUserMessage {
            overview = ClaudeCodeAdapter.firstSingleLine(prompt, maxLength: 80)
        } else {
            overview = "等待你的下一条消息"
        }

        let resolvedTodayUsage = sawTodayTokenCount
            ? latestTodayShardOwn.subtractingClamped(preTodayShardOwn)
            : TokenUsage()

        var session = AgentSession(
            id: sessionID,
            rawSessionID: rawID,
            kind: kind,
            host: host,
            title: title,
            overview: overview,
            status: status,
            cwd: cwd,
            groupDirectory: cwd,
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            usage: usage,
            todayUsage: resolvedTodayUsage,
            modelUsages: modelUsages.isEmpty ? nil : modelUsages,
            todayModelUsages: todayModelUsages.isEmpty ? nil : todayModelUsages,
            isForkedCodex: isForkedThread ? true : nil,
            hasShardScopedToday: (hasShardScopedToday && hasGenuineShardStart) ? true : nil,
            contextUsedTokens: contextUsed,
            contextWindow: contextWindow ?? PricingCatalog.defaultContextWindow(for: model),
            currentTool: currentTool,
            recentTools: recentTail,
            totalToolCalls: totalTools,
            successfulToolCalls: max(0, totalTools - failedTools),
            turnCount: turnCount,
            todayTurnCount: todayTurnCount,
            compactCount: compactCount,
            outputTokensPerSecond: tokPerSec,
            lastOutputMarkdown: lastAssistantMessage,
            errorBanner: errorBanner,
            sourceFilePath: filePath,
            launchEnvironment: launchEnv,
            startedAt: startedAt ?? fileModificationDate,
            lastActivityAt: lastActivityAt,
            isSeen: isSeen
        )
        session.longInputUsages = longInputUsages.isEmpty ? nil : longInputUsages
        session.todayLongInputUsages = todayLongInputUsages.isEmpty ? nil : todayLongInputUsages
        return ParsedRolloutResult(
            session: session,
            isSubagent: isSubagent,
            parentThreadID: parentThreadID
        )
    }

    private static func netInput(raw: Int, cached: Int, written: Int, output: Int, reportedTotal: Int?) -> Int {
        let includesWrite = reportedTotal == raw + output && written <= raw - cached
        return max(0, raw - cached - (includesWrite ? written : 0))
    }

    private static func extractCodexMessageText(content: Any?) -> String {
        if let str = content as? String {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let arr = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for item in arr {
            let t = (item["type"] as? String) ?? ""
            if (t == "input_text" || t == "output_text" || t == "text"),
               let s = item["text"] as? String {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanCodexUserText(_ raw: String) -> String {
        var s = raw
        if let endEnv = s.range(of: "</environment_context>") {
            s = String(s[endEnv.upperBound...])
        }
        if let reqRange = s.range(of: "## My request:") {
            s = String(s[reqRange.upperBound...])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") && s.contains("</") && s.count < 80 {
            return ""
        }
        return s
    }
}
