import Foundation
import SQLite3

/// The day's transcript, one row per utterance, in a local SQLite file.
/// WAL mode lets the MCP server read while the app writes.
actor TranscriptStore {
    struct SQLiteError: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { "Transcript database: \(description)" }
    }

    struct Day: Sendable {
        let date: Date
        let lineCount: Int
        let first: Date
        let last: Date
    }

    /// A stretch of speech with no long silence in it: a call, a meeting, a spell of work.
    struct Session: Sendable {
        let first: Date
        let last: Date
        let mine: Int
        let others: Int
        let words: Int
        let app: String?
    }

    /// How well search results match the query, best first.
    enum Match: Sendable {
        case allWords, wordStarts, someWords, phrase
    }

    private let db: OpaquePointer

    static func defaultURL() throws -> URL {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "RMD", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "rmd.sqlite")
    }

    /// `readOnly` is for readers such as the MCP server: no schema changes, no writes.
    init(url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(handle)
            throw SQLiteError(description: message)
        }
        // The app writes while the MCP server reads: wait out a short lock rather than fail.
        sqlite3_busy_timeout(handle, 5000)
        db = handle
        if !readOnly {
            try Self.exec(db, Self.schema)
        }
    }

    isolated deinit {
        sqlite3_close(db)
    }

    func insert(_ line: TranscriptLine) throws -> TranscriptLine {
        let sql = "INSERT INTO segments (started_at, ended_at, source, language, text, app) VALUES (?, ?, ?, ?, ?, ?)"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, line.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, line.end.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, line.source.rawValue, -1, sqliteTransient)
        if let language = line.language {
            sqlite3_bind_text(statement, 4, language, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_text(statement, 5, line.text, -1, sqliteTransient)
        if let app = line.app {
            sqlite3_bind_text(statement, 6, app, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }

        var saved = line
        saved.id = sqlite3_last_insert_rowid(db)
        return saved
    }

    /// Lines that started in `[from, to)`, oldest first.
    func lines(from: Date, to: Date, limit: Int) throws -> [TranscriptLine] {
        let sql = """
            SELECT \(Self.columns()) FROM segments
            WHERE started_at >= ? AND started_at < ? ORDER BY started_at LIMIT ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(clamping: limit))
        return try readLines(statement)
    }

    /// Lines from one source that overlap `[from, to]`, oldest first. No line is longer than about 25 s,
    /// so only lines that started in the minute before `from` can reach into the window.
    func lines(from source: TranscriptLine.Source, overlapping from: Date, to: Date) throws -> [TranscriptLine] {
        let sql = """
            SELECT \(Self.columns()) FROM segments
            WHERE source = ? AND started_at >= ? AND started_at < ? AND ended_at > ? ORDER BY started_at
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, source.rawValue, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, from.timeIntervalSince1970 - 60)
        sqlite3_bind_double(statement, 3, to.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, from.timeIntervalSince1970)
        return try readLines(statement)
    }

    func setText(_ text: String, of id: Int64) throws {
        let statement = try prepare("UPDATE segments SET text = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, text, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func delete(_ id: Int64) throws {
        let statement = try prepare("DELETE FROM segments WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    /// Full-text search, newest first. It widens only when the step before finds nothing: every word as
    /// written, then every word as the start of a word ("meet" finds "meetings"), then any of the words
    /// (best matches first), then the query as one piece of text, so odd spellings still hit.
    func search(_ query: String, since: Date, limit: Int) throws -> (lines: [TranscriptLine], match: Match) {
        let words = query.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !words.isEmpty else { return ([], .allWords) }

        var attempts: [(match: String, order: String, kind: Match)] = [
            (words.joined(separator: " "), "s.started_at DESC", .allWords),
            (words.map { $0 + "*" }.joined(separator: " "), "s.started_at DESC", .wordStarts),
        ]
        if words.count > 1 {
            attempts.append((words.joined(separator: " OR "), "segments_fts.rank", .someWords))
        }
        for attempt in attempts {
            let sql = """
                SELECT \(Self.columns(of: "s"))
                FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid
                WHERE segments_fts MATCH ? AND s.started_at >= ? ORDER BY \(attempt.order) LIMIT ?
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, attempt.match, -1, sqliteTransient)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(clamping: limit))
            // Some queries aren't valid full-text syntax; the plain text match below still handles them.
            let matches = (try? readLines(statement)) ?? []
            if !matches.isEmpty { return (matches, attempt.kind) }
        }

        let like = """
            SELECT \(Self.columns()) FROM segments
            WHERE text LIKE ? ESCAPE '\\' AND started_at >= ? ORDER BY started_at DESC LIMIT ?
            """
        let statement = try prepare(like)
        defer { sqlite3_finalize(statement) }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        sqlite3_bind_text(statement, 1, "%\(escaped)%", -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(clamping: limit))
        return (try readLines(statement), .phrase)
    }

    /// Stretches of speech that began in `[from, to)`, split wherever nobody spoke for `gap` seconds.
    /// A stretch that runs past `to` (a call over midnight) is listed once, whole.
    func sessions(from: Date, to: Date, gap: TimeInterval) throws -> [Session] {
        let sql = """
            WITH ordered AS (
                SELECT *, lag(ended_at) OVER (ORDER BY started_at) AS previous_end FROM segments
                WHERE started_at >= ? - 43200 AND started_at < ? + 43200
            ), numbered AS (
                SELECT *, sum(previous_end IS NULL OR started_at - previous_end >= ?) OVER (ORDER BY started_at) AS session
                FROM ordered
            )
            SELECT min(started_at), max(ended_at), sum(source = 'me'), sum(source = 'others'),
                   sum(length(text) - length(replace(text, ' ', '')) + 1), max(app)
            FROM numbered GROUP BY session HAVING min(started_at) >= ? AND min(started_at) < ? ORDER BY session
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, gap)
        sqlite3_bind_double(statement, 4, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, to.timeIntervalSince1970)

        var sessions: [Session] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            sessions.append(Session(
                first: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                last: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                mine: Int(sqlite3_column_int(statement, 2)),
                others: Int(sqlite3_column_int(statement, 3)),
                words: Int(sqlite3_column_int(statement, 4)),
                app: sqlite3_column_text(statement, 5).map { String(cString: $0) }
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error() }
        return sessions
    }

    /// Days that have any transcript, newest first (days follow this Mac's time zone).
    func days(limit: Int) throws -> [Day] {
        let sql = """
            SELECT date(started_at, 'unixepoch', 'localtime') AS day, count(*), min(started_at), max(ended_at)
            FROM segments GROUP BY day ORDER BY day DESC LIMIT ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clamping: limit))

        var days: [Day] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let first = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            days.append(Day(
                date: Calendar.current.startOfDay(for: first),
                lineCount: Int(sqlite3_column_int(statement, 1)),
                first: first,
                last: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error() }
        return days
    }

    /// Column order read by `readLines`.
    private static func columns(of table: String? = nil) -> String {
        ["id", "started_at", "ended_at", "source", "language", "text", "app"]
            .map { column in table.map { "\($0).\(column)" } ?? column }
            .joined(separator: ", ")
    }

    /// Throws when the read stops for any reason but the end of the rows, so a locked or damaged
    /// database is never mistaken for "nothing was said".
    private func readLines(_ statement: OpaquePointer) throws -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            lines.append(TranscriptLine(
                id: sqlite3_column_int64(statement, 0),
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                source: TranscriptLine.Source(rawValue: String(cString: sqlite3_column_text(statement, 3))) ?? .me,
                text: String(cString: sqlite3_column_text(statement, 5)),
                language: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                app: sqlite3_column_text(statement, 6).map { String(cString: $0) }
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error() }
        return lines
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    private func error() -> SQLiteError {
        SQLiteError(description: String(cString: sqlite3_errmsg(db)))
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw SQLiteError(description: message.map { String(cString: $0) } ?? "sqlite error")
        }
    }

    // Times are Unix seconds. `segments_fts` mirrors `text` for full-text search.
    private static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS segments (
            id INTEGER PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('me', 'others')),
            app TEXT,
            language TEXT,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS segments_started_at ON segments (started_at);
        CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5 (
            text, content = 'segments', content_rowid = 'id', tokenize = 'unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON segments BEGIN
            INSERT INTO segments_fts (rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON segments BEGIN
            INSERT INTO segments_fts (segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS segments_au AFTER UPDATE OF text ON segments BEGIN
            INSERT INTO segments_fts (segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
            INSERT INTO segments_fts (rowid, text) VALUES (new.id, new.text);
        END;
        """
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
