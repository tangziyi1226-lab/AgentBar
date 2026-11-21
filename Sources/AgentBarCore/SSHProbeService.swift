import Darwin
import Foundation

public struct SSHHostConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var isEnabled: Bool
    public var approvalEnabled: Bool

    public init(
        alias: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        isEnabled: Bool = true,
        approvalEnabled: Bool = true
    ) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.isEnabled = isEnabled
        self.approvalEnabled = approvalEnabled
    }

    public var connectionSubtitle: String? {
        guard let hostname, !hostname.isEmpty else { return nil }
        let target = (user != nil && !user!.isEmpty) ? "\(user!)@\(hostname)" : hostname
        if let port, port != 22 {
            return "\(target):\(port)"
        }
        return target
    }
}

public struct SSHProbeResult: Sendable {
    public var connection: HostConnectionState
    public var remoteHome: String?
    public var sessions: [AgentSession]
    public var pendingApprovals: [PendingApproval]
}

public enum SSHProbeService {
    public static var sharedControlDirectoryPath: String {
        let dir = "/tmp/agentbar-ssh-\(getuid())"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return dir
    }

    public static var sharedControlPathPattern: String {
        (sharedControlDirectoryPath as NSString).appendingPathComponent("cm-%C")
    }

    public static func discoverSSHConfigEntries(homeDirectory: String = NSHomeDirectory()) -> [SSHHostConfig] {
        let sshDir = (homeDirectory as NSString).appendingPathComponent(".ssh")
        let rootConfig = (sshDir as NSString).appendingPathComponent("config")
        var visitedFiles: Set<String> = []
        var rawStanzas: [(aliases: [String], hostname: String?, user: String?, port: Int?, controlPath: String?)] = []

        parseSSHConfigFile(
            path: rootConfig,
            sshDirectory: sshDir,
            homeDirectory: homeDirectory,
            visited: &visitedFiles,
            into: &rawStanzas
        )

        var results: [SSHHostConfig] = []
        var seenAliases: Set<String> = []
        var seenEndpoints: Set<String> = []
        for stanza in rawStanzas {
            for alias in stanza.aliases {
                if isIgnoredGitOrWildcardHost(alias: alias, hostname: stanza.hostname, user: stanza.user) {
                    continue
                }
                let endpointHost = (stanza.hostname ?? alias).lowercased()
                let endpointKey = "\(endpointHost)|\(stanza.port ?? 22)"
                if !seenEndpoints.insert(endpointKey).inserted {
                    continue
                }
                if seenAliases.insert(alias).inserted {
                    results.append(SSHHostConfig(
                        alias: alias,
                        hostname: stanza.hostname,
                        user: stanza.user,
                        port: stanza.port,
                        isEnabled: true,
                        approvalEnabled: true
                    ))
                }
            }
        }
        return results
    }

    public static func discoverSSHConfigHosts(homeDirectory: String = NSHomeDirectory()) -> [String] {
        discoverSSHConfigEntries(homeDirectory: homeDirectory).map(\.alias)
    }

    public static func hasCustomControlPath(alias: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let sshDir = (homeDirectory as NSString).appendingPathComponent(".ssh")
        let rootConfig = (sshDir as NSString).appendingPathComponent("config")
        var visitedFiles: Set<String> = []
        var rawStanzas: [(aliases: [String], hostname: String?, user: String?, port: Int?, controlPath: String?)] = []
        parseSSHConfigFile(
            path: rootConfig,
            sshDirectory: sshDir,
            homeDirectory: homeDirectory,
            visited: &visitedFiles,
            into: &rawStanzas
        )
        for stanza in rawStanzas {
            guard let cp = stanza.controlPath, !cp.isEmpty, cp.lowercased() != "none" else { continue }
            if stanza.aliases.contains(alias) || stanza.aliases.contains("*") {
                return true
            }
        }
        return false
    }

