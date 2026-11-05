import AppIntents
import Foundation
import Shared

/// Runs one installed automation through the background runner, without bringing the app
/// forward. Shortcuts lists it as the "Run Automation" action; `AutomationAgentShortcuts`
/// exposes it to Spotlight and Siri.
struct RunAutomationIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Automation"
    static let openAppWhenRun = false

    @Parameter(title: "Automation", requestValueDialog: "Which automation?")
    var automation: AutomationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$automation)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await Self.run(automation)
        return .result(value: message, dialog: "\(message)")
    }

    /// Sends `.run(id:)` and turns the run record into one sentence. A failed run throws, so
    /// Shortcuts shows the error and a multi-step shortcut stops there.
    private static func run(_ automation: AutomationEntity) async throws -> String {
        let reply: RunnerReply
        do {
            reply = try await RunnerClient().send(.run(id: automation.id))
        } catch {
            throw AutomationIntentError.runner(error.localizedDescription)
        }
        switch reply {
        case .ran(let record):
            if record.outcome == .succeeded {
                return "Ran \(automation.name)."
            }
            if record.outcome == .skipped {
                return "\(automation.name) was skipped."
            }
            throw AutomationIntentError.failed(name: automation.name, reason: record.error ?? "unknown error")
        case .failure(let text):
            throw AutomationIntentError.failed(name: automation.name, reason: text)
        default:
            throw AutomationIntentError.unexpectedReply
        }
    }
}
