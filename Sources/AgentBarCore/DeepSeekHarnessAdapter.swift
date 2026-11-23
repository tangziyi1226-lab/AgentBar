import Foundation

public enum DeepSeekHarnessAdapter {
    public struct DSHLogTailState: Sendable {
        public var lastEventAt: Date?
        public var turnOpen: Bool?
        public var currentTool: ToolCallRecord?
        public var pendingApproval: PendingApproval?
        public var resolvedQuestionCallIDs: Set<String>
        public var cwd: String?
        public var firstPrompt: String?

        public init(
            lastEventAt: Date? = nil,
            turnOpen: Bool? = nil,
            currentTool: ToolCallRecord? = nil,
            pendingApproval: PendingApproval? = nil,
            resolvedQuestionCallIDs: Set<String> = [],
            cwd: String? = nil,
            firstPrompt: String? = nil
        ) {
            self.lastEventAt = lastEventAt
            self.turnOpen = turnOpen
            self.currentTool = currentTool
            self.pendingApproval = pendingApproval
            self.resolvedQuestionCallIDs = resolvedQuestionCallIDs
            self.cwd = cwd
            self.firstPrompt = firstPrompt
        }
    }

    private struct ProjectionCore {
        var baseSession: AgentSession
        var hasPendingToolCalls: Bool
        var turnOpen: Bool
        var hasResponseOrDraft: Bool
        var activeQuestionCallID: String?

