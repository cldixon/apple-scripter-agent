import Foundation

public enum CatalogError: LocalizedError, Equatable {
    case invalidID(String)
    case invalidCommit(String)
    case notInCommit(id: String, commit: String)

    public var errorDescription: String? {
        switch self {
        case .invalidID(let id): "\"\(id)\" is not a valid automation id."
        case .invalidCommit(let commit): "\"\(commit)\" is not a commit hash."
        case .notInCommit(let id, let commit): "\(id) does not exist in commit \(commit.prefix(7))."
        }
    }
}

/// The catalog on disk: the automations folder as a git repository, with one commit per
/// approved change, plus `state.json` (disabled automations) and the drafts folder.
///
/// Without git (no Xcode command line tools) everything still works except history, diff
/// and rollback; `versioningError` says why.
public struct CatalogRepository: Sendable {
    public let store: AutomationStore
    public let git: GitClient
    /// Why changes are not being versioned, or nil when they are.
    public private(set) var versioningError: String?

    public init(store: AutomationStore, gitExecutable: URL = GitClient.defaultExecutable) {
        self.store = store
        git = GitClient(repository: store.automationsDirectory, executable: gitExecutable)
        versioningError = "The catalog has not been prepared yet."
    }

    public var isVersioned: Bool { versioningError == nil }
    public var stateURL: URL { store.automationsDirectory.appending(path: "state.json") }

    // MARK: Setup

    /// Creates the folders and the git repository (with a local identity) if needed, and
    /// commits anything not yet committed. Never throws: problems end up in `versioningError`.
    public mutating func prepare() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: store.automationsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: store.draftsDirectory, withIntermediateDirectories: true)
        } catch {
            versioningError = "Could not create the catalog folders: \(error.localizedDescription)"
            return
        }
        guard git.isAvailable else {
            versioningError = "git is not available at \(git.executable.path). Install the Xcode command line "
                + "tools (xcode-select --install) to keep version history."
            return
        }
        do {
            try initializeRepository()
            versioningError = nil
            try commit("Start version history")
        } catch {
            versioningError = error.localizedDescription
        }
    }

    private func initializeRepository() throws {
        let fileManager = FileManager.default
        let gitDirectory = store.automationsDirectory.appending(path: ".git", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: gitDirectory.path) {
            try git.run(["init", "-q"])
        }
        let settings = [
            ("user.name", "Automation Agent"),
            ("user.email", "runner@localhost"),
            ("commit.gpgsign", "false"),
            // Ignore hooks from the user's global configuration.
            ("core.hooksPath", "/dev/null")
        ]
        for (key, value) in settings {
            try git.run(["config", "--local", key, value])
        }
        let ignore = store.automationsDirectory.appending(path: ".gitignore")
        if !fileManager.fileExists(atPath: ignore.path) {
            try Data(".staging-*\n.DS_Store\n".utf8).write(to: ignore, options: .atomic)
        }
    }

    // MARK: Changes

    /// Commits every change in the folder. Returns false when there was nothing to commit
    /// or versioning is unavailable.
    @discardableResult
    public func commit(_ message: String) throws -> Bool {
        guard isVersioned else { return false }
        try git.run(["add", "-A", "--", "."])
        let status = try git.run(["status", "--porcelain"])
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        try git.run(["commit", "-q", "--no-verify", "-m", message])
        return true
    }

    /// Commits, turning a git failure into a warning: the change itself is already on disk.
    private func commitChange(_ message: String) -> String? {
        do {
            try commit(message)
            return nil
        } catch {
            return "The change was saved but not versioned: \(error.localizedDescription)"
        }
    }

    /// Installs or replaces an automation and commits "Install <id> v<N>" (or "Replace …").
    /// Returns a warning if the commit failed.
    @discardableResult
    public func install(_ manifest: AutomationManifest, sourceFolder: URL? = nil) throws -> String? {
        let existed = FileManager.default.fileExists(atPath: store.folder(for: manifest.id).path)
        try store.install(manifest, sourceFolder: sourceFolder)
        return commitChange("\(existed ? "Replace" : "Install") \(manifest.id) v\(manifest.version)")
    }

    /// Removes an automation's folder and commits "Remove <id>".
    @discardableResult
    public func remove(id: String) throws -> String? {
        try Self.checkID(id)
        try store.remove(id: id)
        var disabled = disabledIDs()
        if disabled.remove(id) != nil {
            try writeDisabled(disabled)
        }
        return commitChange("Remove \(id)")
    }

    /// Records whether an automation is enabled in `state.json` and commits.
    @discardableResult
    public func setEnabled(id: String, enabled: Bool) throws -> String? {
        try Self.checkID(id)
        var disabled = disabledIDs()
        let changed = enabled ? disabled.remove(id) != nil : disabled.insert(id).inserted
        guard changed else { return nil }
        try writeDisabled(disabled)
        return commitChange("\(enabled ? "Enable" : "Disable") \(id)")
    }

    // MARK: State

    private struct State: Codable {
        var disabled: [String]
    }

    /// Ids of disabled automations, from `state.json`.
    public func disabledIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return [] }
        return Set(state.disabled)
    }

    private func writeDisabled(_ ids: Set<String>) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(State(disabled: ids.sorted())).write(to: stateURL, options: .atomic)
    }

    // MARK: Validation

    static func checkID(_ id: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !id.isEmpty, !id.hasPrefix("-"), id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CatalogError.invalidID(id)
        }
    }

    static func checkCommit(_ commit: String) throws {
        guard GitClient.isCommitHash(commit) else { throw CatalogError.invalidCommit(commit) }
    }

    func requireVersioning() throws {
        if let versioningError { throw GitError.unavailable(versioningError) }
    }
}

