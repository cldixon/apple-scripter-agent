import CryptoKit
import Foundation
import os
import Shared

/// An installed automation, as material for the reference library.
struct ReferenceExample: Sendable {
    var manifest: AutomationManifest
    var manifestJSON: String
    var files: [String: String]
}

/// What the runner's menu shows about the reference library.
struct ReferenceStatus: Sendable, Equatable {
    var chunks = 0
    var lastBuild: Date?
    var building = false
    var errors: [String] = []

    var menuLine: String {
        if building { return "Reference library: building… (\(chunks) chunks so far)" }
        guard let lastBuild else { return "Reference library: not built yet" }
        let time = lastBuild.formatted(date: .omitted, time: .shortened)
        let problems = errors.isEmpty ? "" : ", \(errors.count) problem\(errors.count == 1 ? "" : "s")"
        return "Reference library: \(chunks) chunks, built \(time)\(problems)"
    }
}

enum ReferenceServiceError: LocalizedError {
    case unavailable
    case appNotFound(String)
    case notScriptable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The reference library could not be opened."
        case .appNotFound(let app):
            "No app named \"\(app)\" was found. Use list_apps for names and bundle ids."
        case .notScriptable(let app):
            "\(app) is not scriptable (it has no scripting dictionary) — consider UI scripting via System Events "
                + "or Shortcuts."
        }
    }
}

