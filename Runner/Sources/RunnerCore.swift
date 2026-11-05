import AppKit
import os
import Shared

/// The runner's brain: loads installed automations, registers their triggers, runs them,
/// runs their tests, and answers commands from the main app. Catalog changes (versioning,
/// enable/disable, the SQLite index) are in `RunnerCore+Catalog.swift`, tests in
/// `RunnerCore+Testing.swift`, and the agent's tools (reference library, apps, permissions,
/// drafts) in `RunnerCore+Agent.swift`.
@MainActor
final class RunnerCore {
    let state = RunnerState()
    let store: AutomationStore
    /// The automations folder as a git repository. `prepare()` runs in `start()`.
    var catalog: CatalogRepository
    /// `catalog.sqlite`, or nil if it could not be opened.
    var index: CatalogIndex?

    /// The agent's reference library and app dictionaries, built off the main actor.
    let reference: ReferenceService
    /// Rebuilds the reference library now and then (apps get updated).
    var referenceRefresh: Task<Void, Never>?

    let logger = Logger(subsystem: Identifiers.logSubsystem, category: "core")
    private let engine = AutomationEngine(environment: SystemEnvironment())
    private let hotkeys = HotkeyCenter()
    let harness = HarnessController()

    private(set) var manifests: [String: AutomationManifest] = [:]
    private(set) var registrationErrors: [String: String] = [:]
    private var loadFailures: [String: String] = [:]
    private var disabled: Set<String> = []
    private var running: Set<String> = []
    /// Consecutive failures of real runs per automation (M6), recomputed from the log on reload.
    var failureStreaks: [String: FailureStreak] = [:]

    init() {
        let store = AutomationStore(root: AutomationStore.defaultRoot())
        self.store = store
        catalog = CatalogRepository(store: store)
        reference = ReferenceService(directory: store.root.appending(path: "reference", directoryHint: .isDirectory))
    }

    /// Prepares the catalog repository and index, then loads automations.
    func start() {
        catalog.prepare()
        state.versioningProblem = catalog.versioningError
        if let problem = catalog.versioningError {
            logger.error("Catalog versioning is off: \(problem, privacy: .public)")
        }
        openIndex()
        reload()
        startReferenceLibrary()
    }

    /// Reads every manifest from disk and (re)registers triggers of enabled automations.
    func reload() {
        hotkeys.unregisterAll()
        let loaded = store.loadAll()
        manifests = loaded.manifests.reduce(into: [:]) { $0[$1.id] = $1 }
        loadFailures = loaded.failures
        disabled = catalog.disabledIDs()
        registrationErrors = [:]

        for manifest in loaded.manifests where !disabled.contains(manifest.id) {
            let issues = ManifestValidator.validate(manifest, folder: store.folder(for: manifest.id))
            guard !ManifestValidator.hasErrors(issues) else {
                registrationErrors[manifest.id] = "Not active: the manifest has validation errors."
                continue
            }
            guard case .hotkey(let hotkey) = manifest.trigger else { continue }
            let id = manifest.id
            do {
                try hotkeys.register(hotkey) { [weak self] in
                    self?.hotkeyPressed(id)
                }
            } catch {
                registrationErrors[id] = error.localizedDescription
            }
        }
        for (folder, message) in loadFailures {
            logger.error("Could not load \(folder, privacy: .public): \(message, privacy: .public)")
        }
        loadFailureStreaks()
        state.automations = summaries()
        syncIndex()
        refreshReferenceExamples()
        logger.info("Loaded \(self.manifests.count) automations")
    }

    // MARK: Running

    private func hotkeyPressed(_ id: String) {
        guard !state.isPaused else {
            logger.info("Hotkey for \(id, privacy: .public) ignored: automations are paused")
            return
        }
        Task { _ = await run(id: id, cause: .hotkey) }
    }

    func run(id: String, cause: RunRecord.Cause) async -> RunRecord? {
        guard let manifest = manifests[id] else { return nil }
        return await run(manifest, folder: store.folder(for: id), cause: cause)
    }

