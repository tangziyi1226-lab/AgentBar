import AppKit
import Foundation
import SQLite3

public enum AntigravityAdapter {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var summariesCache: [String: (dbStat: FastJSONL.FileStatKey, walStat: FastJSONL.FileStatKey?, sessions: [AgentSession])] = [:]

    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 96,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> [AgentSession] {
        let path = (homeDirectory as NSString)
            .appendingPathComponent(".gemini/antigravity/conversation_summaries.db")
        guard let dbStat = FastJSONL.statKey(atPath: path) else { return [] }
        let walStat = FastJSONL.statKey(atPath: path + "-wal")
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)

        let cachedSessions: [AgentSession]? = cacheLock.withLock {
            guard let hit = summariesCache[path], hit.dbStat == dbStat, hit.walStat == walStat else {
                return nil
            }
            return hit.sessions
        }
        let baseSessions: [AgentSession]
        if let cachedSessions {
            baseSessions = cachedSessions
        } else {
            var parsed = readSummaries(at: path, since: .distantPast, seenAtByID: [:])
            for index in parsed.indices {
                parsed[index].groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: parsed[index].cwd)
            }
            cacheLock.withLock {
                summariesCache[path] = (dbStat, walStat, parsed)
            }
            baseSessions = parsed
        }

        return baseSessions.compactMap { item in
            guard item.lastActivityAt >= cutoff else { return nil }
            var copy = item
            copy.isSeen = SeenSessionLookup.isSeen(
                sessionID: copy.id,
                lastActivityAt: copy.lastActivityAt,
                seenAtByID: seenAtByID
            )
            return copy
        }
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
        let matchedProc = processes.first { proc in
            let lower = proc.command.lowercased()
            return lower == "antigravity" || lower.hasSuffix("/antigravity.app/contents/macos/antigravity")
        }
        var runningApp: NSRunningApplication?
        for bundleID in kind.preferredBundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) {
                runningApp = app
                break
            }
        }
        guard runningApp != nil || matchedProc != nil else { return nil }
        let launchedAt = runningApp?.launchDate ?? Date()
        return AgentSession(
            id: "local:antigravity:desktop",
            rawSessionID: "desktop",
            kind: kind,
            title: kind.displayName,
            overview: "桌面应用运行中 · 暂无近期会话摘要",
            status: .runningProcessOnly,
            process: runningApp.flatMap { app in processes.first { $0.pid == app.processIdentifier } } ?? matchedProc,
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
