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
    nonisolated(unsafe) private static var hooksInstalledCache: (stat: FastJSONL.FileStatKey?, installed: Bool)?
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

    public static func isClaudeHooksInstalled() -> Bool {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
        let curStat = FastJSONL.statKey(atPath: settingsURL.path)
        cacheLock.lock()
        if let cached = hooksInstalledCache, cached.stat == curStat {
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
        hooksInstalledCache = (curStat, installed)
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

    public static func installClaudeHooks(hookExecutablePath: String) throws -> String {
        let claudeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
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
        let stopCmd = "\"\(hookExecutablePath)\" claude-event stop"
        hooks["PermissionRequest"] = [
            [
                "matcher": "*",
                "hooks": [["type": "command", "command": permCmd]]
            ]
        ]
        hooks["Stop"] = [
            [
                "hooks": [["type": "command", "command": stopCmd]]
            ]
        ]
        root["hooks"] = hooks

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: settingsURL, options: .atomic)
        return settingsURL.path
    }
}