// MARK: - History, diff and rollback

extension CatalogRepository {
    /// Commits that touched the automation's folder, newest first.
    public func history(id: String) throws -> [AutomationVersion] {
        try requireVersioning()
        try Self.checkID(id)
        let log = try git.run(["log", "--format=%H%x1f%ct%x1f%s", "--", id])
        return log.split(separator: "\n").compactMap { line -> AutomationVersion? in
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count == 3, let seconds = TimeInterval(String(fields[1])) else { return nil }
            let hash = String(fields[0])
            return AutomationVersion(
                id: hash,
                date: Date(timeIntervalSince1970: seconds),
                message: String(fields[2]),
                version: manifestVersion(id: id, at: hash)
            )
        }
    }

    /// The manifest's version at `commit`, or nil if the automation did not exist there.
    public func manifestVersion(id: String, at commit: String) -> Int? {
        guard (try? Self.checkID(id)) != nil, GitClient.isCommitHash(commit),
              let text = try? git.run(["show", "\(commit):\(id)/manifest.json"]) else { return nil }
        struct VersionOnly: Decodable {
            var version: Int?
        }
        guard let decoded = try? JSONDecoder().decode(VersionOnly.self, from: Data(text.utf8)) else { return nil }
        return decoded.version ?? 1
    }

    /// A unified diff of the automation's folder from `base` to `target`, or between
    /// `target` and its parent when `base` is nil.
    public func diff(id: String, base: String?, target: String) throws -> String {
        try requireVersioning()
        try Self.checkID(id)
        try Self.checkCommit(target)
        if let base {
            try Self.checkCommit(base)
            return try git.run(["diff", "--no-color", "--no-ext-diff", base, target, "--", id])
        }
        let shown = try git.run(["show", "--no-color", "--no-ext-diff", "--format=", target, "--", id])
        return shown.trimmingCharacters(in: .newlines)
    }

    /// Writes the automation's folder back as it was at `target` and commits
    /// "Roll back <id> to v<N>". Returns N.
    @discardableResult
    public func rollback(id: String, toCommit target: String) throws -> Int {
        try requireVersioning()
        try Self.checkID(id)
        try Self.checkCommit(target)
        guard let version = manifestVersion(id: id, at: target) else {
            throw CatalogError.notInCommit(id: id, commit: target)
        }
        let folder = store.folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try git.run(["checkout", target, "--", id])
        try commit("Roll back \(id) to v\(version)")
        return version
    }

    /// When the automation first appeared in history and when it last changed.
    public func dates(id: String) -> (created: Date, updated: Date)? {
        guard isVersioned, (try? Self.checkID(id)) != nil,
              let log = try? git.run(["log", "--format=%ct", "--", id]) else { return nil }
        let stamps = log.split(separator: "\n").compactMap { TimeInterval(String($0)) }
        guard let newest = stamps.first, let oldest = stamps.last else { return nil }
        return (Date(timeIntervalSince1970: oldest), Date(timeIntervalSince1970: newest))
    }
}

// MARK: - Index rows

extension CatalogRepository {
    /// One index row per automation folder, with the status the runner would compute.
    /// Folders whose manifest cannot be read become `broken` rows.
    public func indexRows(registrationErrors: [String: String] = [:], now: Date = Date()) -> [IndexedAutomation] {
        let loaded = store.loadAll()
        let disabled = disabledIDs()
        var rows = loaded.manifests.map { manifest -> IndexedAutomation in
            let status = AutomationStatus.installed(
                enabled: !disabled.contains(manifest.id),
                issues: ManifestValidator.validate(manifest),
                registrationError: registrationErrors[manifest.id]
            )
            let span = dates(id: manifest.id) ?? fileDates(id: manifest.id) ?? (created: now, updated: now)
            return IndexedAutomation(manifest: manifest, status: status, created: span.created, updated: span.updated)
        }
        for folder in loaded.failures.keys.sorted() {
            rows.append(IndexedAutomation(
                id: folder, name: folder, triggerSummary: "Unknown", status: .broken,
                currentVersion: 0, created: now, updated: now
            ))
        }
        return rows
    }

    private func fileDates(id: String) -> (created: Date, updated: Date)? {
        let manifestURL = store.folder(for: id).appending(path: "manifest.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
              let updated = attributes[.modificationDate] as? Date else { return nil }
        return (attributes[.creationDate] as? Date ?? updated, updated)
    }
}
