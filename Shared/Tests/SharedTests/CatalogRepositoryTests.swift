import Foundation
@testable import Shared
import Testing

/// Git-backed versioning. These need `/usr/bin/git` (from the Xcode command line tools)
/// and are skipped without it.
struct CatalogRepositoryTests {
    static let gitInstalled = FileManager.default.isExecutableFile(atPath: GitClient.defaultExecutable.path)

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func manifest(name: String = "Sample", version: Int = 1) -> AutomationManifest {
        AutomationManifest(
            id: "sample",
            name: name,
            trigger: .manual,
            steps: [Step(.primitive(.readClipboard), output: "clip")],
            version: version
        )
    }

    private func preparedCatalog(root: URL) throws -> CatalogRepository {
        var catalog = CatalogRepository(store: AutomationStore(root: root))
        catalog.prepare()
        try #require(catalog.versioningError == nil)
        return catalog
    }

    private func lastMessage(_ catalog: CatalogRepository) throws -> String {
        try catalog.git.run(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitCount(_ catalog: CatalogRepository) throws -> Int {
        let text = try catalog.git.run(["rev-list", "--count", "HEAD"])
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    // MARK: Setup

    @Test(.enabled(if: CatalogRepositoryTests.gitInstalled))
    func prepareCreatesRepositoryAndDrafts() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var catalog = try preparedCatalog(root: root)

        let store = catalog.store
        #expect(FileManager.default.fileExists(atPath: store.draftsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: store.automationsDirectory.appending(path: ".git").path))
        let email = try catalog.git.run(["config", "--local", "user.email"])
        #expect(email.trimmingCharacters(in: .whitespacesAndNewlines) == "runner@localhost")
        let commits = try commitCount(catalog)

        // Preparing again changes nothing.
        catalog.prepare()
        #expect(catalog.versioningError == nil)
        #expect(try commitCount(catalog) == commits)
    }

    @Test func missingGitKeepsWorkingWithoutVersioning() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var unprepared = CatalogRepository(
            store: AutomationStore(root: root),
            gitExecutable: root.appending(path: "no-such-git")
        )
        unprepared.prepare()
        let catalog = unprepared

        #expect(catalog.versioningError != nil)
        #expect(!catalog.isVersioned)
        #expect(try catalog.install(manifest()) == nil)
        #expect(catalog.store.loadAll().manifests.count == 1)
        #expect(throws: GitError.self) { try catalog.history(id: "sample") }
        #expect(FileManager.default.fileExists(atPath: catalog.store.draftsDirectory.path))
    }

    // MARK: Versions

    @Test(.enabled(if: CatalogRepositoryTests.gitInstalled))
    func installsBecomeVersions() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try preparedCatalog(root: root)

        #expect(try catalog.install(manifest(name: "First", version: 1)) == nil)
        var history = try catalog.history(id: "sample")
        #expect(history.count == 1)
        #expect(history.first?.version == 1)
        #expect(history.first?.message == "Install sample v1")

        try catalog.install(manifest(name: "Second", version: 2))
        history = try catalog.history(id: "sample")
        #expect(history.map { $0.version } == [2, 1])
        #expect(history.first?.message == "Replace sample v2")

        let latestChange = try catalog.diff(id: "sample", base: nil, target: history[0].id)
        #expect(latestChange.contains("Second"))
        #expect(latestChange.contains("First"))
        let between = try catalog.diff(id: "sample", base: history[1].id, target: history[0].id)
        #expect(!between.isEmpty)
        let firstVersion = try catalog.diff(id: "sample", base: nil, target: history[1].id)
        #expect(firstVersion.contains("manifest.json"))
    }

    @Test(.enabled(if: CatalogRepositoryTests.gitInstalled))
    func rollbackRestoresTheOldManifest() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try preparedCatalog(root: root)

        try catalog.install(manifest(name: "First", version: 1))
        try catalog.install(manifest(name: "Second", version: 2))
        let oldest = try #require(try catalog.history(id: "sample").last)

        #expect(try catalog.rollback(id: "sample", toCommit: oldest.id) == 1)
        let restored = try #require(catalog.store.loadAll().manifests.first)
        #expect(restored.version == 1)
        #expect(restored.name == "First")

        let history = try catalog.history(id: "sample")
        #expect(history.count == 3)
        #expect(history.first?.message == "Roll back sample to v1")
        #expect(history.first?.version == 1)
    }

    @Test(.enabled(if: CatalogRepositoryTests.gitInstalled))
    func removeIsCommittedAndCanBeUndone() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try preparedCatalog(root: root)

        try catalog.install(manifest())
        try catalog.setEnabled(id: "sample", enabled: false)
        #expect(try catalog.remove(id: "sample") == nil)
        #expect(catalog.store.loadAll().manifests.isEmpty)
        #expect(catalog.disabledIDs().isEmpty)
        #expect(try lastMessage(catalog) == "Remove sample")

        let history = try catalog.history(id: "sample")
        #expect(history.first?.message == "Remove sample")
        #expect(history.first?.version == nil)
        let removal = try #require(history.first)
        #expect(throws: CatalogError.self) { try catalog.rollback(id: "sample", toCommit: removal.id) }

        let installed = try #require(history.last)
        try catalog.rollback(id: "sample", toCommit: installed.id)
        #expect(catalog.store.loadAll().manifests.count == 1)
    }

    @Test(.enabled(if: CatalogRepositoryTests.gitInstalled))
    func enableAndDisableAreCommitted() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try preparedCatalog(root: root)
        try catalog.install(manifest())

        try catalog.setEnabled(id: "sample", enabled: false)
        #expect(catalog.disabledIDs() == ["sample"])
        #expect(try lastMessage(catalog) == "Disable sample")
        let commits = try commitCount(catalog)

        // Disabling twice is not a change.
        try catalog.setEnabled(id: "sample", enabled: false)
        #expect(try commitCount(catalog) == commits)

        try catalog.setEnabled(id: "sample", enabled: true)
        #expect(catalog.disabledIDs().isEmpty)
        #expect(try lastMessage(catalog) == "Enable sample")
    }

    @Test(.enabled(if: CatalogRepositoryTests.gitInstalled))
    func rejectsArgumentsThatAreNotHashesOrIDs() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try preparedCatalog(root: root)
        try catalog.install(manifest())

        #expect(throws: CatalogError.self) { try catalog.diff(id: "sample", base: nil, target: "--output=/tmp/x") }
        #expect(throws: CatalogError.self) { try catalog.history(id: "../sample") }
        #expect(throws: CatalogError.self) { try catalog.rollback(id: "sample", toCommit: "HEAD~1") }
    }

    @Test func commitHashCheck() {
        #expect(GitClient.isCommitHash("0123abcd"))
        #expect(GitClient.isCommitHash(String(repeating: "a", count: 40)))
        #expect(!GitClient.isCommitHash("abc"))
        #expect(!GitClient.isCommitHash("--all"))
        #expect(!GitClient.isCommitHash("ABCDEF12"))
    }
}
