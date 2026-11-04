import Foundation

/// What the loop reports while it runs, in order.
public enum AgentEvent: Sendable, Equatable {
    /// A new model response began streaming.
    case responseStarted
    /// Visible text from the current response.
    case textDelta(String)
    /// The current response's streamed output was dropped (refusal, Stop, or an error) and is
    /// not part of the conversation.
    case responseDiscarded
    case toolCall(id: String, name: String, input: String)
    case toolResult(id: String, output: String, isError: Bool)
    /// Totals for the whole conversation after a response.
    case usageUpdated(TokenUsage, costUSD: Double)
}

/// Why the loop stopped.
public enum AgentStop: Sendable, Equatable {
    case completed
    case cancelled
    case refused(category: String?)
    case maxTokens
    case spendCapReached(capUSD: Double)
    case maxToolRoundsReached(Int)
    case failed(String)
}

public struct AgentRunResult: Sendable, Equatable {
    public var conversation: Conversation
    public var stop: AgentStop
}

/// The agent loop: send the conversation, stream the reply, run any requested tools, send all
/// their results back in one user message, and repeat until Claude ends its turn, the task is
/// cancelled, Claude declines, or a cap is reached.
///
/// The conversation stays valid for the next request whatever happens: a `tool_use` that will
/// not run still gets an error `tool_result`, and partial output from a declined or cancelled
/// response is never appended.
public struct AgentRunner: Sendable {
    public typealias Emit = @Sendable (AgentEvent) async -> Void

    public let transport: any MessagesTransport
    public let tools: ToolRegistry
    public let configuration: AgentConfiguration

    /// Tool output beyond this many characters is cut, to keep the context small.
    static let maxToolOutputLength = 50_000

    public init(transport: any MessagesTransport, tools: ToolRegistry, configuration: AgentConfiguration) {
        self.transport = transport
        self.tools = tools
        self.configuration = configuration
    }

    /// Runs until the turn ends. Cancel the calling task to stop.
    public func run(_ conversation: Conversation, emit: Emit) async -> AgentRunResult {
        var state = conversation
        var toolRounds = 0
        while true {
            if Task.isCancelled {
                return AgentRunResult(conversation: state, stop: .cancelled)
            }
            if state.costUSD >= configuration.spendCapUSD {
                let stop = AgentStop.spendCapReached(capUSD: configuration.spendCapUSD)
                return AgentRunResult(conversation: state, stop: stop)
            }
            let response: AssistantResponse
            do {
                response = try await streamResponse(for: state, emit: emit)
            } catch {
                await emit(.responseDiscarded)
                let stop: AgentStop = Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed(error.localizedDescription)
                return AgentRunResult(conversation: state, stop: stop)
            }
            let pricing = ClaudeModel.pricing(forModelID: response.model ?? configuration.model)
            state.record(usage: response.usage, costUSD: pricing.cost(of: response.usage))
            await emit(.usageUpdated(state.usage, costUSD: state.costUSD))
            if let stop = await handle(response, state: &state, toolRounds: &toolRounds, emit: emit) {
                return AgentRunResult(conversation: state, stop: stop)
            }
        }
    }

    /// Acts on a finished response. Returns nil to send the next request.
    private func handle(
        _ response: AssistantResponse,
        state: inout Conversation,
        toolRounds: inout Int,
        emit: Emit
    ) async -> AgentStop? {
        // Check the stop reason before reading content: a refusal can cut a tool call off.
        switch response.stopReason {
        case "refusal":
            await emit(.responseDiscarded)
            return .refused(category: response.refusalCategory)
        case "tool_use":
            state.append(APIMessage(role: .assistant, content: response.content))
            return await runToolRound(response, state: &state, toolRounds: &toolRounds, emit: emit)
        case "pause_turn":
            // A server-side loop paused; sending the conversation back resumes it.
            state.append(APIMessage(role: .assistant, content: response.content))
            toolRounds += 1
            let limit = configuration.maxToolRounds
            return toolRounds > limit ? .maxToolRoundsReached(limit) : nil
        case "max_tokens":
            state.append(APIMessage(role: .assistant, content: response.content))
            closeToolUses(response.toolUses, in: &state, reason: "Not run: the reply hit the output token limit.")
            return .maxTokens
        default:
            state.append(APIMessage(role: .assistant, content: response.content))
            closeToolUses(response.toolUses, in: &state, reason: "Not run: the turn ended.")
            return .completed
        }
    }

