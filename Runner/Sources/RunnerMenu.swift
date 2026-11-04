import AppKit
import Shared
import SwiftUI

/// Contents of the runner's menu bar item: status, automations, controls.
struct RunnerMenu: View {
    let core: RunnerCore
    @Bindable var state: RunnerState

    var body: some View {
        Text("Automation Agent Runner")
        Text("Running since \(state.startedAt.formatted(date: .omitted, time: .standard)), pid \(state.processID)")
        Text(SystemActions.isAccessibilityTrusted ? "Accessibility: allowed" : "Accessibility: not allowed")
        if let referenceStatus = state.referenceStatus {
            Text(referenceStatus)
        }
        if let problem = state.versioningProblem {
            Text("Version history is off: \(problem)")
        }
        if let lastRun = state.lastRun {
            Text("Last run: \(lastRun.automationID), \(lastRun.outcome.rawValue)")
        }

        Divider()

        if state.automations.isEmpty {
            Text("No automations installed")
        } else {
            Section("Run now") {
                ForEach(state.automations) { automation in
                    Button("\(automation.name) — \(automation.trigger)") {
                        Task { _ = await core.run(id: automation.id, cause: .manual) }
                    }
                }
            }
        }
        Toggle("Pause All Automations", isOn: $state.isPaused)

        Divider()

        Button("Reload Automations") { core.reload() }
        Button("Open Automations Folder") {
            let folder = core.store.automationsDirectory
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
        if !SystemActions.isAccessibilityTrusted {
            Button("Allow Accessibility…") { SystemActions.requestAccessibility() }
        }
        Button("Quit Runner") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