        func materialize(
            fileModificationDate: Date,
            logTail: DSHLogTailState?,
            seenAtByID: [String: TimeInterval],
            now: Date
        ) -> AgentSession {
            var session = baseSession
            var effectiveActivityAt = fileModificationDate
            if let logTime = logTail?.lastEventAt, logTime > effectiveActivityAt {
                effectiveActivityAt = logTime
            }
            session.lastActivityAt = effectiveActivityAt

            var effectiveApproval = session.pendingApproval
            if let qCallID = activeQuestionCallID,
               logTail?.resolvedQuestionCallIDs.contains(qCallID) == true {
                effectiveApproval = nil
            }
            if let logApproval = logTail?.pendingApproval {
                effectiveApproval = logApproval
            } else if let logTail, logTail.turnOpen == false {
                effectiveApproval = nil
            }

            let effectiveTurnOpen = logTail?.turnOpen ?? turnOpen
            let effectiveTool = logTail?.currentTool ?? session.currentTool
            session.currentTool = effectiveTool

            let isSeen = SeenSessionLookup.isSeen(
                sessionID: session.id,
                lastActivityAt: effectiveActivityAt,
                seenAtByID: seenAtByID
            )
            let age = now.timeIntervalSince(effectiveActivityAt)

            let status: SessionStatus
            if let approval = effectiveApproval,
               now.timeIntervalSince(approval.requestedAt) < 43_200,
               age < 43_200 {
                status = .awaitingApproval
                session.pendingApproval = approval
                if approval.toolName == "ask_user_question" || approval.toolName == "AskUserQuestion" {
                    session.overview = "等待确认：\(approval.commandOrSummary)"
                } else {
                    session.overview = "请求执行 \(approval.toolName)：\(approval.commandOrSummary)"
                }
            } else {
                session.pendingApproval = nil
                let hasRunningTool = (effectiveTool != nil) || (hasPendingToolCalls && logTail?.turnOpen != false)
                if hasRunningTool && age < 600 {
                    status = .runningTool
                    if let tool = effectiveTool {
                        session.overview = "\(tool.name)：\(tool.summary)"
                    }
                } else if effectiveTurnOpen && age < 300 {
                    status = .generating
                } else if !isSeen && age < 1800 && hasResponseOrDraft {
                    status = .completed
                } else {
                    status = .waitingForInput
                }
            }

            session.isSeen = isSeen
            session.status = status
            return session
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var projectionCache: [String: (stat: FastJSONL.FileStatKey, core: ProjectionCore?)] = [:]
    nonisolated(unsafe) private static var logPathIndexCache: [String: (dirStats: [FastJSONL.FileStatKey], map: [String: String])] = [:]
    nonisolated(unsafe) private static var logTailCache: [String: (stat: FastJSONL.FileStatKey, tail: DSHLogTailState)] = [:]

    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 96,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> [AgentSession] {
        let dirPath = (homeDirectory as NSString).appendingPathComponent(".dsh/storages/session_projcache/sessions")
        let logPathsByID = resolveSessionLogPaths(homeDirectory: homeDirectory)
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let now = Date()
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        var results: [AgentSession] = []
        var seenRawIDs: Set<String> = []

        for url in items where url.pathExtension == "json" {
            let rawID = url.deletingPathExtension().lastPathComponent
            let projMtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let logPath = logPathsByID[rawID]
            let logStat = logPath.flatMap { FastJSONL.statKey(atPath: $0) }
            let logMtime = logStat.map {
                Date(timeIntervalSince1970: Double($0.mtimeSec) + Double($0.mtimeNsec) / 1_000_000_000.0)
            } ?? .distantPast
            let effectiveMtime = max(projMtime, logMtime)
            guard effectiveMtime >= cutoff else { continue }

            let filePath = url.path
            guard let stat = FastJSONL.statKey(atPath: filePath) else { continue }

            let cachedHit: (found: Bool, core: ProjectionCore?) = cacheLock.withLock {
                if let hit = projectionCache[filePath], hit.stat == stat {
                    return (true, hit.core)
                }
                return (false, nil)
            }
            let coreOpt: ProjectionCore?
            if cachedHit.found {
                coreOpt = cachedHit.core
            } else {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                let fresh = parseProjectionCore(
                    data: data,
                    fallbackID: rawID,
                    filePath: filePath,
                    fileModificationDate: projMtime,
                    host: .local
                )
                cacheLock.withLock {
                    if projectionCache.count > 2000 {
                        projectionCache.removeAll(keepingCapacity: true)
                    }
                    projectionCache[filePath] = (stat, fresh)
                }
                coreOpt = fresh
            }

            guard let core = coreOpt else { continue }
            seenRawIDs.insert(rawID)

            // Only inspect session.v4.jsonl.zstd for recently active sessions (within 12h) or when open state exists.
            let shouldInspectLog = (now.timeIntervalSince(effectiveMtime) < 43_200)
                && (core.turnOpen || core.hasPendingToolCalls || core.baseSession.pendingApproval != nil || logMtime >= projMtime.addingTimeInterval(-10) || now.timeIntervalSince(logMtime) < 1800)
            let logTail: DSHLogTailState?
            if shouldInspectLog, let logPath, let logStat {
                logTail = loadCachedLogTail(
                    path: logPath,
                    stat: logStat,
                    sessionID: rawID,
                    cwd: core.baseSession.cwd,
                    host: .local
                )
            } else {
                logTail = nil
            }

            var session = core.materialize(
                fileModificationDate: effectiveMtime,
                logTail: logTail,
                seenAtByID: seenAtByID,
                now: now
            )
            session.groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: session.cwd)
            results.append(session)
        }

        // Also surface brand-new sessions whose session.v4.jsonl.zstd exists before session_projcache flushes.
        for (rawID, logPath) in logPathsByID where !seenRawIDs.contains(rawID) {
            guard let logStat = FastJSONL.statKey(atPath: logPath) else { continue }
            let logMtime = Date(timeIntervalSince1970: Double(logStat.mtimeSec) + Double(logStat.mtimeNsec) / 1_000_000_000.0)
            guard now.timeIntervalSince(logMtime) < 600, logMtime >= cutoff else { continue }
            guard let tail = loadCachedLogTail(
                path: logPath,
                stat: logStat,
                sessionID: rawID,
                cwd: nil,
                host: .local
            ) else { continue }
            guard tail.pendingApproval != nil || tail.turnOpen == true || tail.currentTool != nil else { continue }
            let sessionID = "local:dsh:\(rawID)"
            let title = tail.firstPrompt.map { ClaudeCodeAdapter.firstSingleLine($0, maxLength: 44) }
                ?? tail.cwd.map { "\(URL(fileURLWithPath: $0).lastPathComponent) 会话" }
                ?? "DeepSeek Harness 会话"
            let status: SessionStatus
            let overview: String
            if let approval = tail.pendingApproval {
                status = .awaitingApproval
                overview = approval.toolName == "ask_user_question"
                    ? "等待确认：\(approval.commandOrSummary)"
                    : "请求执行 \(approval.toolName)：\(approval.commandOrSummary)"
            } else if let tool = tail.currentTool {
                status = .runningTool
                overview = "\(tool.name)：\(tool.summary)"
            } else {
                status = .generating
                overview = tail.firstPrompt.map { ClaudeCodeAdapter.firstSingleLine($0, maxLength: 80) } ?? "正在生成…"
            }
            var session = AgentSession(
                id: sessionID,
                rawSessionID: rawID,
                kind: .deepseekHarness,
                host: .local,
                title: title,
                overview: overview,
                status: status,
                cwd: tail.cwd,
                groupDirectory: await GitRootResolver.shared.resolveGroupDirectory(for: tail.cwd),
                provider: "DeepSeek",
                currentTool: tail.currentTool,
                pendingApproval: tail.pendingApproval,
                sourceFilePath: logPath,
                launchEnvironment: .deepseekHarnessApp,
                startedAt: tail.lastEventAt ?? logMtime,
                lastActivityAt: tail.lastEventAt ?? logMtime,
                isSeen: SeenSessionLookup.isSeen(sessionID: sessionID, lastActivityAt: tail.lastEventAt ?? logMtime, seenAtByID: seenAtByID)
            )
            if session.status == .awaitingApproval, var app = session.pendingApproval, app.cwd == nil {
                app.cwd = tail.cwd
                session.pendingApproval = app
            }
            results.append(session)
        }

        return results
    }

