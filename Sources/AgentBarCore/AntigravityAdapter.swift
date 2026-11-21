import AppKit
import Foundation
import SQLite3

public enum AntigravityAdapter {
    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 96,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> [AgentSession] {
        let path = (homeDirectory as NSString)
            .appendingPathComponent(".gemini/antigravity/conversation_summaries.db")
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)
        var sessions = readSummaries(at: path, since: cutoff, seenAtByID: seenAtByID)
        for index in sessions.indices {
            sessions[index].groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: sessions[index].cwd)
        }
        return sessions
    }

    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 96,
        seenSessionIDs: Set<String>
    ) async -> [AgentSession] {
        let futureTS = Date().addingTimeInterval(60).timeIntervalSince1970
        let seenMap = Dictionary(uniqueKeysWithValues: seenSessionIDs.map { ($0, futureTS) })
        return await loadLocalSessions(homeDirectory: homeDirectory, lookbackHours: lookbackHours, seenAtByID: seenMap)
    }

    @MainActor
    public static func runningDesktopSession(processes: [ProcessStats]) -> AgentSession? {
        let kind = AgentKind.antigravity
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return kind.preferredBundleIdentifiers.contains(bundleID) && !$0.isTerminated
        }) else { return nil }

        let launchedAt = app.launchDate ?? Date()
        return AgentSession(
            id: "local:antigravity:desktop",
            rawSessionID: "desktop",
            kind: kind,
            title: kind.displayName,
            overview: "桌面应用运行中 · 暂无近期会话摘要",
            status: .runningProcessOnly,
            process: processes.first { $0.pid == app.processIdentifier },
            startedAt: launchedAt,
            lastActivityAt: launchedAt,
            isSeen: true
        )
    }

    private static func readSummaries(at path: String, since cutoff: Date, seenAtByID: [String: TimeInterval]) -> [AgentSession] {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard let db else { return [] }
        defer { sqlite3_close(db) }
        guard result == SQLITE_OK else { return [] }
        sqlite3_busy_timeout(db, 100)

        let sql = """
            SELECT conversation_id, title, preview, workspace_uris, unixepoch(last_modified_time)
            FROM conversation_summaries
            WHERE conversation_id <> '' AND unixepoch(last_modified_time) >= ?
            ORDER BY last_modified_time DESC
            LIMIT 100
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970.rounded(.down))

        var sessions: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rawID = columnText(statement, 0)
            let title = columnText(statement, 1)
            let preview = columnText(statement, 2)
            let cwd = workspacePath(from: columnText(statement, 3))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let id = "local:antigravity:\(rawID)"
            sessions.append(AgentSession(
                id: id,
                rawSessionID: rawID,
                kind: .antigravity,
                title: title.isEmpty ? "Antigravity 会话" : title,
                overview: preview.isEmpty ? "本地会话摘要" : preview,
                status: .idle,
                statusIsInferred: true,
                cwd: cwd,
                sourceFilePath: path,
                startedAt: updatedAt,
                lastActivityAt: updatedAt,
                isSeen: SeenSessionLookup.isSeen(
                    sessionID: id,
                    lastActivityAt: updatedAt,
                    seenAtByID: seenAtByID
                )
            ))
        }
        return sessions
    }

    private static func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func workspacePath(from value: String) -> String? {
        let uris = (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? [value]
        for uri in uris {
            if let url = URL(string: uri), url.isFileURL {
                return url.path
            }
        }
        return nil
    }
}
