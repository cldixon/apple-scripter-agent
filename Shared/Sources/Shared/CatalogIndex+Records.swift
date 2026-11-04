import Foundation

// MARK: - Runs, tests and conversations

extension CatalogIndex {
    public func insertRun(_ record: RunRecord) throws {
        let run = IndexedRun(record: record)
        try execute(
            "INSERT OR REPLACE INTO runs (id, automation_id, version, cause, started, duration, outcome, error, "
                + "output_excerpt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .text(run.id), .text(run.automationID), .int(run.version), .text(run.cause),
                .real(run.startedAt.timeIntervalSince1970), .real(run.duration), .text(run.outcome),
                .text(run.error), .text(run.outputExcerpt)
            ]
        )
    }

    /// The most recent runs, newest first, optionally for one automation.
    public func runs(automationID: String? = nil, limit: Int) throws -> [IndexedRun] {
        var bindings: [SQLValue] = []
        var filter = ""
        if let automationID {
            filter = " WHERE automation_id = ?"
            bindings.append(.text(automationID))
        }
        bindings.append(.int(limit))
        let sql = "SELECT id, automation_id, version, cause, started, duration, outcome, error, output_excerpt "
            + "FROM runs\(filter) ORDER BY started DESC LIMIT ?"
        return try query(sql, bindings) { row in
            IndexedRun(
                id: row.text(0) ?? "",
                automationID: row.text(1) ?? "",
                version: row.int(2),
                cause: row.text(3) ?? "",
                startedAt: Date(timeIntervalSince1970: row.real(4)),
                duration: row.real(5),
                outcome: row.text(6) ?? "",
                error: row.text(7),
                outputExcerpt: row.text(8)
            )
        }
    }

    /// Stores the latest report for `version`, replacing an earlier one.
    public func saveTestReport(_ report: TestReport, version: Int) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = String(bytes: try encoder.encode(report), encoding: .utf8) ?? "{}"
        try execute(
            "INSERT OR REPLACE INTO tests (automation_id, version, ran_at, passed, report) VALUES (?, ?, ?, ?, ?)",
            [
                .text(report.automationID), .int(version), .real(report.ranAt.timeIntervalSince1970),
                .int(report.passed ? 1 : 0), .text(json)
            ]
        )
    }

    public func testReport(automationID: String, version: Int) throws -> TestReport? {
        let rows = try query(
            "SELECT report FROM tests WHERE automation_id = ? AND version = ?",
            [.text(automationID), .int(version)]
        ) { $0.text(0) }
        guard let first = rows.first, let json = first else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TestReport.self, from: Data(json.utf8))
    }

    public func addConversation(automationID: String, conversationID: String, created: Date) throws {
        try execute(
            "INSERT OR IGNORE INTO conversations (automation_id, conversation_id, created) VALUES (?, ?, ?)",
            [.text(automationID), .text(conversationID), .real(created.timeIntervalSince1970)]
        )
    }

    public func conversationIDs(automationID: String) throws -> [String] {
        try query(
            "SELECT conversation_id FROM conversations WHERE automation_id = ? ORDER BY created",
            [.text(automationID)]
        ) { $0.text(0) ?? "" }
    }
}

// MARK: - Rebuild

extension CatalogIndex {
    /// Replaces the automations and runs tables. Tests and conversations are kept.
    public func rebuild(automations: [IndexedAutomation], runs: [RunRecord]) throws {
        try transaction {
            try execute("DELETE FROM automations")
            try execute("DELETE FROM runs")
            for automation in automations {
                try upsert(automation)
            }
            for run in runs {
                try insertRun(run)
            }
        }
    }

    /// Recreates the automations and runs tables from the automation folders and `runs.jsonl`.
    public func rebuild(from catalog: CatalogRepository, registrationErrors: [String: String] = [:]) throws {
        try rebuild(
            automations: catalog.indexRows(registrationErrors: registrationErrors),
            runs: catalog.store.allRuns()
        )
    }
}