    private static func resolveSessionLogPaths(homeDirectory: String) -> [String: String] {
        let sessionsRoot = (homeDirectory as NSString).appendingPathComponent(".dsh/sessions")
        guard let rootStat = FastJSONL.statKey(atPath: sessionsRoot) else { return [:] }
        let fm = FileManager.default
        let workspaceDirs = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: sessionsRoot),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var stats: [FastJSONL.FileStatKey] = [rootStat]
        stats.reserveCapacity(workspaceDirs.count + 1)
        for ws in workspaceDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let st = FastJSONL.statKey(atPath: ws.path) {
                stats.append(st)
            }
        }

        let cached: [String: String]? = cacheLock.withLock {
            if let hit = logPathIndexCache[sessionsRoot], hit.dirStats == stats {
                return hit.map
            }
            return nil
        }
        if let cached { return cached }

        var map: [String: String] = [:]
        for ws in workspaceDirs {
            guard let sessionDirs = try? fm.contentsOfDirectory(
                at: ws,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for sDir in sessionDirs {
                let sid = sDir.lastPathComponent
                let zstdPath = sDir.appendingPathComponent("session.v4.jsonl.zstd").path
                if fm.fileExists(atPath: zstdPath) {
                    map[sid] = zstdPath
                }
            }
        }

        cacheLock.withLock {
            logPathIndexCache[sessionsRoot] = (stats, map)
        }
        return map
    }

    private static func loadCachedLogTail(
        path: String,
        stat: FastJSONL.FileStatKey,
        sessionID: String,
        cwd: String?,
        host: HostID
    ) -> DSHLogTailState? {
        let cached: DSHLogTailState? = cacheLock.withLock {
            if let hit = logTailCache[path], hit.stat == stat {
                return hit.tail
            }
            return nil
        }
        if let cached { return cached }

        guard let rawCompressed = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              !rawCompressed.isEmpty else {
            return nil
        }
        let maxTailBytes = 262_144
        let tailSlice: Data
        if rawCompressed.count <= maxTailBytes {
            tailSlice = rawCompressed
        } else {
            tailSlice = Data(rawCompressed.suffix(maxTailBytes))
        }
        guard let jsonlData = decodeZstdConcatenatedFrames(tailSlice) else {
            return nil
        }
        let parsed = parseSessionLogTail(
            jsonlData: jsonlData,
            sessionID: sessionID,
            cwd: cwd,
            host: host
        )
        cacheLock.withLock {
            if logTailCache.count > 1000 {
                logTailCache.removeAll(keepingCapacity: true)
            }
            logTailCache[path] = (stat, parsed)
        }
        return parsed
    }