    public static func isIgnoredGitOrWildcardHost(alias: String, hostname: String? = nil, user: String? = nil) -> Bool {
        if alias.isEmpty || alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") {
            return true
        }
        let lowerAlias = alias.lowercased()
        let lowerHost = (hostname ?? "").lowercased()
        let lowerUser = (user ?? "").lowercased()
        let gitDomains = [
            "github.com", "github-", "github.",
            "gitlab.com", "gitlab-", "gitlab.",
            "bitbucket.org", "gitee.com", "codeup.aliyun.com",
            "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
            "hf.co", "huggingface.co"
        ]
        for pat in gitDomains {
            if lowerAlias.contains(pat) || lowerHost.contains(pat) {
                return true
            }
        }
        if lowerUser == "git" && (lowerAlias.contains("git") || lowerHost.contains("git")) {
            return true
        }
        return false
    }

    private static func parseSSHConfigFile(
        path: String,
        sshDirectory: String,
        homeDirectory: String,
        visited: inout Set<String>,
        into stanzas: inout [(aliases: [String], hostname: String?, user: String?, port: Int?, controlPath: String?)]
    ) {
        let standardized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard visited.insert(standardized).inserted,
              let content = try? String(contentsOfFile: standardized, encoding: .utf8) else {
            return
        }

        var currentAliases: [String] = []
        var currentHostname: String?
        var currentUser: String?
        var currentPort: Int?
        var currentControlPath: String?

        func flushCurrent() {
            if !currentAliases.isEmpty {
                stanzas.append((currentAliases, currentHostname, currentUser, currentPort, currentControlPath))
            }
            currentAliases = []
            currentHostname = nil
            currentUser = nil
            currentPort = nil
            currentControlPath = nil
        }

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let lineWithoutComment: Substring
            if let hashIdx = rawLine.firstIndex(of: "#") {
                lineWithoutComment = rawLine[..<hashIdx]
            } else {
                lineWithoutComment = rawLine
            }
            let trimmed = lineWithoutComment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let tokens = splitSSHConfigTokens(trimmed)
            guard tokens.count >= 2 else { continue }
            let keyword = tokens[0].lowercased()
            let args = Array(tokens.dropFirst())

            switch keyword {
            case "include":
                flushCurrent()
                for pattern in args {
                    for matchedFile in expandIncludePattern(pattern, sshDirectory: sshDirectory, homeDirectory: homeDirectory) {
                        parseSSHConfigFile(
                            path: matchedFile,
                            sshDirectory: sshDirectory,
                            homeDirectory: homeDirectory,
                            visited: &visited,
                            into: &stanzas
                        )
                    }
                }
            case "host":
                flushCurrent()
                currentAliases = args
            case "match":
                flushCurrent()
            case "hostname":
                if currentHostname == nil { currentHostname = args.first }
            case "user":
                if currentUser == nil { currentUser = args.first }
            case "port":
                if currentPort == nil, let first = args.first, let p = Int(first) {
                    currentPort = p
                }
            case "controlpath":
                if currentControlPath == nil { currentControlPath = args.first }
            default:
                break
            }
        }
        flushCurrent()
    }

    private static func splitSSHConfigTokens(_ line: String) -> [String] {
        let normalized = line.replacingOccurrences(of: "=", with: " ")
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in normalized {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func expandIncludePattern(
        _ rawPattern: String,
        sshDirectory: String,
        homeDirectory: String
    ) -> [String] {
        let expanded: String
        if rawPattern.hasPrefix("~/") {
            expanded = (homeDirectory as NSString).appendingPathComponent(String(rawPattern.dropFirst(2)))
        } else if rawPattern.hasPrefix("/") {
            expanded = rawPattern
        } else {
            expanded = (sshDirectory as NSString).appendingPathComponent(rawPattern)
        }

        var globResult = glob_t()
        defer { globfree(&globResult) }
        if glob(expanded, GLOB_TILDE | GLOB_BRACE, nil, &globResult) == 0, globResult.gl_matchc > 0 {
            var paths: [String] = []
            for idx in 0..<Int(globResult.gl_matchc) {
                if let cStr = globResult.gl_pathv[idx] {
                    paths.append(String(cString: cStr))
                }
            }
            return paths.sorted()
        }
        if FileManager.default.fileExists(atPath: expanded) {
            return [expanded]
        }
        return []
    }

    public static var posixProbeScript: String {
        buildPosixProbeScript(includeSubagents: false)
    }

    public static func buildPosixProbeScript(
        includeSubagents: Bool = false,
        dayCutoff: Date = Calendar.current.startOfDay(for: Date())
    ) -> String {
        let subFlag = includeSubagents ? "1" : "0"
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        let cutoffISO = iso.string(from: dayCutoff)
        return "include_subagents=\(subFlag)\nday_cutoff_iso=\"\(cutoffISO)\"\n" + #"""
printf "@@HOME %s\n" "$HOME"
now_ts=$(date +%s 2>/dev/null || echo 0)

list_recent_files() {
  root="$1"
  pat="$2"
  limit="$3"
  [ -d "$root" ] || return 0
  if [ "$include_subagents" = "1" ]; then
    find "$root" -name "$pat" -type f -exec ls -1t {} + 2>/dev/null | head -n "$limit"
  else
    find "$root" -name "$pat" -type f ! -path '*/subagents/*' -exec ls -1t {} + 2>/dev/null | head -n "$limit"
  fi
}

if [ -d "$HOME/.claude/projects" ]; then
  list_recent_files "$HOME/.claude/projects" '*.jsonl' 20 | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    if [ "$include_subagents" = "0" ]; then
      sub_dir="${f%.jsonl}/subagents"
      if [ -d "$sub_dir" ]; then
        sub_f=$(find "$sub_dir" -name '*.jsonl' -type f -exec ls -1t {} + 2>/dev/null | head -n 1)
        if [ -n "$sub_f" ]; then
          sub_mt=$(stat -c %Y "$sub_f" 2>/dev/null || stat -f %m "$sub_f" 2>/dev/null || echo 0)
          if [ "$sub_mt" -gt "$mt" ] 2>/dev/null; then
            mt="$sub_mt"
          fi
        fi
      fi
    fi
    printf "@@BEGIN claude %s %s\n" "$mt" "$f"
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "$sz" -le 170000 ] 2>/dev/null; then
      cat "$f" 2>/dev/null
    else
      head -n 15 "$f" 2>/dev/null
      printf "\n"
      grep -E '"type":"(ai-title|custom-title)"' "$f" 2>/dev/null | tail -n 3
      printf "\n"
      tail -c 160000 "$f" 2>/dev/null
    fi
    printf "\n@@END\n"
  done
fi

if [ -f "$HOME/.codex/session_index.jsonl" ]; then
  printf "@@BEGIN codex_index 0 %s/.codex/session_index.jsonl\n" "$HOME"
  tail -n 200 "$HOME/.codex/session_index.jsonl" 2>/dev/null
  printf "\n@@END\n"
fi

if [ -d "$HOME/.codex/sessions" ] || [ -d "$HOME/.codex/archived_sessions" ]; then
  codex_emitted=0
  {
    [ -d "$HOME/.codex/sessions" ] && list_recent_files "$HOME/.codex/sessions" 'rollout-*.jsonl' 45
    [ -d "$HOME/.codex/archived_sessions" ] && list_recent_files "$HOME/.codex/archived_sessions" 'rollout-*.jsonl' 20
  } | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    [ "$codex_emitted" -lt 24 ] || break
    if [ "$include_subagents" = "0" ]; then
      first_line=$(head -n 1 "$f" 2>/dev/null || true)
      if printf "%s" "$first_line" | grep -q '"subagent"' 2>/dev/null; then
        continue
      fi
    fi
    codex_emitted=$((codex_emitted + 1))
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    printf "@@BEGIN codex %s %s\n" "$mt" "$f"
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "$sz" -le 170000 ] 2>/dev/null; then
      cat "$f" 2>/dev/null
    else
      head -n 10 "$f" 2>/dev/null
      printf "\n"
      grep -E '"type":"event_msg".*"type":"token_count"' "$f" 2>/dev/null | awk -v cut="$day_cutoff_iso" '
        NR == 1 { first = $0 }
        {
          if (match($0, /"timestamp":"[^"]+"/)) {
            ts = substr($0, RSTART + 13, RLENGTH - 14)
            if (ts < cut) pre = $0
          }
        }
        END {
          if (first != "") print first
          if (pre != "" && pre != first) print pre
        }
      ' 2>/dev/null
      printf "\n"
      grep -E '"type":"event_msg".*"type":"(task_started|task_complete|turn_aborted|error)"' "$f" 2>/dev/null | tail -n 3
      printf "\n"
      tail -c 160000 "$f" 2>/dev/null
    fi
    printf "\n@@END\n"
  done
fi

if [ -d "$HOME/.dsh/storages/session_projcache/sessions" ]; then
  list_recent_files "$HOME/.dsh/storages/session_projcache/sessions" '*.json' 12 | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    printf "@@BEGIN dsh %s %s\n" "$mt" "$f"
    cat "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi

printf "@@BEGIN procs 0 ps\n"
tmux_panes=$(tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
ps -eo pid=,pcpu=,rss=,tty=,args= 2>/dev/null | grep -E '(^|[ /])(claude|codex|dsh)( |$)' | grep -v 'grep' | head -n 40 | while IFS= read -r line; do
  pid=$(printf "%s" "$line" | awk '{print $1}')
  tty=$(printf "%s" "$line" | awk '{print $4}')
  cwd=""
  if [ -n "$pid" ] && [ -d "/proc/$pid/cwd" ]; then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  fi
  sid=""
  ep=""
  meta="$HOME/.claude/sessions/$pid.json"
  if [ -n "$pid" ] && [ -f "$meta" ]; then
    sid=$(grep -o '"sessionId" *: *"[^"]*"' "$meta" 2>/dev/null | head -n 1 | cut -d'"' -f4)
    ep=$(grep -o '"entrypoint" *: *"[^"]*"' "$meta" 2>/dev/null | head -n 1 | cut -d'"' -f4)
  fi
  pane=""
  if [ -n "$tmux_panes" ] && [ "$tty" != "?" ]; then
    pane=$(printf "%s\n" "$tmux_panes" | awk -v t="/dev/$tty" '$1 == t { $1 = ""; sub(/^ /, ""); print; exit }')
  fi
  printf "%s\t@@CWD=%s\t@@SID=%s\t@@EP=%s\t@@TMUX=%s\n" "$line" "$cwd" "$sid" "$ep" "$pane"
done
printf "@@END\n"

if [ -d "$HOME/.agentbar/pending" ]; then
  for f in "$HOME/.agentbar/pending"/*.json; do
    [ -f "$f" ] || continue
    printf "@@BEGIN pending 0 %s\n" "$f"
    cat "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi
"""#
    }

    public static func probeHost(
        alias: String,
        lookbackHours: Double = 168,
        includeSubagents: Bool = false,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> SSHProbeResult {
        let hostID = HostID.ssh(alias: alias)
        HookApprovalManager.ensureDirectories()
        let scriptB64 = Data(buildPosixProbeScript(includeSubagents: includeSubagents).utf8).base64EncodedString()
        let remoteCmd = "printf '%s' '\(scriptB64)' | (base64 -d 2>/dev/null || base64 -D) | sh"
        let start = Date()

        var args = [
            "-n",
            "-o", "ClearAllForwardings=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6"
        ]
        if !hasCustomControlPath(alias: alias) {
            args += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(sharedControlPathPattern)",
                "-o", "ControlPersist=10m"
            ]
        }
        args += [alias, remoteCmd]

        let runResult = await runProcess(
            executable: "/usr/bin/ssh",
            arguments: args,
            stdinData: nil,
            timeoutSeconds: 22
        )

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000.0)
        guard runResult.exitCode == 0 else {
            let errText = summarizeSSHError(runResult.stderr)
            return SSHProbeResult(
                connection: HostConnectionState(
                    host: hostID,
                    isOnline: false,
                    latencyMs: nil,
                    errorMessage: errText,
                    updatedAt: Date()
                ),
                remoteHome: nil,
                sessions: [],
                pendingApprovals: []
            )
        }

        let parsed = parseProbeOutput(
            stdout: runResult.stdout,
            host: hostID,
            lookbackHours: lookbackHours,
            includeSubagents: includeSubagents,
            seenAtByID: seenAtByID
        )
        return SSHProbeResult(
            connection: HostConnectionState(
                host: hostID,
                isOnline: true,
                latencyMs: latencyMs,
                errorMessage: nil,
                updatedAt: Date()
            ),
            remoteHome: parsed.remoteHome,
            sessions: parsed.sessions,
            pendingApprovals: parsed.pendingApprovals
        )
    }

    public static func sendRemoteDecision(alias: String, requestID: String, jsonData: Data) async throws {
        let safeID = requestID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let remoteCmd = "mkdir -p ~/.agentbar/decisions && cat > ~/.agentbar/decisions/\(safeID).json && rm -f ~/.agentbar/pending/\(safeID).json"
        var args = [
            "-o", "ClearAllForwardings=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6"
        ]
        if !hasCustomControlPath(alias: alias) {
            args += [
                "-o", "ControlMaster=no",
                "-o", "ControlPath=\(sharedControlPathPattern)"
            ]
        }
        args += [alias, remoteCmd]
        let res = await runProcess(
            executable: "/usr/bin/ssh",
            arguments: args,
            stdinData: jsonData,
            timeoutSeconds: 10
        )
        if res.exitCode != 0 {
            throw NSError(
                domain: "SSHProbeService",
                code: Int(res.exitCode),
                userInfo: [NSLocalizedDescriptionKey: summarizeSSHError(res.stderr)]
            )
        }
    }

    public static func parseProbeOutput(
        stdout: String,
        host: HostID,
        lookbackHours: Double = 168,
        includeSubagents: Bool = false,
        seenAtByID: [String: TimeInterval] = [:]
    ) -> (remoteHome: String?, sessions: [AgentSession], pendingApprovals: [PendingApproval]) {
        var remoteHome: String?
        var codexTitles: [String: String] = [:]
        var blocks: [(kind: String, mtime: Date, path: String, body: String)] = []
        let cutoff = Date().addingTimeInterval(-max(720, lookbackHours) * 3600)

        var currentHeader: (kind: String, mtime: Date, path: String)?
        var currentLines: [Substring] = []

        for line in stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("@@HOME ") {
                remoteHome = String(line.dropFirst("@@HOME ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("@@BEGIN ") {
                let rest = line.dropFirst("@@BEGIN ".count)
                let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count == 3 {
                    let kind = String(parts[0])
                    let ts = Double(parts[1]) ?? Date().timeIntervalSince1970
                    let path = String(parts[2])
                    currentHeader = (kind, Date(timeIntervalSince1970: ts), path)
                    currentLines.removeAll(keepingCapacity: true)
                }
                continue
            }
            if line == "@@END" {
                if let header = currentHeader {
                    blocks.append((header.kind, header.mtime, header.path, currentLines.joined(separator: "\n")))
                }
                currentHeader = nil
                currentLines.removeAll(keepingCapacity: true)
                continue
            }
            if currentHeader != nil {
                currentLines.append(line)
            }
        }

        for b in blocks where b.kind == "codex_index" {
            for line in b.body.split(whereSeparator: \.isNewline) {
                if let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = obj["id"] as? String,
                   let name = obj["thread_name"] as? String {
                    codexTitles[id] = CodexAdapter.cleanThreadTitle(name)
                }
            }
        }

        var sessions: [AgentSession] = []
        var approvals: [PendingApproval] = []
        var remoteProcesses: [ProcessStats] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for b in blocks {
            switch b.kind {
            case "claude":
                guard b.mtime >= cutoff else { continue }
                let fid = URL(fileURLWithPath: b.path).deletingPathExtension().lastPathComponent
                if let s = ClaudeCodeAdapter.parseTranscript(
                    jsonl: b.body,
                    fallbackSessionID: fid,
                    filePath: b.path,
                    fileModificationDate: b.mtime,
                    host: host,
                    includeSubagents: includeSubagents,
                    seenAtByID: seenAtByID
                ) {
                    sessions.append(s)
                }
            case "codex":
                guard b.mtime >= cutoff else { continue }
                if let s = CodexAdapter.parseRollout(
                    jsonl: b.body,
                    filePath: b.path,
                    fileModificationDate: b.mtime,
                    host: host,
                    threadTitles: codexTitles,
                    includeSubagents: includeSubagents,
                    seenAtByID: seenAtByID
                ) {
                    sessions.append(s)
                }
            case "dsh":
                guard b.mtime >= cutoff else { continue }
                let fid = URL(fileURLWithPath: b.path).deletingPathExtension().lastPathComponent
                if let data = b.body.data(using: .utf8),
                   let s = DeepSeekHarnessAdapter.parseProjection(
                       data: data,
                       fallbackID: fid,
                       filePath: b.path,
                       fileModificationDate: b.mtime,
                       host: host,
                       seenAtByID: seenAtByID
                   ) {
                    sessions.append(s)
                }
            case "procs":
                remoteProcesses = parseRemoteProcessBlock(b.body)
            case "pending":
                if let data = b.body.data(using: .utf8),
                   var pending = try? decoder.decode(PendingApproval.self, from: data) {
                    pending.host = host
                    if pending.highRiskMatchedRule == nil {
                        pending.highRiskMatchedRule = HookApprovalManager.matchedHighRiskRule(in: pending.commandOrSummary)
                    }
                    approvals.append(pending)
                }
            default:
                break
            }
        }

        sessions = SessionDeduplicator.deduplicate(sessions)
        if !remoteProcesses.isEmpty {
            attachAndSynthesizeRemoteProcesses(remoteProcesses, into: &sessions, host: host)
        }
        sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        return (remoteHome, sessions, approvals)
    }

    private static func parseRemoteProcessBlock(_ text: String) -> [ProcessStats] {
        var out: [ProcessStats] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.components(separatedBy: "\t@@")
            let psPart = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
            var extras: [String: String] = [:]
            for field in fields.dropFirst() {
                guard let eq = field.firstIndex(of: "=") else { continue }
                let value = field[field.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    extras[String(field[..<eq])] = value
                }
            }
            let cols = psPart.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard cols.count >= 5,
                  let pid = Int32(cols[0]) else {
                continue
            }
            let cpu = Double(cols[1]) ?? 0
            let rssKB = UInt64(cols[2]) ?? 0
            let tty = cols[3] == "?" || cols[3] == "??" ? nil : String(cols[3])
            let cmd = String(cols[4])
            out.append(ProcessStats(
                pid: pid,
                memoryBytes: rssKB * 1024,
                cpuPercent: cpu,
                tty: tty,
                cwd: extras["CWD"],
                command: cmd,
                sessionID: extras["SID"],
                entrypoint: extras["EP"],
                tmuxTarget: extras["TMUX"]
            ))
        }
        return out
    }

    private static func attachAndSynthesizeRemoteProcesses(
        _ procs: [ProcessStats],
        into sessions: inout [AgentSession],
        host: HostID
    ) {
        // Processes that report their Claude session ID are bound exactly; cwd matching is only a fallback.
        let ordered = procs.filter { $0.sessionID != nil } + procs.filter { $0.sessionID == nil }
        for proc in ordered {
            let lowerCmd = proc.command.lowercased()
            let procMatchesKind: (AgentSession) -> Bool = { s in
                if lowerCmd.contains("claude") { return s.kind == .claudeCode }
                if lowerCmd.contains("codex") { return s.kind == .codexCLI || s.kind == .codexDesktop }
                if lowerCmd.contains("dsh") { return s.kind == .deepseekHarness }
                return false
            }
            let matchedIndex: Int?
            if let sid = proc.sessionID {
                matchedIndex = sessions.firstIndex { $0.process == nil && $0.rawSessionID == sid }
            } else {
                matchedIndex = sessions.firstIndex(where: { s in
                    guard s.process == nil, procMatchesKind(s) else { return false }
                    if let pcwd = proc.cwd, let scwd = s.cwd {
                        return pcwd == scwd
                    }
                    return proc.cwd == nil
                })
            }
            if let idx = matchedIndex {
                sessions[idx].process = proc
                let entrypoint = proc.entrypoint?.lowercased()
                if entrypoint?.contains("vscode") == true {
                    sessions[idx].launchEnvironment = .vscodeExtension
                } else if entrypoint == "cli" {
                    sessions[idx].launchEnvironment = .terminalCLI
                }
                if lowerCmd.contains(".cursor-server") || lowerCmd.contains("/cursor/") {
                    sessions[idx].launchEnvironment = .cursorExtension
                } else if lowerCmd.contains(".vscode-server") || lowerCmd.contains("/vscode/") {
                    sessions[idx].launchEnvironment = .vscodeExtension
                }
                if proc.cpuPercent >= 1.5 && sessions[idx].status == .waitingForInput {
                    sessions[idx].status = .generating
                    sessions[idx].statusIsInferred = true
                }
            }
        }
    }

    private static func summarizeSSHError(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("permission denied") || lower.contains("gssapi") || lower.contains("kex_exchange") {
            return "需登录认证"
        }
        if lower.contains("timed out") || lower.contains("timeout") { return "连接超时" }
        if lower.contains("could not resolve") { return "域名无法解析" }
        if lower.contains("connection refused") { return "连接被拒绝" }
        if lower.contains("host key verification failed") { return "HostKey 待确认" }
        let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "不可达"
        return String(line.prefix(36))
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        stdinData: Data?,
        timeoutSeconds: TimeInterval
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                let extraPaths = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(home)/.local/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin"
                ]
                let currentPath = env["PATH"] ?? ""
                env["PATH"] = (extraPaths + [currentPath]).filter { !$0.isEmpty }.joined(separator: ":")
                proc.environment = env
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                let inPipe = Pipe()
                if stdinData != nil {
                    proc.standardInput = inPipe
                }

                final class PipeIOBox: @unchecked Sendable {
                    var outData = Data()
                    var errData = Data()
                    var finished = false
                }

                let ioQueue = DispatchQueue(label: "com.agentbar.ssh.pipe-io")
                let state = PipeIOBox()

                let outReadHandle = outPipe.fileHandleForReading
                let errReadHandle = errPipe.fileHandleForReading
                let outFD = outReadHandle.fileDescriptor
                let errFD = errReadHandle.fileDescriptor

                outReadHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    ioQueue.async {
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                        } else if !state.finished {
                            state.outData.append(chunk)
                        }
                    }
                }
                errReadHandle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    ioQueue.async {
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                        } else if !state.finished {
                            state.errData.append(chunk)
                        }
                    }
                }

                let timer = DispatchSource.makeTimerSource(queue: ioQueue)

                @Sendable func finish(status: Int32, timedOut: Bool) {
                    guard !state.finished else { return }
                    state.finished = true
                    timer.cancel()
                    outReadHandle.readabilityHandler = nil
                    errReadHandle.readabilityHandler = nil
                    drainNonBlocking(fd: outFD, into: &state.outData)
                    drainNonBlocking(fd: errFD, into: &state.errData)
                    try? outReadHandle.close()
                    try? errReadHandle.close()

                    let outStr = String(data: state.outData, encoding: .utf8) ?? ""
                    var errStr = String(data: state.errData, encoding: .utf8) ?? ""
                    if timedOut && errStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errStr = "连接超时"
                    }
                    continuation.resume(returning: (status, outStr, errStr))
                }

                proc.terminationHandler = { exitedProc in
                    ioQueue.async {
                        finish(status: exitedProc.terminationStatus, timedOut: false)
                    }
                }

                do {
                    try proc.run()
                } catch {
                    ioQueue.async {
                        guard !state.finished else { return }
                        state.finished = true
                        timer.cancel()
                        outReadHandle.readabilityHandler = nil
                        errReadHandle.readabilityHandler = nil
                        continuation.resume(returning: (-1, "", error.localizedDescription))
                    }
                    return
                }

                if let stdinData {
                    try? inPipe.fileHandleForWriting.write(contentsOf: stdinData)
                    try? inPipe.fileHandleForWriting.close()
                }

                timer.schedule(deadline: .now() + timeoutSeconds)
                timer.setEventHandler {
                    if proc.isRunning {
                        let pid = proc.processIdentifier
                        proc.terminate()
                        if pid > 0 {
                            kill(pid, SIGKILL)
                        }
                    }
                    finish(status: -1, timedOut: true)
                }
                timer.resume()
            }
        }
    }

    private static func drainNonBlocking(fd: Int32, into buffer: inout Data) {
        guard fd >= 0 else { return }
        let oldFlags = fcntl(fd, F_GETFL)
        guard oldFlags != -1 else { return }
        _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk.prefix(n))
            } else {
                break
            }
        }
    }
}
