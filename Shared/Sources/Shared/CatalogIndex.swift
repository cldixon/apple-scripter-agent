import Foundation
import SQLite3

public enum CatalogIndexError: LocalizedError, Equatable {
    case sqlite(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): "Catalog index: \(message)"
        case .unreadable(let message): "The catalog index is unreadable: \(message)"
        }
    }
}

/// `catalog.sqlite`: a queryable index of the catalog, written with the system SQLite.
///
/// The automation folders and `runs.jsonl` are the source of truth; `rebuild` recreates the
/// automations and runs tables from them. Test reports and conversation links live only here.
/// Not thread-safe: the runner uses it from the main actor.
public final class CatalogIndex {
    public static let schemaVersion: Int32 = 1

    public let url: URL
    private var database: OpaquePointer?

    /// Opens (or creates) the index and checks that it is readable.
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
            throw CatalogIndexError.unreadable(message)
        }
        database = handle
        try verifyAndMigrate()
    }

    deinit {
        sqlite3_close(database)
    }

    /// Opens the index at `url`. If it is missing or unreadable, it is recreated and
    /// `needsRebuild` is true. Returns nil only if a fresh index cannot be created either.
    public static func open(at url: URL) -> (index: CatalogIndex, needsRebuild: Bool)? {
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed, let index = try? CatalogIndex(url: url) {
            return (index, false)
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        guard let index = try? CatalogIndex(url: url) else { return nil }
        return (index, true)
    }

    private func verifyAndMigrate() throws {
        let check = try query("PRAGMA quick_check") { $0.text(0) }
        guard let first = check.first, first == "ok" else {
            throw CatalogIndexError.unreadable(check.compactMap { $0 }.joined(separator: "; "))
        }
        let version = try query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        if version != 0, version != Int(Self.schemaVersion) {
            throw CatalogIndexError.unreadable("schema version \(version), expected \(Self.schemaVersion)")
        }
        try executeScript(Self.schema)
        try executeScript("PRAGMA user_version = \(Self.schemaVersion);")
    }

    private static let schema = """
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS automations (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        request TEXT,
        trigger_summary TEXT NOT NULL,
        status TEXT NOT NULL,
        current_version INTEGER NOT NULL,
        created REAL NOT NULL,
        updated REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY,
        automation_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        cause TEXT NOT NULL,
        started REAL NOT NULL,
        duration REAL NOT NULL,
        outcome TEXT NOT NULL,
        error TEXT,
        output_excerpt TEXT
    );
    CREATE INDEX IF NOT EXISTS runs_by_automation ON runs (automation_id, started DESC);
    CREATE TABLE IF NOT EXISTS tests (
        automation_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        ran_at REAL NOT NULL,
        passed INTEGER NOT NULL,
        report TEXT NOT NULL,
        PRIMARY KEY (automation_id, version)
    );
    CREATE TABLE IF NOT EXISTS conversations (
        automation_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        created REAL NOT NULL,
        PRIMARY KEY (automation_id, conversation_id)
    );
    """
}

// MARK: - Automations

extension CatalogIndex {
    private static let upsertAutomationSQL = """
    INSERT INTO automations
        (id, name, description, request, trigger_summary, status, current_version, created, updated)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
        name = excluded.name, description = excluded.description, request = excluded.request,
        trigger_summary = excluded.trigger_summary, status = excluded.status,
        current_version = excluded.current_version, updated = excluded.updated
    """

    /// Inserts or updates one automation. An existing row keeps its `created` date.
    public func upsert(_ automation: IndexedAutomation) throws {
        try execute(Self.upsertAutomationSQL, [
            .text(automation.id), .text(automation.name), .text(automation.description),
            .text(automation.request), .text(automation.triggerSummary), .text(automation.status.rawValue),
            .int(automation.currentVersion), .real(automation.created.timeIntervalSince1970),
            .real(automation.updated.timeIntervalSince1970)
        ])
    }

    /// Makes the automations table match `automations`: rows for other ids are deleted.
    public func sync(_ automations: [IndexedAutomation]) throws {
        try transaction {
            let keep = Set(automations.map(\.id))
            let existing = try query("SELECT id FROM automations") { $0.text(0) ?? "" }
            for id in existing where !keep.contains(id) {
                try deleteAutomation(id: id)
            }
            for automation in automations {
                try upsert(automation)
            }
        }
    }

    public func deleteAutomation(id: String) throws {
        try execute("DELETE FROM automations WHERE id = ?", [.text(id)])
    }

    /// Automations sorted by name. `search` matches id, name, description and request.
    public func automations(search: String? = nil, status: AutomationStatus? = nil) throws -> [IndexedAutomation] {
        var clauses: [String] = []
        var bindings: [SQLValue] = []
        if let search, !search.isEmpty {
            clauses.append("(id LIKE ? OR name LIKE ? OR description LIKE ? OR request LIKE ?)")
            let pattern = "%\(search)%"
            bindings += Array(repeating: .text(pattern), count: 4)
        }
        if let status {
            clauses.append("status = ?")
            bindings.append(.text(status.rawValue))
        }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let sql = "SELECT id, name, description, request, trigger_summary, status, current_version, created, updated "
            + "FROM automations\(filter) ORDER BY name COLLATE NOCASE, id"
        return try query(sql, bindings) { row in
            IndexedAutomation(
                id: row.text(0) ?? "",
                name: row.text(1) ?? "",
                description: row.text(2),
                request: row.text(3),
                triggerSummary: row.text(4) ?? "",
                status: AutomationStatus(rawValue: row.text(5) ?? "") ?? .broken,
                currentVersion: row.int(6),
                created: Date(timeIntervalSince1970: row.real(7)),
                updated: Date(timeIntervalSince1970: row.real(8))
            )
        }
    }
}

// MARK: - SQLite plumbing

extension CatalogIndex {
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

        func real(_ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
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
            throw CatalogIndexError.sqlite(lastError)
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
            throw CatalogIndexError.sqlite(lastError)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var values: [Value] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw CatalogIndexError.sqlite(lastError) }
            values.append(try makeValue(Row(statement: statement)))
        }
        return values
    }

    private func bind(_ bindings: [SQLValue], to statement: OpaquePointer) throws {
        // SQLITE_TRANSIENT: SQLite copies the string before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let position = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text?):
                status = sqlite3_bind_text(statement, position, text, -1, transient)
            case .text(nil):
                status = sqlite3_bind_null(statement, position)
            case .int(let number):
                status = sqlite3_bind_int64(statement, position, Int64(number))
            case .real(let number):
                status = sqlite3_bind_double(statement, position, number)
            }
            guard status == SQLITE_OK else { throw CatalogIndexError.sqlite(lastError) }
        }
    }
}