    /// Decodes one or more concatenated Zstandard frames (e.g. DSH `session.v4.jsonl.zstd` append-only frame streams).
    /// If `data` is a tail slice starting mid-frame, scans forward to the first valid Zstandard frame magic (`0xFD2FB528`).
    public static func decodeZstdConcatenatedFrames(_ data: Data, maxDecompressedBytes: Int = 4_194_304) -> Data? {
        let out = ZstdDecoder.decodeConcatenatedFrames(data, maxDecompressedBytes: maxDecompressedBytes)
        return out.isEmpty ? nil : out
    }

    public static func parseSessionLogTail(
        jsonlData: Data,
        sessionID: String,
        cwd: String?,
        host: HostID = .local
    ) -> DSHLogTailState {
        struct PendingAskedItem {
            var id: String
            var toolName: String
            var callID: String?
            var summary: String
            var requestedAt: Date
        }

        var lastEventAt: Date?
        var turnOpen: Bool?
        var resolvedCwd = cwd
        var firstPrompt: String?
        var openTools: [String: ToolCallRecord] = [:]
        var openToolOrder: [String] = []
        var openApprovals: [String: PendingAskedItem] = [:]
        var openApprovalOrder: [String] = []
        var openQuestions: [String: PendingAskedItem] = [:]
        var openQuestionOrder: [String] = []
        var resolvedQuestionCallIDs: Set<String> = []

        FastJSONL.forEachJSONObject(in: jsonlData) { obj in
            let type = (obj["type"] as? String) ?? ""
            let timeMs = (obj["time"] as? Double) ?? (obj["time"] as? Int).map(Double.init)
            let eventDate = timeMs.map { Date(timeIntervalSince1970: $0 / 1000.0) }
            if let eventDate {
                if lastEventAt == nil || eventDate > lastEventAt! {
                    lastEventAt = eventDate
                }
            }
            let dataObj = obj["data"] as? [String: Any]

            switch type {
            case "session/seed", "workspace/cwd":
                if let dir = (dataObj?["cwd"] as? String) ?? ((dataObj?["identity"] as? [String: Any])?["cwd"] as? String),
                   !dir.isEmpty {
                    resolvedCwd = dir
                }

            case "user/message":
                if firstPrompt == nil,
                   let content = dataObj?["content"] as? [[String: Any]] {
                    for part in content where (part["type"] as? String) == "text" {
                        if let text = part["text"] as? String,
                           !text.hasPrefix("Time sampled while preparing turn"),
                           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            firstPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                }
                if let src = dataObj?["source"] as? [String: Any],
                   (src["kind"] as? String) == "user-question-reply" {
                    if let cid = src["callId"] as? String, !cid.isEmpty {
                        resolvedQuestionCallIDs.insert(cid)
                        openQuestions.removeValue(forKey: cid)
                        openQuestionOrder.removeAll { $0 == cid }
                    } else {
                        resolvedQuestionCallIDs.formUnion(openQuestions.keys)
                        openQuestions.removeAll()
                        openQuestionOrder.removeAll()
                    }
                }

            case "turn/start", "step/start":
                turnOpen = true

            case "turn/end", "session/end-seed":
                turnOpen = false
                openTools.removeAll()
                openToolOrder.removeAll()
                openApprovals.removeAll()
                openApprovalOrder.removeAll()
                resolvedQuestionCallIDs.formUnion(openQuestions.keys)
                openQuestions.removeAll()
                openQuestionOrder.removeAll()

            case "tool/call":
                turnOpen = true
                guard let dataObj else { return }
                let callID = (dataObj["callId"] as? String) ?? UUID().uuidString
                let name = (dataObj["name"] as? String) ?? "tool"
                let args = dataObj["arguments"] ?? dataObj["input"]
                let summary = ClaudeCodeAdapter.summarizeToolInput(name: name, input: args)
                let started = eventDate ?? lastEventAt ?? Date()
                let record = ToolCallRecord(id: callID, name: name, summary: summary, startedAt: started)
                openTools[callID] = record
                openToolOrder.removeAll { $0 == callID }
                openToolOrder.append(callID)

                if name == "ask_user_question" || name == "AskUserQuestion" {
                    let qItem = PendingAskedItem(
                        id: callID,
                        toolName: name,
                        callID: callID,
                        summary: summary,
                        requestedAt: started
                    )
                    openQuestions[callID] = qItem
                    openQuestionOrder.removeAll { $0 == callID }
                    openQuestionOrder.append(callID)
                }

            case "tool/result":
                guard let dataObj else { return }
                let msgObj = dataObj["message"] as? [String: Any]
                let srcObj = msgObj?["source"] as? [String: Any]
                let callID = (dataObj["callId"] as? String)
                    ?? (dataObj["toolCallId"] as? String)
                    ?? (msgObj?["toolCallId"] as? String)
                    ?? (srcObj?["callId"] as? String)
                    ?? ""
                let statusStr = (dataObj["status"] as? String) ?? (msgObj?["status"] as? String) ?? ""
                if statusStr != "pending", !callID.isEmpty {
                    openTools.removeValue(forKey: callID)
                    openToolOrder.removeAll { $0 == callID }
                    if openQuestions.removeValue(forKey: callID) != nil {
                        openQuestionOrder.removeAll { $0 == callID }
                    }
                    resolvedQuestionCallIDs.insert(callID)
                    let matchingApprovalIDs = openApprovals.values.filter { $0.callID == callID }.map(\.id)
                    for aid in matchingApprovalIDs {
                        openApprovals.removeValue(forKey: aid)
                        openApprovalOrder.removeAll { $0 == aid }
                    }
                }

            case "approval/asked":
                turnOpen = true
                guard let dataObj,
                      let id = dataObj["id"] as? String, !id.isEmpty else { return }
                let toolName = (dataObj["toolName"] as? String) ?? "tool"
                let callID = dataObj["callId"] as? String
                let rawReason = (dataObj["reason"] as? String) ?? ""
                let toolSummary = callID.flatMap { openTools[$0]?.summary }
                let subjectSummary: String? = dataObj["subject"].map {
                    ClaudeCodeAdapter.summarizeToolInput(name: toolName, input: $0)
                }
                let cmdCandidate = [toolSummary, subjectSummary].compactMap { $0 }.first { !$0.isEmpty && $0 != toolName }
                let cleanedReason = cleanDSHApprovalReason(rawReason, toolName: toolName)
                let summary: String
                if let cmdCandidate, !cleanedReason.isEmpty, !cmdCandidate.contains(cleanedReason), !cleanedReason.contains(cmdCandidate) {
                    summary = "\(cleanedReason) · \(cmdCandidate)"
                } else if let cmdCandidate {
                    summary = cmdCandidate
                } else if !cleanedReason.isEmpty {
                    summary = cleanedReason
                } else {
                    summary = toolName
                }
                let item = PendingAskedItem(
                    id: id,
                    toolName: toolName,
                    callID: callID,
                    summary: summary,
                    requestedAt: eventDate ?? lastEventAt ?? Date()
                )
                openApprovals[id] = item
                openApprovalOrder.removeAll { $0 == id }
                openApprovalOrder.append(id)

            case "approval/decided":
                if let id = dataObj?["id"] as? String, !id.isEmpty {
                    openApprovals.removeValue(forKey: id)
                    openApprovalOrder.removeAll { $0 == id }
                }

            default:
                break
            }
        }

        let activeItem = openApprovalOrder.last.flatMap { openApprovals[$0] }
            ?? openQuestionOrder.last.flatMap { openQuestions[$0] }
        let pendingApproval: PendingApproval? = activeItem.map { item in
            PendingApproval(
                requestID: "dsh:\(sessionID):\(item.id)",
                sessionID: sessionID,
                agentKind: .deepseekHarness,
                host: host,
                toolName: item.toolName,
                commandOrSummary: item.summary,
                cwd: resolvedCwd,
                requestedAt: item.requestedAt,
                canRespondViaHook: false,
                highRiskMatchedRule: HookApprovalManager.matchedHighRiskRule(in: item.summary)
            )
        }

        let currentTool = openToolOrder.last.flatMap { openTools[$0] }
        return DSHLogTailState(
            lastEventAt: lastEventAt,
            turnOpen: turnOpen,
            currentTool: currentTool,
            pendingApproval: pendingApproval,
            resolvedQuestionCallIDs: resolvedQuestionCallIDs,
            cwd: resolvedCwd,
            firstPrompt: firstPrompt
        )
    }

    private static func cleanDSHApprovalReason(_ raw: String, toolName: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [
            "escalate sandbox to danger-full-access: ",
            "escalate sandbox: ",
            "\(toolName) "
        ] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if s.hasPrefix("{"),
           let data = s.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ClaudeCodeAdapter.summarizeToolInput(name: toolName, input: dict)
        }
        return ClaudeCodeAdapter.firstSingleLine(s, maxLength: 72)
    }

