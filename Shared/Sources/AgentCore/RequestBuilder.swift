import Foundation

/// Settings for one agent run.
public struct AgentConfiguration: Sendable, Equatable {
    public var model: String
    public var effort: Effort
    /// Thinking counts toward this, so it has room for thinking plus the reply.
    public var maxTokens: Int
    /// Tool rounds allowed per user message before the loop stops.
    public var maxToolRounds: Int
    /// The loop stops once the conversation's estimated cost reaches this.
    public var spendCapUSD: Double
    public var serverSideFallback: Bool
    public var systemPrompt: String

    public init(
        model: String = ClaudeModel.defaultModel.rawValue,
        effort: Effort = .defaultEffort,
        maxTokens: Int = 64_000,
        maxToolRounds: Int = 40,
        spendCapUSD: Double = 2,
        serverSideFallback: Bool = true,
        systemPrompt: String = AgentPrompt.system
    ) {
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.maxToolRounds = maxToolRounds
        self.spendCapUSD = spendCapUSD
        self.serverSideFallback = serverSideFallback
        self.systemPrompt = systemPrompt
    }

    /// `anthropic-beta` values the request needs.
    public var betas: [String] {
        serverSideFallback ? [ClaudeAPI.serverSideFallbackBeta] : []
    }
}

/// Builds the streaming Messages request body.
///
/// Caching layout (the prompt renders tools, then system, then messages):
/// 1. `cache_control` on the last tool definition: the tool list is the most stable part.
/// 2. `cache_control` on the system prompt block (caches tools + system together).
/// 3. Top-level automatic `cache_control`, which moves the breakpoint to the end of the
///    growing conversation each request. Messages themselves are never edited for caching.
///
/// No `temperature`/`top_p`/`top_k` (removed in API version 2026-10-21), no `tool_choice`
/// (the default `auto`; forced choices are rejected by these models), and no assistant prefill.
public enum RequestBuilder {
    public static func body(
        configuration: AgentConfiguration,
        tools: [JSONValue],
        messages: [APIMessage]
    ) -> JSONValue {
        let ephemeral: JSONValue = ["type": "ephemeral"]
        var toolDefinitions = tools
        if let last = toolDefinitions.indices.last, var definition = toolDefinitions[last].objectValue {
            definition["cache_control"] = ephemeral
            toolDefinitions[last] = .object(definition)
        }
        let systemBlock: JSONValue = [
            "type": "text",
            "text": .string(configuration.systemPrompt),
            "cache_control": ephemeral
        ]
        let outputConfig: JSONValue = ["effort": .string(configuration.effort.rawValue)]
        var body: [String: JSONValue] = [
            "model": .string(configuration.model),
            "max_tokens": .int(configuration.maxTokens),
            "stream": true,
            "system": .array([systemBlock]),
            "thinking": ["type": "adaptive"],
            "output_config": outputConfig,
            "cache_control": ephemeral,
            "messages": .array(messages.map(\.json))
        ]
        if !toolDefinitions.isEmpty {
            body["tools"] = .array(toolDefinitions)
        }
        if configuration.serverSideFallback {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }
}

/// A request handed to a transport: the JSON body and the betas for `anthropic-beta`.
public struct MessagesRequest: Sendable, Equatable {
    public var body: Data
    public var betas: [String]

    public init(body: Data, betas: [String]) {
        self.body = body
        self.betas = betas
    }
}

/// Sends a streaming Messages request and yields the response's lines (blank lines included).
/// The app's transport adds the API key and talks HTTP; tests script the lines.
/// A non-2xx status is thrown as `ClaudeAPIError.http`.
public protocol MessagesTransport: Sendable {
    func lines(for request: MessagesRequest) async throws -> AsyncThrowingStream<String, any Error>
}
