import Foundation
import SQLite3

public enum ReferenceLibraryError: LocalizedError, Equatable {
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Reference library: \(message)"
        }
    }
}

/// `reference/library.sqlite`: the agent's offline reference, chunks of markdown with an
/// FTS5 index (porter stemming), written with the system SQLite.
///
/// Every chunk belongs to an *origin* (one bundled file, one app's dictionary, one man page,
/// one installed automation). An origin is replaced as a whole and carries a fingerprint
/// (for example bundle id and version) so unchanged sources are skipped.
/// Not thread-safe: the runner keeps it inside one actor.
public final class ReferenceLibrary {
    public static let schemaVersion: Int32 = 1
    /// `read` returns at most this many characters of a chunk.
    public static let readLimit = 12_000

    public let url: URL
    private var database: OpaquePointer?

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(handle)
            throw ReferenceLibraryError.sqlite(message)
        }
        database = handle
        try prepareSchema()
    }

    deinit {
        sqlite3_close(database)
    }

    /// Opens the library, recreating the file if it is unreadable. Nil if that fails too.
    public static func open(at url: URL) -> ReferenceLibrary? {
        if let library = try? ReferenceLibrary(url: url) { return library }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        return try? ReferenceLibrary(url: url)
    }

    private func prepareSchema() throws {
        let version = try query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        if version != 0, version != Int(Self.schemaVersion) {
            try executeScript("""
            DROP TABLE IF EXISTS chunks_fts;
            DROP TABLE IF EXISTS chunks;
            DROP TABLE IF EXISTS origins;
            """)
        }
        try executeScript(Self.schema)
        try executeScript("PRAGMA user_version = \(Self.schemaVersion);")
    }

    private static let schema = """
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS chunks (
        seq INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        origin TEXT NOT NULL,
        source TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS chunks_by_origin ON chunks (origin);
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        title, body, source, content='chunks', content_rowid='seq', tokenize='porter unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS chunks_after_insert AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts (rowid, title, body, source) VALUES (new.seq, new.title, new.body, new.source);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_after_delete AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts (chunks_fts, rowid, title, body, source)
        VALUES ('delete', old.seq, old.title, old.body, old.source);
    END;
    CREATE TABLE IF NOT EXISTS origins (
        origin TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL,
        updated REAL NOT NULL
    );
    """
}

// MARK: - Writing

extension ReferenceLibrary {
    /// Replaces every chunk of `origin` with `entries`. A chunk id already used by another
    /// origin is taken over.
    public func replace(origin: String, fingerprint: String, entries: [ReferenceEntry]) throws {
        try transaction {
            try execute("DELETE FROM chunks WHERE origin = ?", [.text(origin)])
            for entry in entries {
                try execute("DELETE FROM chunks WHERE id = ?", [.text(entry.id)])
                try execute(
                    "INSERT INTO chunks (id, origin, source, title, body) VALUES (?, ?, ?, ?, ?)",
                    [.text(entry.id), .text(origin), .text(entry.source), .text(entry.title), .text(entry.text)]
                )
            }
            try execute(
                "INSERT OR REPLACE INTO origins (origin, fingerprint, updated) VALUES (?, ?, ?)",
                [.text(origin), .text(fingerprint), .real(Date().timeIntervalSince1970)]
            )
        }
    }

    public func removeOrigin(_ origin: String) throws {
        try transaction {
            try execute("DELETE FROM chunks WHERE origin = ?", [.text(origin)])
            try execute("DELETE FROM origins WHERE origin = ?", [.text(origin)])
        }
    }

    /// The fingerprint stored with `origin`, or nil if it has never been added.
    public func fingerprint(origin: String) throws -> String? {
        try query("SELECT fingerprint FROM origins WHERE origin = ?", [.text(origin)]) { $0.text(0) }
            .first
            .flatMap { $0 }
    }

    /// Origins whose name starts with `prefix`, e.g. "sdef:".
    public func origins(prefix: String) throws -> [String] {
        try query("SELECT origin FROM origins ORDER BY origin") { $0.text(0) ?? "" }
            .filter { $0.hasPrefix(prefix) }
    }
}

// MARK: - Reading

extension ReferenceLibrary {
    public func count() throws -> Int {
        try query("SELECT COUNT(*) FROM chunks") { $0.int(0) }.first ?? 0
    }