    /// Runs a manifest from `folder` (an installed automation's or a draft's) and logs the run.
    func run(_ manifest: AutomationManifest, folder: URL, cause: RunRecord.Cause) async -> RunRecord? {
        let id = manifest.id
        guard !running.contains(id) else {
            logger.info("\(id, privacy: .public) is already running; ignoring the new trigger")
            return nil
        }
        running.insert(id)
        let record = await engine.run(manifest, cause: cause, folder: folder)
        running.remove(id)
        do {
            try store.appendRun(record)
        } catch {
            logger.error("Could not write the run log: \(error.localizedDescription, privacy: .public)")
        }
        indexRun(record)
        state.record(record)
        trackFailures(record, manifest: manifest)
        return record
    }

    // MARK: Install

    func install(manifestData: Data, sourceFolder: URL?) async -> InstallReport {
        let manifest: AutomationManifest
        do {
            manifest = try AutomationManifest.decode(from: manifestData)
        } catch {
            return InstallReport(
                automationID: nil, installed: false, issues: [],
                message: "The manifest could not be read: \(Self.describe(error))"
            )
        }
        var issues = ManifestValidator.validate(manifest, folder: sourceFolder)
        for failure in await compileResults(manifest, folder: sourceFolder) where !failure.passed {
            issues.append(ValidationIssue(.error, failure.name, failure.message))
        }
        guard !ManifestValidator.hasErrors(issues) else {
            return InstallReport(
                automationID: manifest.id, installed: false, issues: issues,
                message: "Not installed: fix the errors below first."
            )
        }
        let versioningWarning: String?
        do {
            versioningWarning = try catalog.install(manifest, sourceFolder: sourceFolder)
        } catch {
            return InstallReport(
                automationID: manifest.id, installed: false, issues: issues,
                message: "Could not save the automation: \(error.localizedDescription)"
            )
        }
        reload()
        var message = registrationErrors[manifest.id].map { "Installed, but not active: \($0)" }
            ?? "Installed \"\(manifest.name)\" (\(manifest.trigger.summary))."
        if let versioningWarning { message += " \(versioningWarning)" }
        return InstallReport(automationID: manifest.id, installed: true, issues: issues, message: message)
    }

    // MARK: Commands from the main app

    func handle(_ command: RunnerCommand) async -> RunnerReply {
        switch command {
        case .listAutomations:
            return .automations(summaries(), paused: state.isPaused)
        case .installFromFile, .installManifest, .remove, .setEnabled, .rebuildIndex:
            return await handleCatalogChange(command)
        case .history, .diff, .rollback:
            return handleVersionCommand(command)
        case .run(let id):
            guard let record = await run(id: id, cause: .manual) else {
                return .failure("\(id) is not installed or is already running.")
            }
            return .ran(record)
        case .test(let id):
            guard let report = await test(id: id) else { return .failure("\(id) is not installed.") }
            return .tested(report)
        case .recentRuns(let limit):
            return .runs(store.recentRuns(limit: limit))
        case .setPaused(let paused):
            state.isPaused = paused
            return .done
        case .requestAccessibility:
            SystemActions.requestAccessibility()
            return .done
        case .runSnippet, .compile:
            return await handleScriptCommand(command)
        case .searchReference, .readReference, .introspectApp, .listApps, .listShortcuts, .checkPermissions,
             .readAutomation:
            return await handleAgentCommand(command)
        case .writeDraft, .validateDraft, .installDraft, .discardDraft:
            return await handleDraftCommand(command)
        }
    }

    private func handleScriptCommand(_ command: RunnerCommand) async -> RunnerReply {
        do {
            switch command {
            case .runSnippet(let language, let source, let timeout):
                let request = ScriptRequest(language: language, source: source, timeout: min(max(timeout, 1), 120))
                return .snippet(try await ScriptRunner.execute(request))
            case .compile(let language, let source):
                return .compiled(errors: try await ScriptRunner.compile(language, source: source))
            default:
                return .failure("Not a script command.")
            }
        } catch {
            return .failure("The script could not run: \(error.localizedDescription)")
        }
    }

    func summaries() -> [AutomationSummary] {
        manifests.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { manifest in
                AutomationSummary(
                    manifest: manifest,
                    issues: ManifestValidator.validate(manifest, folder: store.folder(for: manifest.id)),
                    registrationError: registrationErrors[manifest.id],
                    folderPath: store.folder(for: manifest.id).path,
                    enabled: !disabled.contains(manifest.id),
                    failureStreak: failureStreaks[manifest.id] ?? FailureStreak()
                )
            }
    }

    /// An error's message; for a decoding error, with the coding path that failed.
    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let context), .keyNotFound(_, let context),
             .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
