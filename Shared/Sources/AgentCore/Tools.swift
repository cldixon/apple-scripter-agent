import Foundation

/// A client-side tool the agent can call. `run` gets input already checked against
/// `inputSchema`; whatever it returns (or the error it throws) goes back to Claude as the
/// tool result, so never return secrets from a tool.
public protocol AgentTool: Sendable {
    var name: String { get }
    /// Say when to call the tool, not only what it does: Claude picks tools from this.
    var description: String { get }
    /// A JSON Schema object for the input.
    var inputSchema: JSONValue { get }
    func run(input: JSONValue) async throws -> String
}

/// An error a tool throws with a message meant for Claude.
public struct ToolError: Error, Sendable, Equatable, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The tools offered to Claude, sorted by name so the `tools` array (the start of the cached
/// prompt prefix) serializes the same way every time. Keep the set fixed for a conversation:
/// changing it invalidates the cache and earlier thinking blocks.
public struct ToolRegistry: Sendable {
    public let tools: [any AgentTool]

    public init(_ tools: [any AgentTool]) {
        self.tools = tools.sorted { $0.name < $1.name }
    }

    public func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.name == name }
    }

    /// Tool definitions for the request. With streaming, `eager_input_streaming` streams input
    /// as it is generated; the input is then validated here before a tool runs.
    public func definitions(eagerInputStreaming: Bool) -> [JSONValue] {
        tools.map { tool in
            var definition: [String: JSONValue] = [
                "name": .string(tool.name),
                "description": .string(tool.description),
                "input_schema": tool.inputSchema
            ]
            if eagerInputStreaming {
                definition["eager_input_streaming"] = true
            }
            return .object(definition)
        }
    }
}

/// Checks tool input against the subset of JSON Schema the tools use: an object with typed
/// `properties`, `required` keys, `enum` values and `additionalProperties: false`.
public enum SchemaValidator {
    public static func validate(_ input: JSONValue, against schema: JSONValue) -> [String] {
        guard let object = input.objectValue else {
            return ["The input must be a JSON object."]
        }
        let properties = schema["properties"]?.objectValue ?? [:]
        var problems: [String] = []
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
            problems.append("Missing required property \"\(key)\".")
        }
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            guard let propertySchema = properties[key] else {
                if schema["additionalProperties"]?.boolValue == false {
                    problems.append("Unknown property \"\(key)\".")
                }
                continue
            }
            if let type = propertySchema["type"]?.stringValue, !matches(value, type: type) {
                problems.append("Property \"\(key)\" must be of type \(type).")
            }
            if let options = propertySchema["enum"]?.arrayValue, !options.contains(value) {
                problems.append("Property \"\(key)\" must be one of \(JSONValue.array(options).compactText).")
            }
        }
        return problems
    }

    static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("integer", .int), ("array", .array),
             ("object", .object), ("null", .null), ("number", .int), ("number", .double):
            true
        case ("integer", .double(let number)):
            number.rounded() == number
        default:
            false
        }
    }
}

/// A stub tool that returns its input text. It exists so the tool round trip can be tested
/// end to end before M5 adds the real tools.
public struct EchoTool: AgentTool {
    public let name = "echo"
    public let description = """
        Returns the text you give it, unchanged. Use it only when the user asks you to test \
        the tool connection.
        """

    public init() {}

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "The text to send back."]
            ],
            "required": ["text"],
            "additionalProperties": false
        ]
    }

    public func run(input: JSONValue) async throws -> String {
        guard let text = input["text"]?.stringValue else {
            throw ToolError("Missing \"text\".")
        }
        return text
    }
}
