@testable import AgentCore
import Foundation
import Testing

struct RequestBuilderTests {
    private struct ListTool: AgentTool {
        let name = "list_things"
        let description = "Lists things."
        var inputSchema: JSONValue { ["type": "object", "properties": [:]] }
        func run(input: JSONValue) async throws -> String { "[]" }
    }

    private func buildBody(_ configuration: AgentConfiguration = AgentConfiguration()) throws -> JSONValue {
        var conversation = Conversation()
        conversation.appendUserText("Hello")
        let tools = ToolRegistry([ListTool(), EchoTool()])
        let body = RequestBuilder.body(
            configuration: configuration,
            tools: tools.definitions(eagerInputStreaming: true),
            messages: conversation.messages
        )
        // Through bytes and back, as the transport sends it.
        return try JSONValue.parse(body.encoded())
    }

    @Test func setsModelEffortThinkingStreamingAndFallbacks() throws {
        let body = try buildBody()
        #expect(body["model"]?.stringValue == "claude-opus-5-5")
        #expect(body["max_tokens"]?.intValue == 64_000)
        #expect(body["stream"]?.boolValue == true)
        let highEffort: JSONValue = ["effort": "high"]
        let adaptive: JSONValue = ["type": "adaptive", "display": "summarized"]
        #expect(body["output_config"] == highEffort)
        #expect(body["thinking"] == adaptive)
        #expect(body["fallbacks"]?.stringValue == "default")
        #expect(body["tool_choice"] == nil)
    }

    @Test func neverSendsSamplingParameters() throws {
        let body = try buildBody()
        for key in ["temperature", "top_p", "top_k"] {
            #expect(body[key] == nil)
        }
    }

    @Test func placesCacheBreakpointsOnLastToolSystemAndTopLevel() throws {
        let body = try buildBody()
        let ephemeral: JSONValue = ["type": "ephemeral"]
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.map { $0["name"]?.stringValue } == ["echo", "list_things"])
        #expect(tools[0]["cache_control"] == nil)
        #expect(tools[1]["cache_control"] == ephemeral)
        #expect(tools.allSatisfy { $0["eager_input_streaming"]?.boolValue == true })
        let system = try #require(body["system"]?.arrayValue)
        #expect(system.count == 1)
        #expect(system[0]["cache_control"] == ephemeral)
        #expect(system[0]["text"]?.stringValue == AgentPrompt.system)
        #expect(body["cache_control"] == ephemeral)
        // Messages are sent as stored, without markers added.
        let expectedMessages: JSONValue = [["role": "user", "content": [["type": "text", "text": "Hello"]]]]
        #expect(body["messages"] == expectedMessages)
    }

    @Test func honoursSettings() throws {
        let configuration = AgentConfiguration(model: "claude-sonnet-5-5", effort: .low, serverSideFallback: false)
        let body = try buildBody(configuration)
        #expect(body["model"]?.stringValue == "claude-sonnet-5-5")
        let lowEffort: JSONValue = ["effort": "low"]
        #expect(body["output_config"] == lowEffort)
        #expect(body["fallbacks"] == nil)
        #expect(configuration.betas.isEmpty)
        #expect(AgentConfiguration().betas == ["server-side-fallback-2026-07-01"])
    }

    @Test func encodingIsDeterministic() throws {
        let configuration = AgentConfiguration()
        let tools = ToolRegistry([EchoTool(), ListTool()]).definitions(eagerInputStreaming: true)
        let first = try RequestBuilder.body(configuration: configuration, tools: tools, messages: []).encoded()
        let second = try RequestBuilder.body(configuration: configuration, tools: tools, messages: []).encoded()
        #expect(first == second)
    }

    @Test func headersCarryVersionKeyAndBetas() {
        let headers = ClaudeAPI.headers(apiKey: "test-key", betas: ["server-side-fallback-2026-07-01"])
        #expect(headers["anthropic-version"] == "2026-10-21")
        #expect(headers["x-api-key"] == "test-key")
        #expect(headers["content-type"] == "application/json")
        #expect(headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        #expect(ClaudeAPI.headers(apiKey: "k")["anthropic-beta"] == nil)
    }

    @Test func readsAPIErrorBodies() {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        let error = ClaudeAPIError.fromHTTP(status: 401, body: body)
        #expect(error == .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
    }
}

struct PricingTests {
    @Test func opusPricing() {
        let pricing = ClaudeModel.opus55.pricing
        #expect(pricing.cost(of: TokenUsage(input: 1_000_000)) == 4)
        #expect(pricing.cost(of: TokenUsage(output: 1_000_000)) == 20)
        #expect(abs(pricing.cost(of: TokenUsage(cacheRead: 1_000_000)) - 0.20) < 1e-9)
        #expect(pricing.cost(of: TokenUsage(cacheCreation: 1_000_000)) == 5)
    }

    @Test func sonnetPricing() {
        let usage = TokenUsage(input: 10_000, output: 2_000, cacheRead: 50_000, cacheCreation: 4_000)
        // 10k x $2 + 2k x $10 + 50k x $0.20 + 4k x $2.50, per million.
        let expected = (10_000.0 * 2 + 2_000.0 * 10 + 50_000.0 * 0.2 + 4_000.0 * 2.5) / 1_000_000
        #expect(abs(ClaudeModel.sonnet55.pricing.cost(of: usage) - expected) < 1e-12)
    }

    @Test func unknownModelsArePricedHigh() {
        #expect(ClaudeModel.pricing(forModelID: "claude-opus-4-8") == ClaudeModel.opus55.pricing)
        #expect(ClaudeModel.pricing(forModelID: "claude-sonnet-5-5") == ClaudeModel.sonnet55.pricing)
    }

    @Test func usageAppliesLaterCounts() {
        var usage = TokenUsage()
        usage.apply(["input_tokens": 10, "cache_read_input_tokens": 5, "output_tokens": 1])
        usage.apply(["output_tokens": 30])
        #expect(usage == TokenUsage(input: 10, output: 30, cacheRead: 5, cacheCreation: 0))
        #expect((usage + usage).outputTokens == 60)
    }
}