/// Owns `reference/library.sqlite` and the scripting dictionaries the agent reads. All SQLite
/// access happens on this actor; `sdef` and `man` run as child processes, off the main actor.
actor ReferenceService {
    private let libraryURL: URL
    private var library: ReferenceLibrary?
    /// Parsed dictionaries by bundle id, with the fingerprint they were read for.
    private var dictionaries: [String: (fingerprint: String, dictionary: SdefDictionary)] = [:]
    private(set) var status = ReferenceStatus()
    private let logger = Logger(subsystem: Identifiers.logSubsystem, category: "reference")

    init(directory: URL) {
        libraryURL = directory.appending(path: "library.sqlite")
    }

    private func openLibrary() throws -> ReferenceLibrary {
        if let library { return library }
        guard let opened = ReferenceLibrary.open(at: libraryURL) else { throw ReferenceServiceError.unavailable }
        library = opened
        return opened
    }

    // MARK: Queries

    func search(_ query: String, limit: Int) throws -> [ReferenceHit] {
        try openLibrary().search(query, limit: limit)
    }

    func read(id: String) throws -> ReferenceChunk? {
        try openLibrary().read(id: id)
    }

    func scanApps() -> [FoundApp] {
        AppScanner.scan()
    }

    /// The app's dictionary as markdown, filtered by `query` and capped in size.
    func introspect(app: String, query: String?, hint: URL?) async throws -> AppDictionarySummary {
        guard let found = AppScanner.resolve(app, in: AppScanner.scan(), hint: hint) else {
            throw ReferenceServiceError.appNotFound(app)
        }
        let dictionary = try await loadDictionary(for: found)
        let text = SdefSummarizer.markdown(dictionary, appName: found.name, query: query)
        let capped = SdefSummarizer.capped(text)
        return AppDictionarySummary(
            app: found.name, bundleID: found.bundleID, text: capped.text, truncated: capped.truncated
        )
    }

    /// The parsed dictionary, read again when the app's version changed. Keeps the
    /// library's copy in step too.
    private func loadDictionary(for app: FoundApp) async throws -> SdefDictionary {
        if let cached = dictionaries[app.bundleID], cached.fingerprint == app.fingerprint {
            return cached.dictionary
        }
        guard let dictionary = try? await ReferenceSources.dictionary(at: app.url), !dictionary.isEmpty else {
            throw ReferenceServiceError.notScriptable(app.name)
        }
        dictionaries[app.bundleID] = (app.fingerprint, dictionary)
        let origin = "sdef:\(app.bundleID)"
        if let library = try? openLibrary(), (try? library.fingerprint(origin: origin)) != app.fingerprint {
            let entries = Self.entries(dictionary, app: app)
            try? library.replace(origin: origin, fingerprint: app.fingerprint, entries: entries)
        }
        return dictionary
    }

    // MARK: Building

    /// Adds or refreshes every source whose fingerprint changed: the bundled notes, man pages,
    /// scripting dictionaries of scriptable apps, and installed automations.
    func build(bundled: URL?, examples: [ReferenceExample]) async -> ReferenceStatus {
        guard !status.building else { return status }
        status.building = true
        status.errors = []
        do {
            let library = try openLibrary()
            addBundled(bundled, to: library)
            await addManPages(to: library)
            await addDictionaries(to: library)
            updateExamples(examples, in: library)
            status.chunks = (try? library.count()) ?? 0
        } catch {
            status.errors.append(error.localizedDescription)
        }
        status.building = false
        status.lastBuild = Date()
        for problem in status.errors.prefix(10) {
            logger.error("Reference library: \(problem, privacy: .public)")
        }
        return status
    }

    /// Replaces the installed-automation examples (after an install, removal or rollback).
    func updateExamples(_ examples: [ReferenceExample]) -> ReferenceStatus {
        guard let library = try? openLibrary() else { return status }
        updateExamples(examples, in: library)
        if !status.building { status.chunks = (try? library.count()) ?? status.chunks }
        return status
    }

    private func record(_ problem: String) {
        if status.errors.count < 50 { status.errors.append(problem) }
    }

    private func addBundled(_ folder: URL?, to library: ReferenceLibrary) {
        guard let folder else {
            record("The bundled Reference folder is missing from the runner.")
            return
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
        var origins: Set<String> = []
        for file in files {
            let origin = "bundled:\(file.lastPathComponent)"
            origins.insert(origin)
            guard let markdown = try? String(contentsOf: file, encoding: .utf8) else {
                record("Could not read \(file.lastPathComponent).")
                continue
            }
            let fingerprint = Self.digest(markdown)
            guard (try? library.fingerprint(origin: origin)) != fingerprint else { continue }
            let entries = ReferenceDocuments.bundledEntries(fileName: file.lastPathComponent, markdown: markdown)
            do {
                try library.replace(origin: origin, fingerprint: fingerprint, entries: entries)
            } catch {
                record("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        removeOrigins(prefix: "bundled:", keeping: origins, in: library)
    }

    private func addManPages(to library: ReferenceLibrary) async {
        let fingerprint = ProcessInfo.processInfo.operatingSystemVersionString
        for name in ReferenceDocuments.manPages {
            let origin = "man:\(name)"
            guard (try? library.fingerprint(origin: origin)) != fingerprint else { continue }
            do {
                let raw = try await ReferenceSources.manPage(name)
                let entries = ReferenceDocuments.manPageEntries(name: name, raw: raw)
                try library.replace(origin: origin, fingerprint: fingerprint, entries: entries)
            } catch {
                record("man \(name): \(error.localizedDescription)")
            }
        }
    }

    private func addDictionaries(to library: ReferenceLibrary) async {
        // Apps with a dynamic dictionary would be launched by sdef; introspect_app still reads them.
        var apps = AppScanner.scan().filter { $0.scriptable && !$0.dynamicDictionary }
        if let additions = AppScanner.info(at: AppScanner.standardAdditions) { apps.append(additions) }
        var origins: Set<String> = []
        for app in apps {
            let origin = "sdef:\(app.bundleID)"
            origins.insert(origin)
            guard (try? library.fingerprint(origin: origin)) != app.fingerprint else { continue }
            do {
                let dictionary = try await ReferenceSources.dictionary(at: app.url)
                // An empty dictionary is stored too (no chunks), so the app is not read again until it changes.
                let entries = dictionary.isEmpty ? [] : Self.entries(dictionary, app: app)
                try library.replace(origin: origin, fingerprint: app.fingerprint, entries: entries)
            } catch {
                record("sdef \(app.name): \(error.localizedDescription)")
            }
        }
        removeOrigins(prefix: "sdef:", keeping: origins, in: library)
    }

    private func updateExamples(_ examples: [ReferenceExample], in library: ReferenceLibrary) {
        var origins: Set<String> = []
        for example in examples {
            let origin = "example:\(example.manifest.id)"
            origins.insert(origin)
            let fingerprint = Self.digest(
                example.manifestJSON + example.files.keys.sorted().map { $0 + (example.files[$0] ?? "") }.joined()
            )
            guard (try? library.fingerprint(origin: origin)) != fingerprint else { continue }
            let entries = ReferenceDocuments.automationEntries(
                example.manifest, manifestJSON: example.manifestJSON, files: example.files
            )
            do {
                try library.replace(origin: origin, fingerprint: fingerprint, entries: entries)
            } catch {
                record("example \(example.manifest.id): \(error.localizedDescription)")
            }
        }
        removeOrigins(prefix: "example:", keeping: origins, in: library)
    }

    private func removeOrigins(prefix: String, keeping: Set<String>, in library: ReferenceLibrary) {
        for origin in (try? library.origins(prefix: prefix)) ?? [] where !keeping.contains(origin) {
            try? library.removeOrigin(origin)
        }
    }

    private static func entries(_ dictionary: SdefDictionary, app: FoundApp) -> [ReferenceEntry] {
        ReferenceDocuments.dictionaryEntries(dictionary, appName: app.name, bundleID: app.bundleID)
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
