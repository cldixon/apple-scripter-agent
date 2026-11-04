import AppKit
import os
import Shared

/// The runner's brain: loads installed automations, registers their triggers, runs them,
/// runs their tests, and answers commands from the main app. Catalog changes (versioning,
/// enable/disable, the SQLite index) are in `RunnerCore+Catalog.swift`.
@MainActor
final class RunnerCore {
    let state = RunnerState()
    let store: AutomationStore
    /// The automations folder as a git repository. `prepare()` runs in `start()`.
    var catalog: CatalogRepository
    /// `catalog.sqlite`, or nil if it could not be opened.
    var index: CatalogIndex?

    let logger = Logger(subsystem: Identifiers.logSubsystem, category: "core")
    private let engine = AutomationEngine(environment: SystemEnvironment())
    private let hotkeys = HotkeyCenter()
    private let harness = HarnessController()

    private(set) var manifests: [String: AutomationManifest] = [:]
    private(set) var registrationErrors: [String: String] = [:]
    private var loadFailures: [String: String] = [:]
    private var disabled: Set<String> = []
    private var running: Set<String> = []

    init() {
        let store = AutomationStore(root: AutomationStore.defaultRoot())
        self.store = store
        catalog = CatalogRepository(store: store)
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
            guard !ManifestValidator.hasErrors(ManifestValidator.validate(manifest)) else {
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
        state.automations = summaries()
        syncIndex()
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
        guard !running.contains(id) else {
            logger.info("\(id, privacy: .public) is already running; ignoring the new trigger")
            return nil
        }
        running.insert(id)
        let record = await engine.run(manifest, cause: cause)
        running.remove(id)
        do {
            try store.appendRun(record)
        } catch {
            logger.error("Could not write the run log: \(error.localizedDescription, privacy: .public)")
        }
        indexRun(record)
        state.record(record)
        return record
    }

    func test(id: String) async -> TestReport? {
        guard let manifest = manifests[id] else { return nil }
        let issues = ManifestValidator.validate(manifest)
        var results = await UnitTestRunner.run(manifest)
        for (position, test) in manifest.tests.enumerated() {
            guard case .harness(let harnessTest) = test else { continue }
            results += await harness.run(harnessTest, name: "tests[\(position)] harness", manifest: manifest) {
                await self.run(id: id, cause: .test)
            }
        }
        let report = TestReport(automationID: id, ranAt: Date(), issues: issues, results: results)
        indexTestReport(report, version: manifest.version)
        return report
    }

    // MARK: Install

    func install(manifestData: Data, sourceFolder: URL?) -> InstallReport {
        let manifest: AutomationManifest
        do {
            manifest = try AutomationManifest.decode(from: manifestData)
        } catch {
            return InstallReport(
                automationID: nil, installed: false, issues: [],
                message: "The manifest could not be read: \(Self.describe(error))"
            )
        }
        let issues = ManifestValidator.validate(manifest)
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
            return handleCatalogChange(command)
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
        }
    }

    func summaries() -> [AutomationSummary] {
        manifests.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { manifest in
                AutomationSummary(
                    manifest: manifest,
                    issues: ManifestValidator.validate(manifest),
                    registrationError: registrationErrors[manifest.id],
                    folderPath: store.folder(for: manifest.id).path,
                    enabled: !disabled.contains(manifest.id)
                )
            }
    }

    private static func describe(_ error: any Error) -> String {
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
