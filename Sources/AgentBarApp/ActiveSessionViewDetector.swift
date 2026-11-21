import AgentBarCore
import AppKit
import Foundation

@MainActor
final class ActiveSessionViewDetector {
    struct WorkspaceTarget: Hashable {
        let host: HostID
        let path: String
    }

    private var trackedBundleID: String?
    private var trackedSince: Date = Date()
    private var activationObserver: NSObjectProtocol?

    private static var storageWorkspacesCache: [String: (stat: FastJSONL.FileStatKey?, targets: Set<WorkspaceTarget>)] = [:]
    private static var sshAliasesCache: (checkedAt: TimeInterval, hostCount: Int, aliases: Set<String>)?

    init() {
        self.trackedBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        self.trackedSince = Date()
        self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if bundleID != self.trackedBundleID {
                    self.trackedBundleID = bundleID
                    self.trackedSince = Date()
                }
            }
        }
    }

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.cmuxterm.app",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "org.alacritty",
        "co.zeit.hyper",
        "com.github.wez.wezterm"
    ]

    func detectViewedSessionIDs(
        sessions: [AgentSession],
        sshHosts: [SSHHostConfig],
        now: Date = Date()
    ) -> [String] {
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontBundle != trackedBundleID {
            trackedBundleID = frontBundle
            trackedSince = now
        }

        let unseenCompleted = sessions.filter {
            $0.status == .completed && !$0.isSeen && !$0.kind.isChatOnly
        }
        guard !unseenCompleted.isEmpty, let bundleID = frontBundle else {
            return []
        }

        let dwell = now.timeIntervalSince(trackedSince)
        guard dwell >= 1.8 else { return [] }

        let ideFolders = Self.ideStorageAppFolders(for: bundleID)
        let openWorkspaces: [WorkspaceTarget] = ideFolders.isEmpty
            ? []
            : Self.loadOpenWorkspaces(appSupportFolders: ideFolders)

        let isTerminalFrontmost = Self.terminalBundleIDs.contains(bundleID)
        var cachedSSHAliases: Set<String>?

        var matchedIDs: [String] = []
        for session in unseenCompleted {
            let sinceActivity = now.timeIntervalSince(session.lastActivityAt)
            let effectiveReadSeconds = min(dwell, sinceActivity)
            guard effectiveReadSeconds >= 1.8 else { continue }

            if !ideFolders.isEmpty {
                if Self.matchesIDEWorkspace(session: session, workspaces: openWorkspaces) {
                    matchedIDs.append(session.id)
                    continue
                }
                if session.host.isLocal,
                   session.cwd == nil,
                   session.kind.preferredBundleIdentifiers.contains(bundleID) {
                    matchedIDs.append(session.id)
                    continue
                }
            }

            if session.host.isLocal {
                if session.kind == .deepseekHarness && Self.isDeepSeekHarness(bundleID: bundleID) {
                    matchedIDs.append(session.id)
                    continue
                }
                if session.kind == .claudeDesktop && AgentKind.claudeDesktop.preferredBundleIdentifiers.contains(bundleID) {
                    matchedIDs.append(session.id)
                    continue
                }
                if session.kind == .codexDesktop,
                   AgentKind.codexDesktop.preferredBundleIdentifiers.contains(bundleID),
                   !Self.hasCodexGlobalStateFile() {
                    matchedIDs.append(session.id)
                    continue
                }
            }

            if isTerminalFrontmost && effectiveReadSeconds >= 2.2 {
                if session.host.isLocal && Self.isTerminalSession(session) {
                    matchedIDs.append(session.id)
                    continue
                }
                if case .ssh(let alias) = session.host, Self.isTerminalSession(session) {
                    if cachedSSHAliases == nil {
                        cachedSSHAliases = Self.activeInteractiveSSHAliases(sshHosts: sshHosts)
                    }
                    if cachedSSHAliases?.contains(alias) == true {
                        matchedIDs.append(session.id)
                        continue
                    }
                }
            }
        }

        return matchedIDs
    }

    private static func isTerminalSession(_ session: AgentSession) -> Bool {
        if session.launchEnvironment == .terminalCLI {
            return true
        }
        return session.launchEnvironment == .auto
            && (session.kind == .claudeCode || session.kind == .codexCLI || session.kind == .generic)
    }

    private static func isDeepSeekHarness(bundleID: String) -> Bool {
        if AgentKind.deepseekHarness.preferredBundleIdentifiers.contains(bundleID) {
            return true
        }
        return bundleID.localizedCaseInsensitiveContains("deepseek")
    }

    private static func hasCodexGlobalStateFile() -> Bool {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/.codex-global-state.json")
        return FileManager.default.fileExists(atPath: path)
    }

    private static func ideStorageAppFolders(for bundleID: String) -> [String] {
        switch bundleID {
        case "com.microsoft.VSCode", "com.visualstudio.code.oss":
            return ["Code"]
        case "com.microsoft.VSCodeInsiders":
            return ["Code - Insiders", "Code"]
        case "com.todesktop.230313mzl4w4u92", "com.cursor.Cursor":
            return ["Cursor"]
        case "com.marswave.trae", "com.bytedance.trae", "com.trae.app":
            return ["Trae", "Trae CN"]
        case "com.google.antigravity", "dev.antigravity.app":
            return ["Antigravity"]
        default:
            return []
        }
    }

    private static func matchesIDEWorkspace(session: AgentSession, workspaces: [WorkspaceTarget]) -> Bool {
        guard !workspaces.isEmpty else { return false }
        for ws in workspaces where ws.host == session.host {
            if pathsOverlap(ws.path, session.cwd) || pathsOverlap(ws.path, session.groupDirectory) {
                return true
            }
        }
        return false
    }

    private static func pathsOverlap(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let rawA = lhs, !rawA.isEmpty, let rawB = rhs, !rawB.isEmpty else { return false }
        let a = normalizePath(rawA)
        let b = normalizePath(rawB)
        if a == b { return true }
        return a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func normalizePath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.count > 1 && s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }

    private static func loadOpenWorkspaces(appSupportFolders: [String]) -> [WorkspaceTarget] {
        var targets: Set<WorkspaceTarget> = []
        let home = NSHomeDirectory() as NSString
        for folder in appSupportFolders {
            let storagePath = home.appendingPathComponent("Library/Application Support/\(folder)/User/globalStorage/storage.json")
            let curStat = FastJSONL.statKey(atPath: storagePath)
            if let hit = storageWorkspacesCache[storagePath], hit.stat == curStat {
                targets.formUnion(hit.targets)
                continue
            }
            var parsed: Set<WorkspaceTarget> = []
            if curStat != nil,
               let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath), options: .mappedIfSafe),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let windowsState = root["windowsState"] as? [String: Any] {
                if let lastActive = windowsState["lastActiveWindow"] as? [String: Any],
                   let target = parseWindowDict(lastActive) {
                    parsed.insert(target)
                }
                if let opened = windowsState["openedWindows"] as? [[String: Any]] {
                    for win in opened {
                        if let target = parseWindowDict(win) {
                            parsed.insert(target)
                        }
                    }
                }
            }
            storageWorkspacesCache[storagePath] = (curStat, parsed)
            targets.formUnion(parsed)
        }
        return Array(targets)
    }

    private static func parseWindowDict(_ dict: [String: Any]) -> WorkspaceTarget? {
        let uriCandidates: [String] = [
            dict["folder"] as? String,
            dict["folderUri"] as? String,
            (dict["workspaceIdentifier"] as? [String: Any])?["configURIPath"] as? String
        ].compactMap { $0 }

        for rawURI in uriCandidates {
            if rawURI.hasPrefix("file://"),
               let url = URL(string: rawURI),
               url.isFileURL {
                return WorkspaceTarget(host: .local, path: normalizePath(url.path))
            }

            let decoded = rawURI.removingPercentEncoding ?? rawURI
            if let range = decoded.range(of: "ssh-remote+") {
                let after = decoded[range.upperBound...]
                if let slashIdx = after.firstIndex(of: "/") {
                    let alias = String(after[..<slashIdx])
                    let remotePath = normalizePath(String(after[slashIdx...]))
                    if !alias.isEmpty && !remotePath.isEmpty {
                        return WorkspaceTarget(host: .ssh(alias: alias), path: remotePath)
                    }
                }
            }
        }
        return nil
    }

    private static func activeInteractiveSSHAliases(sshHosts: [SSHHostConfig]) -> Set<String> {
        guard !sshHosts.isEmpty else { return [] }
        let nowTS = Date().timeIntervalSince1970
        if let hit = sshAliasesCache, hit.hostCount == sshHosts.count, nowTS - hit.checkedAt < 6.0 {
            return hit.aliases
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "tty=,comm=,args="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        var matched: Set<String> = []
        for line in out.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }
            let tty = String(parts[0])
            let comm = String(parts[1])
            let args = String(parts[2])
            guard tty != "??" && tty != "?" else { continue }
            guard comm == "ssh" || comm.hasSuffix("/ssh") else { continue }
            if args.contains(" -n ") || args.contains("ControlMaster=no") { continue }

            let tokens = Set(args.split(whereSeparator: \.isWhitespace).map(String.init))
            for cfg in sshHosts {
                if tokens.contains(cfg.alias) {
                    matched.insert(cfg.alias)
                    continue
                }
                if let host = cfg.hostname, !host.isEmpty {
                    if tokens.contains(host) || tokens.contains(where: { $0.hasSuffix("@\(host)") }) {
                        matched.insert(cfg.alias)
                    }
                }
                if tokens.contains(where: { $0.hasSuffix("@\(cfg.alias)") }) {
                    matched.insert(cfg.alias)
                }
            }
        }
        sshAliasesCache = (nowTS, sshHosts.count, matched)
        return matched
    }
}
