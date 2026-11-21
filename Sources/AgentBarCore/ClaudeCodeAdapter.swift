import Darwin
import Foundation

public enum FastJSONL {
    public struct FileStatKey: Equatable, Sendable {
        public var mtimeSec: Int
        public var mtimeNsec: Int
        public var size: Int
    }

    public static func statKey(atPath path: String) -> FileStatKey? {
        var st = Darwin.stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileStatKey(
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec,
            size: Int(st.st_size)
        )
    }

    static func forEachJSONObject(in data: Data, _ body: ([String: Any]) -> Void) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = rawBuf.count
            var cursor = 0
            while cursor < count {
                autoreleasepool {
                    var processedInBatch = 0
                    while cursor < count && processedInBatch < 64 {
                        let remaining = count - cursor
                        let nlPtr = memchr(base + cursor, 0x0A, remaining)
                        let lineEnd: Int
                        if let nlPtr {
                            lineEnd = UnsafeRawPointer(nlPtr).assumingMemoryBound(to: UInt8.self) - base
                        } else {
                            lineEnd = count
                        }
                        var start = cursor
                        var end = lineEnd
                        cursor = lineEnd + 1

                        while start < end && base[start] <= 0x20 { start += 1 }
                        while end > start && base[end - 1] <= 0x20 { end -= 1 }
                        guard end - start >= 2, base[start] == 0x7B, base[end - 1] == 0x7D else {
                            continue
                        }
                        processedInBatch += 1
                        let sliceData = Data(
                            bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                            count: end - start,
                            deallocator: .none
                        )
                        if let obj = (try? JSONSerialization.jsonObject(with: sliceData)) as? [String: Any] {
                            body(obj)
                        }
                    }
                }
            }
        }
    }
}

public enum ClaudeCodeAdapter {
    private struct ParsedTranscriptCore {
        var baseSession: AgentSession
        var maxEventDate: Date?
        var firstEventDate: Date?
        var lastEventKind: String
        var lastStopReason: String?
        var hasAssistantText: Bool

        func materialize(
            effectiveModificationDate: Date,
            seenAtByID: [String: TimeInterval],
            now: Date
        ) -> AgentSession {
            var session = baseSession
            let lastActivityAt: Date
            if let maxEventDate, maxEventDate > effectiveModificationDate {
                lastActivityAt = maxEventDate
            } else {
                lastActivityAt = effectiveModificationDate
            }
            session.lastActivityAt = lastActivityAt
            if firstEventDate == nil {
                session.startedAt = effectiveModificationDate
            }
            let seenBaseline = session.lastGeneratedAt ?? lastActivityAt
            let isSeen = SeenSessionLookup.isSeen(
                sessionID: session.id,
                lastActivityAt: seenBaseline,
                seenAtByID: seenAtByID
            )
            let ageSeconds = now.timeIntervalSince(lastActivityAt)

            let status: SessionStatus
            var statusInferred = false
            if session.errorBanner != nil && ageSeconds < 7200 {
                status = .failed
            } else if session.currentTool != nil && ageSeconds < 1800 {
                status = .runningTool
                statusInferred = ageSeconds > 8 && ageSeconds < 300
            } else if (lastEventKind == "api_request"
                || lastEventKind == "user_prompt"
                || lastEventKind == "tool_result"
                || lastStopReason == "tool_use"
                || lastStopReason == nil) && ageSeconds < 600 {
                status = .generating
            } else if !isSeen && ageSeconds < 1800 && hasAssistantText {
                status = .completed
            } else {
                status = .waitingForInput
            }
            session.isSeen = isSeen
            session.status = status
            session.statusIsInferred = statusInferred
            return session
        }
    }

    private struct CachedTranscriptEntry {
        var stat: FastJSONL.FileStatKey
        var dayCutoff: TimeInterval
        var provider: String
        var includeSubagents: Bool
        var core: ParsedTranscriptCore?
    }

    private static let transcriptCacheLock = NSLock()
    nonisolated(unsafe) private static var transcriptCache: [String: CachedTranscriptEntry] = [:]
    nonisolated(unsafe) private static var providerCache: [String: (stat: FastJSONL.FileStatKey?, value: String)] = [:]

