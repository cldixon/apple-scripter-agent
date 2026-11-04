import AppKit
import Foundation
import Observation
import Shared
import UniformTypeIdentifiers

/// The main app's view of installed automations. All changes go through the runner.
@MainActor
@Observable
final class CatalogController {
    private(set) var automations: [AutomationSummary] = []
    private(set) var isPaused = false
    private(set) var recentRuns: [RunRecord] = []
    private(set) var testReports: [String: TestReport] = [:]
    private(set) var lastInstall: InstallReport?
    /// The latest error or confirmation, shown at the top of the catalog.
    private(set) var message: String?
    /// The automation a command is running for, or "" for a catalog-wide command.
    private(set) var busyWith: String?

    var selection: String?

    private let client = RunnerClient()

    var selected: AutomationSummary? {
        automations.first { $0.id == selection }
    }

    func runs(for id: String) -> [RunRecord] {
        recentRuns.filter { $0.automationID == id }
    }

    func refresh() async {
        await perform(.listAutomations, busy: "")
        await perform(.recentRuns(limit: 50), busy: "")
    }

    func installFromFile() async {
        let panel = NSOpenPanel()
        panel.title = "Choose an automation's manifest.json"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await perform(.installFromFile(path: url.path), busy: "")
        await refresh()
    }

    func installDateExample() async {
        await perform(.installManifest(Data(ExampleManifests.insertISODate.utf8)), busy: "")
        await refresh()
    }

    func run(_ id: String) async {
        await perform(.run(id: id), busy: id)
        await perform(.recentRuns(limit: 50), busy: "")
    }

    func test(_ id: String) async {
        // The harness window belongs to the runner; let it come to the front.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: Identifiers.runnerBundleID)
        await perform(.test(id: id), busy: id)
        NSApp.activate()
        await perform(.recentRuns(limit: 50), busy: "")
    }

    func remove(_ id: String) async {
        await perform(.remove(id: id), busy: id)
        await refresh()
    }

    func setPaused(_ paused: Bool) async {
        await perform(.setPaused(paused), busy: "")
        await perform(.listAutomations, busy: "")
    }

    func revealInFinder(_ automation: AutomationSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: automation.folderPath)])
    }

    private func perform(_ command: RunnerCommand, busy: String) async {
        busyWith = busy
        defer { busyWith = nil }
        do {
            apply(try await client.send(command))
        } catch {
            message = "Runner unavailable: \(error.localizedDescription)"
        }
    }

    private func apply(_ reply: RunnerReply) {
        switch reply {
        case .automations(let list, let paused):
            automations = list
            isPaused = paused
            if selection == nil || !list.contains(where: { $0.id == selection }) {
                selection = list.first?.id
            }
        case .installed(let report):
            lastInstall = report
            message = report.message
            if report.installed { selection = report.automationID }
        case .removed(let id):
            message = "Removed \(id)."
            testReports[id] = nil
        case .ran(let record):
            message = record.outcome == .succeeded
                ? "Ran \(record.automationID) in \(record.duration.formatted(.number.precision(.fractionLength(2)))) s."
                : "\(record.automationID) failed: \(record.error ?? "unknown error")"
        case .tested(let report):
            testReports[report.automationID] = report
            message = report.passed ? "All tests passed for \(report.automationID)." : "Some tests failed."
        case .runs(let runs):
            recentRuns = runs
        case .ok:
            break
        case .failure(let text):
            message = text
        }
    }
}
