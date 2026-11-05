import Foundation
import Synchronization

/// A complete, append-only record of one chat conversation, written as JSON Lines.
///
/// One file per conversation. Each line is `{"seq", "time", "type", ...}`:
/// - `request`: the request settings (system prompt, tools, model, effort...) when they
///   change, and every message added to the conversation since the previous request.
/// - `response`: the response exactly as assembled from the stream (thinking included), with
///   stop reason, usage, cost and timing; `response_failed` keeps any partial output.
/// - `tool_call` / `tool_result`: input, output, error flag and timing.
/// - `stop`: why the agent loop ended.
/// - Anything the app records with `record(_:_:)`: user messages, cards and their answers,
///   notices.
///
/// Writes are synchronous and serialized, so lines land in the order they are recorded
/// whichever actor records them. A failed write is dropped: logging never stops the chat.
/// Nothing here sees the API key, so it cannot reach the file.
public final class ConversationLog: Sendable {
    public let id: UUID
    public let fileURL: URL

    private struct State {
        var handle: FileHandle?
        var sequence = 0
        /// Messages already written by earlier `request` lines.
        var loggedMessageCount = 0
        /// The last request body without `messages`, so unchanged settings are written once.
        var lastSettings: JSONValue?
    }

    private let state: Mutex<State>

    /// Creates `<directory>/<date>-<id prefix>.jsonl`, readable only by the user.
    public init(directory: URL, id: UUID = UUID(), date: Date = Date()) throws {
        self.id = id
        let stamp = date.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let prefix = id.uuidString.prefix(8).lowercased()
        fileURL = directory.appending(path: "\(stamp)-\(prefix).jsonl")
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path]) }
        let handle = try FileHandle(forWritingTo: fileURL)
        state = Mutex(State(handle: handle))
    }

    /// Appends one line.
    public func record(_ type: String, _ fields: [String: JSONValue] = [:]) {
        state.withLock { state in
            write(type, fields, state: &state)
        }
    }

    /// Stops writing. Later records are ignored.
    public func close() {
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
        }
    }

    private func write(_ type: String, _ fields: [String: JSONValue], state: inout State) {
        guard let handle = state.handle else { return }
        state.sequence += 1
        var entry = fields
        entry["seq"] = .int(state.sequence)
        entry["time"] = .string(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date()))
        entry["type"] = .string(type)
        guard var data = try? JSONValue.object(entry).encoded() else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    // MARK: Agent loop

    func recordRequest(body: JSONValue, byteCount: Int) {
        state.withLock { state in
            var settings = body.objectValue ?? [:]
            let messages = settings.removeValue(forKey: "messages")?.arrayValue ?? []
            let start = messages.count >= state.loggedMessageCount ? state.loggedMessageCount : 0
            var fields: [String: JSONValue] = [
                "messageCount": .int(messages.count),
                "newMessages": .array(Array(messages[start...])),
                "bodyBytes": .int(byteCount)
            ]
            let settingsValue = JSONValue.object(settings)
            if settingsValue != state.lastSettings {
                fields["settings"] = settingsValue
                state.lastSettings = settingsValue
            }
            state.loggedMessageCount = messages.count
            write("request", fields, state: &state)
        }
    }

    func recordResponse(_ response: AssistantResponse, costUSD: Double, duration: Duration) {
        var fields: [String: JSONValue] = [
            "content": .array(response.content.map(\.json)),
            "stopReason": response.stopReason.map(JSONValue.string) ?? .null,
            "model": response.model.map(JSONValue.string) ?? .null,
            "usage": response.usage.json,
            "costUSD": .double(costUSD),
            "durationMS": .int(duration.milliseconds)
        ]
        if let details = response.stopDetails {
            fields["stopDetails"] = details
        }
        if !response.invalidToolInputs.isEmpty {
            fields["invalidToolInputs"] = .object(response.invalidToolInputs.mapValues(JSONValue.string))
        }
        record("response", fields)
    }

    func recordResponseFailure(_ error: any Error, partial: [ContentBlock], duration: Duration) {
        record("response_failed", [
            "error": .string(error.localizedDescription),
            "errorDetail": .string(String(describing: error)),
            "partialContent": .array(partial.map(\.json)),
            "durationMS": .int(duration.milliseconds)
        ])
    }

    func recordToolResult(_ use: ToolUse, output: String, isError: Bool, duration: Duration) {
        record("tool_result", [
            "id": .string(use.id),
            "name": .string(use.name),
            "output": .string(output),
            "isError": .bool(isError),
            "durationMS": .int(duration.milliseconds)
        ])
    }

    func recordStop(_ stop: AgentStop, conversation: Conversation) {
        record("stop", [
            "reason": .string(stop.logDescription),
            "totalUsage": conversation.usage.json,
            "totalCostUSD": .double(conversation.costUSD),
            "messageCount": .int(conversation.messages.count)
        ])
    }
}

extension TokenUsage {
    var json: JSONValue {
        [
            "input_tokens": .int(inputTokens),
            "output_tokens": .int(outputTokens),
            "cache_read_input_tokens": .int(cacheReadInputTokens),
            "cache_creation_input_tokens": .int(cacheCreationInputTokens)
        ]
    }
}

extension AgentStop {
    var logDescription: String {
        switch self {
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .refused(let category): "refused" + (category.map { " (\($0))" } ?? "")
        case .maxTokens: "max_tokens"
        case .spendCapReached(let cap): "spend_cap_reached (\(cap))"
        case .maxToolRoundsReached(let rounds): "max_tool_rounds_reached (\(rounds))"
        case .failed(let message): "failed: \(message)"
        }
    }
}

extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