    private static let fractionalISOStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let basicISOStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let fast = parseFastUTCISODate(raw) {
            return fast
        }
        return (try? fractionalISOStyle.parse(raw)) ?? (try? basicISOStyle.parse(raw))
    }

    private static func parseFastUTCISODate(_ raw: String) -> Date? {
        var rawCopy = raw
        return rawCopy.withUTF8 { buf -> Date? in
            let n = buf.count
            // Minimum "YYYY-MM-DDTHH:MM:SSZ" = 20 bytes
            guard n >= 20,
                  buf[n - 1] == 0x5A || buf[n - 1] == 0x7A, // 'Z' or 'z'
                  buf[4] == 0x2D, buf[7] == 0x2D,
                  (buf[10] == 0x54 || buf[10] == 0x74 || buf[10] == 0x20),
                  buf[13] == 0x3A, buf[16] == 0x3A else {
                return nil
            }
            @inline(__always)
            func digit(_ idx: Int) -> Int? {
                let b = buf[idx]
                return (b >= 0x30 && b <= 0x39) ? Int(b - 0x30) : nil
            }
            @inline(__always)
            func twoDigits(_ idx: Int) -> Int? {
                guard let d1 = digit(idx), let d2 = digit(idx + 1) else { return nil }
                return d1 * 10 + d2
            }
            guard let c1 = twoDigits(0), let c2 = twoDigits(2),
                  let month = twoDigits(5), month >= 1, month <= 12,
                  let day = twoDigits(8), day >= 1, day <= 31,
                  let hour = twoDigits(11), hour <= 23,
                  let minute = twoDigits(14), minute <= 59,
                  let second = twoDigits(17), second <= 60 else {
                return nil
            }
            var fracSeconds = 0.0
            if n > 20 {
                guard buf[19] == 0x2E else { return nil } // '.'
                var scale = 0.1
                var i = 20
                guard i < n - 1 else { return nil }
                while i < n - 1 {
                    guard let d = digit(i) else { return nil }
                    fracSeconds += Double(d) * scale
                    scale *= 0.1
                    i += 1
                }
            }
            let year = c1 * 100 + c2
            var y = year
            if month <= 2 { y -= 1 }
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146097 + doe - 719468
            let totalSec = Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fracSeconds
            return Date(timeIntervalSince1970: totalSec)
        }
    }

    public static func detectLocalProvider(homeDirectory: String = NSHomeDirectory()) -> String {
        let path = (homeDirectory as NSString).appendingPathComponent(".claude/settings.json")
        let curStat = FastJSONL.statKey(atPath: path)
        transcriptCacheLock.lock()
        if let cached = providerCache[path], cached.stat == curStat {
            transcriptCacheLock.unlock()
            return cached.value
        }
        transcriptCacheLock.unlock()

        let resolved: String = {
            guard curStat != nil,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
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
        }()

        transcriptCacheLock.lock()
        providerCache[path] = (curStat, resolved)
        transcriptCacheLock.unlock()
        return resolved
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
        var parsedSessions: [AgentSession] = []
        var acceptedIDs: Set<String> = []
        let now = Date()
        let dayCutoff = Calendar.current.startOfDay(for: now)
        let dayCutoffTS = dayCutoff.timeIntervalSince1970

        for item in collected.mainFiles.prefix(maxCandidateScan) {
            if var session = loadOrParseLocalTranscript(
                url: item.url,
                effectiveModificationDate: item.mtime,
                provider: provider,
                includeSubagents: includeSubagents,
                seenAtByID: seenAtByID,
                dayCutoff: dayCutoff,
                dayCutoffTS: dayCutoffTS,
                now: now
            ) {
                if !acceptedIDs.contains(session.id) {
                    guard acceptedIDs.count < maxUniqueSessions || item.mtime >= dayCutoff else { continue }
                    acceptedIDs.insert(session.id)
                }
                session.groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: session.cwd)
                parsedSessions.append(session)
            }
        }
        var deduped = SessionDeduplicator.deduplicate(parsedSessions)
        if !includeSubagents && !collected.subagentFiles.isEmpty {
            let subsByParent = Dictionary(grouping: collected.subagentFiles.prefix(1000), by: \.parentSessionID)
            for idx in deduped.indices {
                guard let subItems = subsByParent[deduped[idx].rawSessionID] else { continue }
                var subParsed: [AgentSession] = []
                for subItem in subItems {
                    if let subSession = loadOrParseLocalTranscript(
                        url: subItem.url,
                        effectiveModificationDate: subItem.mtime,
                        provider: provider,
                        includeSubagents: true,
                        seenAtByID: seenAtByID,
                        dayCutoff: dayCutoff,
                        dayCutoffTS: dayCutoffTS,
                        now: now
                    ) {
                        subParsed.append(subSession)
                    }
                }
                for subSession in SessionDeduplicator.deduplicate(subParsed) {
                    deduped[idx].rollUpChildUsage(subSession, dayCutoff: dayCutoff)
                }
            }
        }
        return deduped
    }

    private static func loadOrParseLocalTranscript(
        url: URL,
        effectiveModificationDate: Date,
        provider: String,
        includeSubagents: Bool,
        seenAtByID: [String: TimeInterval],
        dayCutoff: Date,
        dayCutoffTS: TimeInterval,
        now: Date
    ) -> AgentSession? {
        let filePath = url.path
        guard let stat = FastJSONL.statKey(atPath: filePath) else { return nil }
        let coreOpt: ParsedTranscriptCore?
        if let cached = lookupCachedTranscript(
            path: filePath,
            stat: stat,
            dayCutoff: dayCutoffTS,
            provider: provider,
            includeSubagents: includeSubagents
        ) {
            coreOpt = cached
        } else {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let diskDate = Date(
                timeIntervalSince1970: Double(stat.mtimeSec) + Double(stat.mtimeNsec) / 1_000_000_000.0
            )
            let rawID = url.deletingPathExtension().lastPathComponent
            let fresh = parseTranscriptCore(
                data: data,
                fallbackSessionID: rawID,
                filePath: filePath,
                fileModificationDate: diskDate,
                host: .local,
                defaultProvider: provider,
                includeSubagents: includeSubagents,
                dayCutoff: dayCutoff
            )
            storeCachedTranscript(
                path: filePath,
                stat: stat,
                dayCutoff: dayCutoffTS,
                provider: provider,
                includeSubagents: includeSubagents,
                core: fresh
            )
            coreOpt = fresh
        }
        return coreOpt?.materialize(
            effectiveModificationDate: effectiveModificationDate,
            seenAtByID: seenAtByID,
            now: now
        )
    }

    private static func lookupCachedTranscript(
        path: String,
        stat: FastJSONL.FileStatKey,
        dayCutoff: TimeInterval,
        provider: String,
        includeSubagents: Bool
    ) -> ParsedTranscriptCore?? {
        transcriptCacheLock.lock()
        defer { transcriptCacheLock.unlock() }
        guard let entry = transcriptCache[path],
              entry.stat == stat,
              entry.dayCutoff == dayCutoff,
              entry.provider == provider,
              entry.includeSubagents == includeSubagents else {
            return nil
        }
        return entry.core
    }

    private static func storeCachedTranscript(
        path: String,
        stat: FastJSONL.FileStatKey,
        dayCutoff: TimeInterval,
        provider: String,
        includeSubagents: Bool,
        core: ParsedTranscriptCore?
    ) {
        transcriptCacheLock.lock()
        defer { transcriptCacheLock.unlock() }
        if transcriptCache.count > 4000 {
            transcriptCache.removeAll(keepingCapacity: true)
        }
        transcriptCache[path] = CachedTranscriptEntry(
            stat: stat,
            dayCutoff: dayCutoff,
            provider: provider,
            includeSubagents: includeSubagents,
            core: core
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
        let data = Data(jsonl.utf8)
        return parseTranscriptCore(
            data: data,
            fallbackSessionID: fallbackSessionID,
            filePath: filePath,
            fileModificationDate: fileModificationDate,
            host: host,
            defaultProvider: defaultProvider,
            includeSubagents: includeSubagents,
            dayCutoff: dayCutoff
        )?.materialize(
            effectiveModificationDate: fileModificationDate,
            seenAtByID: seenAtByID,
            now: Date()
        )
    }

    private static func parseTranscriptCore(
        data: Data,
        fallbackSessionID: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID,
        defaultProvider: String,
        includeSubagents: Bool,
        dayCutoff: Date
    ) -> ParsedTranscriptCore? {
        struct MessageUsageEntry {
            var usage: TokenUsage
            var model: String?
            var date: Date?
        }

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
        var compactCount = 0
        var lastAssistantText: String?
        var lastStopReason: String?
        var lastEventKind = ""
        var errorBanner: String?
        var sawIDEMarker = false
        var startedAt: Date?
        var maxEventDate: Date?
        var lastActivityAt = fileModificationDate
        var lastGeneratedAt: Date?
        var lastEntrypoint: String?

        FastJSONL.forEachJSONObject(in: data) { obj in
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
                if maxEventDate == nil || eventDate > maxEventDate! {
                    maxEventDate = eventDate
                }
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
                guard let msg = obj["message"] as? [String: Any] else { return }
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
            case "assistant":
                guard let msg = obj["message"] as? [String: Any] else { return }
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
                            date: mergedDate
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
        let baseSession = AgentSession(
            id: sessionID,
            rawSessionID: rawSessionID,
            kind: .claudeCode,
            host: host,
            title: finalTitle,
            overview: overview,
            status: .waitingForInput,
            statusIsInferred: false,
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
            turnCount: max(1, turnCount),
            compactCount: compactCount,
            lastOutputMarkdown: lastAssistantText,
            errorBanner: errorBanner,
            sourceFilePath: filePath,
            launchEnvironment: (sawIDEMarker || lastEntrypoint?.contains("vscode") == true) ? .vscodeExtension : .terminalCLI,
            startedAt: startedAt ?? fileModificationDate,
            lastActivityAt: lastActivityAt,
            isSeen: false,
            lastGeneratedAt: lastGeneratedAt
        )
        return ParsedTranscriptCore(
            baseSession: baseSession,
            maxEventDate: maxEventDate,
            firstEventDate: startedAt,
            lastEventKind: lastEventKind,
            lastStopReason: lastStopReason,
            hasAssistantText: lastAssistantText != nil
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
            for key in ["command", "cmd", "file_path", "path", "pattern", "query", "url", "description", "skill", "notebook_path", "prompt"] {
                if let val = dict[key] as? String, !val.isEmpty {
                    return firstSingleLine(val, maxLength: 72)
                }
            }
            // Avoid serializing huge multi-KB tool payloads (e.g. file contents) just for a 72-char preview
            for (k, v) in dict {
                if let s = v as? String, !s.isEmpty {
                    return firstSingleLine("\(k): \(firstSingleLine(s, maxLength: 60))", maxLength: 72)
                }
            }
            if dict.count <= 8,
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data.prefix(256), encoding: .utf8) {
                return firstSingleLine(s, maxLength: 72)
            }
        } else if let str = input as? String, !str.isEmpty {
            let firstNonWS = str.utf8.first { $0 > 0x20 }
            if firstNonWS == 0x7B { // '{'
                if str.utf8.count <= 32_768,
                   let data = str.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return summarizeToolInput(name: name, input: dict)
                }
            } else if str.hasPrefix("*** Begin Patch") {
                let prefixText = str.utf8.count > 1024 ? String(decoding: str.utf8.prefix(1024), as: UTF8.self) : str
                let fileLine = prefixText.split(whereSeparator: \.isNewline).first {
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
        guard !text.isEmpty else { return "" }
        let scalars = text.unicodeScalars
        let maxTotalScalars = max(2048, maxLength * 16)
        let maxLineScalars = max(256, maxLength * 3)
        var cursor = scalars.startIndex
        var scannedScalars = 0
        var chosenLine: String?

        while cursor < scalars.endIndex && scannedScalars < maxTotalScalars {
            // Skip leading whitespace / newlines
            while cursor < scalars.endIndex && scannedScalars < maxTotalScalars {
                let v = scalars[cursor].value
                if v == 0x0A || v == 0x0D || v == 0x20 || v == 0x09 || scalars[cursor].properties.isWhitespace {
                    cursor = scalars.index(after: cursor)
                    scannedScalars += 1
                } else {
                    break
                }
            }
            guard cursor < scalars.endIndex && scannedScalars < maxTotalScalars else { break }

            let lineStart = cursor
            var lineScalarCount = 0
            var lineKeepEnd = cursor
            while cursor < scalars.endIndex && scannedScalars < maxTotalScalars {
                let v = scalars[cursor].value
                if v == 0x0A || v == 0x0D || v == 0x2028 || v == 0x2029 {
                    break
                }
                cursor = scalars.index(after: cursor)
                scannedScalars += 1
                if lineScalarCount < maxLineScalars {
                    lineScalarCount += 1
                    lineKeepEnd = cursor
                }
            }

            let rawLine = String(String.UnicodeScalarView(scalars[lineStart..<lineKeepEnd]))
                .trimmingCharacters(in: .whitespaces)
            if !rawLine.isEmpty && !rawLine.hasPrefix("```") {
                chosenLine = rawLine
                break
            }
        }

        let single: String
        if let chosenLine {
            single = chosenLine
        } else {
            let capEnd = scalars.index(scalars.startIndex, offsetBy: maxLineScalars, limitedBy: scalars.endIndex) ?? scalars.endIndex
            single = String(String.UnicodeScalarView(scalars[scalars.startIndex..<capEnd]))
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

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