    public static func parseProjection(
        data: Data,
        fallbackID: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID,
        seenAtByID: [String: TimeInterval] = [:]
    ) -> AgentSession? {
        parseProjectionCore(
            data: data,
            fallbackID: fallbackID,
            filePath: filePath,
            fileModificationDate: fileModificationDate,
            host: host
        )?.materialize(
            fileModificationDate: fileModificationDate,
            logTail: nil,
            seenAtByID: seenAtByID,
            now: Date()
        )
    }

    private static func parseProjectionCore(
        data: Data,
        fallbackID: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID
    ) -> ProjectionCore? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any],
              let rows = record["rows"] as? [String: Any] else {
            return nil
        }

        if let meta = (rows["sessionListMetadata"] as? [String: Any])?["val"] as? [String: Any],
           (meta["blank"] as? Bool) == true {
            return nil
        }
        if let sub = (rows["subagent"] as? [String: Any])?["val"] as? [String: Any],
           !sub.isEmpty, sub["parentSessionId"] != nil {
            return nil
        }

        let identity = record["identity"] as? [String: Any]
        let createdMs = identity?["createdAt"] as? Double
        let startedAt = createdMs.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? fileModificationDate

        let cwd = ((rows["workingDirectory"] as? [String: Any])?["val"] as? String)
            ?? (identity?["cwd"] as? String)

        let rawTitle = ((rows["title"] as? [String: Any])?["val"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outlineVal = (rows["turnOutline"] as? [String: Any])?["val"] as? [String: Any]
        let turnsArr = (outlineVal?["turns"] as? [[String: Any]]) ?? []
        let draft = (outlineVal?["draft"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstPrompt = turnsArr.first?["prompt"] as? String
        let lastResponse = turnsArr.reversed().compactMap { ($0["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }

        let title = (rawTitle?.isEmpty == false ? rawTitle : nil)
            ?? firstPrompt.map { ClaudeCodeAdapter.firstSingleLine($0, maxLength: 44) }
        guard let title, !title.isEmpty else { return nil }

        var provider = "DeepSeek"
        var model: String?
        if let ms = (rows["modelSelection"] as? [String: Any])?["val"] as? [String: Any],
           let lastUsed = ms["lastUsed"] as? [String: Any] {
            if let p = lastUsed["provider"] as? String, !p.isEmpty {
                provider = FormattingHelpers.providerDisplay(from: p) ?? p
            }
            if let m = lastUsed["model"] as? String, !m.isEmpty {
                model = m
            }
        }

        var usage = TokenUsage()
        if let tu = (rows["tokenUsage"] as? [String: Any])?["val"] as? [String: Any],
           let totals = tu["totals"] as? [String: Any] {
            usage = TokenUsage(
                input: (totals["uncachedInputTokens"] as? Int) ?? 0,
                output: (totals["outputTokens"] as? Int) ?? 0,
                cacheRead: (totals["cacheReadTokens"] as? Int) ?? 0,
                cacheWrite: (totals["cacheWriteTokens"] as? Int) ?? 0
            )
        }

        var contextUsed: Int?
        var contextWindow: Int?
        if let cp = (rows["contextPressure"] as? [String: Any])?["val"] as? [String: Any] {
            contextUsed = (cp["pressureTokens"] as? Int) ?? (cp["surfaceTokens"] as? Int)
            contextWindow = cp["contextWindow"] as? Int
        }

        var turnsCount = max(1, turnsArr.count)
        var stepsCount = 0
        var tokPerSec: Double?
        var hasPendingToolCalls = false
        if let stats = (rows["sessionStats"] as? [String: Any])?["val"] as? [String: Any] {
            turnsCount = max(turnsCount, (stats["turns"] as? Int) ?? 1)
            stepsCount = (stats["steps"] as? Int) ?? 0
            if let decodeTokens = stats["decodeTokens"] as? Int,
               let decodeMs = stats["decodeMs"] as? Double,
               decodeMs > 200, decodeTokens > 0 {
                tokPerSec = Double(decodeTokens) / (decodeMs / 1000.0)
            }
            if let pending = stats["pendingCalls"] as? [String: Any], !pending.isEmpty {
                hasPendingToolCalls = true
            }
        }

        var projectedApproval: PendingApproval?
        var activeQuestionCallID: String?
        if let uqVal = (rows["userQuestions"] as? [String: Any])?["val"] as? [String: Any],
           let questionsObj = uqVal["questions"] as? [String: Any] {
            let activeItems: [[String: Any]]
            if let arr = questionsObj["active"] as? [[String: Any]] {
                activeItems = arr
            } else if let single = questionsObj["active"] as? [String: Any], !single.isEmpty {
                activeItems = [single]
            } else {
                activeItems = []
            }
            if let latestQ = activeItems.last {
                let state = (latestQ["state"] as? String) ?? "open"
                if state == "open" || state == "continued" {
                    let cid = (latestQ["callId"] as? String) ?? "question"
                    activeQuestionCallID = cid
                    let qSummary = ClaudeCodeAdapter.summarizeToolInput(name: "ask_user_question", input: latestQ)
                    projectedApproval = PendingApproval(
                        requestID: "dsh:\(fallbackID):\(cid)",
                        sessionID: fallbackID,
                        agentKind: .deepseekHarness,
                        host: host,
                        toolName: "ask_user_question",
                        commandOrSummary: qSummary,
                        cwd: cwd,
                        requestedAt: fileModificationDate,
                        canRespondViaHook: false
                    )
                }
            }
        }

        let approvalVal = (rows["approvalState"] as? [String: Any])?["val"] as? [String: Any]
        let turnOpen = (approvalVal?["turnOpen"] as? Bool) ?? false

        let sessionID = "\(host.storageKey):dsh:\(fallbackID)"
        let outputMarkdown = (lastResponse?.isEmpty == false ? lastResponse : draft)
        let overview: String
        if let draft, !draft.isEmpty && turnOpen {
            overview = ClaudeCodeAdapter.firstSingleLine(draft, maxLength: 80)
        } else if let resp = lastResponse, !resp.isEmpty {
            overview = ClaudeCodeAdapter.firstSingleLine(resp, maxLength: 80)
        } else if let fp = firstPrompt, !fp.isEmpty {
            overview = ClaudeCodeAdapter.firstSingleLine(fp, maxLength: 80)
        } else {
            overview = "DeepSeek Harness 会话"
        }

        let baseSession = AgentSession(
            id: sessionID,
            rawSessionID: fallbackID,
            kind: .deepseekHarness,
            host: host,
            title: title,
            overview: overview,
            status: .waitingForInput,
            cwd: cwd,
            groupDirectory: cwd,
            provider: provider,
            model: model,
            usage: usage,
            contextUsedTokens: contextUsed,
            contextWindow: contextWindow ?? PricingCatalog.defaultContextWindow(for: model),
            totalToolCalls: stepsCount,
            successfulToolCalls: stepsCount,
            turnCount: turnsCount,
            outputTokensPerSecond: tokPerSec,
            pendingApproval: projectedApproval,
            lastOutputMarkdown: outputMarkdown,
            sourceFilePath: filePath,
            launchEnvironment: host.isLocal ? .deepseekHarnessApp : .auto,
            startedAt: startedAt,
            lastActivityAt: fileModificationDate,
            isSeen: false
        )
        return ProjectionCore(
            baseSession: baseSession,
            hasPendingToolCalls: hasPendingToolCalls,
            turnOpen: turnOpen,
            hasResponseOrDraft: lastResponse != nil || draft != nil,
            activeQuestionCallID: activeQuestionCallID
        )
    }
}
