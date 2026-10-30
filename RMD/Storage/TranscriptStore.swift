import Foundation
import SQLite3

/// The day's transcript, one row per utterance, in a local SQLite file.
/// WAL mode lets the MCP server read while the app writes.
actor TranscriptStore {
    struct SQLiteError: Error, CustomStringConvertible {
        let description: String
    }

    struct Day: Sendable {
        let date: Date
        let lineCount: Int
        let first: Date
        let last: Date
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
        db = handle
        if !readOnly {
            try Self.exec(db, Self.schema)
        }
    }

    isolated deinit {
        sqlite3_close(db)
    }

    func insert(_ line: TranscriptLine) throws -> TranscriptLine {
        let sql = "INSERT INTO segments (started_at, ended_at, source, language, text) VALUES (?, ?, ?, ?, ?)"
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
        sqlite3_bind_int(statement, 3, Int32(limit))
        return readLines(statement)
    }

    /// Full-text search (every word must appear), falling back to a plain substring match
    /// so partial words and odd spellings still hit. Newest first.
    func search(_ query: String, since: Date, limit: Int) throws -> [TranscriptLine] {
        let words = query.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !words.isEmpty else { return [] }

        let fts = """
            SELECT \(Self.columns(of: "s"))
            FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid
            WHERE segments_fts MATCH ? AND s.started_at >= ? ORDER BY s.started_at DESC LIMIT ?
            """
        let ftsStatement = try prepare(fts)
        defer { sqlite3_finalize(ftsStatement) }
        sqlite3_bind_text(ftsStatement, 1, words.joined(separator: " "), -1, sqliteTransient)
        sqlite3_bind_double(ftsStatement, 2, since.timeIntervalSince1970)
        sqlite3_bind_int(ftsStatement, 3, Int32(limit))
        let matches = readLines(ftsStatement)
        if !matches.isEmpty { return matches }

        let like = """
            SELECT \(Self.columns()) FROM segments
            WHERE text LIKE ? ESCAPE '\\' AND started_at >= ? ORDER BY started_at DESC LIMIT ?
            """
        let likeStatement = try prepare(like)
        defer { sqlite3_finalize(likeStatement) }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        sqlite3_bind_text(likeStatement, 1, "%\(escaped)%", -1, sqliteTransient)
        sqlite3_bind_double(likeStatement, 2, since.timeIntervalSince1970)
        sqlite3_bind_int(likeStatement, 3, Int32(limit))
        return readLines(likeStatement)
    }

    /// Days that have any transcript, newest first (days follow this Mac's time zone).
    func days(limit: Int) throws -> [Day] {
        let sql = """
            SELECT date(started_at, 'unixepoch', 'localtime') AS day, count(*), min(started_at), max(ended_at)
            FROM segments GROUP BY day ORDER BY day DESC LIMIT ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var days: [Day] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let first = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            days.append(Day(
                date: Calendar.current.startOfDay(for: first),
                lineCount: Int(sqlite3_column_int(statement, 1)),
                first: first,
                last: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return days
    }

    /// Column order read by `readLines`.
    private static func columns(of table: String? = nil) -> String {
        ["id", "started_at", "ended_at", "source", "language", "text"]
            .map { column in table.map { "\($0).\(column)" } ?? column }
            .joined(separator: ", ")
    }

    private func readLines(_ statement: OpaquePointer) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            lines.append(TranscriptLine(
                id: sqlite3_column_int64(statement, 0),
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                source: TranscriptLine.Source(rawValue: String(cString: sqlite3_column_text(statement, 3))) ?? .me,
                text: String(cString: sqlite3_column_text(statement, 5)),
                language: sqlite3_column_text(statement, 4).map { String(cString: $0) }
            ))
        }
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
