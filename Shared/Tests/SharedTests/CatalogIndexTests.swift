import Foundation
@testable import Shared
import Testing

struct CatalogIndexTests {
    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func row(
        _ id: String,
        name: String,
        status: AutomationStatus = .active,
        version: Int = 1,
        at seconds: TimeInterval = 1_700_000_000
    ) -> IndexedAutomation {
        IndexedAutomation(
            id: id,
            name: name,
            description: "Does \(name).",
            request: "Please \(name)",
            triggerSummary: "Manual",
            status: status,
            currentVersion: version,
            created: Date(timeIntervalSince1970: seconds),
            updated: Date(timeIntervalSince1970: seconds)
        )
    }

    private func record(_ automationID: String, at seconds: TimeInterval, output: String? = "out") -> RunRecord {
        RunRecord(
            automationID: automationID,
            version: 1,
            cause: .manual,
            startedAt: Date(timeIntervalSince1970: seconds),
            duration: 0.5,
            outcome: .succeeded,
            error: nil,
            steps: [.init(index: 0, type: "primitive", outcome: .succeeded, output: output, error: nil, duration: 0.25)]
        )
    }

    private func manifest(id: String, name: String) -> AutomationManifest {
        AutomationManifest(
            id: id,
            name: name,
            trigger: .manual,
            steps: [Step(.primitive(.readClipboard), output: "clip")],
            tests: [.unit(.init(step: 0, clipboard: "x", expect: "x"))]
        )
    }

    // MARK: Automations

    @Test func upsertAndQuery() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try CatalogIndex(url: root.appending(path: "catalog.sqlite"))

        let beta = row("beta", name: "Beta", status: .disabled)
        let alpha = row("alpha", name: "alpha")
        try index.upsert(beta)
        try index.upsert(alpha)

        let all = try index.automations()
        #expect(all == [alpha, beta])
        #expect(try index.automations(status: .disabled) == [beta])
        #expect(try index.automations(search: "please bet") == [beta])
        #expect(try index.automations(search: "nothing like this").isEmpty)
        #expect(try index.automations(search: "a", status: .active) == [alpha])
    }

    @Test func upsertKeepsCreatedDate() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try CatalogIndex(url: root.appending(path: "catalog.sqlite"))

        try index.upsert(row("alpha", name: "Alpha", at: 1_700_000_000))
        try index.upsert(row("alpha", name: "Alpha 2", version: 2, at: 1_700_000_500))

        let stored = try #require(try index.automations().first)
        #expect(stored.name == "Alpha 2")
        #expect(stored.currentVersion == 2)
        #expect(stored.created == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(stored.updated == Date(timeIntervalSince1970: 1_700_000_500))
    }

    @Test func syncDeletesMissingRows() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try CatalogIndex(url: root.appending(path: "catalog.sqlite"))

        try index.sync([row("alpha", name: "Alpha"), row("beta", name: "Beta")])
        try index.sync([row("beta", name: "Beta", status: .broken)])
        let ids = try index.automations().map { $0.id }
        #expect(ids == ["beta"])
        #expect(try index.automations(status: .broken).count == 1)
    }

    // MARK: Runs, tests, conversations

    @Test func runsNewestFirstWithExcerpt() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try CatalogIndex(url: root.appending(path: "catalog.sqlite"))

        let long = String(repeating: "z", count: RunRecord.outputExcerptLimit + 50)
        let oldest = record("alpha", at: 1_700_000_000)
        let middle = record("beta", at: 1_700_000_100)
        let newest = record("alpha", at: 1_700_000_200, output: long)
        for run in [oldest, middle, newest] {
            try index.insertRun(run)
        }
        // Inserting the same run twice keeps one row.
        try index.insertRun(newest)

        let all = try index.runs(limit: 10)
        #expect(all.map { $0.id } == [newest, middle, oldest].map { $0.id.uuidString })
        let alphaRuns = try index.runs(automationID: "alpha", limit: 10)
        #expect(alphaRuns.count == 2)
        #expect(alphaRuns.first?.outputExcerpt?.count == RunRecord.outputExcerptLimit)
        #expect(alphaRuns.last?.outputExcerpt == "out")
        #expect(try index.runs(limit: 1).count == 1)
    }

    @Test func testReportsPerVersion() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try CatalogIndex(url: root.appending(path: "catalog.sqlite"))

        let report = TestReport(
            automationID: "alpha",
            ranAt: Date(timeIntervalSince1970: 1_700_000_000),
            issues: [ValidationIssue(.warning, "tests", "No tests declared.")],
            results: [.init(name: "tests[0]", passed: true, message: "Got \"x\"")]
        )
        try index.saveTestReport(report, version: 1)
        var failing = report
        failing.results[0].passed = false
        try index.saveTestReport(failing, version: 1)

        #expect(try index.testReport(automationID: "alpha", version: 1) == failing)
        #expect(try index.testReport(automationID: "alpha", version: 2) == nil)
    }

    @Test func conversationsTable() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try CatalogIndex(url: root.appending(path: "catalog.sqlite"))

        try index.addConversation(automationID: "alpha", conversationID: "c1", created: Date(timeIntervalSince1970: 1))
        try index.addConversation(automationID: "alpha", conversationID: "c2", created: Date(timeIntervalSince1970: 2))
        try index.addConversation(automationID: "alpha", conversationID: "c1", created: Date(timeIntervalSince1970: 3))
        #expect(try index.conversationIDs(automationID: "alpha") == ["c1", "c2"])
        #expect(try index.conversationIDs(automationID: "beta").isEmpty)
    }

    // MARK: Opening and rebuilding

    @Test func persistsAcrossOpens() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "catalog.sqlite")

        let first = try #require(CatalogIndex.open(at: url))
        #expect(first.needsRebuild)
        try first.index.upsert(row("alpha", name: "Alpha"))

        let second = try #require(CatalogIndex.open(at: url))
        #expect(!second.needsRebuild)
        #expect(try second.index.automations().count == 1)
    }

    @Test func unreadableIndexIsRecreated() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "catalog.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(String(repeating: "not a database ", count: 100).utf8).write(to: url)

        let opened = try #require(CatalogIndex.open(at: url))
        #expect(opened.needsRebuild)
        #expect(try opened.index.automations().isEmpty)
    }

    @Test func rebuildFromFoldersAndRunLog() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)
        // Versioning is never prepared here, so this test does not need git.
        let catalog = CatalogRepository(store: store)

        try catalog.install(manifest(id: "alpha", name: "Alpha"))
        try catalog.install(manifest(id: "beta", name: "Beta"))
        try catalog.setEnabled(id: "beta", enabled: false)
        let broken = store.folder(for: "gamma")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appending(path: "manifest.json"))
        try store.appendRun(record("alpha", at: 1_700_000_000))
        try store.appendRun(record("beta", at: 1_700_000_100))

        let index = try CatalogIndex(url: store.indexURL)
        try index.upsert(row("stale", name: "Stale"))
        try index.insertRun(record("stale", at: 1_600_000_000))
        try index.rebuild(from: catalog)

        let rows = try index.automations()
        #expect(rows.map { $0.id } == ["alpha", "beta", "gamma"])
        #expect(rows.map { $0.status } == [.active, .disabled, .broken])
        #expect(try index.automations(search: "alp").first?.name == "Alpha")
        let runs = try index.runs(limit: 10)
        #expect(runs.map { $0.automationID } == ["beta", "alpha"])
    }
}
