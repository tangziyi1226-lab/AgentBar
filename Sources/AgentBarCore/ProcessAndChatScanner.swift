import AppKit
import CoreGraphics
import Darwin
import Foundation

public enum ProcessAndChatScanner {
    private struct CPUSample {
        var totalMachTicks: UInt64
        var uptimeNs: UInt64
        var lastPercent: Double
    }

    private static let cpuLock = NSLock()
    nonisolated(unsafe) private static var prevCPUSamples: [Int32: CPUSample] = [:]
    private static let timebaseNumerDenom: (numer: Double, denom: Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let denom = tb.denom > 0 ? Double(tb.denom) : 1.0
        return (Double(tb.numer), denom)
    }()

    private static let agentAsciiKeywords: [[UInt8]] = [
        Array("claude".utf8),
        Array("codex".utf8),
        Array("chatgpt.app".utf8),
        Array("cursor".utf8),
        Array("trae".utf8),
        Array("antigravity".utf8),
        Array("deepseek".utf8),
        Array("doubao".utf8),
        Array("dsh".utf8)
    ]

    private static func asciiContainsAnyAgentKeyword(_ bytes: ArraySlice<UInt8>) -> Bool {
        let count = bytes.count
        guard count >= 3 else { return false }
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            for kw in agentAsciiKeywords {
                let kLen = kw.count
                guard count >= kLen else { continue }
                let first = kw[0]
                let limit = count - kLen
                var i = 0
                while i <= limit {
                    let b0 = base[i]
                    let c0 = (b0 >= 0x41 && b0 <= 0x5A) ? (b0 &+ 32) : b0
                    if c0 == first {
                        var match = true
                        var j = 1
                        while j < kLen {
                            let bj = base[i &+ j]
                            let cj = (bj >= 0x41 && bj <= 0x5A) ? (bj &+ 32) : bj
                            if cj != kw[j] {
                                match = false
                                break
                            }
                            j &+= 1
                        }
                        if match { return true }
                    }
                    i &+= 1
                }
            }
            return false
        }
    }

    public static func scanLocalAgentProcesses() -> [ProcessStats] {
        let estimatedBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimatedBytes > 0 else { return [] }

        let capacity = Int(estimatedBytes) / MemoryLayout<pid_t>.stride + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualBytes = pids.withUnsafeMutableBytes { rawBuf -> Int32 in
            guard let base = rawBuf.baseAddress else { return 0 }
            return proc_listpids(UInt32(PROC_ALL_PIDS), 0, base, Int32(rawBuf.count))
        }
        guard actualBytes > 0 else { return [] }
        let pidCount = Int(actualBytes) / MemoryLayout<pid_t>.stride

        let currentUID = getuid()
        let bsdStride = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let taskStride = Int32(MemoryLayout<proc_taskinfo>.stride)
        var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let nowUptimeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        var activeMatchedPIDs: Set<Int32> = []
        var results: [ProcessStats] = []

        for idx in 0..<pidCount {
            let pid = pids[idx]
            guard pid > 0 else { continue }

            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdStride) == bsdStride else {
                continue
            }
            guard bsd.pbi_uid == currentUID, bsd.pbi_status != UInt32(SZOMB) else {
                continue
            }

            let comm: String
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if pathLen > 0 {
                let slice = pathBuffer[0..<Int(pathLen)]
                guard asciiContainsAnyAgentKeyword(slice) else { continue }
                comm = String(decoding: slice, as: UTF8.self)
            } else {
                comm = withUnsafePointer(to: &bsd.pbi_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2) { cStr in
                        let s = String(cString: cStr)
                        if !s.isEmpty { return s }
                        return withUnsafePointer(to: &bsd.pbi_comm) { commPtr in
                            commPtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                                String(cString: $0)
                            }
                        }
                    }
                }
                guard !comm.isEmpty else { continue }
            }

            let lower = comm.lowercased()
            guard lower.contains("claude")
                || lower.contains("codex")
                || lower.contains("chatgpt.app")
                || lower.contains("cursor")
                || lower.contains("trae")
                || isAntigravityDesktopProcess(lower)
                || lower.contains("deepseek")
                || lower.contains("doubao")
                || lower.contains("dsh") else {
                continue
            }

            activeMatchedPIDs.insert(pid)

            var ttyName: String?
            if bsd.e_tdev != UInt32.max, bsd.e_tdev != 0,
               let devPtr = devname(dev_t(bitPattern: bsd.e_tdev), S_IFCHR) {
                let s = String(cString: devPtr)
                if !s.isEmpty && s != "??" && s != "?" {
                    ttyName = s
                }
            }

            var taskInfo = proc_taskinfo()
            let hasTaskInfo = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskStride) == taskStride
            let cpuPercent: Double
            if hasTaskInfo {
                let totalTicks = taskInfo.pti_total_user &+ taskInfo.pti_total_system
                cpuPercent = sampleCPUPercent(pid: pid, totalTicks: totalTicks, nowUptimeNs: nowUptimeNs)
            } else {
                cpuPercent = 0.0
            }

            let fallbackRSS = hasTaskInfo ? taskInfo.pti_resident_size : 0
            let footprint = physicalFootprint(pid: pid) ?? fallbackRSS
            let cwd = processWorkingDirectory(pid: pid)
            results.append(ProcessStats(
                pid: pid,
                memoryBytes: footprint,
                cpuPercent: cpuPercent,
                tty: ttyName,
                cwd: cwd,
                command: comm
            ))
        }

        cpuLock.lock()
        prevCPUSamples = prevCPUSamples.filter { activeMatchedPIDs.contains($0.key) }
        cpuLock.unlock()

        return results
    }

    private static func sampleCPUPercent(pid: Int32, totalTicks: UInt64, nowUptimeNs: UInt64) -> Double {
        cpuLock.lock()
        defer { cpuLock.unlock() }
        if let prev = prevCPUSamples[pid] {
            let wallDeltaNs = nowUptimeNs > prev.uptimeNs ? (nowUptimeNs - prev.uptimeNs) : 0
            if wallDeltaNs < 250_000_000 {
                return prev.lastPercent
            }
            let tickDelta = totalTicks >= prev.totalMachTicks ? (totalTicks - prev.totalMachTicks) : 0
            let cpuNs = Double(tickDelta) * timebaseNumerDenom.numer / timebaseNumerDenom.denom
            let rawPct = max(0.0, (cpuNs / Double(wallDeltaNs)) * 100.0)
            let rounded = (rawPct * 10.0).rounded() / 10.0
            prevCPUSamples[pid] = CPUSample(totalMachTicks: totalTicks, uptimeNs: nowUptimeNs, lastPercent: rounded)
            return rounded
        } else {
            prevCPUSamples[pid] = CPUSample(totalMachTicks: totalTicks, uptimeNs: nowUptimeNs, lastPercent: 0.0)
            return 0.0
        }
    }

    public static func physicalFootprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let res = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard res == 0 else { return nil }
        return info.ri_phys_footprint
    }

    public static func processWorkingDirectory(pid: Int32) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size)
        guard ret == size else { return nil }
        return withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                let path = String(cString: cStr)
                return path.isEmpty ? nil : path
            }
        }
    }

    public static func attachProcesses(to sessions: inout [AgentSession], processes: [ProcessStats]) {
        guard !processes.isEmpty else { return }
        let prepared: [(proc: ProcessStats, lowerCmd: String)] = processes.map { ($0, $0.command.lowercased()) }
        for idx in sessions.indices where sessions[idx].host.isLocal {
            let kind = sessions[idx].kind
            let targetCwd = sessions[idx].cwd
            let matched = prepared.compactMap { entry -> ProcessStats? in
                let cmd = entry.lowerCmd
                let ok: Bool
                switch kind {
                case .claudeCode:
                    ok = cmd.hasSuffix("/claude") || cmd == "claude"
                case .claudeDesktop:
                    ok = cmd.contains("claude.app")
                case .codexCLI:
                    ok = (cmd.hasSuffix("/codex") || cmd == "codex") && !cmd.contains("chatgpt.app/contents/macos/chatgpt")
                case .codexDesktop:
                    ok = cmd.contains("chatgpt.app") || cmd.contains("codex")
                case .deepseekHarness:
                    ok = cmd.contains("deepseek harness.app") || cmd.contains("dsh")
                case .cursor:
                    ok = cmd.contains("cursor.app/contents/macos/cursor")
                case .trae:
                    ok = cmd.contains("trae")
                case .antigravity:
                    ok = isAntigravityDesktopProcess(cmd)
                case .doubao:
                    ok = cmd.contains("doubao")
                case .deepseekChat:
                    ok = cmd.contains("deepseek.app")
                case .generic:
                    ok = false
                }
                return ok ? entry.proc : nil
            }
            if let exactCwdMatch = matched.first(where: { proc in
                guard let pcwd = proc.cwd, let scwd = targetCwd else { return false }
                return pcwd == scwd || pcwd.hasPrefix(scwd + "/") || scwd.hasPrefix(pcwd + "/")
            }) {
                sessions[idx].process = exactCwdMatch
            } else if let best = matched.max(by: { $0.memoryBytes < $1.memoryBytes }) {
                sessions[idx].process = best
            }
        }
    }

    private static func isAntigravityDesktopProcess(_ command: String) -> Bool {
        command == "antigravity" || command.hasSuffix("/antigravity.app/contents/macos/antigravity")
    }

    @MainActor
    public static func scanRunningChatApps(processes: [ProcessStats]) -> [AgentSession] {
        let running = NSWorkspace.shared.runningApplications
        let windowTitles = currentWindowTitlesByPID()
        var chatSessions: [AgentSession] = []

        for app in running {
            guard let bid = app.bundleIdentifier?.lowercased() else { continue }
            let kind: AgentKind?
            if bid.contains("doubao") {
                kind = .doubao
            } else if bid == "com.deepseek.chat" {
                kind = .deepseekChat
            } else {
                kind = nil
            }
            guard let kind else { continue }
            let pid = app.processIdentifier
            let winTitle = windowTitles[pid]?.first { !$0.isEmpty }
            let procStat = processes.first { $0.pid == pid }
            let title = winTitle ?? "\(kind.displayName)"
            let stateDesc = app.isActive ? "前台窗口运行中" : "后台运行中"
            let overview = winTitle != nil ? "窗口标题 · \(stateDesc)" : "\(stateDesc) · 仅进程级检测"

            chatSessions.append(AgentSession(
                id: "local:chat:\(bid):\(pid)",
                rawSessionID: "\(pid)",
                kind: kind,
                host: .local,
                title: title,
                overview: overview,
                status: .runningProcessOnly,
                process: procStat,
                startedAt: app.launchDate ?? Date(),
                lastActivityAt: Date(),
                isSeen: true
            ))
        }
        return chatSessions
    }

    private static func currentWindowTitlesByPID() -> [pid_t: [String]] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var map: [pid_t: [String]] = [:]
        for entry in infoList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let name = entry[kCGWindowName as String] as? String else {
                continue
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                map[pid, default: []].append(trimmed)
            }
        }
        return map
    }
}
