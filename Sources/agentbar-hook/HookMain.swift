import AgentBarCore
import Darwin
import Foundation

nonisolated(unsafe) private var gSignalPendingPath: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var gSignalDecisionPath: UnsafeMutablePointer<CChar>?

private let hookCleanupSignalHandler: @convention(c) (Int32) -> Void = { _ in
    if let p = gSignalPendingPath {
        unlink(p)
    }
    if let d = gSignalDecisionPath {
        unlink(d)
    }
    _exit(0)
}

@main
struct AgentBarHookMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let subcommand = args.first ?? "claude-event"
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

        switch subcommand {
        case "claude-permission":
            handlePermission(json: json, defaultKind: .claudeCode)
        case "codex-permission":
            handlePermission(json: json, defaultKind: .codexCLI)
        case "codex-event":
            let eventName = args.dropFirst().first ?? (json["hook_event_name"] as? String) ?? "event"
            handleLifecycleEvent(tool: "codex", eventName: eventName, json: json)
        case "self-test":
            Task {
                await runSelfTest(
                    probeSSH: args.contains("--probe-ssh"),
                    probeDSH: args.contains("--probe-dsh"),
                    printMetrics: args.contains("--print-metrics")
                )
                Foundation.exit(0)
            }
            RunLoop.main.run()
        default:
            let eventName = args.dropFirst().first ?? (json["hook_event_name"] as? String) ?? "event"
            handleLifecycleEvent(tool: "claude-code", eventName: eventName, json: json)
        }
    }

    private static func runSelfTest(probeSSH: Bool = false, probeDSH: Bool = false, printMetrics: Bool = false) async {
        let jsonl = """
        {"type":"user","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:00.000Z","message":{"role":"user","content":"帮我修 bug"}}
        {"type":"ai-title","aiTitle":"修复加载器崩溃","sessionId":"s-1"}
        {"type":"assistant","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:05.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":1000,"output_tokens":50,"cache_read_input_tokens":4000,"cache_creation_input_tokens":200},"content":[{"type":"text","text":"我先看一下代码。"}]}}
        {"type":"assistant","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:06.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":1000,"output_tokens":120,"cache_read_input_tokens":4000,"cache_creation_input_tokens":200},"content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"swift test"}}]}}
        {"type":"user","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":false}]}}
        {"type":"assistant","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:14.000Z","message":{"id":"msg_2","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":1200,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"### 修复完成\\n全部测试通过。"}]}}
        """
        guard let claude = ClaudeCodeAdapter.parseTranscript(
            jsonl: jsonl,
            fallbackSessionID: "s-1",
            filePath: "/tmp/s-1.jsonl",
            fileModificationDate: Date(),
            host: .local
        ) else {
            fputs("FAIL: claude parse nil\n", stderr)
            Foundation.exit(1)
        }
        precondition(claude.title == "修复加载器崩溃")
        precondition(claude.usage.input == 2200 && claude.usage.output == 320 && claude.usage.cacheRead == 9000)
        precondition(HookApprovalManager.matchedHighRiskRule(in: "rm -rf .build") == "rm -rf")

        // Regression: trailing non-assistant records must not re-mark a viewed session as new.
        let seenISO = ISO8601DateFormatter()
        seenISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seenTestNow = Date()
        let replyDate = seenTestNow.addingTimeInterval(-120)
        let noiseDate = seenTestNow.addingTimeInterval(-30)
        let seenBaseJSONL = """
        {"type":"user","cwd":"/tmp/proj","sessionId":"s-seen","timestamp":"\(seenISO.string(from: replyDate.addingTimeInterval(-10)))","message":{"role":"user","content":"跑一下训练"}}
        {"type":"assistant","cwd":"/tmp/proj","sessionId":"s-seen","timestamp":"\(seenISO.string(from: replyDate))","message":{"id":"m_seen_1","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"训练已启动。"}]}}
        {"type":"queue-operation","operation":"enqueue","sessionId":"s-seen","timestamp":"\(seenISO.string(from: noiseDate))"}
        {"type":"file-history-snapshot","sessionId":"s-seen"}
        """
        let unseen = ClaudeCodeAdapter.parseTranscript(
            jsonl: seenBaseJSONL,
            fallbackSessionID: "s-seen",
            filePath: "/tmp/s-seen.jsonl",
            fileModificationDate: noiseDate,
            host: .local
        )!
        precondition(unseen.status == .completed && !unseen.isSeen)
        let seenMap = [unseen.id: replyDate.timeIntervalSince1970 + 1]
        let afterNoise = ClaudeCodeAdapter.parseTranscript(
            jsonl: seenBaseJSONL,
            fallbackSessionID: "s-seen",
            filePath: "/tmp/s-seen.jsonl",
            fileModificationDate: noiseDate,
            host: .local,
            seenAtByID: seenMap
        )!
        precondition(afterNoise.isSeen && afterNoise.status == .waitingForInput, "Non-assistant records re-marked a viewed session as new")
        let newReplyJSONL = seenBaseJSONL + "\n" + """
        {"type":"assistant","cwd":"/tmp/proj","sessionId":"s-seen","timestamp":"\(seenISO.string(from: seenTestNow.addingTimeInterval(-5)))","message":{"id":"m_seen_2","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"训练完成。"}]}}
        """
        let afterReply = ClaudeCodeAdapter.parseTranscript(
            jsonl: newReplyJSONL,
            fallbackSessionID: "s-seen",
            filePath: "/tmp/s-seen.jsonl",
            fileModificationDate: seenTestNow,
            host: .local,
            seenAtByID: seenMap
        )!
        precondition(!afterReply.isSeen && afterReply.status == .completed, "A new assistant reply must mark the session as new")

        // Regression: remote processes bind to sessions by Claude session ID, carrying entrypoint and tmux pane.
        let probeMtime = Int(noiseDate.timeIntervalSince1970)
        let probeStdout = [
            "@@HOME /home/tester",
            "@@BEGIN claude \(probeMtime) /home/tester/.claude/projects/-tmp-proj/s-vscode.jsonl",
            #"{"type":"user","cwd":"/tmp/proj","sessionId":"s-vscode","entrypoint":"claude-vscode","message":{"role":"user","content":"插件里的会话"}}"#,
            "@@END",
            "@@BEGIN claude \(probeMtime) /home/tester/.claude/projects/-tmp-proj/s-tmux.jsonl",
            #"{"type":"user","cwd":"/tmp/proj","sessionId":"s-tmux","entrypoint":"claude-vscode","message":{"role":"user","content":"tmux 里的会话"}}"#,
            "@@END",
            "@@BEGIN claude \(probeMtime) /home/tester/.claude/projects/-tmp-proj/s-idle.jsonl",
            #"{"type":"user","cwd":"/tmp/proj","sessionId":"s-idle","message":{"role":"user","content":"没有进程的会话"}}"#,
            "@@END",
            "@@BEGIN procs 0 ps",
            "  303  0.0  1000 ? /home/tester/.vscode-server/extensions/openai.chatgpt/bin/codex app-server\t@@CWD=/tmp/proj",
            "  101  0.0  1000 pts/3 claude\t@@CWD=/tmp/proj\t@@SID=s-tmux\t@@EP=cli\t@@TMUX=cc:0.0",
            "  202  0.0  1000 ? /home/tester/.vscode-server/extensions/anthropic.claude-code/resources/native-binary/claude\t@@CWD=/tmp/proj\t@@SID=s-vscode\t@@EP=claude-vscode\t@@TMUX=",
            "@@END"
        ].joined(separator: "\n")
        let probed = SSHProbeService.parseProbeOutput(stdout: probeStdout, host: .ssh(alias: "test-host"))
        guard let tmuxSession = probed.sessions.first(where: { $0.rawSessionID == "s-tmux" }),
              let vscodeSession = probed.sessions.first(where: { $0.rawSessionID == "s-vscode" }),
              let idleSession = probed.sessions.first(where: { $0.rawSessionID == "s-idle" }) else {
            fputs("FAIL: remote probe sessions missing\n", stderr)
            Foundation.exit(1)
        }
        precondition(tmuxSession.process?.pid == 101 && tmuxSession.process?.tmuxTarget == "cc:0.0" && tmuxSession.launchEnvironment == .terminalCLI)
        precondition(vscodeSession.process?.pid == 202 && vscodeSession.process?.tmuxTarget == nil && vscodeSession.launchEnvironment == .vscodeExtension)
        precondition(idleSession.process == nil, "A Codex process must never be attached to a Claude session")

        // Regression tests for Issue #1: Codex multi-shard deduplication & Claude subagent IDs
        let sharedCodexID = "01a1f304-3559-7223-8f2a-f5fca907db41"
        let now = Date()
        let oldShard = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"2026-11-19T08:55:02Z","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"2026-11-19T08:55:03Z","type":"event_msg","payload":{"type":"task_started"}}
            {"timestamp":"2026-11-19T08:55:04Z","type":"response_item","payload":{"type":"message","role":"user","content":"修复重复卡片与统计翻倍"}}
            {"timestamp":"2026-11-19T08:55:50Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":57143,"cached_input_tokens":30907,"cache_write_input_tokens":0,"output_tokens":639,"reasoning_output_tokens":0,"total_tokens":57782}}}}
            """,
            filePath: "/tmp/rollout-old-\(sharedCodexID).jsonl",
            fileModificationDate: now.addingTimeInterval(-600),
            host: .local
        )!
        let newShard = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"2026-11-19T08:55:54Z","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"2026-11-19T08:55:55Z","type":"event_msg","payload":{"type":"task_started"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"已完成去重修复"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":655414,"cached_input_tokens":587574,"cache_write_input_tokens":0,"output_tokens":5681,"reasoning_output_tokens":0,"total_tokens":661095}}}}
            """,
            filePath: "/tmp/rollout-new-\(sharedCodexID)_shard2.jsonl",
            fileModificationDate: now.addingTimeInterval(-20),
            host: .local
        )!
        let mergedCodex = SessionDeduplicator.deduplicate([oldShard, newShard])
        precondition(mergedCodex.count == 1)
        precondition(mergedCodex[0].title == "修复重复卡片与统计翻倍")
        precondition(mergedCodex[0].overview == "已完成去重修复")
        precondition(mergedCodex[0].usage.totalTokens == 661_095)
        precondition(mergedCodex[0].turnCount == 2)
        precondition(SessionDeduplicator.deduplicate([mergedCodex[0], mergedCodex[0]])[0].turnCount == 2)

        // Regression test: timestamp-based seen state clears green on current turn, but re-alerts on a newer turn
        let seenMapOld: [String: TimeInterval] = [
            "local:codex:\(sharedCodexID)": now.addingTimeInterval(-300).timeIntervalSince1970
        ]
        let oldShardSeen = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"2026-11-19T08:55:02Z","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"2026-11-19T08:55:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"旧回复"}}
            {"timestamp":"2026-11-19T08:55:05Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":500}}
            """,
            filePath: "/tmp/rollout-old-\(sharedCodexID).jsonl",
            fileModificationDate: now.addingTimeInterval(-600),
            host: .local,
            seenAtByID: seenMapOld
        )!
        let newShardUnseen = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"2026-11-19T08:55:54Z","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"新生成的回复"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}
            """,
            filePath: "/tmp/rollout-new-\(sharedCodexID)_shard2.jsonl",
            fileModificationDate: now.addingTimeInterval(-10),
            host: .local,
            seenAtByID: seenMapOld
        )!
        precondition(oldShardSeen.isSeen == true && oldShardSeen.status == .waitingForInput)
        precondition(newShardUnseen.isSeen == false && newShardUnseen.status == .completed)
        let mergedAfterNewTurn = SessionDeduplicator.deduplicate([oldShardSeen, newShardUnseen])
        precondition(mergedAfterNewTurn[0].isSeen == false && mergedAfterNewTurn[0].status == .completed)

        // Regression test: Codex Desktop native read state (`electron-thread-read-state-v1`) auto-clears green when viewed
        let codexReadWhenUnread = CodexReadState(
            hasReadState: true,
            unreadThreadIDs: [sharedCodexID],
            userActivityAtByThreadID: [:],
            stateFileUpdatedAt: now
        )
        let codexReadWhenViewed = CodexReadState(
            hasReadState: true,
            unreadThreadIDs: [],
            userActivityAtByThreadID: [sharedCodexID: now.timeIntervalSince1970],
            stateFileUpdatedAt: now
        )
        let unreadDesktopSession = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"2026-11-19T08:55:54Z","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"桌面端回复"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}
            """,
            filePath: "/tmp/rollout-new-\(sharedCodexID)_shard2.jsonl",
            fileModificationDate: now.addingTimeInterval(-10),
            host: .local,
            readState: codexReadWhenUnread
        )!
        let viewedDesktopSession = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"2026-11-19T08:55:54Z","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"桌面端回复"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}
            """,
            filePath: "/tmp/rollout-new-\(sharedCodexID)_shard2.jsonl",
            fileModificationDate: now.addingTimeInterval(-10),
            host: .local,
            readState: codexReadWhenViewed
        )!
        precondition(unreadDesktopSession.isSeen == false && unreadDesktopSession.status == .completed)
        precondition(viewedDesktopSession.isSeen == true && viewedDesktopSession.status == .waitingForInput)

        let isoNow = ISO8601DateFormatter()
        let truncatedActiveSession = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"\(isoNow.string(from: now.addingTimeInterval(-3600)))","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"\(isoNow.string(from: now.addingTimeInterval(-5)))","type":"compacted","payload":{"window_number":2,"resume_metadata":{"previous_turn_settings":{"model":"gpt-5.4"}}}}
            {"timestamp":"\(isoNow.string(from: now.addingTimeInterval(-4)))","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"swift build\\"}","call_id":"c1"}}
            {"timestamp":"\(isoNow.string(from: now.addingTimeInterval(-4)))","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"ok"}}
            """,
            filePath: "/tmp/rollout-truncated-\(sharedCodexID).jsonl",
            fileModificationDate: now.addingTimeInterval(-4),
            host: .local,
            threadTitles: [sharedCodexID: "长任务截断回归"],
            readState: codexReadWhenViewed
        )!
        precondition(truncatedActiveSession.status == .generating && truncatedActiveSession.model == "gpt-5.4")

        let fm = FileManager.default
        let tmpCodexHome = fm.temporaryDirectory.appendingPathComponent("agentbar-selftest-large-\(UUID().uuidString)")
        let tmpDayDir = tmpCodexHome.appendingPathComponent(".codex/sessions/2026/11/20")
        try? fm.createDirectory(at: tmpDayDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpCodexHome) }

        let tmpRolloutURL = tmpDayDir.appendingPathComponent("rollout-2026-11-20T16-52-31-\(sharedCodexID).jsonl")
        let tmpIndexURL = tmpCodexHome.appendingPathComponent(".codex/session_index.jsonl")
        let tmpGlobalStateURL = tmpCodexHome.appendingPathComponent(".codex/.codex-global-state.json")
        try? Data(#"{"id":"\#(sharedCodexID)","thread_name":"超长单轮重构任务"}"#.utf8).write(to: tmpIndexURL)
        try? Data(#"{"electron-thread-read-state-v1":{"unreadByIdentity":{"u":{"local":[]}}}}"#.utf8).write(to: tmpGlobalStateURL)

        let filler = String(repeating: "a", count: 28_000) + #" \"type\":\"task_complete\" "#
        var bigLines: [String] = [
            #"{"timestamp":"\#(isoNow.string(from: now.addingTimeInterval(-3600)))","type":"session_meta","payload":{"id":"\#(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}"#,
            #"{"timestamp":"\#(isoNow.string(from: now.addingTimeInterval(-3599)))","type":"event_msg","payload":{"type":"task_started"}}"#
        ]
        for idx in 0..<95 {
            let stepTS = isoNow.string(from: now.addingTimeInterval(Double(-3500 + idx)))
            bigLines.append(#"{"timestamp":"\#(stepTS)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"echo 1\"}","call_id":"fill_\#(idx)"}}"#)
            bigLines.append(#"{"timestamp":"\#(stepTS)","type":"response_item","payload":{"type":"function_call_output","call_id":"fill_\#(idx)","output":"\#(filler)"}}"#)
        }
        bigLines.append(#"{"timestamp":"\#(isoNow.string(from: now.addingTimeInterval(-3)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":5000,"cache_write_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":10500}}}}"#)
        try? Data((bigLines.joined(separator: "\n") + "\n").utf8).write(to: tmpRolloutURL)

        let largeLoaded = await CodexAdapter.loadLocalSessions(homeDirectory: tmpCodexHome.path, lookbackHours: 24)
        precondition(largeLoaded.first?.status == .generating, "Expected >2.5 MB unclosed rollout to remain .generating")

        bigLines.append(#"{"timestamp":"\#(isoNow.string(from: now))","type":"response_item","payload":{"type":"message","role":"assistant","content":"完成"}}"#)
        bigLines.append(#"{"timestamp":"\#(isoNow.string(from: now))","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}"#)
        try? Data((bigLines.joined(separator: "\n") + "\n").utf8).write(to: tmpRolloutURL)
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: tmpGlobalStateURL.path)
        let largeFinished = await CodexAdapter.loadLocalSessions(homeDirectory: tmpCodexHome.path, lookbackHours: 24)
        precondition(largeFinished.first?.status == .waitingForInput, "Expected >2.5 MB completed+viewed rollout to be .waitingForInput")

        let subJSONL = """
        {"type":"user","sessionId":"s-1","agentId":"a68596","isSidechain":true,"cwd":"/Users/test/repo","timestamp":"2026-11-19T04:10:00Z","message":{"role":"user","content":"子代理任务"}}
        """
        precondition(ClaudeCodeAdapter.parseTranscript(
            jsonl: subJSONL,
            fallbackSessionID: "agent-a68596",
            filePath: "/Users/test/.claude/projects/p/s-1/subagents/agent-a68596.jsonl",
            fileModificationDate: now,
            host: .local,
            includeSubagents: false
        ) == nil)
        let parsedSub = ClaudeCodeAdapter.parseTranscript(
            jsonl: subJSONL,
            fallbackSessionID: "agent-a68596",
            filePath: "/Users/test/.claude/projects/p/s-1/subagents/agent-a68596.jsonl",
            fileModificationDate: now,
            host: .local,
            includeSubagents: true
        )!
        precondition(parsedSub.id == "local:claude:s-1:a68596" && parsedSub.rawSessionID == "s-1")

        // Unit tests: DeepSeek Harness credentials YAML & wallet summary parser
        let sampleCredYAML = """
        version: 1
        records:
          deepseek-account-platform/device:
            kind: grant
            payload:
              id: 00000000-0000-4000-8000-000000000001
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: "test_dsh_grant_token_123456"
              issuer: https://platform.deepseek.com
        refs:
          SAMPLE_KEY: sample
        """
        let parsedGrant = DeepSeekAccountUsageService.parseCredentialsGrant(yaml: sampleCredYAML)
        precondition(parsedGrant?.token == "test_dsh_grant_token_123456")
        precondition(parsedGrant?.issuerOrigin == "https://platform.deepseek.com")

        let sampleSummaryJSON = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"USD","balance":"0E-16"},{"currency":"CNY","balance":"2.7088218400000000"}],"bonus_wallets":[{"currency":"USD","balance":"0"},{"currency":"CNY","balance":"5.00"}],"total_costs":[{"currency":"USD","amount":"0E-16"},{"currency":"CNY","amount":"7.3964567200000000"}]}}}
        """.data(using: .utf8)!
        let parsedSnap = DeepSeekAccountUsageService.parseUserSummaryResponse(
            data: sampleSummaryJSON,
            statusCode: 200
        )
        precondition(parsedSnap.status == .ready)
        precondition(parsedSnap.primaryFormattedBalance == "¥7.70")
        let sampleReading = parsedSnap.toBalanceReading(source: .deepSeekHarnessPreset)
        precondition(sampleReading.formattedValue == "¥7.70")
        precondition(sampleReading.footnote.contains("含赠金 ¥5.00") && sampleReading.footnote.contains("已用 ¥7.39"))
        precondition(!sampleReading.isLow && !sampleReading.needsLogin)

        let expiredJSON = #"{"code":40003,"msg":"token expired"}"#.data(using: .utf8)!
        let expiredSnap = DeepSeekAccountUsageService.parseUserSummaryResponse(data: expiredJSON, statusCode: 200)
        precondition(expiredSnap.status == .expired)
        precondition(expiredSnap.toBalanceReading(source: .deepSeekHarnessPreset).needsLogin == true)
        precondition(DeepSeekAccountUsageService.formatBalance(Decimal(string: "0.004")!, symbol: "¥") == "<¥0.01")
        precondition(DeepSeekAccountUsageService.formatBalance(Decimal(string: "1234.569")!, symbol: "¥") == "¥1,234.56")

        // Unit tests: forked Codex baseline subtraction + cross-day todayUsage + pricing catalog matching
        let dayCutoff = Calendar.current.startOfDay(for: now)
        let forkedSession = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"\(isoNow.string(from: now.addingTimeInterval(-30)))","type":"session_meta","payload":{"id":"fork-1","forked_from_id":"parent-1","attached_thread":true,"cwd":"/tmp/p","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"\(isoNow.string(from: now.addingTimeInterval(-25)))","type":"turn_context","payload":{"model":"gateway/glm-53:latest"}}
            {"timestamp":"\(isoNow.string(from: now.addingTimeInterval(-20)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":69154423,"cached_input_tokens":66079403,"cache_write_input_tokens":0,"output_tokens":566724,"reasoning_output_tokens":100,"total_tokens":69721147},"last_token_usage":{"input_tokens":173803,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":198,"reasoning_output_tokens":100,"total_tokens":174001}}}}
            """,
            filePath: "/tmp/rollout-fork-1.jsonl",
            fileModificationDate: now,
            host: .local,
            dayCutoff: dayCutoff
        )!
        precondition(forkedSession.usage.totalTokens == 174_001)
        precondition(forkedSession.effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens == 174_001)
        precondition(PricingCatalog.rule(for: "claude-opus-5-5", customRules: PricingCatalog.defaults)?.inputPerMillionUSD == 4.0)
        precondition(PricingCatalog.rule(for: "openai/gpt-5.3-codex", customRules: PricingCatalog.defaults)?.inputPerMillionUSD == 1.75)
        precondition(PricingCatalog.rule(for: "gateway/glm-53:latest", customRules: PricingCatalog.defaults)?.inputPerMillionUSD == 1.2)

        // Unit tests: active (<1800s) file caching + dynamic seen/status materialization without file mtime change
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }
        let tmpClaudeDir = tmpHome.appendingPathComponent(".claude/projects/-tmp-proj", isDirectory: true)
        let tmpSubDir = tmpClaudeDir.appendingPathComponent("c-parent-1/subagents", isDirectory: true)
        let tmpCodexDir = tmpHome.appendingPathComponent(".codex/sessions/2026/11/21", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpSubDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: tmpCodexDir, withIntermediateDirectories: true)

        let tsRecent = isoNow.string(from: now.addingTimeInterval(-12))
        let parentJSONL = """
        {"type":"user","sessionId":"c-parent-1","cwd":"/tmp/proj","timestamp":"\(tsRecent)","message":{"role":"user","content":"Check CPU optimization"}}
        {"type":"assistant","sessionId":"c-parent-1","cwd":"/tmp/proj","timestamp":"\(tsRecent)","message":{"id":"m-p1","role":"assistant","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"Optimization complete!"}],"usage":{"input_tokens":120,"output_tokens":45,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}
        """
        let cacheSubJSONL = """
        {"type":"assistant","sessionId":"c-sub-1","cwd":"/tmp/proj","timestamp":"\(tsRecent)","message":{"id":"m-s1","role":"assistant","model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"Subagent done"}],"usage":{"input_tokens":30,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
        let codexActiveJSONL = """
        {"timestamp":"\(tsRecent)","type":"session_meta","payload":{"id":"cx-active-1","cwd":"/tmp/proj","originator":"codex_cli_rs","source":"cli"}}
        {"timestamp":"\(tsRecent)","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}
        {"timestamp":"\(tsRecent)","type":"event_msg","payload":{"type":"user_message","message":"Benchmark warm cache"}}
        {"timestamp":"\(tsRecent)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":200,"output_tokens":80,"total_tokens":580}},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300}}}}
        {"timestamp":"\(tsRecent)","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Warm cache hit verified"}}
        """
        try! Data(parentJSONL.utf8).write(to: tmpClaudeDir.appendingPathComponent("c-parent-1.jsonl"))
        try! Data(cacheSubJSONL.utf8).write(to: tmpSubDir.appendingPathComponent("agent-s1.jsonl"))
        try! Data(codexActiveJSONL.utf8).write(to: tmpCodexDir.appendingPathComponent("rollout-cx-active-1.jsonl"))

        let coldClaude = await ClaudeCodeAdapter.loadLocalSessions(homeDirectory: tmpHome.path, lookbackHours: 24, seenAtByID: [:])
        let coldCodex = await CodexAdapter.loadLocalSessions(homeDirectory: tmpHome.path, lookbackHours: 24, seenAtByID: [:])
        precondition(coldClaude.count == 1 && coldClaude[0].usage.totalTokens == 705) // 665 parent + 40 subagent
        precondition(coldClaude[0].status == .completed && !coldClaude[0].isSeen)
        precondition(coldCodex.count == 1 && coldCodex[0].status == .completed && !coldCodex[0].isSeen)

        // Warm poll with updated seenAtByID must transition both to seen/waitingForInput without mtime change
        let futureSeenTS = now.addingTimeInterval(60).timeIntervalSince1970
        let cacheSeenMap: [String: TimeInterval] = [
            coldClaude[0].id: futureSeenTS,
            coldCodex[0].id: futureSeenTS
        ]
        let warmClaude = await ClaudeCodeAdapter.loadLocalSessions(homeDirectory: tmpHome.path, lookbackHours: 24, seenAtByID: cacheSeenMap)
        let warmCodex = await CodexAdapter.loadLocalSessions(homeDirectory: tmpHome.path, lookbackHours: 24, seenAtByID: cacheSeenMap)
        precondition(warmClaude.count == 1 && warmClaude[0].isSeen && warmClaude[0].status == .waitingForInput)
        precondition(warmClaude[0].usage.totalTokens == 705)
        precondition(warmCodex.count == 1 && warmCodex[0].isSeen && warmCodex[0].status == .waitingForInput)
        let tmpSubs = SubscriptionAndStatsService.detectLocalSubscriptions(homeDirectory: tmpHome.path, sessions: warmCodex)
        precondition(tmpSubs.first(where: { $0.id == "sub:codex" })?.quotas.first?.usedPercent == 12.5)

        // Unit tests: PR #8 cross-file Claude fork deduplication (both cold & warm cache), Codex cache_write disambiguation,
        // inherited fork snapshot with zeroed last_token_usage, and >272k Astra tiered pricing
        let forkHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-fork-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: forkHome) }
        let forkProject = forkHome.appendingPathComponent(".claude/projects/project", isDirectory: true)
        try! FileManager.default.createDirectory(at: forkProject, withIntermediateDirectories: true)
        let forkToday = isoNow.string(from: now)
        let forkYesterday = isoNow.string(from: dayCutoff.addingTimeInterval(-60))
        let forkHistory = """
        {"type":"user","uuid":"prompt1","entrypoint":"claude-desktop-3p","sessionId":"parent","timestamp":"\(forkYesterday)","message":{"content":"first"}}
        {"type":"assistant","sessionId":"parent","timestamp":"\(forkToday)","message":{"id":"reply1","model":"model-a","usage":{"cache_read_input_tokens":100}}}
        """
        let forkChild = """
        {"type":"user","uuid":"prompt2","entrypoint":"claude-desktop-3p","sessionId":"child","timestamp":"\(forkToday)","message":{"content":"next"}}
        {"type":"assistant","sessionId":"child","timestamp":"\(forkToday)","message":{"id":"reply2","model":"model-b","usage":{"output_tokens":7}}}
        """
        try! Data(forkHistory.utf8).write(to: forkProject.appendingPathComponent("parent.jsonl"))
        try! Data((forkHistory + "\n" + forkChild).utf8).write(to: forkProject.appendingPathComponent("child.jsonl"))
        for pass in 0..<2 {
            let forkRows = await ClaudeCodeAdapter.loadLocalSessions(homeDirectory: forkHome.path)
            let forkRow = forkRows.first { $0.rawSessionID == "child" }!
            precondition(forkRow.todayUsage == TokenUsage(output: 7), "Fork pass \(pass) failed todayUsage")
            precondition(forkRow.todayModelUsages?["model-a"] == nil, "Fork pass \(pass) leaked parent model")
            precondition(forkRow.kind == .claudeDesktop, "Fork pass \(pass) kind mismatch")
            let forkStats = SubscriptionAndStatsService.buildAnalytics(sessions: forkRows)
            precondition(forkStats.todayUsage.totalTokens == 107 && forkStats.allTurnCount == 2 && forkStats.todayTurnCount == 1)
        }

        for reported in [30_167, 54_503] {
            let cwRow = CodexAdapter.parseRollout(
                jsonl: """
                {"type":"session_meta","payload":{"id":"example","cwd":"/tmp"}}
                {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":29052,"cached_input_tokens":4714,"cache_write_input_tokens":24336,"output_tokens":1115,"total_tokens":\(reported)}}}}
                """,
                filePath: nil,
                fileModificationDate: now,
                host: .local
            )!
            precondition(cwRow.usage.totalTokens == reported && cwRow.usage.cacheWrite == 24_336)
        }

        let zeroLastCutoff = ClaudeCodeAdapter.parseISODate("2026-11-21T00:00:00Z")!
        let zeroLastSession = CodexAdapter.parseRollout(
            jsonl: """
            {"type":"session_meta","payload":{"id":"child","forked_from_id":"parent","cwd":"/tmp"}}
            {"timestamp":"2026-11-20T09:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":800,"cached_input_tokens":700,"output_tokens":300},"last_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":13}}}}
            {"timestamp":"2026-11-21T09:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":820,"cached_input_tokens":712,"output_tokens":304}}}}
            """,
            filePath: nil,
            fileModificationDate: zeroLastCutoff,
            host: .local,
            dayCutoff: zeroLastCutoff
        )!
        precondition(zeroLastSession.usage == TokenUsage(input: 8, output: 4, cacheRead: 12))
        precondition(zeroLastSession.todayUsage == zeroLastSession.usage)
        precondition(zeroLastSession.turnCount == 2 && zeroLastSession.todayTurnCount == 1)

        let astraCatalog = #"{"openai":{"models":{"gpt-6.2-astra":{"cost":{"input":8,"output":40,"cache_read":0.4,"cache_write":10,"context_over_200k":{"input":999},"tiers":[{"tier":{"type":"context","size":272000},"input":16,"output":60,"cache_read":0.8,"cache_write":20}]}}}}}"#
        let astraRules = PricingCatalogSyncService.parseModelsDevJSON(Data(astraCatalog.utf8))
        let astraCutoff = ClaudeCodeAdapter.parseISODate("2026-11-22T00:00:00Z")!
        func astraEvent(_ time: String, _ cumulative: [Int], _ last: [Int]?) -> String {
            func usageJSON(_ counts: [Int]) -> String {
                "{\"input_tokens\":\(counts[0]),\"cached_input_tokens\":\(counts[1]),\"output_tokens\":\(counts[2])}"
            }
            let detail = last.map { ",\"last_token_usage\":" + usageJSON($0) } ?? ""
            return "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(usageJSON(cumulative))\(detail)}}}"
        }
        let astraLarge = astraEvent("2026-11-22T01:00:00Z", [564_824, 1_000, 208], [292_824, 0, 204])
        let astraLines = [
            #"{"type":"session_meta","payload":{"id":"thread","cwd":"/tmp"}}"#,
            #"{"type":"turn_context","payload":{"model":"byr/gpt-6.2-astra"}}"#,
            astraEvent("2026-11-21T23:59:00Z", [272_000, 1_000, 4], [272_000, 1_000, 4]),
            astraLarge,
            astraLarge,
            astraEvent("2026-11-22T01:00:00Z", [869_085, 299_624, 503], [304_261, 298_624, 295]),
            astraEvent("2026-11-22T01:00:00Z", [1_169_085, 299_624, 503], nil)
        ]
        let astraRow = CodexAdapter.parseRollout(
            jsonl: astraLines.joined(separator: "\n"),
            filePath: "/tmp/first",
            fileModificationDate: astraCutoff,
            host: .local,
            dayCutoff: astraCutoff
        )!
        let expectedYesterday = (271_000 * 8.0 + 1_000 * 0.4 + 4 * 40.0) / 1e6
        let expectedToday = 4.697424 + 0.3467912 + 2.4
        precondition(abs(PricingCatalog.estimatedCostUSD(for: astraRow, rules: astraRules)! - (expectedYesterday + expectedToday)) < 0.000001)
        precondition(abs(PricingCatalog.estimatedTodayCostUSD(for: astraRow, dayCutoff: astraCutoff, rules: astraRules)! - expectedToday) < 0.000001)
        let freeAstra = ModelPriceRule(modelPrefix: "byr/gpt-6.2-astra", inputPerMillionUSD: 0, outputPerMillionUSD: 0, cacheReadPerMillionUSD: 0, cacheWritePerMillionUSD: 0, defaultContextWindow: 1_000_000)
        precondition(PricingCatalog.estimatedTodayCostUSD(for: astraRow, rules: [freeAstra]) == 0)

        // Unit tests: Codex awaitingApproval (escalated exec, request_permissions, request_user_input, granular policy)
        // and Guardian auto-review subagent isolation
        let recentTS = isoNow.string(from: now.addingTimeInterval(-6))
        let codexExecApproval = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"\(recentTS)","type":"session_meta","payload":{"id":"cx-appr-1","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"\(recentTS)","type":"turn_context","payload":{"model":"gpt-5.4","approval_policy":{"granular":{"sandbox_approval":true,"request_permissions":true}},"approvals_reviewer":"user"}}
            {"timestamp":"\(recentTS)","type":"event_msg","payload":{"type":"task_started"}}
            {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"message","role":"user","content":"拉取线上日志"}}
            {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"curl -fsSL https://example.com\\",\\"justification\\":\\"需要外网权限\\",\\"sandbox_permissions\\":\\"require_escalated\\"}","call_id":"call_esc_1"}}
            """,
            filePath: "/tmp/rollout-cx-appr-1.jsonl",
            fileModificationDate: now,
            host: .local
        )!
        precondition(codexExecApproval.status == .awaitingApproval, "Escalated exec_command should enter .awaitingApproval")
        precondition(codexExecApproval.pendingApproval?.toolName == "exec_command")
        precondition(codexExecApproval.pendingApproval?.commandOrSummary.contains("需要外网权限") == true)

        // When approvals_reviewer == "auto_review", Guardian handles sandbox_permissions automatically -> NOT awaitingApproval
        let codexAutoReviewExec = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"\(recentTS)","type":"session_meta","payload":{"id":"cx-appr-auto","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"\(recentTS)","type":"turn_context","payload":{"model":"gpt-5.4","approval_policy":"on-request","approvals_reviewer":"auto_review"}}
            {"timestamp":"\(recentTS)","type":"event_msg","payload":{"type":"task_started"}}
            {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"message","role":"user","content":"自动审查模式"}}
            {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ls\\",\\"sandbox_permissions\\":\\"require_escalated\\"}","call_id":"call_esc_2"}}
            """,
            filePath: "/tmp/rollout-cx-appr-auto.jsonl",
            fileModificationDate: now,
            host: .local
        )!
        precondition(codexAutoReviewExec.status == .runningTool, "auto_review must not surface escalated exec as user approval")

        // Structured request_user_input question enters .awaitingApproval and clears on function_call_output
        let codexQuestionBase = """
        {"timestamp":"\(recentTS)","type":"session_meta","payload":{"id":"cx-q-1","cwd":"/tmp/proj","originator":"codex_cli_rs","source":"cli"}}
        {"timestamp":"\(recentTS)","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"message","role":"user","content":"配置部署方案"}}
        {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"questions\\":[{\\"header\\":\\"环境\\",\\"question\\":\\"部署到哪个集群？\\"}]}","call_id":"call_q_1"}}
        """
        let codexQuestionOpen = CodexAdapter.parseRollout(
            jsonl: codexQuestionBase,
            filePath: "/tmp/rollout-cx-q-1.jsonl",
            fileModificationDate: now,
            host: .local
        )!
        precondition(codexQuestionOpen.status == .awaitingApproval)
        precondition(codexQuestionOpen.overview.contains("环境：部署到哪个集群？"))
        let codexQuestionAnswered = CodexAdapter.parseRollout(
            jsonl: codexQuestionBase + "\n" + #"{"timestamp":"\#(recentTS)","type":"response_item","payload":{"type":"function_call_output","call_id":"call_q_1","output":"prod"}}"#,
            filePath: "/tmp/rollout-cx-q-1.jsonl",
            fileModificationDate: now,
            host: .local
        )!
        precondition(codexQuestionAnswered.status == .generating)

        // Guardian internal review rollout must roll up tokens into parent session without overriding parent model/status
        let guardianHome = fm.temporaryDirectory.appendingPathComponent("agentbar-guardian-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: guardianHome) }
        let guardianDay = guardianHome.appendingPathComponent(".codex/sessions/2026/11/23", isDirectory: true)
        try! fm.createDirectory(at: guardianDay, withIntermediateDirectories: true)
        let parentRollout = """
        {"timestamp":"\(recentTS)","type":"session_meta","payload":{"id":"parent-cx-1","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(recentTS)","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"\(recentTS)","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"message","role":"user","content":"主对话任务"}}
        {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"function_call","name":"request_permissions","arguments":"{\\"reason\\":\\"写入配置目录\\"}","call_id":"call_perm_1"}}
        {"timestamp":"\(recentTS)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100,"total_tokens":1100}}}}
        """
        let guardianRollout = """
        {"timestamp":"\(recentTS)","type":"session_meta","payload":{"id":"guardian-sub-1","session_id":"parent-cx-1","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(recentTS)","type":"turn_context","payload":{"model":"codex-auto-review"}}
        {"timestamp":"\(recentTS)","type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_trigger":"guardian_review"}}}
        {"timestamp":"\(recentTS)","type":"response_item","payload":{"type":"message","role":"assistant","content":"{\\"risk_score\\":10}"}}
        {"timestamp":"\(recentTS)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":50,"total_tokens":450}}}}
        {"timestamp":"\(recentTS)","type":"event_msg","payload":{"type":"task_complete"}}
        """
        try! Data(parentRollout.utf8).write(to: guardianDay.appendingPathComponent("rollout-parent-cx-1.jsonl"))
        try! Data(guardianRollout.utf8).write(to: guardianDay.appendingPathComponent("rollout-guardian-sub-1.jsonl"))
        let loadedGuardianSessions = await CodexAdapter.loadLocalSessions(homeDirectory: guardianHome.path, lookbackHours: 24)
        precondition(loadedGuardianSessions.count == 1)
        precondition(loadedGuardianSessions[0].rawSessionID == "parent-cx-1")
        precondition(loadedGuardianSessions[0].model == "gpt-5.4", "Guardian rollout must not overwrite parent model")
        precondition(loadedGuardianSessions[0].status == .awaitingApproval, "Guardian completion must not overwrite parent awaitingApproval")
        precondition(loadedGuardianSessions[0].usage.totalTokens == 1550, "Guardian tokens must roll up into parent")

        // Unit tests: DeepSeek Harness multi-frame Zstd session.v4.jsonl.zstd approval/asked -> approval/decided & ask_user_question
        func zstdCompressFrame(_ string: String) -> Data {
            ZstdDecoder.encodeUncompressedFrame(Data(string.utf8))
        }

        // Verify RFC 8878 ZstdDecoder against real compressed ~/.dsh/sessions/*/*/session.v4.jsonl.zstd files if present
        let realDSHSessionsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh/sessions", isDirectory: true)
        if let wsDirs = try? fm.contentsOfDirectory(at: realDSHSessionsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var verifiedRealZstdCount = 0
            for ws in wsDirs {
                guard let sDirs = try? fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for sd in sDirs {
                    let zstdFile = sd.appendingPathComponent("session.v4.jsonl.zstd")
                    guard let raw = try? Data(contentsOf: zstdFile), !raw.isEmpty else { continue }
                    let decoded = ZstdDecoder.decodeConcatenatedFrames(raw, maxDecompressedBytes: 8 * 1024 * 1024)
                    precondition(!decoded.isEmpty, "ZstdDecoder failed to decode real DSH log: \(zstdFile.path)")
                    let text = String(decoding: decoded, as: UTF8.self)
                    precondition(text.contains("\"type\":\"session\""), "Decoded DSH log missing session header: \(zstdFile.path)")
                    verifiedRealZstdCount += 1
                }
            }
            if verifiedRealZstdCount > 0 {
                print("Verified RFC 8878 ZstdDecoder across \(verifiedRealZstdCount) real DSH .jsonl.zstd logs")
            }
        }

        let dshHome = fm.temporaryDirectory.appendingPathComponent("agentbar-dsh-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dshHome) }
        let dshSessionID = "019d96f0-1111-7222-8333-444455556666"
        let dshProjCacheDir = dshHome.appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true)
        let dshSessionDir = dshHome.appendingPathComponent(".dsh/sessions/-tmp-proj/\(dshSessionID)", isDirectory: true)
        try! fm.createDirectory(at: dshProjCacheDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: dshSessionDir, withIntermediateDirectories: true)

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dshProjJSON = """
        {"updatedAt":\(nowMs),"record":{"identity":{"createdAt":\(nowMs - 10_000),"cwd":"/tmp/proj"},"rows":{"title":{"val":"DSH 审批验证"},"workingDirectory":{"val":"/tmp/proj"},"turnOutline":{"val":{"turns":[{"prompt":"推送分支并确认发布","response":""}],"draft":"准备执行推送"}},"modelSelection":{"val":{"lastUsed":{"provider":"deepseek","model":"deepseek-reasoner"}}},"approvalState":{"val":{"policy":"ask","turnOpen":true}},"userQuestions":{"val":{"questions":{"active":[]}}},"tokenUsage":{"val":{"totals":{"uncachedInputTokens":2000,"outputTokens":150,"cacheReadTokens":1200,"cacheWriteTokens":0}}}}}}
        """
        try! Data(dshProjJSON.utf8).write(to: dshProjCacheDir.appendingPathComponent("\(dshSessionID).json"))

        let dshFrame1 = zstdCompressFrame("""
        {"type":"session/seed","seq":1,"time":"\(recentTS)","data":{"sessionId":"\(dshSessionID)","cwd":"/tmp/proj","title":"DSH 审批验证"}}
        {"type":"turn/start","seq":2,"time":"\(recentTS)","data":{}}
        {"type":"tool/call","seq":3,"time":"\(recentTS)","data":{"callId":"tc_bash_1","name":"bash","input":{"command":"git push --force origin main"}}}
        {"type":"approval/asked","seq":4,"time":"\(recentTS)","data":{"id":"appr_1","toolName":"bash","callId":"tc_bash_1","reason":"需要强制推送远端分支","subject":{"command":"git push --force origin main"}}}
        """ + "\n")
        let dshLogURL = dshSessionDir.appendingPathComponent("session.v4.jsonl.zstd")
        try! dshFrame1.write(to: dshLogURL)

        let dshPendingList = await DeepSeekHarnessAdapter.loadLocalSessions(homeDirectory: dshHome.path, lookbackHours: 24)
        precondition(dshPendingList.count == 1)
        precondition(dshPendingList[0].status == .awaitingApproval, "DSH approval/asked must set .awaitingApproval")
        precondition(dshPendingList[0].pendingApproval?.toolName == "bash")
        precondition(dshPendingList[0].pendingApproval?.highRiskMatchedRule == "git push --force", "High-risk git push --force rule should match")

        // Append second concatenated Zstd frame deciding approval + opening ask_user_question
        let dshFrame2 = zstdCompressFrame("""
        {"type":"approval/decided","seq":5,"time":"\(isoNow.string(from: now))","data":{"id":"appr_1","outcome":"allowed-once"}}
        {"type":"tool/result","seq":6,"time":"\(isoNow.string(from: now))","data":{"callId":"tc_bash_1","status":"ok"}}
        {"type":"tool/call","seq":7,"time":"\(isoNow.string(from: now))","data":{"callId":"tc_q_1","name":"ask_user_question","input":{"questions":[{"header":"发布确认","question":"是否同步创建 GitHub Release？"}]}}}
        """ + "\n")
        var combinedFrames = dshFrame1
        combinedFrames.append(dshFrame2)
        try! combinedFrames.write(to: dshLogURL)

        let dshQuestionList = await DeepSeekHarnessAdapter.loadLocalSessions(homeDirectory: dshHome.path, lookbackHours: 24)
        precondition(dshQuestionList[0].status == .awaitingApproval, "DSH open ask_user_question must set .awaitingApproval")
        precondition(dshQuestionList[0].pendingApproval?.toolName == "ask_user_question")
        precondition(dshQuestionList[0].overview.contains("发布确认：是否同步创建 GitHub Release？"))

        // Append third Zstd frame settling ask_user_question and ending turn
        let dshFrame3 = zstdCompressFrame("""
        {"type":"tool/result","seq":8,"time":"\(isoNow.string(from: now))","data":{"callId":"tc_q_1","status":"ok"}}
        {"type":"turn/end","seq":9,"time":"\(isoNow.string(from: now))","data":{}}
        """ + "\n")
        combinedFrames.append(dshFrame3)
        try! combinedFrames.write(to: dshLogURL)
        let dshProjDoneJSON = dshProjJSON.replacingOccurrences(of: "\"turnOpen\":true", with: "\"turnOpen\":false")
        try! Data(dshProjDoneJSON.utf8).write(to: dshProjCacheDir.appendingPathComponent("\(dshSessionID).json"))

        let dshSettledList = await DeepSeekHarnessAdapter.loadLocalSessions(homeDirectory: dshHome.path, lookbackHours: 24)
        precondition(dshSettledList[0].status != .awaitingApproval && dshSettledList[0].pendingApproval == nil, "DSH settled turn must clear awaitingApproval")

        // Unit tests: non-destructive Codex & Claude hook installation preserving existing 3rd-party hooks & TOML tables
        let hookTestHome = fm.temporaryDirectory.appendingPathComponent("agentbar-hook-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: hookTestHome) }
        let hookCodexDir = hookTestHome.appendingPathComponent(".codex", isDirectory: true)
        try! fm.createDirectory(at: hookCodexDir, withIntermediateDirectories: true)
        let existingHooksJSON = """
        {"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"/usr/local/bin/codeisland-bridge --source codex","timeout":86400}]}]}}
        """
        let existingConfigTOML = """
        model = "gpt-5.4"

        [projects."/tmp/proj"]
        trust_level = "trusted"
        """
        try! Data(existingHooksJSON.utf8).write(to: hookCodexDir.appendingPathComponent("hooks.json"))
        try! Data(existingConfigTOML.utf8).write(to: hookCodexDir.appendingPathComponent("config.toml"))
        precondition(!HookApprovalManager.isCodexHooksInstalled(homeDirectory: hookTestHome.path))
        _ = try! HookApprovalManager.installCodexHooks(hookExecutablePath: "/Applications/AgentBar.app/Contents/MacOS/agentbar-hook", homeDirectory: hookTestHome.path)
        precondition(HookApprovalManager.isCodexHooksInstalled(homeDirectory: hookTestHome.path))
        let mergedHooksObj = try! JSONSerialization.jsonObject(with: Data(contentsOf: hookCodexDir.appendingPathComponent("hooks.json"))) as! [String: Any]
        let permGroups = (mergedHooksObj["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]]
        precondition(permGroups.count == 2, "Must preserve existing index-0 hook group and append agentbar-hook at index 1")
        let firstCmd = ((permGroups[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
        precondition(firstCmd.contains("codeisland-bridge"), "Existing index-0 hook must remain at index 0 for trusted_hash stability")
        let updatedTOML = try! String(contentsOf: hookCodexDir.appendingPathComponent("config.toml"), encoding: .utf8)
        let hooksKeyRange = updatedTOML.range(of: "features.hooks = true")
        let projectsSectionRange = updatedTOML.range(of: "[projects.\"/tmp/proj\"]")
        precondition(hooksKeyRange != nil && projectsSectionRange != nil && hooksKeyRange!.lowerBound < projectsSectionRange!.lowerBound, "features.hooks = true must be placed at top-level before [projects] table")

        let scannedProcs = ProcessAndChatScanner.scanLocalAgentProcesses()
        precondition(scannedProcs.allSatisfy { $0.pid > 0 && !$0.command.isEmpty })

        let tCold0 = ContinuousClock.now
        let realClaude = await ClaudeCodeAdapter.loadLocalSessions(lookbackHours: 168)
        let realCodex = await CodexAdapter.loadLocalSessions(lookbackHours: 168)
        let realDSH = await DeepSeekHarnessAdapter.loadLocalSessions(lookbackHours: 168)
        let realCursor = await CursorTraeAdapter.loadLocalSessions(lookbackHours: 168)
        let coldSubs = SubscriptionAndStatsService.detectLocalSubscriptions(sessions: realClaude + realCodex + realDSH + realCursor)
        let coldElapsed = ContinuousClock.now - tCold0

        let tWarm0 = ContinuousClock.now
        let warmRealClaude = await ClaudeCodeAdapter.loadLocalSessions(lookbackHours: 168)
        let warmRealCodex = await CodexAdapter.loadLocalSessions(lookbackHours: 168)
        let warmRealDSH = await DeepSeekHarnessAdapter.loadLocalSessions(lookbackHours: 168)
        let warmRealCursor = await CursorTraeAdapter.loadLocalSessions(lookbackHours: 168)
        let warmProcs = ProcessAndChatScanner.scanLocalAgentProcesses()
        let warmSubs = SubscriptionAndStatsService.detectLocalSubscriptions(sessions: warmRealClaude + warmRealCodex + warmRealDSH + warmRealCursor)
        let warmElapsed = ContinuousClock.now - tWarm0

        precondition(warmRealClaude.count == realClaude.count && warmRealCodex.count == realCodex.count)
        precondition(warmSubs == coldSubs)
        let combinedReal = realClaude + realCodex + realDSH + realCursor
        precondition(Set(combinedReal.map(\.id)).count == combinedReal.count, "Duplicate session IDs detected!")
        let sshEntries = SSHProbeService.discoverSSHConfigEntries()
        print("PASS self-test | local sessions -> claude=\(realClaude.count), codex=\(realCodex.count), dsh=\(realDSH.count), cursor=\(realCursor.count), procs=\(warmProcs.count), ssh_hosts=\(sshEntries.count) | cold=\(coldElapsed), warm_full_poll=\(warmElapsed)")
        var allSessionsForMetrics = combinedReal
        if probeDSH {
            let snap = await DeepSeekAccountUsageService.fetchSnapshot()
            let reading = snap.toBalanceReading(source: .deepSeekHarnessPreset)
            print("DSH account probe -> status=\(snap.status), balance=\(reading.formattedValue), footnote=\(reading.footnote), usedFraction=\(String(describing: reading.usedFraction))")
        }
        if probeSSH {
            await withTaskGroup(of: (Int, SSHProbeResult).self) { group in
                for (idx, cfg) in sshEntries.enumerated() {
                    group.addTask {
                        let res = await SSHProbeService.probeHost(alias: cfg.alias, lookbackHours: 168)
                        return (idx, res)
                    }
                }
                for await (idx, res) in group {
                    allSessionsForMetrics.append(contentsOf: res.sessions)
                    let claudeCount = res.sessions.filter { $0.kind == .claudeCode }.count
                    let runningCount = res.sessions.filter { StatusCategoryFilter.running.matches($0) }.count
                    print("SSH host #\(idx): online=\(res.connection.isOnline), latency=\(res.connection.latencyMs ?? -1)ms, sessions=\(res.sessions.count) (claude=\(claudeCount), running=\(runningCount)), err=\(res.connection.errorMessage ?? "none")")
                    for s in res.sessions where s.kind == .claudeCode && s.process != nil {
                        print("  claude \(s.rawSessionID.prefix(8)) env=\(s.launchEnvironment) pid=\(s.process?.pid ?? 0) tmux=\(s.process?.tmuxTarget ?? "-") status=\(s.status)")
                    }
                }
            }
        }
        if printMetrics {
            let syncStatus = await PricingCatalogSyncService.syncNow()
            let localAnalytics = SubscriptionAndStatsService.buildAnalytics(sessions: combinedReal)
            let totalAnalytics = SubscriptionAndStatsService.buildAnalytics(sessions: allSessionsForMetrics)
            print(String(
                format: "METRICS [pricing=%@ active=%d synced=%d 304=%@] | local today=%@ [net=%@] ($%.2f, sessions=%d) | all(+SSH) today=%@ [net=%@] ($%.2f, sessions=%d) | window=%@ [net=%@] ($%.2f, sessions=%d)",
                syncStatus.source,
                syncStatus.activeModelCount,
                syncStatus.syncedModelCount,
                String(syncStatus.usedNotModified304),
                FormattingHelpers.compactTokens(localAnalytics.todayUsage.totalTokens),
                FormattingHelpers.compactTokens(localAnalytics.todayUsage.uncachedInputOutputTokens),
                localAnalytics.todayCostUSD,
                localAnalytics.todaySessionCount,
                FormattingHelpers.compactTokens(totalAnalytics.todayUsage.totalTokens),
                FormattingHelpers.compactTokens(totalAnalytics.todayUsage.uncachedInputOutputTokens),
                totalAnalytics.todayCostUSD,
                totalAnalytics.todaySessionCount,
                FormattingHelpers.compactTokens(totalAnalytics.allUsage.totalTokens),
                FormattingHelpers.compactTokens(totalAnalytics.allUsage.uncachedInputOutputTokens),
                totalAnalytics.allCostUSD,
                totalAnalytics.allSessionCount
            ))
        }
    }

    private static func installCleanupSignals(pendingPath: String, decisionPath: String) {
        gSignalPendingPath = strdup(pendingPath)
        gSignalDecisionPath = strdup(decisionPath)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = hookCleanupSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(sig, &action, nil)
        }
    }

    private static func handlePermission(json: [String: Any], defaultKind: AgentKind) {
        HookApprovalManager.ensureDirectories()
        let requestID = UUID().uuidString
        let sessionID = json["session_id"] as? String
        let cwd = json["cwd"] as? String
        let toolName = (json["tool_name"] as? String) ?? "Tool"
        let rawToolInput = json["tool_input"]
        let normalizedInput: Any?
        if let inputStr = rawToolInput as? String,
           let inputData = inputStr.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: inputData) {
            normalizedInput = parsed
        } else {
            normalizedInput = rawToolInput
        }
        let summary = ClaudeCodeAdapter.summarizeToolInput(name: toolName, input: normalizedInput)

        let pending = PendingApproval(
            requestID: requestID,
            sessionID: sessionID,
            agentKind: defaultKind,
            host: .local,
            toolName: toolName,
            commandOrSummary: summary,
            cwd: cwd,
            requestedAt: Date(),
            canRespondViaHook: true,
            highRiskMatchedRule: HookApprovalManager.matchedHighRiskRule(in: summary)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let pendingURL = HookApprovalManager.pendingDirectory.appendingPathComponent("\(requestID).json")
        let decisionURL = HookApprovalManager.decisionsDirectory.appendingPathComponent("\(requestID).json")
        installCleanupSignals(pendingPath: pendingURL.path, decisionPath: decisionURL.path)
        defer {
            try? FileManager.default.removeItem(at: pendingURL)
            try? FileManager.default.removeItem(at: decisionURL)
        }

        guard let data = try? encoder.encode(pending),
              (try? data.write(to: pendingURL, options: .atomic)) != nil else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let deadline = Date().addingTimeInterval(120)

        while Date() < deadline {
            if getppid() == 1 || !FileManager.default.fileExists(atPath: pendingURL.path) {
                return
            }
            if let decisionData = try? Data(contentsOf: decisionURL),
               let decision = try? decoder.decode(ApprovalDecisionPayload.self, from: decisionData) {
                switch decision.action {
                case .allow:
                    if let sessionID, !sessionID.isEmpty {
                        HookApprovalManager.markPermissionResolved(sessionID: sessionID)
                    }
                    let response: [String: Any] = [
                        "hookSpecificOutput": [
                            "hookEventName": "PermissionRequest",
                            "decision": [
                                "behavior": "allow"
                            ]
                        ]
                    ]
                    writeJSONStdout(response)
                case .deny:
                    if let sessionID, !sessionID.isEmpty {
                        HookApprovalManager.markPermissionResolved(sessionID: sessionID)
                    }
                    let response: [String: Any] = [
                        "hookSpecificOutput": [
                            "hookEventName": "PermissionRequest",
                            "decision": [
                                "behavior": "deny",
                                "message": decision.reason ?? "由 AgentBar 拒绝执行"
                            ]
                        ]
                    ]
                    writeJSONStdout(response)
                case .passthrough:
                    // Print nothing -> Claude Code / Codex falls back to native prompt
                    break
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func handleLifecycleEvent(tool: String, eventName: String, json: [String: Any]) {
        if let sid = json["session_id"] as? String, !sid.isEmpty {
            switch eventName {
            case "PostToolUse", "Stop", "Interrupt", "UserPromptSubmit", "SessionEnd":
                HookApprovalManager.clearPendingApprovals(forSessionID: sid)
                HookApprovalManager.markPermissionResolved(sessionID: sid)
            default:
                break
            }
        }
        recordEvent(tool: tool, eventName: eventName, json: json)
    }

    private static func recordEvent(tool: String, eventName: String, json: [String: Any]) {
        HookApprovalManager.ensureDirectories()
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "tool": tool,
            "event": eventName,
            "session": (json["session_id"] as? String) ?? "",
            "cwd": (json["cwd"] as? String) ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        let url = HookApprovalManager.eventsFileURL
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func writeJSONStdout(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
