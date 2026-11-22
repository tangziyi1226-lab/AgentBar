import Foundation

public enum ClaudeCodeAdapter {
    private struct MessageUsageEntry {
        var usage: TokenUsage
        var model: String?
        var date: Date?
        var origin: String?
    }

    private struct TranscriptEvents {
        var messages: [String: MessageUsageEntry] = [:]
        var prompts: [String: (Date?, String?)] = [:]
    }

    private struct Transcript {
        var session: AgentSession
        var events: TranscriptEvents
        var creation: Date
        var parentID: String?
    }

    private struct CachedTranscriptEntry {
        var mtime: TimeInterval
        var fileSize: Int
        var dayCutoff: TimeInterval
        var includeSubagents: Bool
        var session: Transcript?
    }

    private static let transcriptCacheLock = NSLock()
    nonisolated(unsafe) private static var transcriptCache: [String: CachedTranscriptEntry] = [:]

    private static let fractionalISOStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let basicISOStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return (try? fractionalISOStyle.parse(raw)) ?? (try? basicISOStyle.parse(raw))
    }

    public static func detectLocalProvider(homeDirectory: String = NSHomeDirectory()) -> String {
        let path = (homeDirectory as NSString).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = obj["env"] as? [String: Any] else {
            return "Anthropic"
        }
        if env["CLAUDE_CODE_USE_BEDROCK"] != nil {
            return "AWS Bedrock"
        }
        if env["CLAUDE_CODE_USE_VERTEX"] != nil {
            return "Vertex AI"
        }
        if let baseURL = env["ANTHROPIC_BASE_URL"] as? String,
           let host = URL(string: baseURL)?.host {
            return FormattingHelpers.providerDisplay(from: host) ?? host
        }
        return "Anthropic"
    }

    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 72,
        includeSubagents: Bool = false,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> [AgentSession] {
        let rootPath = (homeDirectory as NSString).appendingPathComponent(".claude/projects")
        let provider = detectLocalProvider(homeDirectory: homeDirectory)
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)
        var collected = collectRecentJSONLFilesWithSubagents(
            rootPath: rootPath,
            cutoff: cutoff,
            includeSubagents: includeSubagents
        )
        let desktopRoots = [
            (homeDirectory as NSString).appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions"),
            (homeDirectory as NSString).appendingPathComponent("Library/Application Support/Claude-3p/local-agent-mode-sessions")
        ]
        for desktopRoot in desktopRoots {
            let extra = collectClaudeDesktopLocalAgentFiles(
                rootPath: desktopRoot,
                cutoff: cutoff,
                includeSubagents: includeSubagents
            )
            if !extra.mainFiles.isEmpty {
                collected.mainFiles.append(contentsOf: extra.mainFiles)
            }
            if !extra.subagentFiles.isEmpty {
                collected.subagentFiles.append(contentsOf: extra.subagentFiles)
            }
        }
        collected.mainFiles.sort { $0.mtime > $1.mtime }

        let maxUniqueSessions = 1000
        let maxCandidateScan = 2500
        var transcripts: [Transcript] = []
        var acceptedIDs: Set<String> = []
        let now = Date()
        let dayCutoff = Calendar.current.startOfDay(for: now)
        let dayCutoffTS = dayCutoff.timeIntervalSince1970

        for item in collected.mainFiles.prefix(maxCandidateScan) {
            let fileAge = now.timeIntervalSince(item.mtime)
            let filePath = item.url.path
            let fileSize = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let mtimeTS = item.mtime.timeIntervalSince1970
            let rawID = item.url.deletingPathExtension().lastPathComponent
            let parsedOpt: Transcript?
            if fileAge > 1800,
               let cached = lookupCachedTranscript(
                   path: filePath,
                   mtime: mtimeTS,
                   size: fileSize,
                   dayCutoff: dayCutoffTS,
                   includeSubagents: includeSubagents
               ) {
                parsedOpt = cached
            } else {
                guard let content = try? String(contentsOf: item.url, encoding: .utf8) else { continue }
                var events = TranscriptEvents()
                let fresh = parseTranscript(
                    jsonl: content,
                    fallbackSessionID: rawID,
                    filePath: filePath,
                    fileModificationDate: item.mtime,
                    host: .local,
                    defaultProvider: provider,
                    includeSubagents: includeSubagents,
                    seenAtByID: seenAtByID,
                    dayCutoff: dayCutoff, events: &events
                ).map { Transcript(session: $0, events: events, creation: (try? item.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? item.mtime) }
                if fileAge > 1800 {
                    storeCachedTranscript(
                        path: filePath,
                        mtime: mtimeTS,
                        size: fileSize,
                        dayCutoff: dayCutoffTS,
                        includeSubagents: includeSubagents,
                        session: fresh
                    )
                }
                parsedOpt = fresh
            }

            if var transcript = parsedOpt {
                let session = transcript.session
                if !acceptedIDs.contains(session.id) {
                    guard acceptedIDs.count < maxUniqueSessions || item.mtime >= dayCutoff else { continue }
                    acceptedIDs.insert(session.id)
                }
                transcript.session.groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: session.cwd)
                transcripts.append(transcript)
            }
        }
        if !includeSubagents && !collected.subagentFiles.isEmpty {
            for subItem in collected.subagentFiles {
                guard let content = try? String(contentsOf: subItem.url, encoding: .utf8) else { continue }
                var events = TranscriptEvents()
                if let session = parseTranscript(
                    jsonl: content, fallbackSessionID: subItem.url.deletingPathExtension().lastPathComponent,
                    filePath: subItem.url.path, fileModificationDate: subItem.mtime, host: .local,
                    defaultProvider: provider, includeSubagents: true, seenAtByID: seenAtByID,
                    dayCutoff: dayCutoff, events: &events
                ) {
                    transcripts.append(Transcript(session: session, events: events, creation: (try? subItem.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? subItem.mtime, parentID: subItem.parentSessionID))
                }
            }
        }
        reconcile(&transcripts, dayCutoff: dayCutoff)
        var deduped = mergeReconciled(transcripts.filter { $0.parentID == nil }.map(\.session))
        let children = Dictionary(grouping: transcripts.filter { $0.parentID != nil }, by: \.parentID)
        for (parent, records) in children {
            let sessions = mergeReconciled(records.map(\.session))
            if let index = deduped.firstIndex(where: { $0.rawSessionID == parent }) {
                for child in sessions { deduped[index].rollUpChildUsage(child, dayCutoff: dayCutoff) }
            } else {
                deduped.append(contentsOf: sessions)
            }
        }
        return deduped
    }

    private static func mergeReconciled(_ rows: [AgentSession]) -> [AgentSession] {
        var result: [AgentSession] = []
        var indices: [String: Int] = [:]
        for row in rows {
            guard let index = indices[row.id] else {
                indices[row.id] = result.count
                result.append(row)
                continue
            }
            let previous = result[index]
            var merged = SessionDeduplicator.merge(previous, row)
            merged.usage = previous.usage.adding(row.usage)
            merged.todayUsage = (previous.todayUsage ?? TokenUsage()).adding(row.todayUsage ?? TokenUsage())
            merged.modelUsages = SessionDeduplicator.mergeModelUsageMaps(previous.modelUsages, row.modelUsages, additive: true)
            merged.todayModelUsages = SessionDeduplicator.mergeModelUsageMaps(previous.todayModelUsages, row.todayModelUsages, additive: true)
            result[index] = merged
        }
        return result
    }

    private static func reconcile(_ records: inout [Transcript], dayCutoff: Date) {
        var messageOwners: [String: (index: Int, entry: MessageUsageEntry)] = [:]
        var promptOwners: [String: Int] = [:]
        func prefers(_ index: Int, origin: String?, over previous: Int, previousOrigin: String?) -> Bool {
            let direct = origin == records[index].session.rawSessionID
            let previousDirect = previousOrigin == records[previous].session.rawSessionID
            if direct != previousDirect { return direct }
            if records[index].creation != records[previous].creation { return records[index].creation < records[previous].creation }
            return (records[index].session.sourceFilePath ?? "") < (records[previous].session.sourceFilePath ?? "")
        }
        func adjust(_ session: inout AgentSession, _ entry: MessageUsageEntry, add: Bool) {
            func updated(_ original: TokenUsage) -> TokenUsage {
                add ? original.adding(entry.usage) : original.subtractingClamped(entry.usage)
            }
            let model = entry.model ?? session.model
            func updateMap(_ map: inout [String: TokenUsage]?) {
                guard let model else { return }
                let value = updated(map?[model] ?? TokenUsage())
                if value.totalTokens == 0 { map?.removeValue(forKey: model) }
                else {
                    if map == nil { map = [:] }
                    map?[model] = value
                }
            }
            session.usage = updated(session.usage)
            updateMap(&session.modelUsages)
            if let date = entry.date, date >= dayCutoff {
                session.todayUsage = updated(session.todayUsage ?? TokenUsage())
                updateMap(&session.todayModelUsages)
            }
        }
        for index in records.indices {
            for (key, entry) in records[index].events.messages {
                guard let previous = messageOwners[key] else {
                    messageOwners[key] = (index, entry); continue
                }
                let keepNew = prefers(index, origin: entry.origin, over: previous.index, previousOrigin: previous.entry.origin)
                let owner = keepNew ? index : previous.index
                var merged = keepNew ? entry : previous.entry
                merged.usage = TokenUsage.componentMax(entry.usage, previous.entry.usage)
                adjust(&records[index].session, entry, add: false)
                adjust(&records[previous.index].session, previous.entry, add: false)
                adjust(&records[owner].session, merged, add: true)
                messageOwners[key] = (owner, merged)
            }
            for (key, prompt) in records[index].events.prompts {
                guard let previous = promptOwners[key] else { promptOwners[key] = index; continue }
                let keepNew = prefers(index, origin: prompt.1, over: previous, previousOrigin: records[previous].events.prompts[key]?.1)
                let duplicate = keepNew ? previous : index
                records[duplicate].session.turnCount -= 1
                if let date = records[duplicate].events.prompts[key]?.0, date >= dayCutoff {
                    records[duplicate].session.todayTurnCount? -= 1
                }
                if keepNew { promptOwners[key] = index }
            }
        }
    }

    private static func lookupCachedTranscript(
        path: String,
        mtime: TimeInterval,
        size: Int,
        dayCutoff: TimeInterval,
        includeSubagents: Bool
    ) -> Transcript?? {
        transcriptCacheLock.lock()
        defer { transcriptCacheLock.unlock() }
        guard let entry = transcriptCache[path],
              entry.mtime == mtime,
              entry.fileSize == size,
              entry.dayCutoff == dayCutoff,
              entry.includeSubagents == includeSubagents else {
            return nil
        }
        return entry.session
    }

    private static func storeCachedTranscript(
        path: String,
        mtime: TimeInterval,
        size: Int,
        dayCutoff: TimeInterval,
        includeSubagents: Bool,
        session: Transcript?
    ) {
        transcriptCacheLock.lock()
        defer { transcriptCacheLock.unlock() }
        if transcriptCache.count > 3000 {
            transcriptCache.removeAll(keepingCapacity: true)
        }
        transcriptCache[path] = CachedTranscriptEntry(
            mtime: mtime,
            fileSize: size,
            dayCutoff: dayCutoff,
            includeSubagents: includeSubagents,
            session: session
        )
    }

    public static func collectRecentJSONLFiles(
        rootPath: String,
        cutoff: Date,
        includeSubagents: Bool = false
    ) -> [(url: URL, mtime: Date)] {
        collectRecentJSONLFilesWithSubagents(
            rootPath: rootPath,
            cutoff: cutoff,
            includeSubagents: includeSubagents
        ).mainFiles
    }

    struct CollectedClaudeFiles {
        var mainFiles: [(url: URL, mtime: Date)]
        var subagentFiles: [(parentSessionID: String, url: URL, mtime: Date)]
    }

    static func collectRecentJSONLFilesWithSubagents(
        rootPath: String,
        cutoff: Date,
        includeSubagents: Bool = false,
        skipHiddenFiles: Bool = true,
        requireProjectsSubpath: Bool = false
    ) -> CollectedClaudeFiles {
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = skipHiddenFiles ? [.skipsHiddenFiles] : []
        guard fm.fileExists(atPath: rootPath),
              let enumerator = fm.enumerator(
                  at: URL(fileURLWithPath: rootPath),
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: options
              ) else {
            return CollectedClaudeFiles(mainFiles: [], subagentFiles: [])
        }
        var candidates: [(url: URL, mtime: Date)] = []
        var subagents: [(parentSessionID: String, url: URL, mtime: Date)] = []
        var subagentNewestByParentPath: [String: Date] = [:]
        while let obj = enumerator.nextObject() {
            guard let url = obj as? URL, url.pathExtension == "jsonl" else { continue }
            let pathStr = url.path
            if requireProjectsSubpath && !pathStr.contains("/.claude/projects/") {
                continue
            }
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard vals?.isRegularFile == true else { continue }
            let mtime = vals?.contentModificationDate ?? .distantPast
            if !includeSubagents, let subRange = pathStr.range(of: "/subagents/") {
                let parentDirPath = String(pathStr[..<subRange.lowerBound])
                let parentPrefix = parentDirPath + ".jsonl"
                if let prev = subagentNewestByParentPath[parentPrefix] {
                    if mtime > prev { subagentNewestByParentPath[parentPrefix] = mtime }
                } else {
                    subagentNewestByParentPath[parentPrefix] = mtime
                }
                if mtime >= cutoff {
                    let parentID = URL(fileURLWithPath: parentDirPath).lastPathComponent
                    if !parentID.isEmpty {
                        subagents.append((parentID, url, mtime))
                    }
                }
                continue
            }
            if mtime >= cutoff {
                candidates.append((url, mtime))
            }
        }
        for idx in candidates.indices {
            if let subMtime = subagentNewestByParentPath[candidates[idx].url.path],
               subMtime > candidates[idx].mtime {
                candidates[idx].mtime = subMtime
            }
        }
        candidates.sort { $0.mtime > $1.mtime }
        subagents.sort { $0.mtime > $1.mtime }
        return CollectedClaudeFiles(mainFiles: candidates, subagentFiles: subagents)
    }

    private static func collectClaudeDesktopLocalAgentFiles(
        rootPath: String,
        cutoff: Date,
        includeSubagents: Bool
    ) -> CollectedClaudeFiles {
        collectRecentJSONLFilesWithSubagents(
            rootPath: rootPath,
            cutoff: cutoff,
            includeSubagents: includeSubagents,
            skipHiddenFiles: false,
            requireProjectsSubpath: true
        )
    }

    public static func parseTranscript(
        jsonl: String,
        fallbackSessionID: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID,
        defaultProvider: String = "Anthropic",
        includeSubagents: Bool = false,
        seenAtByID: [String: TimeInterval] = [:],
        dayCutoff: Date = Calendar.current.startOfDay(for: Date())
    ) -> AgentSession? {
        var events = TranscriptEvents()
        return parseTranscript(jsonl: jsonl, fallbackSessionID: fallbackSessionID, filePath: filePath, fileModificationDate: fileModificationDate, host: host, defaultProvider: defaultProvider, includeSubagents: includeSubagents, seenAtByID: seenAtByID, dayCutoff: dayCutoff, events: &events)
    }

    private static func parseTranscript(jsonl: String, fallbackSessionID: String, filePath: String?, fileModificationDate: Date, host: HostID, defaultProvider: String, includeSubagents: Bool, seenAtByID: [String: TimeInterval], dayCutoff: Date, events: inout TranscriptEvents) -> AgentSession? {

        var rawSessionID = fallbackSessionID
        var agentID: String?
        var sawSidechain = false
        var sawNonSidechain = false
        var aiTitle: String?
        var customTitle: String?
        var firstUserPrompt: String?
        var lastUserPrompt: String?
        var cwd: String?
        var model: String?
        var usageByMessageID: [String: MessageUsageEntry] = [:]
        var anonymousEntries: [MessageUsageEntry] = []
        var lastPromptTokens: Int?
        var openTools: [String: ToolCallRecord] = [:]
        var openToolOrder: [String] = []
        var completedTools: [ToolCallRecord] = []
        var totalToolCalls = 0
        var failedToolCalls = 0
        var turnCount = 0
        var todayTurnCount = 0
        var compactCount = 0
        var lastAssistantText: String?
        var lastStopReason: String?
        var lastEventKind = ""
        var errorBanner: String?
        var sawIDEMarker = false
        var startedAt: Date?
        var lastActivityAt = fileModificationDate
        var lastGeneratedAt: Date?
        var lastEntrypoint: String?

        for lineSub in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = lineSub.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let sid = obj["sessionId"] as? String, !sid.isEmpty {
                rawSessionID = sid
            }
            if let aid = obj["agentId"] as? String, !aid.isEmpty {
                agentID = aid
            }
            if let sidechain = obj["isSidechain"] as? Bool {
                if sidechain {
                    sawSidechain = true
                } else {
                    sawNonSidechain = true
                }
            }
            if let dir = obj["cwd"] as? String, !dir.isEmpty {
                cwd = dir
            }
            if let ep = obj["entrypoint"] as? String, !ep.isEmpty {
                lastEntrypoint = ep
            }
            if let attachment = obj["attachment"] as? [String: Any] {
                sawIDEMarker = true
                let attType = (attachment["type"] as? String) ?? ""
                if attType == "environment",
                   let snap = attachment["snapshot"] as? [String: Any],
                   let wdir = snap["workingDirectory"] as? String,
                   !wdir.isEmpty {
                    if cwd == nil { cwd = wdir }
                } else if attType == "model",
                          let ident = attachment["identity"] as? [String: Any],
                          let mid = ident["modelId"] as? String,
                          !mid.isEmpty {
                    if model == nil { model = mid }
                }
            }
            let eventDate = parseISODate(obj["timestamp"] as? String)
            if let eventDate {
                if startedAt == nil { startedAt = eventDate }
                if eventDate > lastActivityAt { lastActivityAt = eventDate }
            }

            let type = (obj["type"] as? String) ?? ""
            switch type {
            case "ai-title":
                if let t = obj["aiTitle"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    aiTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    customTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "compact_boundary", "summary":
                compactCount += 1
            case "api-request", "api-request-blob":
                lastEventKind = "api_request"
                lastStopReason = nil
            case "user":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                let previousCount = turnCount
                if let text = msg["content"] as? String {
                    let cleaned = cleanUserPrompt(text)
                    if !cleaned.isEmpty {
                        if firstUserPrompt == nil { firstUserPrompt = cleaned }
                        lastUserPrompt = cleaned
                        turnCount += 1
                        lastEventKind = "user_prompt"
                        errorBanner = nil
                    }
                } else if let arr = msg["content"] as? [[String: Any]] {
                    var sawUserText = false
                    for item in arr {
                        let ctype = (item["type"] as? String) ?? ""
                        if ctype == "tool_result" {
                            let toolID = (item["tool_use_id"] as? String) ?? ""
                            let isErr = (item["is_error"] as? Bool) ?? false
                            if isErr { failedToolCalls += 1 }
                            if var tool = openTools.removeValue(forKey: toolID) {
                                openToolOrder.removeAll { $0 == toolID }
                                tool.finishedAt = eventDate ?? lastActivityAt
                                tool.isError = isErr
                                completedTools.append(tool)
                            }
                            lastEventKind = "tool_result"
                        } else if ctype == "text", let t = item["text"] as? String {
                            if t.contains("<ide_") {
                                sawIDEMarker = true
                            }
                            let cleaned = cleanUserPrompt(t)
                            if !cleaned.isEmpty {
                                if firstUserPrompt == nil { firstUserPrompt = cleaned }
                                lastUserPrompt = cleaned
                                sawUserText = true
                            }
                        }
                    }
                    if sawUserText {
                        turnCount += 1
                        lastEventKind = "user_prompt"
                        errorBanner = nil
                    }
                }
                if turnCount != previousCount {
                    if let uuid = obj["uuid"] as? String, !uuid.isEmpty {
                        if events.prompts[uuid] != nil { turnCount = previousCount; continue }
                        events.prompts[uuid] = (eventDate, obj["sessionId"] as? String)
                    }
                    if let eventDate, eventDate >= dayCutoff { todayTurnCount += 1 }
                }
            case "assistant":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                var msgModel: String?
                if let m = msg["model"] as? String, !m.isEmpty, m != "<synthetic>" {
                    model = m
                    msgModel = m
                }
                if let sr = msg["stop_reason"] as? String {
                    lastStopReason = sr
                }
                if let usageObj = msg["usage"] as? [String: Any] {
                    let u = TokenUsage(
                        input: (usageObj["input_tokens"] as? Int) ?? 0,
                        output: (usageObj["output_tokens"] as? Int) ?? 0,
                        cacheRead: (usageObj["cache_read_input_tokens"] as? Int) ?? 0,
                        cacheWrite: (usageObj["cache_creation_input_tokens"] as? Int) ?? 0
                    )
                    lastPromptTokens = u.totalPromptTokens
                    if let msgID = msg["id"] as? String, !msgID.isEmpty {
                        let prev = usageByMessageID[msgID]
                        let mergedUsage = TokenUsage.componentMax(prev?.usage ?? TokenUsage(), u)
                        let mergedDate: Date? = {
                            switch (prev?.date, eventDate) {
                            case let (d1?, d2?): return max(d1, d2)
                            case let (d1?, nil): return d1
                            case let (nil, d2?): return d2
                            case (nil, nil): return nil
                            }
                        }()
                        usageByMessageID[msgID] = MessageUsageEntry(
                            usage: mergedUsage,
                            model: msgModel ?? prev?.model ?? model,
                            date: mergedDate ?? fileModificationDate, origin: obj["sessionId"] as? String
                        )
                    } else {
                        anonymousEntries.append(MessageUsageEntry(
                            usage: u,
                            model: msgModel ?? model,
                            date: eventDate
                        ))
                    }
                }

                if let arr = msg["content"] as? [[String: Any]] {
                    var textChunks: [String] = []
                    for item in arr {
                        let ctype = (item["type"] as? String) ?? ""
                        if ctype == "text", let t = item["text"] as? String {
                            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                textChunks.append(trimmed)
                            }
                        } else if ctype == "tool_use" {
                            let id = (item["id"] as? String) ?? UUID().uuidString
                            let name = (item["name"] as? String) ?? "Tool"
                            let summary = summarizeToolInput(name: name, input: item["input"])
                            if openTools[id] == nil {
                                let record = ToolCallRecord(
                                    id: id,
                                    name: name,
                                    summary: summary,
                                    startedAt: eventDate ?? lastActivityAt
                                )
                                openTools[id] = record
                                openToolOrder.append(id)
                                totalToolCalls += 1
                            }
                            lastEventKind = "tool_use"
                        }
                    }
                    if !textChunks.isEmpty {
                        let joined = textChunks.joined(separator: "\n\n")
                        lastAssistantText = joined
                        lastGeneratedAt = eventDate ?? lastActivityAt
                        if openTools.isEmpty {
                            lastEventKind = "assistant_text"
                        }
                        if joined.contains("API Error:")
                            || joined.contains("rate_limit_error")
                            || joined.contains("429 Too Many Requests")
                            || joined.hasPrefix("Request timed out.") {
                            errorBanner = firstSingleLine(joined, maxLength: 140)
                        }
                    }
                }
            default:
                break
            }
        }

        let pathIsSubagent = filePath?.contains("/subagents/") == true
        let isSubagent = pathIsSubagent || agentID != nil || (sawSidechain && !sawNonSidechain)
        if isSubagent && !includeSubagents {
            return nil
        }

        let hasRealActivity = turnCount > 0
            || !usageByMessageID.isEmpty
            || anonymousEntries.contains(where: { $0.usage.totalTokens > 0 })
            || lastAssistantText != nil
            || !openTools.isEmpty
            || lastEventKind == "api_request"

        let finalTitle = customTitle
            ?? aiTitle
            ?? firstUserPrompt.map { firstSingleLine($0, maxLength: 44) }
            ?? (hasRealActivity ? lastAssistantText.map { firstSingleLine($0, maxLength: 44) } : nil)
            ?? (hasRealActivity ? cwd.map { "\(URL(fileURLWithPath: $0).lastPathComponent) 会话" } : nil)

        guard let finalTitle, !finalTitle.isEmpty else {
            return nil
        }

        var totalUsage = TokenUsage()
        var todayUsage = TokenUsage()
        var modelUsages: [String: TokenUsage] = [:]
        var todayModelUsages: [String: TokenUsage] = [:]

        for entry in (Array(usageByMessageID.values) + anonymousEntries) where entry.usage.totalTokens > 0 {
            totalUsage = totalUsage.adding(entry.usage)
            let resolvedModel = entry.model ?? model
            if let resolvedModel, !resolvedModel.isEmpty {
                modelUsages[resolvedModel] = (modelUsages[resolvedModel] ?? TokenUsage()).adding(entry.usage)
            }
            let ts = entry.date ?? fileModificationDate
            if ts >= dayCutoff {
                todayUsage = todayUsage.adding(entry.usage)
                if let resolvedModel, !resolvedModel.isEmpty {
                    todayModelUsages[resolvedModel] = (todayModelUsages[resolvedModel] ?? TokenUsage()).adding(entry.usage)
                }
            }
        }

        events.messages = usageByMessageID
        let desktop = host.isLocal && (lastEntrypoint?.hasPrefix("claude-desktop") == true || filePath?.contains("/local-agent-mode-sessions/") == true)
        let currentTool = openToolOrder.last.flatMap { openTools[$0] }
        var recent = completedTools
        if let currentTool {
            recent.append(currentTool)
        }
        let recentTail = Array(recent.suffix(5).reversed())

        let sessionID: String
        if isSubagent {
            let subagentKey = agentID ?? fallbackSessionID
            sessionID = "\(host.storageKey):claude:\(rawSessionID):\(subagentKey)"
        } else {
            sessionID = "\(host.storageKey):claude:\(rawSessionID)"
        }
        let isSeen = SeenSessionLookup.isSeen(
            sessionID: sessionID,
            lastActivityAt: lastGeneratedAt ?? lastActivityAt,
            seenAtByID: seenAtByID
        )
        let ageSeconds = Date().timeIntervalSince(lastActivityAt)

        let status: SessionStatus
        var statusInferred = false
        if errorBanner != nil && ageSeconds < 7200 {
            status = .failed
        } else if currentTool != nil && ageSeconds < 1800 {
            if ageSeconds > 8 && ageSeconds < 300 {
                status = .runningTool
                statusInferred = true
            } else {
                status = .runningTool
            }
        } else if (lastEventKind == "api_request"
            || lastEventKind == "user_prompt"
            || lastEventKind == "tool_result"
            || lastStopReason == "tool_use"
            || lastStopReason == nil) && ageSeconds < 600 {
            status = .generating
        } else if !isSeen && ageSeconds < 1800 && lastAssistantText != nil {
            status = .completed
        } else {
            status = .waitingForInput
        }

        let overview: String
        if let err = errorBanner {
            overview = err
        } else if let tool = currentTool {
            overview = "\(tool.name)：\(tool.summary)"
        } else if let text = lastAssistantText {
            overview = firstSingleLine(text, maxLength: 80)
        } else if let prompt = lastUserPrompt {
            overview = firstSingleLine(prompt, maxLength: 80)
        } else {
            overview = "等待你的下一条消息"
        }

        let contextWindow = PricingCatalog.defaultContextWindow(for: model)
        let resolvedProvider: String
        if defaultProvider == "Anthropic",
           let m = model,
           let slashIdx = m.firstIndex(of: "/"),
           slashIdx > m.startIndex {
            let prefix = String(m[..<slashIdx])
            resolvedProvider = FormattingHelpers.providerDisplay(from: prefix) ?? prefix
        } else {
            resolvedProvider = defaultProvider
        }
        return AgentSession(
            id: sessionID,
            rawSessionID: rawSessionID,
            kind: desktop ? .claudeDesktop : .claudeCode,
            host: host,
            title: finalTitle,
            overview: overview,
            status: status,
            statusIsInferred: statusInferred,
            cwd: cwd,
            groupDirectory: cwd,
            provider: resolvedProvider,
            model: model,
            usage: totalUsage,
            todayUsage: todayUsage,
            modelUsages: modelUsages.isEmpty ? nil : modelUsages,
            todayModelUsages: todayModelUsages.isEmpty ? nil : todayModelUsages,
            contextUsedTokens: lastPromptTokens,
            contextWindow: contextWindow,
            currentTool: currentTool,
            recentTools: recentTail,
            totalToolCalls: totalToolCalls,
            successfulToolCalls: max(0, totalToolCalls - failedToolCalls),
            turnCount: turnCount,
            todayTurnCount: todayTurnCount,
            compactCount: compactCount,
            lastOutputMarkdown: lastAssistantText,
            errorBanner: errorBanner,
            sourceFilePath: filePath,
            launchEnvironment: desktop ? .auto : ((sawIDEMarker || lastEntrypoint?.contains("vscode") == true) ? .vscodeExtension : .terminalCLI),
            startedAt: startedAt ?? fileModificationDate,
            lastActivityAt: lastActivityAt,
            isSeen: isSeen,
            lastGeneratedAt: lastGeneratedAt
        )
    }

    private static func cleanUserPrompt(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<local-command") || text.hasPrefix("<command-name>") {
            return ""
        }
        if let range = text.range(of: "</ide_opened_file>") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    public static func summarizeToolInput(name: String, input: Any?) -> String {
        if let dict = input as? [String: Any] {
            for key in ["command", "cmd", "file_path", "path", "pattern", "query", "url", "description"] {
                if let val = dict[key] as? String, !val.isEmpty {
                    return firstSingleLine(val, maxLength: 72)
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data, encoding: .utf8) {
                return firstSingleLine(s, maxLength: 72)
            }
        } else if let str = input as? String, !str.isEmpty {
            if let data = str.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return summarizeToolInput(name: name, input: dict)
            }
            if str.hasPrefix("*** Begin Patch") {
                let fileLine = str.split(whereSeparator: \.isNewline).first {
                    $0.hasPrefix("*** Update File:") || $0.hasPrefix("*** Add File:") || $0.hasPrefix("*** Delete File:")
                }
                if let fileLine {
                    let cleaned = fileLine
                        .replacingOccurrences(of: "*** Update File: ", with: "")
                        .replacingOccurrences(of: "*** Add File: ", with: "")
                        .replacingOccurrences(of: "*** Delete File: ", with: "")
                    return URL(fileURLWithPath: String(cleaned)).lastPathComponent
                }
            }
            return firstSingleLine(str, maxLength: 72)
        }
        return name
    }

    public static func firstSingleLine(_ text: String, maxLength: Int) -> String {
        let single = text
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = single
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
        if stripped.count <= maxLength {
            return stripped
        }
        return String(stripped.prefix(maxLength)) + "…"
    }
}
