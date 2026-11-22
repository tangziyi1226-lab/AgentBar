import AgentBarCore
import Foundation
import XCTest

final class AccountingTests: XCTestCase {
    func testAstraPricesVerifiedRequestsNotTheSessionTotal() throws {
        let catalog = #"{"openai":{"models":{"gpt-6.2-astra":{"cost":{"input":8,"output":40,"cache_read":0.4,"cache_write":10,"context_over_200k":{"input":999},"tiers":[{"tier":{"type":"context","size":272000},"input":16,"output":60,"cache_read":0.8,"cache_write":20}]}}}}}"#
        let rules = PricingCatalogSyncService.parseModelsDevJSON(Data(catalog.utf8))
        let model = "byr/gpt-6.2-astra"
        let cutoff = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-22T00:00:00Z"))
        func event(_ time: String, _ cumulative: [Int], _ last: [Int]?) -> String {
            func usage(_ counts: [Int]) -> String {
                "{\"input_tokens\":\(counts[0]),\"cached_input_tokens\":\(counts[1]),\"output_tokens\":\(counts[2])}"
            }
            let detail = last.map { ",\"last_token_usage\":" + usage($0) } ?? ""
            return "{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(usage(cumulative))\(detail)}}}"
        }
        let old = "2026-11-21T23:59:00Z", today = "2026-11-22T01:00:00Z"
        let large = event(today, [564824, 1000, 208], [292824, 0, 204])
        let lines = [#"{"type":"session_meta","payload":{"id":"thread","cwd":"/tmp"}}"#,
                     #"{"type":"turn_context","payload":{"model":"byr/gpt-6.2-astra"}}"#,
                     event(old, [272000, 1000, 4], [272000, 1000, 4]), large, large,
                     event(today, [869085, 299624, 503], [304261, 298624, 295]),
                     event(today, [1169085, 299624, 503], nil)]
        let row = try XCTUnwrap(CodexAdapter.parseRollout(jsonl: lines.joined(separator: "\n"), filePath: "/tmp/first", fileModificationDate: cutoff, host: .local, dayCutoff: cutoff))
        let baseYesterday = (271000 * 8.0 + 1000 * 0.4 + 4 * 40) / 1e6
        let todayCost = 4.697424 + 0.3467912 + 2.4
        func check(_ row: AgentSession, factor: Double = 1) throws {
            XCTAssertEqual(try XCTUnwrap(PricingCatalog.estimatedCostUSD(for: row, rules: rules)), (baseYesterday + todayCost) * factor, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(PricingCatalog.estimatedTodayCostUSD(for: row, dayCutoff: cutoff, rules: rules)), todayCost * factor, accuracy: 0.000001)
        }
        try check(row)
        try check(SessionDeduplicator.merge(row, row))
        var shard = row
        shard.sourceFilePath = "/tmp/second"
        try check(SessionDeduplicator.merge(row, shard), factor: 2)
        var parent = row
        parent.rollUpChildUsage(shard, dayCutoff: cutoff)
        try check(parent, factor: 2)
        let free = ModelPriceRule(modelPrefix: model, inputPerMillionUSD: 0, outputPerMillionUSD: 0, cacheReadPerMillionUSD: 0, cacheWritePerMillionUSD: 0, defaultContextWindow: 1000000)
        XCTAssertEqual(PricingCatalog.estimatedTodayCostUSD(for: row, rules: [free]), 0)
    }

    func testCodexCacheWriteBucketsMatchReportedTotal() throws {
        for reported in [30167, 54503] {
            let text = """
            {"type":"session_meta","payload":{"id":"example","cwd":"/tmp"}}
            {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":29052,"cached_input_tokens":4714,"cache_write_input_tokens":24336,"output_tokens":1115,"total_tokens":\(reported)}}}}
            """
            let row = try XCTUnwrap(CodexAdapter.parseRollout(jsonl: text, filePath: nil, fileModificationDate: Date(), host: .local))
            XCTAssertEqual(row.usage.totalTokens, reported)
            XCTAssertEqual(row.usage.cacheWrite, 24336)
        }
    }

    func testInheritedForkSnapshotWithZeroLastComponents() throws {
        let text = """
        {"type":"session_meta","payload":{"id":"child","forked_from_id":"parent","cwd":"/tmp"}}
        {"timestamp":"2026-11-20T09:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":800,"cached_input_tokens":700,"output_tokens":300},"last_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":13}}}}
        {"timestamp":"2026-11-21T09:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":820,"cached_input_tokens":712,"output_tokens":304}}}}
        """
        let cutoff = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z"))
        let session = try XCTUnwrap(CodexAdapter.parseRollout(jsonl: text, filePath: nil, fileModificationDate: cutoff, host: .local, dayCutoff: cutoff))
        XCTAssertEqual(session.usage, TokenUsage(input: 8, output: 4, cacheRead: 12))
        XCTAssertEqual(session.todayUsage, session.usage)
        XCTAssertEqual(session.turnCount, 2)
        XCTAssertEqual(session.todayTurnCount, 1)
    }

    func testClaudeForkCopiesDoNotCreateNewUsageOrTurns() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".claude/projects/project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let today = ISO8601DateFormatter().string(from: Date())
        let yesterday = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-60))
        let history = """
        {"type":"user","uuid":"prompt1","entrypoint":"claude-desktop-3p","sessionId":"parent","timestamp":"\(yesterday)","message":{"content":"first"}}
        {"type":"assistant","sessionId":"parent","timestamp":"\(today)","message":{"id":"reply1","model":"model-a","usage":{"cache_read_input_tokens":100}}}
        """
        let child = """
        {"type":"user","uuid":"prompt2","entrypoint":"claude-desktop-3p","sessionId":"child","timestamp":"\(today)","message":{"content":"next"}}
        {"type":"assistant","sessionId":"child","timestamp":"\(today)","message":{"id":"reply2","model":"model-b","usage":{"output_tokens":7}}}
        """
        try Data(history.utf8).write(to: project.appendingPathComponent("parent.jsonl"))
        try Data((history + "\n" + child).utf8).write(to: project.appendingPathComponent("child.jsonl"))
        let rows = await ClaudeCodeAdapter.loadLocalSessions(homeDirectory: home.path)
        let fork = try XCTUnwrap(rows.first { $0.rawSessionID == "child" })
        XCTAssertEqual(fork.todayUsage, TokenUsage(output: 7))
        XCTAssertNil(fork.todayModelUsages?["model-a"])
        XCTAssertEqual(fork.kind, .claudeDesktop)
        let stats = SubscriptionAndStatsService.buildAnalytics(sessions: rows)
        XCTAssertEqual(stats.todayUsage.totalTokens, 107)
        XCTAssertEqual(stats.allTurnCount, 2)
        XCTAssertEqual(stats.todayTurnCount, 1)
    }
}
