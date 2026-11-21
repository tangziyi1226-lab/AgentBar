import AgentBarCore
import Foundation
import XCTest

final class ParserTests: XCTestCase {
    func testHighRiskMatcher() {
        XCTAssertEqual(HookApprovalManager.matchedHighRiskRule(in: "rm -rf .build && swift build"), "rm -rf")
        XCTAssertEqual(HookApprovalManager.matchedHighRiskRule(in: "git push --force origin main"), "git push --force")
        XCTAssertNil(HookApprovalManager.matchedHighRiskRule(in: "swift test"))
    }

    func testCodexMultiShardDeduplicationPreservesLatestStateAndCumulativeTokens() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agentbar-test-codex-\(UUID().uuidString)")
        let dayDir = tempHome.appendingPathComponent(".codex/sessions/2026/11/19")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let sharedID = "01a1f304-3559-7223-8f2a-f5fca907db41"
        let oldShardURL = dayDir.appendingPathComponent("rollout-2026-11-19T16-55-01-\(sharedID).jsonl")
        let newShardURL = dayDir.appendingPathComponent("rollout-2026-11-19T16-55-54-\(sharedID)_01a1f305-0289-79d0-8872-b9ec515f2fe4.jsonl")

        let now = Date()
        let oldDate = now.addingTimeInterval(-600)
        let newDate = now.addingTimeInterval(-30)
        let iso = ISO8601DateFormatter()

        let oldContent = """
        {"timestamp":"\(iso.string(from: oldDate))","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(2)))","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(3)))","type":"response_item","payload":{"type":"message","role":"user","content":"修复重复卡片显示问题"}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(15)))","type":"response_item","payload":{"type":"message","role":"assistant","content":"旧分片回复"}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(16)))","type":"event_msg","payload":{"type":"task_complete","duration_ms":1200}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(16)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":57143,"cached_input_tokens":30907,"cache_write_input_tokens":0,"output_tokens":639,"reasoning_output_tokens":0,"total_tokens":57782}}}}
        """

        let newContent = """
        {"timestamp":"\(iso.string(from: newDate))","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso.string(from: newDate.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(iso.string(from: newDate.addingTimeInterval(5)))","type":"response_item","payload":{"type":"function_call","call_id":"call_1","name":"exec_command","arguments":"{\\"cmd\\":\\"swift test\\"}"}}
        {"timestamp":"\(iso.string(from: newDate.addingTimeInterval(10)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":655414,"cached_input_tokens":587574,"cache_write_input_tokens":0,"output_tokens":5681,"reasoning_output_tokens":0,"total_tokens":661095}}}}
        """

