import Foundation
@testable import Shared
import Testing

struct AutomationStoreTests {
    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func manifest(id: String = "sample", name: String = "Sample", version: Int = 1) -> AutomationManifest {
        AutomationManifest(
            id: id,
            name: name,
            trigger: .manual,
            steps: [Step(.primitive(.readClipboard), output: "clip")],
            version: version
        )
    }

    private func record(_ automationID: String, at seconds: TimeInterval) -> RunRecord {
        RunRecord(
            automationID: automationID,
            version: 1,
            cause: .manual,
            startedAt: Date(timeIntervalSince1970: seconds),
            duration: 0.5,
            outcome: .succeeded,
            error: nil,
            steps: [.init(index: 0, type: "primitive", outcome: .succeeded, output: "x", error: nil, duration: 0.25)]
        )
    }

    // MARK: Automations

    @Test func installThenLoad() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)

        let sample = manifest()
        try store.install(sample)
        let loaded = store.loadAll()
        #expect(loaded.manifests == [sample])
        #expect(loaded.failures.isEmpty)
        let manifestURL = store.folder(for: "sample").appending(path: "manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test func loadAllSortsByName() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)

        try store.install(manifest(id: "zeta", name: "Beta"))
        try store.install(manifest(id: "alpha", name: "Gamma"))
        try store.install(manifest(id: "mid", name: "alpha"))
        #expect(store.loadAll().manifests.map(\.id) == ["mid", "zeta", "alpha"])
    }

    @Test func installReplacesSameID() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)

        try store.install(manifest(name: "First", version: 1))
        let second = manifest(name: "Second", version: 2)
        try store.install(second)

        let loaded = store.loadAll()
        #expect(loaded.manifests == [second])
        #expect(loaded.failures.isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.automationsDirectory.path)
        #expect(entries.filter { !$0.hasPrefix(".") } == ["sample"])
    }

    @Test func installCopiesSourceFolder() throws {
        let root = makeTemporaryDirectory()
        let source = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let scripts = source.appending(path: "scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("return 1".utf8).write(to: scripts.appending(path: "a.applescript"))

        let store = AutomationStore(root: root)
        let sample = manifest()
        try store.install(sample, sourceFolder: source)

        let installedScript = store.folder(for: "sample").appending(path: "scripts/a.applescript")
        #expect(try String(contentsOf: installedScript, encoding: .utf8) == "return 1")
        #expect(store.loadAll().manifests == [sample])
        // The source folder is copied, not moved.
        #expect(FileManager.default.fileExists(atPath: scripts.appending(path: "a.applescript").path))
    }

    @Test func reinstallWithoutSourceDropsOldFiles() throws {
        let root = makeTemporaryDirectory()
        let source = makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: source.appending(path: "old.txt"))

        let store = AutomationStore(root: root)
        try store.install(manifest(version: 1), sourceFolder: source)
        let oldFile = store.folder(for: "sample").appending(path: "old.txt")
        #expect(FileManager.default.fileExists(atPath: oldFile.path))

        try store.install(manifest(version: 2))
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(store.loadAll().manifests.map(\.version) == [2])
    }

    @Test func removeDeletesTheFolder() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)

        try store.install(manifest())
        try store.remove(id: "sample")
        #expect(store.loadAll().manifests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: "sample").path))
        #expect(throws: (any Error).self) { try store.remove(id: "sample") }
    }

    @Test func corruptManifestIsReportedAsFailure() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)

        try store.install(manifest())
        let broken = store.folder(for: "broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appending(path: "manifest.json"))
        // A folder without a manifest is ignored entirely.
        try FileManager.default.createDirectory(at: store.folder(for: "empty"), withIntermediateDirectories: true)

        let loaded = store.loadAll()
        #expect(loaded.manifests.map(\.id) == ["sample"])
        #expect(Array(loaded.failures.keys) == ["broken"])
        #expect(loaded.failures["broken"]?.isEmpty == false)
    }

    @Test func missingRootLoadsNothing() {
        let store = AutomationStore(root: makeTemporaryDirectory())
        let loaded = store.loadAll()
        #expect(loaded.manifests.isEmpty)
        #expect(loaded.failures.isEmpty)
    }

    // MARK: Run log

    @Test func recentRunsNewestFirst() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)

        let oldest = record("alpha", at: 1_700_000_000)
        let middle = record("beta", at: 1_700_000_100)
        let newest = record("alpha", at: 1_700_000_200)
        for run in [oldest, middle, newest] {
            try store.appendRun(run)
        }

        #expect(store.recentRuns(limit: 10) == [newest, middle, oldest])
        #expect(store.recentRuns(limit: 2).map(\.id) == [newest.id, middle.id])
        #expect(store.recentRuns(limit: 10, automationID: "alpha").map(\.id) == [newest.id, oldest.id])
        #expect(store.recentRuns(limit: 1, automationID: "alpha").map(\.id) == [newest.id])
        #expect(store.recentRuns(limit: 10, automationID: "beta").map(\.id) == [middle.id])
        #expect(store.recentRuns(limit: 10, automationID: "gamma").isEmpty)
    }

    @Test func runLogIsOneLinePerRecord() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(root: root)

        try store.appendRun(record("alpha", at: 1_700_000_000))
        try store.appendRun(record("alpha", at: 1_700_000_001))
        let text = try String(contentsOf: store.runLogURL, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.hasSuffix("\n"))
    }

    @Test func emptyLogReturnsNoRuns() {
        let store = AutomationStore(root: makeTemporaryDirectory())
        #expect(store.recentRuns(limit: 10).isEmpty)
    }
}
