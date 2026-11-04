import AgentCore
import Foundation
import Shared

/// What the tools share with the chat: the card center they wait on, the drafts written in this
/// conversation, and the catalog to refresh after a change. All main-actor objects, so Sendable.
struct ToolContext: Sendable {
    let interactions: InteractionCenter
    let drafts: DraftStore
    let catalog: CatalogController?
}

/// The tools offered to Claude and the system prompt. The set must stay the same for the whole
/// of a conversation (see `ToolRegistry`).
enum AgentToolbox {
    static func registry(context: ToolContext) -> ToolRegistry {
        ToolRegistry([
            // Research
            SearchReferenceTool(),
            ReadReferenceTool(),
            IntrospectAppTool(),
            ListAppsTool(),
            ListShortcutsTool(),
            CheckPermissionsTool(),
            FetchURLTool(),
            RunSnippetTool(context: context),
            // Catalog
            SearchCatalogTool(),
            ReadAutomationTool(),
            ReadRunLogTool(),
            SetStatusTool(context: context),
            // Drafting
            WriteDraftTool(context: context),
            ValidateTool(context: context),
            RequestInstallTool(context: context),
            AskUserTool(context: context)
        ])
    }

    /// AgentCore's base prompt plus the manifest schema. Fixed text, so it caches.
    static let systemPrompt = AgentPrompt.assembled(manifestSchema: ManifestSchema.json)
}

/// Sending runner commands from tools, with errors phrased for Claude.
enum RunnerTool {
    static func send(_ command: RunnerCommand, timeout: Double = 30) async throws -> RunnerReply {
        let reply: RunnerReply
        do {
            reply = try await RunnerClient().send(command, timeout: timeout)
        } catch {
            throw ToolError("Could not reach the runner: \(error.localizedDescription)")
        }
        if case .failure(let message) = reply {
            throw ToolError("The runner reported an error: \(message)")
        }
        return reply
    }

    static func unexpected(_ reply: RunnerReply) -> ToolError {
        ToolError("The runner sent an unexpected reply (\(String(describing: reply).prefix(80))).")
    }

    /// The error a tool throws when the user pressed Stop or New Conversation at a card.
    static let cancelled = ToolError("Cancelled: the user stopped the agent before answering.")
}

/// An input schema for an object with these properties.
func objectSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    [
        "type": "object",
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
        "additionalProperties": false
    ]
}