        try Data(oldContent.utf8).write(to: oldShardURL)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldShardURL.path)
        try Data(newContent.utf8).write(to: newShardURL)
        try fm.setAttributes([.modificationDate: newDate], ofItemAtPath: newShardURL.path)

        let loaded = await CodexAdapter.loadLocalSessions(homeDirectory: tempHome.path, lookbackHours: 24)
        XCTAssertEqual(loaded.count, 1)

        let merged = try XCTUnwrap(loaded.first)
        XCTAssertEqual(merged.id, "local:codex:\(sharedID)")
        XCTAssertEqual(merged.title, "修复重复卡片显示问题")
        XCTAssertEqual(merged.status, .runningTool)
        XCTAssertEqual(merged.usage.totalTokens, 661_095)
        XCTAssertEqual(merged.turnCount, 2)

        // Idempotent second deduplication pass must not double-count turns or tokens.
        let idempotent = SessionDeduplicator.deduplicate([merged, merged])
        XCTAssertEqual(idempotent.count, 1)
        XCTAssertEqual(idempotent[0].usage.totalTokens, 661_095)
        XCTAssertEqual(idempotent[0].turnCount, 2)
    }

    func testClaudeSubagentFilteringAndDistinctIDs() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agentbar-test-claude-\(UUID().uuidString)")
        let projDir = tempHome.appendingPathComponent(".claude/projects/-tmp-demo")
        let parentID = "aaf3c0c8-c408-49a7-b1f8-a72548d312a0"
        let subDir = projDir.appendingPathComponent("\(parentID)/subagents")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date()
        let iso = ISO8601DateFormatter()
        let parentURL = projDir.appendingPathComponent("\(parentID).jsonl")
        let subURL = subDir.appendingPathComponent("agent-a68596dca9c3560a7.jsonl")

        let parentJSONL = """
        {"type":"user","sessionId":"\(parentID)","isSidechain":false,"cwd":"/tmp/demo","timestamp":"\(iso.string(from: now.addingTimeInterval(-120)))","message":{"role":"user","content":"主会话任务"}}
        {"type":"assistant","sessionId":"\(parentID)","isSidechain":false,"cwd":"/tmp/demo","timestamp":"\(iso.string(from: now.addingTimeInterval(-90)))","message":{"id":"m1","model":"claude-sonnet-4-5","stop_reason":"end_turn","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"主会话已完成"}]}}
        """

        let subJSONL = """
        {"type":"user","sessionId":"\(parentID)","agentId":"a68596dca9c3560a7","isSidechain":true,"cwd":"/tmp/demo","timestamp":"\(iso.string(from: now.addingTimeInterval(-60)))","message":{"role":"user","content":"子代理检索任务"}}
        {"type":"assistant","sessionId":"\(parentID)","agentId":"a68596dca9c3560a7","isSidechain":true,"cwd":"/tmp/demo","timestamp":"\(iso.string(from: now.addingTimeInterval(-30)))","message":{"id":"m2","model":"claude-haiku-4-5","stop_reason":"end_turn","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"子代理已完成"}]}}
        """

        try Data(parentJSONL.utf8).write(to: parentURL)
        try Data(subJSONL.utf8).write(to: subURL)

        let withoutSubagents = await ClaudeCodeAdapter.loadLocalSessions(
            homeDirectory: tempHome.path,
            lookbackHours: 24,
            includeSubagents: false
        )
        XCTAssertEqual(withoutSubagents.count, 1)
        XCTAssertEqual(withoutSubagents.first?.id, "local:claude:\(parentID)")
        // Even when subagent rows are hidden in UI, parent session rolls up subagent tokens (1200 + 600 = 1800).
        XCTAssertEqual(withoutSubagents.first?.usage.totalTokens, 1_800)
        XCTAssertEqual(withoutSubagents.first?.modelUsages?["claude-sonnet-4-5"]?.totalTokens, 1_200)
        XCTAssertEqual(withoutSubagents.first?.modelUsages?["claude-haiku-4-5"]?.totalTokens, 600)

        let withSubagents = await ClaudeCodeAdapter.loadLocalSessions(
            homeDirectory: tempHome.path,
            lookbackHours: 24,
            includeSubagents: true
        )
        XCTAssertEqual(withSubagents.count, 2)
        let ids = Set(withSubagents.map(\.id))
        XCTAssertEqual(ids, [
            "local:claude:\(parentID)",
            "local:claude:\(parentID):a68596dca9c3560a7"
        ])
        // Both keep parent rawSessionID so `claude --resume` remains valid.
        XCTAssertTrue(withSubagents.allSatisfy { $0.rawSessionID == parentID })
    }

    func testSSHProbeAndGroupingAnalyticsDeduplicateDuplicateIDs() {
        let now = Date()
        let tsOld = Int(now.addingTimeInterval(-300).timeIntervalSince1970)
        let tsNew = Int(now.addingTimeInterval(-20).timeIntervalSince1970)
        let sharedID = "01a1f1d9-833d-75b3-8ba5-91a164e6cd19"

        let probeStdout = """
        @@HOME /home/dev
        @@BEGIN codex \(tsNew) /home/dev/.codex/sessions/rollout-new-\(sharedID)_shard2.jsonl
        {"timestamp":"2026-11-19T09:05:00Z","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/home/dev/app","originator":"codex_cli_rs"}}
        {"timestamp":"2026-11-19T09:05:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"最新远程输出"}}
        {"timestamp":"2026-11-19T09:05:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20000,"cached_input_tokens":5000,"cache_write_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":21000}}}}
        @@END
        @@BEGIN codex \(tsOld) /home/dev/.codex/sessions/rollout-old-\(sharedID).jsonl
        {"timestamp":"2026-11-19T08:55:00Z","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/home/dev/app","originator":"codex_cli_rs"}}
        {"timestamp":"2026-11-19T08:55:01Z","type":"response_item","payload":{"type":"message","role":"user","content":"远程训练排查"}}
        {"timestamp":"2026-11-19T08:55:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8000,"cached_input_tokens":1000,"cache_write_input_tokens":0,"output_tokens":300,"reasoning_output_tokens":0,"total_tokens":8300}}}}
        @@END
        """

        let host = HostID.ssh(alias: "gpu-box")
        let parsed = SSHProbeService.parseProbeOutput(stdout: probeStdout, host: host, lookbackHours: 168)
        XCTAssertEqual(parsed.sessions.count, 1)
        XCTAssertEqual(parsed.sessions[0].title, "远程训练排查")
        XCTAssertEqual(parsed.sessions[0].overview, "最新远程输出")
        XCTAssertEqual(parsed.sessions[0].usage.totalTokens, 21_000)

        // Even if duplicate AgentSession entries are fed into grouping or analytics, they are deduplicated.
        let duplicatedInput = [parsed.sessions[0], parsed.sessions[0]]
        let groups = SessionGroupingBuilder.buildHostGroups(
            sessions: duplicatedInput,
            hostStates: [host: HostConnectionState(host: host, isOnline: true)],
            homeByHost: [host: "/home/dev"]
        )
        XCTAssertEqual(groups.first?.totalSessionCount, 1)

        let analytics = SubscriptionAndStatsService.buildAnalytics(sessions: duplicatedInput, demoMode: true)
        XCTAssertEqual(analytics.allSessionCount, 1)
        XCTAssertEqual(analytics.allUsage.totalTokens, 21_000)
        XCTAssertEqual(analytics.todayUsage.totalTokens, 21_000)
    }

    func testLargeTruncatedCodexRolloutPreservesRunningAndCompletedStatus() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agentbar-test-codex-large-\(UUID().uuidString)")
        let codexDir = tempHome.appendingPathComponent(".codex")
        let dayDir = codexDir.appendingPathComponent("sessions/2026/11/20")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let sessionID = "01a1f828-0000-7000-8000-000000000001"
        let rolloutURL = dayDir.appendingPathComponent("rollout-2026-11-20T16-52-31-\(sessionID).jsonl")
        let indexURL = codexDir.appendingPathComponent("session_index.jsonl")
        let globalStateURL = codexDir.appendingPathComponent(".codex-global-state.json")

        let indexLine = """
        {"id":"\(sessionID)","thread_name":"大型工程重构长任务"}
        """
        try Data(indexLine.utf8).write(to: indexURL)

        let globalStateJSON = """
        {"electron-thread-read-state-v1":{"unreadByIdentity":{"user":{"local":[]}}}}
        """
        try Data(globalStateJSON.utf8).write(to: globalStateURL)

        let now = Date()
        let startTS = now.addingTimeInterval(-3600)
        let recentTS = now.addingTimeInterval(-5)
        let iso = ISO8601DateFormatter()

        var lines: [String] = [
            #"{"timestamp":"\#(iso.string(from: startTS))","type":"session_meta","payload":{"id":"\#(sessionID)","session_id":"\#(sessionID)","cwd":"/tmp/refactor-proj","originator":"Codex Desktop","source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"\#(iso.string(from: startTS.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":996147}}"#
        ]

        let fillerChunk = String(repeating: "x", count: 28_000) + #" \"type\":\"task_complete\" "#
        for idx in 0..<100 {
            let callID = "call_fill_\(idx)"
            let stepTS = iso.string(from: startTS.addingTimeInterval(Double(idx + 2)))
            lines.append(#"{"timestamp":"\#(stepTS)","type":"response_item","payload":{"type":"function_call","status":"completed","name":"exec_command","arguments":"{\"cmd\":\"echo test\"}","call_id":"\#(callID)"}}"#)
            lines.append(#"{"timestamp":"\#(stepTS)","type":"response_item","payload":{"type":"function_call_output","call_id":"\#(callID)","output":"\#(fillerChunk)"}}"#)
        }

        lines.append(#"{"timestamp":"\#(iso.string(from: recentTS.addingTimeInterval(-2)))","type":"compacted","payload":{"window_number":4,"resume_metadata":{"previous_turn_settings":{"model":"gpt-5.4"}}}}"#)
        lines.append(#"{"timestamp":"\#(iso.string(from: recentTS.addingTimeInterval(-1)))","type":"response_item","payload":{"type":"function_call","status":"completed","name":"exec_command","arguments":"{\"cmd\":\"swift test\"}","call_id":"call_tail"}}"#)
        lines.append(#"{"timestamp":"\#(iso.string(from: recentTS))","type":"response_item","payload":{"type":"function_call_output","call_id":"call_tail","output":"Process exited with code 0"}}"#)
        lines.append(#"{"timestamp":"\#(iso.string(from: recentTS))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":36763978,"cached_input_tokens":34992247,"cache_write_input_tokens":0,"output_tokens":279532,"reasoning_output_tokens":0,"total_tokens":37043510},"last_token_usage":{"input_tokens":163811,"cached_input_tokens":159016,"output_tokens":101,"total_tokens":163912},"model_context_window":996147}}}"#)

        let activePayload = Data((lines.joined(separator: "\n") + "\n").utf8)
        XCTAssertGreaterThan(activePayload.count, 2_600_000)
        try activePayload.write(to: rolloutURL)
        try fm.setAttributes([.modificationDate: recentTS], ofItemAtPath: rolloutURL.path)

        let activeLoaded = await CodexAdapter.loadLocalSessions(homeDirectory: tempHome.path, lookbackHours: 24)
        let activeSession = try XCTUnwrap(activeLoaded.first)
        XCTAssertEqual(activeSession.status, .generating)
        XCTAssertEqual(activeSession.model, "gpt-5.4")
        XCTAssertEqual(activeSession.usage.totalTokens, 37_043_510)

        var finishedLines = lines
        finishedLines.append(#"{"timestamp":"\#(iso.string(from: now))","type":"response_item","payload":{"type":"message","role":"assistant","content":"重构已完成并通过全部测试。"}}"#)
        finishedLines.append(#"{"timestamp":"\#(iso.string(from: now))","type":"event_msg","payload":{"type":"task_complete","duration_ms":5000}}"#)
        try Data((finishedLines.joined(separator: "\n") + "\n").utf8).write(to: rolloutURL)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: rolloutURL.path)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: globalStateURL.path)

        let finishedLoaded = await CodexAdapter.loadLocalSessions(homeDirectory: tempHome.path, lookbackHours: 24)
        let finishedSession = try XCTUnwrap(finishedLoaded.first)
        XCTAssertEqual(finishedSession.status, .waitingForInput)
    }

    func testTruncatedSSHCodexSnippetInfersGeneratingWithoutTaskStarted() {
        let now = Date()
        let tsRecent = Int(now.addingTimeInterval(-8).timeIntervalSince1970)
        let iso = ISO8601DateFormatter()
        let sessionID = "01a1f828-0000-7000-8000-000000000002"

        let probeStdout = """
        @@HOME /home/dev
        @@BEGIN codex \(tsRecent) /home/dev/.codex/sessions/rollout-2026-11-20-\(sessionID).jsonl
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-1200)))","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/home/dev/repo","originator":"codex_cli_rs"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-1199)))","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-1198)))","type":"response_item","payload":{"type":"message","role":"user","content":"执行全量压测与重构"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-1100)))","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-10)))","type":"response_item","payload":{"type":"reasoning"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-8)))","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"pytest\\"}","call_id":"c_ssh"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-8)))","type":"response_item","payload":{"type":"function_call_output","call_id":"c_ssh","output":"passed"}}
        @@END
        """

        let parsed = SSHProbeService.parseProbeOutput(
            stdout: probeStdout,
            host: .ssh(alias: "gpu-box"),
            lookbackHours: 24
        )
        XCTAssertEqual(parsed.sessions.count, 1)
        XCTAssertEqual(parsed.sessions[0].status, .generating)
    }

    func testCodexForkedSideChatSubtractsInheritedParentBaseline() throws {
        let now = Date()
        let dayCutoff = Calendar.current.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        let sideID = "01a1f957-0000-7000-8000-000000000002"
        let parentID = "01a1f828-0000-7000-8000-000000000001"

        let jsonl = """
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-60)))","type":"session_meta","payload":{"id":"\(sideID)","forked_from_id":"\(parentID)","attached_thread":true,"cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-58)))","type":"turn_context","payload":{"model":"gateway/glm-53:latest"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-55)))","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-50)))","type":"response_item","payload":{"type":"message","role":"user","content":"一句话说一下问题出在哪？"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-30)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":69154423,"cached_input_tokens":66079403,"cache_write_input_tokens":0,"output_tokens":566724,"reasoning_output_tokens":100,"total_tokens":69721147},"last_token_usage":{"input_tokens":173803,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":198,"reasoning_output_tokens":100,"total_tokens":174001}}}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-10)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":69354423,"cached_input_tokens":66259403,"cache_write_input_tokens":0,"output_tokens":567724,"reasoning_output_tokens":200,"total_tokens":69922147},"last_token_usage":{"input_tokens":200000,"cached_input_tokens":180000,"cache_write_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":100,"total_tokens":201000}}}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-9)))","type":"event_msg","payload":{"type":"task_complete","duration_ms":2000}}
        """

        let session = try XCTUnwrap(CodexAdapter.parseRollout(
            jsonl: jsonl,
            filePath: "/tmp/rollout-side-\(sideID).jsonl",
            fileModificationDate: now,
            host: .local,
            dayCutoff: dayCutoff
        ))

        // Own usage must only include the 2 side-chat steps (174,001 + 201,000 = 375,001), NOT the 69.55M parent baseline.
        XCTAssertEqual(session.usage.totalTokens, 375_001)
        XCTAssertEqual(session.effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens, 375_001)
        XCTAssertEqual(session.usage.input, 193_803)
        XCTAssertEqual(session.usage.cacheRead, 180_000)
        XCTAssertEqual(session.usage.output, 1_198)
    }

    func testCrossDayAndMultiShardModelSwitchMetricsAndPricing() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agentbar-test-crossday-\(UUID().uuidString)")
        let dayDir = tempHome.appendingPathComponent(".codex/sessions/2026/11/20")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date()
        let dayCutoff = Calendar.current.startOfDay(for: now)
        let yesterday = dayCutoff.addingTimeInterval(-3600)
        let todayStep1 = dayCutoff.addingTimeInterval(60)
        let todayStep2 = dayCutoff.addingTimeInterval(120)
        let iso = ISO8601DateFormatter()

        let sharedID = "01a1f6ef-c1b3-7d32-a5ae-d946310120a1"
        let shard1URL = dayDir.appendingPathComponent("rollout-2026-11-19-\(sharedID).jsonl")
        let shard2URL = dayDir.appendingPathComponent("rollout-2026-11-20-\(sharedID)_shard2.jsonl")

        // Shard 1: 1,000,000 tokens yesterday + 500,000 tokens today on gpt-6.2-astra
        let shard1 = """
        {"timestamp":"\(iso.string(from: yesterday.addingTimeInterval(-60)))","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso.string(from: yesterday.addingTimeInterval(-50)))","type":"turn_context","payload":{"model":"proxy/gpt-6.2-astra"}}
        {"timestamp":"\(iso.string(from: yesterday))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900000,"cached_input_tokens":800000,"cache_write_input_tokens":0,"output_tokens":100000,"reasoning_output_tokens":0,"total_tokens":1000000},"last_token_usage":{"input_tokens":900000,"cached_input_tokens":800000,"cache_write_input_tokens":0,"output_tokens":100000,"reasoning_output_tokens":0,"total_tokens":1000000}}}}
        {"timestamp":"\(iso.string(from: todayStep1))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1350000,"cached_input_tokens":1200000,"cache_write_input_tokens":0,"output_tokens":150000,"reasoning_output_tokens":0,"total_tokens":1500000},"last_token_usage":{"input_tokens":450000,"cached_input_tokens":400000,"cache_write_input_tokens":0,"output_tokens":50000,"reasoning_output_tokens":0,"total_tokens":500000}}}}
        """

        // Shard 2: Resumes today from 1,500,000 baseline, switches model to gemini-4-carbon for 300,000 tokens
        let shard2 = """
        {"timestamp":"\(iso.string(from: todayStep2.addingTimeInterval(-10)))","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso.string(from: todayStep2.addingTimeInterval(-5)))","type":"turn_context","payload":{"model":"gateway/gemini-4-carbon:latest"}}
        {"timestamp":"\(iso.string(from: todayStep2))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1620000,"cached_input_tokens":1450000,"cache_write_input_tokens":0,"output_tokens":180000,"reasoning_output_tokens":0,"total_tokens":1800000},"last_token_usage":{"input_tokens":270000,"cached_input_tokens":250000,"cache_write_input_tokens":0,"output_tokens":30000,"reasoning_output_tokens":0,"total_tokens":300000}}}}
        """

        try Data(shard1.utf8).write(to: shard1URL)
        try fm.setAttributes([.modificationDate: todayStep1], ofItemAtPath: shard1URL.path)
        try Data(shard2.utf8).write(to: shard2URL)
        try fm.setAttributes([.modificationDate: todayStep2], ofItemAtPath: shard2URL.path)

        let loaded = await CodexAdapter.loadLocalSessions(homeDirectory: tempHome.path, lookbackHours: 48)
        XCTAssertEqual(loaded.count, 1)
        let merged = try XCTUnwrap(loaded.first)

        // Lifetime = 1.8M, Today = 500k (gpt-6.2-astra) + 300k (gemini-4-carbon) = 800k
        XCTAssertEqual(merged.usage.totalTokens, 1_800_000)
        XCTAssertEqual(merged.effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens, 800_000)

        // Repeated deduplication is idempotent
        let reDedup = SessionDeduplicator.deduplicate([merged, merged])
        XCTAssertEqual(reDedup[0].effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens, 800_000)

        // Per-model today cost:
        // gpt-6.2-astra ($8 / $40 / CR $0.4): 50k in ($0.40) + 50k out ($2.00) + 400k CR ($0.16) = $2.56
        // gemini-4-carbon ($2 / $10 / CR $0.1): 20k in ($0.04) + 30k out ($0.30) + 250k CR ($0.025) = $0.365
        // Total today cost = $2.925
        let todayCost = try XCTUnwrap(PricingCatalog.estimatedTodayCostUSD(
            for: merged,
            dayCutoff: dayCutoff,
            rules: PricingCatalog.defaults
        ))
        XCTAssertEqual(todayCost, 2.925, accuracy: 0.0001)
    }

    func testClaudeCrossDayAndPerMessageModelPricing() throws {
        let now = Date()
        let dayCutoff = Calendar.current.startOfDay(for: now)
        let yesterday = dayCutoff.addingTimeInterval(-7200)
        let today = dayCutoff.addingTimeInterval(300)
        let iso = ISO8601DateFormatter()

        let jsonl = """
        {"type":"user","sessionId":"c-1","cwd":"/tmp/p","timestamp":"\(iso.string(from: yesterday))","message":{"role":"user","content":"昨天的问题"}}
        {"type":"assistant","sessionId":"c-1","cwd":"/tmp/p","timestamp":"\(iso.string(from: yesterday.addingTimeInterval(10)))","message":{"id":"m_old","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":100000,"output_tokens":10000,"cache_read_input_tokens":900000,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"昨天的回答"}]}}
        {"type":"user","sessionId":"c-1","cwd":"/tmp/p","timestamp":"\(iso.string(from: today))","message":{"role":"user","content":"今天切小模型追问"}}
        {"type":"assistant","sessionId":"c-1","cwd":"/tmp/p","timestamp":"\(iso.string(from: today.addingTimeInterval(5)))","message":{"id":"m_today","model":"proxy/claude-haiku-5-5","stop_reason":"end_turn","usage":{"input_tokens":50000,"output_tokens":5000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"今天的回答"}]}}
        """

        let session = try XCTUnwrap(ClaudeCodeAdapter.parseTranscript(
            jsonl: jsonl,
            fallbackSessionID: "c-1",
            filePath: "/tmp/c-1.jsonl",
            fileModificationDate: today,
            host: .local,
            dayCutoff: dayCutoff
        ))

        XCTAssertEqual(session.usage.totalTokens, 1_165_000)
        XCTAssertEqual(session.effectiveTodayUsage(dayCutoff: dayCutoff).totalTokens, 155_000)

        // Today's message used claude-haiku-5-5 ($0.10 / $0.50 / CR $0.01):
        // 50k * 0.10 + 5k * 0.50 + 100k * 0.01 = $0.005 + $0.0025 + $0.001 = $0.0085
        let todayCost = try XCTUnwrap(PricingCatalog.estimatedTodayCostUSD(
            for: session,
            dayCutoff: dayCutoff,
            rules: PricingCatalog.defaults
        ))
        XCTAssertEqual(todayCost, 0.0085, accuracy: 0.00001)
    }

    func testPricingNormalizationLongestPrefixAndCatalogSyncParsing() throws {
        let rules = PricingCatalog.defaults
        XCTAssertEqual(PricingCatalog.rule(for: "us.anthropic.claude-opus-5.5-20260915:latest", customRules: rules)?.inputPerMillionUSD, 4.0)
        XCTAssertEqual(PricingCatalog.rule(for: "claude-opus-5-5", customRules: rules)?.cacheReadPerMillionUSD, 0.2)
        XCTAssertEqual(PricingCatalog.rule(for: "openai/gpt-5.3-codex", customRules: rules)?.inputPerMillionUSD, 1.75)
        XCTAssertEqual(PricingCatalog.rule(for: "gpt-5-mini-2025-08-07", customRules: rules)?.inputPerMillionUSD, 0.25)
        XCTAssertEqual(PricingCatalog.rule(for: "gateway/glm-53:latest", customRules: rules)?.inputPerMillionUSD, 1.2)
        XCTAssertEqual(PricingCatalog.rule(for: "gateway/gemini-4-carbon:latest", customRules: rules)?.defaultContextWindow, 1_048_576)
        XCTAssertEqual(PricingCatalog.rule(for: "router-981469.anthropic.claude-opus-5-5[1m]", customRules: rules)?.inputPerMillionUSD, 4.0)
        XCTAssertEqual(PricingCatalog.rule(for: "proxy/claude-opus-5-5:1m", customRules: rules)?.inputPerMillionUSD, 4.0)
        XCTAssertEqual(PricingCatalog.rule(for: "gateway-pool/claude-sonnet-5-5 @ gateway.example.com", customRules: rules)?.inputPerMillionUSD, 2.0)
        XCTAssertEqual(PricingCatalog.rule(for: "aws:anthropic.claude-opus-5-5", customRules: rules)?.inputPerMillionUSD, 4.0)

        let sampleModelsDev = """
        {
          "anthropic": {
            "models": {
              "claude-opus-5-5": {
                "cost": { "input": 4.0, "output": 20.0, "cache_read": 0.2, "cache_write": 5.0 },
                "limit": { "context": 1000000 }
              }
            }
          },
          "zai-coding-plan": {
            "models": {
              "glm-5.3": {
                "cost": { "input": 0, "output": 0 },
                "limit": { "context": 200000 }
              }
            }
          }
        }
        """.data(using: .utf8)!

        let parsed = PricingCatalogSyncService.parseModelsDevJSON(sampleModelsDev)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.modelPrefix, "claude-opus-5-5")
        XCTAssertEqual(parsed.first?.defaultContextWindow, 1_000_000)
    }

    func testArchivedCodexSubagentRollupAndLargeMultiModelAttribution() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agentbar-test-arch-sub-\(UUID().uuidString)")
        let dayDir = tempHome.appendingPathComponent(".codex/sessions/2026/11/20")
        let archivedDir = tempHome.appendingPathComponent(".codex/archived_sessions")
        let claudeDesktopDir = tempHome.appendingPathComponent(
            "Library/Application Support/Claude-3p/local-agent-mode-sessions/u1/0000/s1/.claude/projects/session"
        )
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: claudeDesktopDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date()
        let dayCutoff = Calendar.current.startOfDay(for: now)
        let iso = ISO8601DateFormatter()

        // 1. Large (>2.5 MB) Codex parent rollout switching from gemini-4-carbon to gpt-6.2-astra
        let parentID = "01a1e735-0000-7000-8000-000000000010"
        var lines: [String] = [
            #"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-600)))","type":"session_meta","payload":{"id":"\#(parentID)","cwd":"/tmp/p","originator":"Codex Desktop","source":"vscode"}}"#,
            #"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-599)))","type":"turn_context","payload":{"model":"gateway/gemini-4-carbon:latest"}}"#,
            #"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-595)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":900000,"output_tokens":100000,"total_tokens":1100000},"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":900000,"output_tokens":100000,"total_tokens":1100000}}}}"#
        ]
        let filler = String(repeating: "z", count: 28_000)
        for i in 0..<95 {
            lines.append(#"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-500 + Double(i))))","type":"response_item","payload":{"type":"function_call_output","call_id":"c_\#(i)","output":"\#(filler)"}}"#)
        }
        lines.append(#"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-30)))","type":"turn_context","payload":{"model":"proxy/gpt-6.2-astra"}}"#)
        lines.append(#"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-20)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200000,"cached_input_tokens":1000000,"output_tokens":150000,"total_tokens":1350000},"last_token_usage":{"input_tokens":200000,"cached_input_tokens":100000,"output_tokens":50000,"total_tokens":250000}}}}"#)
        lines.append(#"{"timestamp":"\#(iso.string(from: now.addingTimeInterval(-19)))","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}"#)

        let parentURL = dayDir.appendingPathComponent("rollout-2026-11-20-\(parentID).jsonl")
        let payloadData = Data((lines.joined(separator: "\n") + "\n").utf8)
        XCTAssertGreaterThan(payloadData.count, 2_600_000)
        try payloadData.write(to: parentURL)

        // 2. Codex subagent spawned from parentID (adds 100k tokens on glm-53)
        let subID = "01a1e735-0000-7000-8000-000000000011"
        let subJSONL = """
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-15)))","type":"session_meta","payload":{"id":"\(subID)","session_id":"\(parentID)","parent_thread_id":"\(parentID)","forked_from_id":"\(parentID)","thread_source":"subagent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(parentID)"}}},"cwd":"/tmp/p","originator":"Codex Desktop"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-14)))","type":"turn_context","payload":{"model":"gateway/glm-53:latest"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-10)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1280000,"cached_input_tokens":1000000,"output_tokens":170000,"total_tokens":1450000},"last_token_usage":{"input_tokens":80000,"cached_input_tokens":0,"output_tokens":20000,"total_tokens":100000}}}}
        """
        try Data(subJSONL.utf8).write(to: dayDir.appendingPathComponent("rollout-2026-11-20-\(subID).jsonl"))

        // 3. Archived Codex session
        let archID = "01a1f8f9-0000-7000-8000-000000000012"
        let archJSONL = """
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-100)))","type":"session_meta","payload":{"id":"\(archID)","cwd":"/tmp/p","originator":"Codex Desktop"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-95)))","type":"response_item","payload":{"type":"message","role":"assistant","content":"已归档会话"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-90)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50000,"cached_input_tokens":0,"output_tokens":5000,"total_tokens":55000},"last_token_usage":{"input_tokens":50000,"cached_input_tokens":0,"output_tokens":5000,"total_tokens":55000}}}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-89)))","type":"event_msg","payload":{"type":"task_complete","duration_ms":500}}
        """
        try Data(archJSONL.utf8).write(to: archivedDir.appendingPathComponent("rollout-2026-11-20-\(archID).jsonl"))

        let codexSessions = await CodexAdapter.loadLocalSessions(
            homeDirectory: tempHome.path,
            lookbackHours: 24,
            includeSubagents: false
        )
        XCTAssertEqual(codexSessions.count, 2)
        let mainSession = try XCTUnwrap(codexSessions.first { $0.rawSessionID == parentID })
        let archSession = try XCTUnwrap(codexSessions.first { $0.rawSessionID == archID })
        XCTAssertTrue(archSession.isSeen)
        // 1,350,000 parent + 100,000 rolled-up subagent = 1,450,000
        XCTAssertEqual(mainSession.usage.totalTokens, 1_450_000)
        XCTAssertEqual(mainSession.modelUsages?["gateway/gemini-4-carbon:latest"]?.totalTokens, 1_100_000)
        XCTAssertEqual(mainSession.modelUsages?["proxy/gpt-6.2-astra"]?.totalTokens, 250_000)
        XCTAssertEqual(mainSession.modelUsages?["gateway/glm-53:latest"]?.totalTokens, 100_000)

        let mainCost = try XCTUnwrap(PricingCatalog.estimatedTodayCostUSD(
            for: mainSession,
            dayCutoff: dayCutoff,
            rules: PricingCatalog.defaults
        ))
        // carbon: 100k*2 + 100k*10 + 900k*0.1 = $0.20 + $1.00 + $0.09 = $1.29
        // astra:  100k*8 +  50k*40 + 100k*0.4 = $0.80 + $2.00 + $0.04 = $2.84
        // glm-53:  80k*1.20 + 20k*4.18        = $0.096 + $0.0836      = $0.1796
        XCTAssertEqual(mainCost, 4.3096, accuracy: 0.001)

        // 4. Claude Desktop local-agent-mode-sessions (.claude hidden path)
        let desktopSessionID = "b43e3172-cf1a-4ec7-a5a3-75671b254e80"
        let desktopJSONL = """
        {"type":"user","sessionId":"\(desktopSessionID)","cwd":"/private/var/empty","timestamp":"\(iso.string(from: now.addingTimeInterval(-40)))","message":{"role":"user","content":"自动化发版配置"}}
        {"type":"assistant","sessionId":"\(desktopSessionID)","cwd":"/private/var/empty","timestamp":"\(iso.string(from: now.addingTimeInterval(-35)))","message":{"id":"m_desk","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":10000,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"已完成"}]}}
        """
        try Data(desktopJSONL.utf8).write(to: claudeDesktopDir.appendingPathComponent("\(desktopSessionID).jsonl"))
        try Data("{}".utf8).write(to: claudeDesktopDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("audit.jsonl"))

        let claudeSessions = await ClaudeCodeAdapter.loadLocalSessions(homeDirectory: tempHome.path, lookbackHours: 24)
        XCTAssertEqual(claudeSessions.count, 1)
        XCTAssertEqual(claudeSessions.first?.rawSessionID, desktopSessionID)
        XCTAssertEqual(claudeSessions.first?.usage.totalTokens, 12_000)
    }
}
