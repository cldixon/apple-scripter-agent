import AppKit
import Foundation
import Observation
import Shared
import UniformTypeIdentifiers

/// Text shown in the diff sheet.
struct DiffSheet: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// The main app's view of installed automations. All changes go through the runner.
@MainActor
@Observable
final class CatalogController {
    private(set) var automations: [AutomationSummary] = []
    private(set) var isPaused = false
    private(set) var recentRuns: [RunRecord] = []
    private(set) var testReports: [String: TestReport] = [:]
    /// Committed versions per automation, newest first.
    private(set) var versions: [String: [AutomationVersion]] = [:]
    /// Why version history could not be loaded, if it could not.
    private(set) var historyProblem: String?
    private(set) var lastInstall: InstallReport?
    /// The latest error or confirmation, shown at the top of the catalog.
    private(set) var message: String?
    /// The automation a command is running for, or "" for a catalog-wide command.
    private(set) var busyWith: String?

    var selection: String?
    var searchText = ""
    /// Only automations with this status, or all when nil.
    var statusFilter: AutomationStatus?
    var diffSheet: DiffSheet?

    private let client = RunnerClient()

    var selected: AutomationSummary? {
        automations.first { $0.id == selection }
    }

    /// The list after the search field and status filter.
    var filteredAutomations: [AutomationSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return automations.filter { automation in
            if let statusFilter, automation.status != statusFilter { return false }
            guard !query.isEmpty else { return true }
            return [automation.name, automation.id, automation.trigger, automation.description ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func runs(for id: String) -> [RunRecord] {
        recentRuns.filter { $0.automationID == id }
    }

    func refresh() async {
        await perform(.listAutomations, busy: "")
        await perform(.recentRuns(limit: 50), busy: "")
        if let selection {
            await loadHistory(selection)
        }
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

    func setEnabled(_ id: String, enabled: Bool) async {
        await perform(.setEnabled(id: id, enabled: enabled), busy: id)
        await perform(.listAutomations, busy: "")
    }

    // MARK: Versions

    /// Loads the selected automation's versions. A failure (for example, git missing) is
    /// shown in the Versions section rather than as the catalog message.
    func loadHistory(_ id: String) async {
        do {
            switch try await client.send(.history(id: id)) {
            case .history(let historyID, let list):
                versions[historyID] = list
                historyProblem = nil
            case .failure(let text):
                historyProblem = text
            default:
                break
            }
        } catch {
            historyProblem = "Runner unavailable: \(error.localizedDescription)"
        }
    }

    /// Shows what `version` changed compared with the commit before it.
    func showDiff(_ id: String, version: AutomationVersion) async {
        await perform(.diff(id: id, base: nil, target: version.id), busy: id)
    }

    /// Shows the changes from `version` to the newest version.
    func showDiffToLatest(_ id: String, version: AutomationVersion) async {
        guard let latest = versions[id]?.first, latest.id != version.id else { return }
        await perform(.diff(id: id, base: version.id, target: latest.id), busy: id)
    }

    func restore(_ id: String, version: AutomationVersion) async {
        await perform(.rollback(id: id, toCommit: version.id), busy: id)
        await refresh()
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
            AutomationAgentShortcuts.updateAppShortcutParameters()
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
            let seconds = record.duration.formatted(.number.precision(.fractionLength(2)))
            switch record.outcome {
            case .succeeded: message = "Ran \(record.automationID) in \(seconds) s."
            case .skipped: message = "\(record.automationID) was skipped: \(record.error ?? "cancelled")."
            case .failed: message = "\(record.automationID) failed: \(record.error ?? "unknown error")"
            }
        case .tested(let report):
            testReports[report.automationID] = report
            message = report.passed ? "All tests passed for \(report.automationID)." : "Some tests failed."
        case .runs(let runs):
            recentRuns = runs
        default:
            applyCatalogReply(reply)
        }
    }

    private func applyCatalogReply(_ reply: RunnerReply) {
        switch reply {
        case .enabledChanged(let id, let enabled):
            message = enabled ? "Enabled \(id)." : "Disabled \(id). Its trigger is off until you enable it again."
        case .history(let id, let list):
            versions[id] = list
        case .diff(let id, let text):
            diffSheet = DiffSheet(title: "Changes in \(id)", text: text.isEmpty ? "No changes." : text)
        case .rolledBack(let id, let version):
            message = "Restored \(id) to version \(version)."
        case .failure(let text):
            message = text
        default:
            break
        }
    }
}
