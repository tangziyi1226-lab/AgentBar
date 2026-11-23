import Foundation

public enum ApprovalDecisionAction: String, Codable, Sendable {
    case allow
    case deny
    case passthrough
}

public struct ApprovalDecisionPayload: Codable, Sendable {
    public var requestID: String
    public var action: ApprovalDecisionAction
    public var reason: String?
    public var decidedAt: Date

    public init(requestID: String, action: ApprovalDecisionAction, reason: String? = nil, decidedAt: Date = Date()) {
        self.requestID = requestID
        self.action = action
        self.reason = reason
        self.decidedAt = decidedAt
    }
}

public enum HookApprovalManager {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var claudeHooksInstalledCache: [String: (stat: FastJSONL.FileStatKey?, installed: Bool)] = [:]
    nonisolated(unsafe) private static var codexHooksInstalledCache: [String: (stat: FastJSONL.FileStatKey?, installed: Bool)] = [:]
    nonisolated(unsafe) private static var pendingDirStatCache: (stat: FastJSONL.FileStatKey?, items: [PendingApproval], checkedAt: TimeInterval)?

    public static var agentBarRuntimeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agentbar", isDirectory: true)
    }

    public static var pendingDirectory: URL {
        agentBarRuntimeDirectory.appendingPathComponent("pending", isDirectory: true)
    }

    public static var decisionsDirectory: URL {
        agentBarRuntimeDirectory.appendingPathComponent("decisions", isDirectory: true)
    }

    public static var resolvedDirectory: URL {
        agentBarRuntimeDirectory.appendingPathComponent("resolved", isDirectory: true)
    }

    public static var eventsFileURL: URL {
        agentBarRuntimeDirectory.appendingPathComponent("events.jsonl")
    }

    public static var auditLogURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("AgentBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("approvals.jsonl")
    }

    public static let defaultHighRiskPatterns: [String] = [
        "rm -rf",
        "sudo ",
        "git push --force",
        "git push -f",
        "git reset --hard",
        "chmod 777",
        "| sh",
        "| bash",
        "mkfs",
        "dd if="
    ]

    public static func matchedHighRiskRule(in command: String, customPatterns: [String] = defaultHighRiskPatterns) -> String? {
        let lower = command.lowercased()
        for pattern in customPatterns {
            if lower.contains(pattern.lowercased()) {
                return pattern.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    public static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: decisionsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
    }

    private static func sanitizedMarkerName(for sessionID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(sessionID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(128))
    }

    public static func markPermissionResolved(sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        ensureDirectories()
        let markerURL = resolvedDirectory.appendingPathComponent(sanitizedMarkerName(for: sessionID))
        try? Data("1".utf8).write(to: markerURL, options: .atomic)
    }

    public static func lastPermissionResolvedAt(sessionID: String) -> Date? {
        guard !sessionID.isEmpty else { return nil }
        let markerPath = resolvedDirectory.appendingPathComponent(sanitizedMarkerName(for: sessionID)).path
        guard let stat = FastJSONL.statKey(atPath: markerPath) else { return nil }
        return Date(timeIntervalSince1970: Double(stat.mtimeSec) + Double(stat.mtimeNsec) / 1_000_000_000.0)
    }

    public static func clearPendingApprovals(forSessionID sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        markPermissionResolved(sessionID: sessionID)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil),
              !files.isEmpty else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var removed = false
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let item = try? decoder.decode(PendingApproval.self, from: data),
               item.sessionID == sessionID {
                try? fm.removeItem(at: url)
                removed = true
            }
        }
        if removed {
            cacheLock.lock()
            pendingDirStatCache = nil
            cacheLock.unlock()
        }
    }

    public static func loadLocalPendingApprovals(maxAgeSeconds: TimeInterval = 180) -> [PendingApproval] {
        let pendingPath = pendingDirectory.path
        let curStat = FastJSONL.statKey(atPath: pendingPath)
        guard let curStat else {
            ensureDirectories()
            return []
        }
        let now = Date()
        let nowTS = now.timeIntervalSince1970
        cacheLock.lock()
        if let cached = pendingDirStatCache,
           cached.stat == curStat,
           (cached.items.isEmpty || nowTS - cached.checkedAt < 5.0) {
            cacheLock.unlock()
            return cached.items
        }
        cacheLock.unlock()

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var valid: [PendingApproval] = []
        var removedAny = false
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var item = try? decoder.decode(PendingApproval.self, from: data) else {
                continue
            }
            if now.timeIntervalSince(item.requestedAt) > maxAgeSeconds {
                try? fm.removeItem(at: url)
                removedAny = true
                continue
            }
            if item.highRiskMatchedRule == nil {
                item.highRiskMatchedRule = matchedHighRiskRule(in: item.commandOrSummary)
            }
            valid.append(item)
        }
        let sorted = valid.sorted { $0.requestedAt > $1.requestedAt }
        let finalStat = removedAny ? FastJSONL.statKey(atPath: pendingPath) : curStat
        cacheLock.lock()
        pendingDirStatCache = (finalStat, sorted, nowTS)
        cacheLock.unlock()
        return sorted
    }

    public static func submitDecision(
        for approval: PendingApproval,
        action: ApprovalDecisionAction,
        reason: String? = nil
    ) async throws {
        let payload = ApprovalDecisionPayload(
            requestID: approval.requestID,
            action: action,
            reason: reason
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        switch approval.host {
        case .local:
            ensureDirectories()
            let target = decisionsDirectory.appendingPathComponent("\(approval.requestID).json")
            let tmp = decisionsDirectory.appendingPathComponent(".\(approval.requestID).tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: tmp, to: target)
            let pendingURL = pendingDirectory.appendingPathComponent("\(approval.requestID).json")
            try? FileManager.default.removeItem(at: pendingURL)
            if action != .passthrough {
                markPermissionResolved(sessionID: approval.sessionID)
            }
            cacheLock.withLock {
                pendingDirStatCache = nil
            }
        case .ssh(let alias):
            try await SSHProbeService.sendRemoteDecision(alias: alias, requestID: approval.requestID, jsonData: data)
        }
        appendAuditLog(approval: approval, action: action, reason: reason)
    }

    private static func appendAuditLog(
        approval: PendingApproval,
        action: ApprovalDecisionAction,
        reason: String?
    ) {
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "host": approval.host.storageKey,
            "sessionID": approval.sessionID ?? "",
            "requestID": approval.requestID,
            "tool": approval.toolName,
            "summary": approval.commandOrSummary,
            "action": action.rawValue,
            "reason": reason ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        let url = auditLogURL
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    public static func hookBinaryPath() -> String {
        if let bundleExec = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("agentbar-hook").path,
           FileManager.default.isExecutableFile(atPath: bundleExec) {
            return bundleExec
        }
        return ("~/.agentbar/bin/agentbar-hook" as NSString).expandingTildeInPath
    }

    public static func isClaudeHooksInstalled(homeDirectory: String = NSHomeDirectory()) -> Bool {
        let settingsURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".claude/settings.json")
        let key = settingsURL.path
        let curStat = FastJSONL.statKey(atPath: key)
        cacheLock.lock()
        if let cached = claudeHooksInstalledCache[key], cached.stat == curStat {
            cacheLock.unlock()
            return cached.installed
        }
        cacheLock.unlock()

        let installed: Bool
        if curStat != nil, let data = try? Data(contentsOf: settingsURL) {
            installed = data.range(of: Data("agentbar-hook".utf8)) != nil
        } else {
            installed = false
        }
        cacheLock.lock()
        claudeHooksInstalledCache[key] = (curStat, installed)
        cacheLock.unlock()
        return installed
    }

    public static func isCodexHooksInstalled(homeDirectory: String = NSHomeDirectory()) -> Bool {
        let hooksURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".codex/hooks.json")
        let key = hooksURL.path
        let curStat = FastJSONL.statKey(atPath: key)
        cacheLock.lock()
        if let cached = codexHooksInstalledCache[key], cached.stat == curStat {
            cacheLock.unlock()
            return cached.installed
        }
        cacheLock.unlock()

        let installed: Bool
        if curStat != nil, let data = try? Data(contentsOf: hooksURL) {
            installed = data.range(of: Data("agentbar-hook".utf8)) != nil
        } else {
            installed = false
        }
        cacheLock.lock()
        codexHooksInstalledCache[key] = (curStat, installed)
        cacheLock.unlock()
        return installed
    }

    public static func previewClaudeHooksJSON(hookExecutablePath: String) -> String {
        let escaped = hookExecutablePath.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "hooks": {
            "PermissionRequest": [
              {
                "matcher": "*",
                "hooks": [
                  { "type": "command", "command": "\\"\(escaped)\\" claude-permission" }
                ]
              }
            ],
            "PostToolUse": [
              {
                "hooks": [
                  { "type": "command", "command": "\\"\(escaped)\\" claude-event post_tool_use" }
                ]
              }
            ],
            "Stop": [
              {
                "hooks": [
                  { "type": "command", "command": "\\"\(escaped)\\" claude-event stop" }
                ]
              }
            ]
          }
        }
        """
    }

    public static func previewCodexHooksJSON(hookExecutablePath: String) -> String {
        let escaped = hookExecutablePath.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "hooks": {
            "PermissionRequest": [
              {
                "hooks": [
                  { "type": "command", "command": "\\"\(escaped)\\" codex-permission", "timeout": 125 }
                ]
              }
            ],
            "PostToolUse": [
              {
                "hooks": [
                  { "type": "command", "command": "\\"\(escaped)\\" codex-event post_tool_use", "timeout": 5 }
                ]
              }
            ],
            "Stop": [
              {
                "hooks": [
                  { "type": "command", "command": "\\"\(escaped)\\" codex-event stop", "timeout": 5 }
                ]
              }
            ],
            "Interrupt": [
              {
                "hooks": [
                  { "type": "command", "command": "\\"\(escaped)\\" codex-event interrupt", "timeout": 3 }
                ]
              }
            ]
          }
        }
        """
    }

    private static func groupContainsAgentBarHook(_ group: [String: Any]) -> Bool {
        if let inner = group["hooks"] as? [[String: Any]] {
            return inner.contains { ($0["command"] as? String)?.contains("agentbar-hook") == true }
        }
        if let cmd = group["command"] as? String {
            return cmd.contains("agentbar-hook")
        }
        return false
    }

    private static func mergeHookGroup(
        into hooksDict: inout [String: Any],
        event: String,
        newGroup: [String: Any]
    ) {
        var existingGroups = (hooksDict[event] as? [[String: Any]]) ?? []
        existingGroups.removeAll { groupContainsAgentBarHook($0) }
        existingGroups.append(newGroup)
        hooksDict[event] = existingGroups
    }

    public static func installClaudeHooks(
        hookExecutablePath: String,
        homeDirectory: String = NSHomeDirectory()
    ) throws -> String {
        let claudeDir = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backupURL = claudeDir.appendingPathComponent("settings.json.agentbar-bak")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
            }
            if let data = try? Data(contentsOf: settingsURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = existing
            }
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let permCmd = "\"\(hookExecutablePath)\" claude-permission"
        let postCmd = "\"\(hookExecutablePath)\" claude-event post_tool_use"
        let stopCmd = "\"\(hookExecutablePath)\" claude-event stop"
        let promptCmd = "\"\(hookExecutablePath)\" claude-event user_prompt_submit"

        mergeHookGroup(
            into: &hooks,
            event: "PermissionRequest",
            newGroup: [
                "matcher": "*",
                "hooks": [["type": "command", "command": permCmd]]
            ]
        )
        mergeHookGroup(
            into: &hooks,
            event: "PostToolUse",
            newGroup: [
                "hooks": [["type": "command", "command": postCmd]]
            ]
        )
        mergeHookGroup(
            into: &hooks,
            event: "Stop",
            newGroup: [
                "hooks": [["type": "command", "command": stopCmd]]
            ]
        )
        mergeHookGroup(
            into: &hooks,
            event: "UserPromptSubmit",
            newGroup: [
                "hooks": [["type": "command", "command": promptCmd]]
            ]
        )
        root["hooks"] = hooks

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL, options: .atomic)
        cacheLock.lock()
        claudeHooksInstalledCache.removeValue(forKey: settingsURL.path)
        cacheLock.unlock()
        return settingsURL.path
    }

    public static func installCodexHooks(
        hookExecutablePath: String,
        homeDirectory: String = NSHomeDirectory()
    ) throws -> String {
        let codexDir = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let hooksURL = codexDir.appendingPathComponent("hooks.json")

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: hooksURL.path) {
            let backupURL = codexDir.appendingPathComponent("hooks.json.agentbar-bak")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.copyItem(at: hooksURL, to: backupURL)
            }
            if let data = try? Data(contentsOf: hooksURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = existing
            }
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let permCmd = "\"\(hookExecutablePath)\" codex-permission"
        let postCmd = "\"\(hookExecutablePath)\" codex-event post_tool_use"
        let stopCmd = "\"\(hookExecutablePath)\" codex-event stop"
        let interruptCmd = "\"\(hookExecutablePath)\" codex-event interrupt"
        let promptCmd = "\"\(hookExecutablePath)\" codex-event user_prompt_submit"

        mergeHookGroup(
            into: &hooks,
            event: "PermissionRequest",
            newGroup: [
                "hooks": [["type": "command", "command": permCmd, "timeout": 125]]
            ]
        )
        mergeHookGroup(
            into: &hooks,
            event: "PostToolUse",
            newGroup: [
                "hooks": [["type": "command", "command": postCmd, "timeout": 5]]
            ]
        )
        mergeHookGroup(
            into: &hooks,
            event: "Stop",
            newGroup: [
                "hooks": [["type": "command", "command": stopCmd, "timeout": 5]]
            ]
        )
        mergeHookGroup(
            into: &hooks,
            event: "Interrupt",
            newGroup: [
                "hooks": [["type": "command", "command": interruptCmd, "timeout": 3]]
            ]
        )
        mergeHookGroup(
            into: &hooks,
            event: "UserPromptSubmit",
            newGroup: [
                "hooks": [["type": "command", "command": promptCmd, "timeout": 5]]
            ]
        )
        root["hooks"] = hooks

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: hooksURL, options: .atomic)
        ensureCodexHooksFeatureEnabled(codexDir: codexDir)
        cacheLock.lock()
        codexHooksInstalledCache.removeValue(forKey: hooksURL.path)
        cacheLock.unlock()
        return hooksURL.path
    }

    private static func ensureCodexHooksFeatureEnabled(codexDir: URL) {
        let configURL = codexDir.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            let fresh = "features.hooks = true\n"
            try? fresh.write(to: configURL, atomically: true, encoding: .utf8)
            return
        }

        var lines = content.components(separatedBy: "\n")
        var currentSection = ""
        var featuresSectionIndex: Int?
        var hooksKeyLineIndex: Int?

        for (idx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if currentSection == "features" {
                    featuresSectionIndex = idx
                }
                continue
            }
            if currentSection.isEmpty && trimmed.hasPrefix("features.hooks") && trimmed.contains("=") {
                hooksKeyLineIndex = idx
                if trimmed.hasSuffix("true") { return }
            } else if currentSection == "features" && trimmed.hasPrefix("hooks") && trimmed.contains("=") {
                let lhs = trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
                if lhs == "hooks" {
                    hooksKeyLineIndex = idx
                    if trimmed.hasSuffix("true") { return }
                }
            }
        }

        let backupURL = codexDir.appendingPathComponent("config.toml.agentbar-bak")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.copyItem(at: configURL, to: backupURL)
        }

        if let keyIdx = hooksKeyLineIndex {
            lines[keyIdx] = lines[keyIdx].contains("features.hooks") ? "features.hooks = true" : "hooks = true"
        } else if let secIdx = featuresSectionIndex {
            lines.insert("hooks = true", at: secIdx + 1)
        } else if let firstSectionIdx = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.hasSuffix("]")
        }) {
            lines.insert("", at: firstSectionIdx)
            lines.insert("features.hooks = true", at: firstSectionIdx)
        } else {
            lines.append("features.hooks = true")
        }

        let updated = lines.joined(separator: "\n")
        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
