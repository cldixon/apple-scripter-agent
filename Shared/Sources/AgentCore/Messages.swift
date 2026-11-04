import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

/// One content block, kept as its raw JSON object. Blocks Claude returns are stored as
/// received and sent back unchanged, whatever their type: preserved thinking requires
/// thinking blocks (and everything before them) to be byte-for-byte what the API produced.
public struct ContentBlock: Sendable, Equatable, Codable {
    public let fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public var type: String { fields["type"]?.stringValue ?? "" }

    /// The text of a `text` block.
    public var text: String? {
        type == "text" ? fields["text"]?.stringValue : nil
    }

    /// The call a `tool_use` block asks for.
    public var toolUse: ToolUse? {
        guard type == "tool_use",
              let id = fields["id"]?.stringValue,
              let name = fields["name"]?.stringValue
        else { return nil }
        return ToolUse(id: id, name: name, input: fields["input"] ?? .object([:]))
    }

    public var json: JSONValue { .object(fields) }

    public static func text(_ text: String) -> ContentBlock {
        ContentBlock(fields: ["type": "text", "text": .string(text)])
    }

    public static func toolResult(toolUseID: String, content: String, isError: Bool) -> ContentBlock {
        var fields: [String: JSONValue] = [
            "type": "tool_result",
            "tool_use_id": .string(toolUseID),
            "content": .string(content)
        ]
        if isError {
            fields["is_error"] = true
        }
        return ContentBlock(fields: fields)
    }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let object = value.objectValue, object["type"]?.stringValue != nil else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "A content block needs a string \"type\"."
            )
            throw DecodingError.dataCorrupted(context)
        }
        fields = object
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// A tool call Claude requested.
public struct ToolUse: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// One turn in the Messages API `messages` array.
public struct APIMessage: Sendable, Equatable, Codable {
    public var role: MessageRole
    public var content: [ContentBlock]

    public init(role: MessageRole, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public var json: JSONValue {
        .object(["role": .string(role.rawValue), "content": .array(content.map(\.json))])
    }
}

/// The conversation sent to Claude. Append-only: earlier turns are never edited or removed,
/// which keeps the prompt cache warm and earlier thinking blocks valid.
public struct Conversation: Sendable, Equatable {
    public private(set) var messages: [APIMessage] = []
    /// Tokens used by every request in this conversation.
    public private(set) var usage = TokenUsage()
    /// Estimated cost of every request in this conversation, in US dollars.
    public private(set) var costUSD: Double = 0

    public init() {}

    public mutating func appendUserText(_ text: String) {
        messages.append(APIMessage(role: .user, content: [.text(text)]))
    }

    mutating func append(_ message: APIMessage) {
        guard !message.content.isEmpty else { return }
        messages.append(message)
    }

    mutating func record(usage added: TokenUsage, costUSD addedCost: Double) {
        usage += added
        costUSD += addedCost
    }
}
