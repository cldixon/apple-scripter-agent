import AppKit
import SwiftUI

/// Contents of the runner's menu bar item: status first, then controls.
struct RunnerMenu: View {
    @Bindable var state: RunnerState

    var body: some View {
        Text("Automation Agent Runner")
        Text("Running since \(state.startedAt.formatted(date: .omitted, time: .standard))")
        Text("Process ID \(state.processID)")
        Text("Pings served: \(state.pingsServed)")
        if let lastPingAt = state.lastPingAt {
            Text("Last ping \(lastPingAt.formatted(date: .omitted, time: .standard))")
        }

        Divider()

        Toggle("Pause All Automations", isOn: $state.isPaused)
        Text("No automations installed yet")

        Divider()

        Button("Quit Runner") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
