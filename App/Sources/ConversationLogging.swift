import AgentCore
import Foundation
import Shared

/// Where chat transcripts go: `~/Library/Application Support/AutomationAgent/conversations/`.
enum ConversationLogs {
    static var directory: URL {
        AutomationStore.defaultRoot().appending(path: "conversations", directoryHint: .isDirectory)
    }

    /// The facts about this app that a transcript needs to be read later.
    static var environment: [String: JSONValue] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "appVersion": .string(info["CFBundleShortVersionString"] as? String ?? ""),
            "appBuild": .string(info["CFBundleVersion"] as? String ?? ""),
            "osVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString)
        ]
    }
}

extension InteractionRequest {
    /// Everything the card shows, for the conversation log.
    var logJSON: JSONValue {
        switch self {
        case .runSnippet(let snippet):
            [
                "kind": "run_snippet",
                "language": .string(snippet.language.rawValue),
                "source": .string(snippet.source),
                "timeout": .double(snippet.timeout)
            ]
        case .install(let install):
            [
                "kind": "install",
                "draftID": .string(install.draftID),
                "summary": .string(install.summary),
                "name": .string(install.name),
                "trigger": .string(install.trigger),
                "permissions": .array(install.permissions.map(JSONValue.string)),
                "destructive": .bool(install.destructive),
                "parseProblem": install.parseProblem.map(JSONValue.string) ?? .null,
                "rawManifest": .string(install.rawManifest),
                "otherFiles": .array(install.otherFiles.map { .string($0.path) }),
                "report": install.report.flatMap(JSONValue.init(encoding:)) ?? .null,
                "canApprove": .bool(install.canApprove)
            ]
        case .setStatus(let status):
            [
                "kind": "set_status",
                "automationID": .string(status.automationID),
                "action": .string(status.action),
                "commit": status.commit.map(JSONValue.string) ?? .null
            ]
        case .question(let question):
            [
                "kind": "question",
                "question": .string(question.question),
                "questionKind": .string(question.kind.rawValue),
                "options": .array(question.options.map(JSONValue.string))
            ]
        }
    }
}

extension InteractionAnswer {
    var logJSON: JSONValue {
        switch self {
        case .approved: ["answer": "approved"]
        case .declined(let note): ["answer": "declined", "note": .string(note)]
        case .answered(let text): ["answer": "answered", "text": .string(text)]
        case .cancelled: ["answer": "cancelled"]
        }
    }
}

extension JSONValue {
    /// Any `Encodable` value as JSON, or nil if it cannot be encoded.
    init?(encoding value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let json = try? JSONValue.parse(data) else { return nil }
        self = json
    }
}
