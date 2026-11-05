import Shared
import SwiftUI

/// M6: how the automation's recent real runs went, and a way to ask the agent to fix it.
struct MonitoringSection: View {
    @Environment(CatalogController.self) private var catalog
    @Environment(ChatController.self) private var chat
    @Environment(AppNavigator.self) private var navigator
    let automation: AutomationSummary

    var body: some View {
        Section("Health") {
            let streak = automation.failureStreak
            if streak.failures == 0 {
                Text("No recent failures.").foregroundStyle(.secondary)
            } else {
                Label(
                    "Failed \(streak.failures) time\(streak.failures == 1 ? "" : "s") in a row"
                        + (streak.isBroken ? " — marked broken" : ""),
                    systemImage: streak.isBroken ? "exclamationmark.octagon" : "exclamationmark.triangle"
                )
                .foregroundStyle(streak.isBroken ? Color.red : Color.orange)
                if let lastError = streak.lastError {
                    Text(lastError)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Fix with Agent") { fixWithAgent() }
                    .disabled(chat.isRunning)
                if chat.isRunning {
                    Text("The agent is busy with another conversation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Opens a new chat with this automation and its recent failures. "
                 + "The fix goes through the usual draft, validate and approve steps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fixWithAgent() {
        let message = FixRequest.message(for: automation, recentRuns: catalog.runs(for: automation.id))
        chat.startConversation(with: message)
        navigator.selection = .chat
    }
}