    private func runToolRound(
        _ response: AssistantResponse,
        state: inout Conversation,
        toolRounds: inout Int,
        emit: Emit
    ) async -> AgentStop? {
        let uses = response.toolUses
        guard !uses.isEmpty else { return .completed }
        if state.costUSD >= configuration.spendCapUSD {
            closeToolUses(uses, in: &state, reason: "Not run: the conversation reached its spend cap.")
            return .spendCapReached(capUSD: configuration.spendCapUSD)
        }
        if toolRounds >= configuration.maxToolRounds {
            closeToolUses(uses, in: &state, reason: "Not run: too many tool rounds for one message.")
            return .maxToolRoundsReached(configuration.maxToolRounds)
        }
        toolRounds += 1
        var results: [ContentBlock] = []
        for use in uses {
            if Task.isCancelled {
                let reason = "Not run: the user stopped the agent."
                results.append(.toolResult(toolUseID: use.id, content: reason, isError: true))
                continue
            }
            await emit(.toolCall(id: use.id, name: use.name, input: use.input.compactText))
            let outcome = await execute(use, invalidInput: response.invalidToolInputs[use.id])
            await emit(.toolResult(id: use.id, output: outcome.output, isError: outcome.isError))
            results.append(.toolResult(toolUseID: use.id, content: outcome.output, isError: outcome.isError))
        }
        // Every result goes back in one user message.
        state.append(APIMessage(role: .user, content: results))
        return Task.isCancelled ? .cancelled : nil
    }

    private struct ToolOutcome {
        var output: String
        var isError: Bool
    }

    private func execute(_ use: ToolUse, invalidInput: String?) async -> ToolOutcome {
        if let invalidInput {
            let wrapped = JSONValue.object(["INVALID_JSON": .string(invalidInput)]).compactText
            return ToolOutcome(output: wrapped, isError: true)
        }
        guard let tool = tools.tool(named: use.name) else {
            let names = tools.tools.map(\.name).joined(separator: ", ")
            return ToolOutcome(output: "Unknown tool \"\(use.name)\". Available tools: \(names).", isError: true)
        }
        let problems = SchemaValidator.validate(use.input, against: tool.inputSchema)
        guard problems.isEmpty else {
            return ToolOutcome(output: "Invalid input: " + problems.joined(separator: " "), isError: true)
        }
        do {
            let output = try await tool.run(input: use.input)
            return ToolOutcome(output: Self.truncated(output), isError: false)
        } catch {
            return ToolOutcome(output: error.localizedDescription, isError: true)
        }
    }

    /// Answers tool calls that will not run, so the next request is still valid.
    private func closeToolUses(_ uses: [ToolUse], in state: inout Conversation, reason: String) {
        guard !uses.isEmpty else { return }
        let results = uses.map { ContentBlock.toolResult(toolUseID: $0.id, content: reason, isError: true) }
        state.append(APIMessage(role: .user, content: results))
    }

    private func streamResponse(for state: Conversation, emit: Emit) async throws -> AssistantResponse {
        let body = RequestBuilder.body(
            configuration: configuration,
            tools: tools.definitions(eagerInputStreaming: true),
            messages: state.messages
        )
        let encodedBody = try body.encoded()
        let request = MessagesRequest(body: encodedBody, betas: configuration.betas)
        let lines = try await transport.lines(for: request)
        await emit(.responseStarted)
        var parser = SSEParser()
        var accumulator = MessageAccumulator()
        for try await line in lines {
            if let event = parser.feed(line) {
                try await apply(event, to: &accumulator, emit: emit)
            }
        }
        if let event = parser.finish() {
            try await apply(event, to: &accumulator, emit: emit)
        }
        try Task.checkCancellation()
        guard accumulator.isComplete else { throw ClaudeAPIError.incompleteStream }
        return accumulator.finish()
    }

    private func apply(_ event: SSEEvent, to accumulator: inout MessageAccumulator, emit: Emit) async throws {
        let streamEvent = try StreamEvent.parse(event.data)
        if let text = try accumulator.apply(streamEvent), !text.isEmpty {
            await emit(.textDelta(text))
        }
    }

    static func truncated(_ output: String) -> String {
        guard output.count > maxToolOutputLength else { return output }
        return String(output.prefix(maxToolOutputLength)) + "\n[Output truncated.]"
    }
}
