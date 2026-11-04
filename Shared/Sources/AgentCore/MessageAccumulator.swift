import Foundation

/// A complete assistant response assembled from a stream.
public struct AssistantResponse: Sendable, Equatable {
    /// The content blocks, in order, as the API produced them (see `MessageAccumulator`).
    public var content: [ContentBlock]
    public var stopReason: String?
    public var stopDetails: JSONValue?
    public var usage: TokenUsage
    /// The model that produced the message; a server-side fallback can make this differ
    /// from the requested model.
    public var model: String?
    /// Tool calls whose streamed input was not valid JSON, by tool use id, with the raw text.
    public var invalidToolInputs: [String: String]

    public var toolUses: [ToolUse] {
        content.compactMap(\.toolUse)
    }

    /// `stop_details.category` of a refusal; informational only, and can be absent.
    public var refusalCategory: String? {
        stopDetails?["category"]?.stringValue
    }
}

/// Folds streaming events into a final message.
///
/// Blocks start as the `content_block_start` object and grow with each delta: text, thinking
/// and signature deltas append to their fields, and `input_json_delta` fragments are joined and
/// parsed when the block stops. Block types and delta types this client does not know are kept
/// (or skipped) without failing, so new block types still round-trip.
public struct MessageAccumulator: Sendable {
    private var blocks: [Int: [String: JSONValue]] = [:]
    private var order: [Int] = []
    private var partialJSON: [Int: String] = [:]
    private var invalidToolInputs: [String: String] = [:]
    private var stopDetails: JSONValue?
    public private(set) var usage = TokenUsage()
    public private(set) var model: String?
    public private(set) var stopReason: String?
    public private(set) var isComplete = false

    public init() {}

    /// Applies one event. Returns new visible text, if the event carried some.
    @discardableResult
    public mutating func apply(_ event: StreamEvent) throws -> String? {
        switch event {
        case .messageStart(let model, let usage):
            self.model = model
            if let usage { self.usage.apply(usage) }
        case .contentBlockStart(let index, let block):
            if blocks[index] == nil { order.append(index) }
            blocks[index] = block.objectValue ?? [:]
        case .contentBlockDelta(let index, let delta):
            return applyDelta(delta, at: index)
        case .contentBlockStop(let index):
            finishBlock(at: index)
        case .messageDelta(let delta, let usage):
            if let reason = delta["stop_reason"]?.stringValue { stopReason = reason }
            if let details = delta["stop_details"], details != .null { stopDetails = details }
            if let usage { self.usage.apply(usage) }
        case .messageStop:
            isComplete = true
        case .ping, .unknown:
            break
        case .error(let type, let message):
            throw ClaudeAPIError.stream(type: type, message: message)
        }
        return nil
    }

    public func finish() -> AssistantResponse {
        let content = order.compactMap { blocks[$0] }.map { ContentBlock(fields: $0) }
        return AssistantResponse(
            content: Self.contentForHistory(content),
            stopReason: stopReason,
            stopDetails: stopDetails,
            usage: usage,
            model: model,
            invalidToolInputs: invalidToolInputs
        )
    }

    private mutating func applyDelta(_ delta: JSONValue, at index: Int) -> String? {
        guard var block = blocks[index] else { return nil }
        defer { blocks[index] = block }
        switch delta["type"]?.stringValue {
        case "text_delta":
            let text = delta["text"]?.stringValue ?? ""
            block["text"] = .string((block["text"]?.stringValue ?? "") + text)
            return text
        case "input_json_delta":
            partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
        case "thinking_delta":
            let thinking = delta["thinking"]?.stringValue ?? ""
            block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + thinking)
        case "signature_delta":
            block["signature"] = .string((block["signature"]?.stringValue ?? "")
                + (delta["signature"]?.stringValue ?? ""))
        case "citations_delta":
            if let citation = delta["citation"] {
                block["citations"] = .array((block["citations"]?.arrayValue ?? []) + [citation])
            }
        default:
            break
        }
        return nil
    }

    /// Parses a tool call's joined input fragments. Invalid JSON leaves `input` as `{}` and is
    /// recorded so the tool is not run and Claude gets an error result instead.
    private mutating func finishBlock(at index: Int) {
        guard let json = partialJSON.removeValue(forKey: index), var block = blocks[index] else { return }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            block["input"] = block["input"] ?? .object([:])
        } else if let parsed = try? JSONValue.parse(trimmed), parsed.objectValue != nil {
            block["input"] = parsed
        } else {
            block["input"] = .object([:])
            if let id = block["id"]?.stringValue {
                invalidToolInputs[id] = json
            }
        }
        blocks[index] = block
    }

    /// After a mid-output server-side fallback, the declined model's thinking and tool calls
    /// before the last `fallback` block must not be sent back; text and the markers stay.
    static func contentForHistory(_ content: [ContentBlock]) -> [ContentBlock] {
        guard let boundary = content.lastIndex(where: { $0.type == "fallback" }) else { return content }
        return content.enumerated().compactMap { offset, block in
            if offset >= boundary || block.type == "text" || block.type == "fallback" {
                return block
            }
            return nil
        }
    }
}
