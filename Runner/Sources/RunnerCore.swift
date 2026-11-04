import AppKit
import os
import Shared

/// The runner's brain: loads installed automations, registers their triggers, runs them,
/// runs their tests, and answers commands from the main app.
@MainActor
final class RunnerCore {
    let state = RunnerState()
    let store = AutomationStore(root: AutomationStore.defaultRoot())

    private let engine = AutomationEngine(environment: SystemEnvironment())
    private let hotkeys = HotkeyCenter()
    private let harness = HarnessController()
    private let logger = Logger(subsystem: Identifiers.logSubsystem, category: "core")

    private var manifests: [String: AutomationManifest] = [:]
    private var registrationErrors: [String: String] = [:]
    private var loadFailures: [String: String] = [:]
    private var running: Set<String> = []

    /// Reads every manifest from disk and (re)registers triggers.
    func reload() {
        hotkeys.unregisterAll()
        let loaded = store.loadAll()
        manifests = loaded.manifests.reduce(into: [:]) { $0[$1.id] = $1 }
        loadFailures = loaded.failures
        registrationErrors = [:]

        for manifest in loaded.manifests {
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
        state.record(record)
        return record
    }

    func test(id: String) async -> TestReport? {
        guard let manifest = manifests[id] else { return nil }
        let issues = ManifestValidator.validate(manifest)
        var results = await UnitTestRunner.run(manifest)
        for (index, test) in manifest.tests.enumerated() {
            guard case .harness(let harnessTest) = test else { continue }
            results += await harness.run(harnessTest, name: "tests[\(index)] harness", manifest: manifest) {
                await self.run(id: id, cause: .test)
            }
        }
        return TestReport(automationID: id, ranAt: Date(), issues: issues, results: results)
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
        do {
            try store.install(manifest, sourceFolder: sourceFolder)
        } catch {
            return InstallReport(
                automationID: manifest.id, installed: false, issues: issues,
                message: "Could not save the automation: \(error.localizedDescription)"
            )
        }
        reload()
        let message = registrationErrors[manifest.id].map { "Installed, but not active: \($0)" }
            ?? "Installed \"\(manifest.name)\" (\(manifest.trigger.summary))."
        return InstallReport(automationID: manifest.id, installed: true, issues: issues, message: message)
    }

    // MARK: Commands from the main app

    func handle(_ command: RunnerCommand) async -> RunnerReply {
        switch command {
        case .listAutomations:
            return .automations(summaries(), paused: state.isPaused)
        case .installFromFile(let path):
            let url = URL(filePath: path)
            do {
                let data = try Data(contentsOf: url)
                return .installed(install(manifestData: data, sourceFolder: url.deletingLastPathComponent()))
            } catch {
                return .failure("Could not read \(path): \(error.localizedDescription)")
            }
        case .installManifest(let data):
            return .installed(install(manifestData: data, sourceFolder: nil))
        case .remove(let id):
            do {
                try store.remove(id: id)
                reload()
                return .removed(id: id)
            } catch {
                return .failure("Could not remove \(id): \(error.localizedDescription)")
            }
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
                    folderPath: store.folder(for: manifest.id).path
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
