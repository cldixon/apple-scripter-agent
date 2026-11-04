import Foundation

/// File-based storage for installed automations and the run log.
///
/// ```
/// <root>/automations/<id>/manifest.json   (+ scripts/, tests/fixtures/)
/// <root>/runs.jsonl                       one RunRecord per line
/// ```
/// The runner is the only writer. M3 turns `automations/` into a git repository and adds
/// a SQLite index; the folder stays the source of truth.
public struct AutomationStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/AutomationAgent`.
    public static func defaultRoot() -> URL {
        URL.applicationSupportDirectory.appending(path: "AutomationAgent", directoryHint: .isDirectory)
    }

    public var automationsDirectory: URL { root.appending(path: "automations", directoryHint: .isDirectory) }
    public var runLogURL: URL { root.appending(path: "runs.jsonl") }

    public func folder(for id: String) -> URL {
        automationsDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    // MARK: Automations

    /// Every readable manifest, sorted by name. Unreadable folders are reported, not thrown.
    public func loadAll() -> (manifests: [AutomationManifest], failures: [String: String]) {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(
            at: automationsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var manifests: [AutomationManifest] = []
        var failures: [String: String] = [:]
        for folder in folders {
            let manifestURL = folder.appending(path: "manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            do {
                manifests.append(try AutomationManifest.decode(from: Data(contentsOf: manifestURL)))
            } catch {
                failures[folder.lastPathComponent] = error.localizedDescription
            }
        }
        return (manifests.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, failures)
    }

    /// Installs a manifest, replacing any automation with the same id. When `sourceFolder`
    /// is given, its other files (scripts, fixtures) are copied alongside.
    public func install(_ manifest: AutomationManifest, sourceFolder: URL? = nil) throws {
        let fileManager = FileManager.default
        let destination = folder(for: manifest.id)
        let staging = automationsDirectory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: automationsDirectory, withIntermediateDirectories: true)

        if let sourceFolder {
            try fileManager.copyItem(at: sourceFolder, to: staging)
        } else {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        try manifest.encoded().write(to: staging.appending(path: "manifest.json"), options: .atomic)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    public func remove(id: String) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }

    // MARK: Run log

    public func appendRun(_ record: RunRecord) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(0x0A)

        if let handle = try? FileHandle(forWritingTo: runLogURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: runLogURL, options: .atomic)
        }
    }

    /// The most recent runs, newest first, optionally for one automation.
    public func recentRuns(limit: Int, automationID: String? = nil) -> [RunRecord] {
        guard let data = try? Data(contentsOf: runLogURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [RunRecord] = []
        for line in data.split(separator: 0x0A).reversed() {
            guard let record = try? decoder.decode(RunRecord.self, from: Data(line)) else { continue }
            if let automationID, record.automationID != automationID { continue }
            records.append(record)
            if records.count >= limit { break }
        }
        return records
    }
}