    /// Best matches first. Every term must match; if nothing does, any term may.
    public func search(_ text: String, limit: Int) throws -> [ReferenceHit] {
        let limit = min(max(limit, 1), 50)
        guard let strict = ReferenceQuery.expression(text, joiner: "AND") else { return [] }
        let hits = try search(expression: strict, limit: limit)
        guard hits.isEmpty, let loose = ReferenceQuery.expression(text, joiner: "OR"), loose != strict else {
            return hits
        }
        return try search(expression: loose, limit: limit)
    }

    private func search(expression: String, limit: Int) throws -> [ReferenceHit] {
        let sql = """
        SELECT c.id, c.title, c.source, hits.snip FROM (
            SELECT rowid AS hit,
                   snippet(chunks_fts, 1, '**', '**', ' … ', 24) AS snip,
                   bm25(chunks_fts, 4.0, 1.0, 2.0) AS score
            FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY score LIMIT ?
        ) AS hits JOIN chunks AS c ON c.seq = hits.hit ORDER BY hits.score
        """
        return try query(sql, [.text(expression), .int(limit)]) { row in
            ReferenceHit(
                id: row.text(0) ?? "",
                title: row.text(1) ?? "",
                source: row.text(2) ?? "",
                snippet: ReferenceQuery.collapseWhitespace(row.text(3) ?? "")
            )
        }
    }

    /// One chunk, cut to `limit` characters.
    public func read(id: String, limit: Int = readLimit) throws -> ReferenceChunk? {
        let rows = try query("SELECT id, title, source, body FROM chunks WHERE id = ?", [.text(id)]) { row in
            ReferenceChunk(
                id: row.text(0) ?? "", title: row.text(1) ?? "", source: row.text(2) ?? "",
                text: row.text(3) ?? "", truncated: false
            )
        }
        guard var chunk = rows.first else { return nil }
        if chunk.text.count > limit {
            chunk.text = String(chunk.text.prefix(limit))
            chunk.truncated = true
        }
        return chunk
    }
}

// MARK: - Query sanitizing

/// Turns free text into a safe FTS5 expression: words of letters and digits, each quoted,
/// so quotes, operators (AND, OR, NOT, NEAR), hyphens and parentheses cannot cause a syntax error.
public enum ReferenceQuery {
    static let maxTerms = 16
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "do", "does", "for", "from", "how", "i", "in", "is",
        "it", "me", "my", "of", "on", "or", "the", "to", "what", "with"
    ]

    /// Lowercased words, without duplicates and (unless nothing else is left) stop words.
    public static func terms(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        var seen: Set<String> = []
        let unique = words.filter { seen.insert($0).inserted }
        let meaningful = unique.filter { !stopWords.contains($0) }
        return Array((meaningful.isEmpty ? unique : meaningful).prefix(maxTerms))
    }

    /// `"word" AND "word"` (or OR), or nil when the text has no words.
    public static func expression(_ text: String, joiner: String) -> String? {
        let words = terms(text)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"" }.joined(separator: " \(joiner) ")
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - SQLite plumbing

extension ReferenceLibrary {
    enum SQLValue {
        case text(String?)
        case int(Int)
        case real(Double)
    }

    struct Row {
        let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }
    }

    private var lastError: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "the database is closed"
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func executeScript(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ReferenceLibraryError.sqlite(lastError)
        }
    }

    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        _ = try query(sql, bindings) { _ in () }
    }

    func query<Value>(
        _ sql: String,
        _ bindings: [SQLValue] = [],
        row makeValue: (Row) throws -> Value
    ) throws -> [Value] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw ReferenceLibraryError.sqlite(lastError)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let position = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text?): status = sqlite3_bind_text(statement, position, text, -1, transient)
            case .text(nil): status = sqlite3_bind_null(statement, position)
            case .int(let number): status = sqlite3_bind_int64(statement, position, Int64(number))
            case .real(let number): status = sqlite3_bind_double(statement, position, number)
            }
            guard status == SQLITE_OK else { throw ReferenceLibraryError.sqlite(lastError) }
        }
        var values: [Value] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw ReferenceLibraryError.sqlite(lastError) }
            values.append(try makeValue(Row(statement: statement)))
        }
        return values
    }
}
