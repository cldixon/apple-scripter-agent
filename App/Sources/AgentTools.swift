import AgentCore
import Foundation
import Shared

/// The tools offered to Claude. M5 adds the drafting, validation and install tools here.
/// The set must stay the same for the whole of a conversation (see `ToolRegistry`).
enum AgentToolbox {
    static func registry() -> ToolRegistry {
        ToolRegistry([
            ListAutomationsTool(),
            EchoTool()
        ])
    }
}

/// Lists installed automations by asking the runner. Read-only.
struct ListAutomationsTool: AgentTool {
    let name = "list_automations"
    let description = """
        Lists the automations installed on this Mac: id, name, trigger, whether each is active, \
        and any validation problems. Call it whenever the person asks what is installed, before \
        suggesting a new automation (to avoid duplicates), or when they refer to an existing one.
        """

    var inputSchema: JSONValue {
        ["type": "object", "properties": [:], "additionalProperties": false]
    }

    func run(input: JSONValue) async throws -> String {
        let reply = try await RunnerClient().send(.listAutomations, timeout: 10)
        switch reply {
        case .automations(let summaries, let paused):
            let items = summaries.map { summary in
                AutomationListing.Item(
                    id: summary.id,
                    name: summary.name,
                    description: summary.description,
                    trigger: summary.trigger,
                    active: summary.isActive,
                    version: summary.version,
                    stepTypes: summary.stepTypes,
                    issues: summary.issues.map { $0.description },
                    registrationError: summary.registrationError
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(AutomationListing(paused: paused, automations: items))
            return String(data: data, encoding: .utf8) ?? "{}"
        case .failure(let message):
            throw ToolError("The runner reported an error: \(message)")
        default:
            throw ToolError("The runner sent an unexpected reply.")
        }
    }
}

/// What `list_automations` returns, as JSON.
private struct AutomationListing: Encodable {
    struct Item: Encodable {
        var id: String
        var name: String
        var description: String?
        var trigger: String
        var active: Bool
        var version: Int
        var stepTypes: [String]
        var issues: [String]
        var registrationError: String?
    }

    var paused: Bool
    var automations: [Item]
}
