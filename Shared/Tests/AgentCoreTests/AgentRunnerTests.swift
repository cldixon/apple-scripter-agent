@testable import AgentCore
import Foundation
import Testing

struct AgentRunnerTests {
    private func makeRunner(
        _ transport: FakeTransport,
        configuration: AgentConfiguration = AgentConfiguration()
    ) -> AgentRunner {
        AgentRunner(transport: transport, tools: ToolRegistry([EchoTool()]), configuration: configuration)
    }

    private func startConversation() -> Conversation {
        var conversation = Conversation()
        conversation.appendUserText("Echo twice")
        return conversation
    }

    @Test func runsToolsAndSendsAllResultsInOneUserMessage() async throws {
        let transport = FakeTransport(responses: [
            Fixtures.toolUseResponse([
                (id: "toolu_a", input: #"{"text":"one"}"#),
                (id: "toolu_b", input: #"{"text":"two"}"#)
            ]),
            Fixtures.textResponse("Done.")
        ])
        let log = EventLog()
        let result = await makeRunner(transport).run(startConversation()) { await log.append($0) }

        #expect(result.stop == .completed)
        let bodies = try await transport.requestBodies()
        #expect(bodies.count == 2)

        // The second request carries the assistant turn exactly as streamed, then one user
        // message holding both results.
        let messages = try #require(bodies[1]["messages"]?.arrayValue)
        #expect(messages.count == 3)
        let assistant = try #require(messages[1]["content"]?.arrayValue)
        #expect(assistant.map { $0["type"]?.stringValue } == ["thinking", "tool_use", "tool_use"])
        #expect(assistant[0]["signature"]?.stringValue == "sig==")
        let firstInput: JSONValue = ["text": "one"]
        #expect(assistant[1]["input"] == firstInput)
        #expect(messages[2]["role"]?.stringValue == "user")
        let results = try #require(messages[2]["content"]?.arrayValue)
        #expect(results.map { $0["tool_use_id"]?.stringValue } == ["toolu_a", "toolu_b"])
        #expect(results.map { $0["content"]?.stringValue } == ["one", "two"])
        #expect(results.allSatisfy { $0["is_error"] == nil })

        // The final conversation: user, assistant, tool results, assistant.
        #expect(result.conversation.messages.map { $0.role } == [.user, .assistant, .user, .assistant])
        #expect(result.conversation.messages.last?.content.first?.text == "Done.")

        let events = await log.events
        #expect(events.contains(.toolCall(id: "toolu_a", name: "echo", input: #"{"text":"one"}"#)))
        #expect(events.contains(.toolResult(id: "toolu_b", output: "two", isError: false)))
        #expect(events.contains(.textDelta("Done.")))
    }

    @Test func tracksUsageAndCostAcrossRequests() async throws {
        let transport = FakeTransport(responses: [
            Fixtures.toolUseResponse([(id: "toolu_a", input: #"{"text":"x"}"#)], output: 50),
            Fixtures.textResponse("ok")
        ])
        let result = await makeRunner(transport).run(startConversation()) { _ in }
        let usage = result.conversation.usage
        #expect(usage.inputTokens == 200)
        #expect(usage.outputTokens == 60)
        let expected = ClaudeModel.opus55.pricing.cost(of: usage)
        #expect(abs(result.conversation.costUSD - expected) < 1e-12)
    }

    @Test func stopsAtTheSpendCapWithoutRunningTools() async throws {
        let transport = FakeTransport(responses: [
            Fixtures.toolUseResponse([(id: "toolu_a", input: #"{"text":"x"}"#)]),
            Fixtures.textResponse("never sent")
        ])
        let configuration = AgentConfiguration(spendCapUSD: 0.000_01)
        let log = EventLog()
        let result = await makeRunner(transport, configuration: configuration).run(startConversation()) {
            await log.append($0)
        }

        #expect(result.stop == .spendCapReached(capUSD: 0.000_01))
        #expect(await transport.requests.count == 1)
        let last = try #require(result.conversation.messages.last)
        #expect(last.role == .user)
        #expect(last.content.first?.fields["is_error"]?.boolValue == true)
        let ranATool = await log.events.contains { event in
            if case .toolCall = event { return true }
            return false
        }
        #expect(!ranATool)

        // A later message stops before sending anything.
        var next = result.conversation
        next.appendUserText("Again")
        let again = await makeRunner(transport, configuration: configuration).run(next) { _ in }
        #expect(again.stop == .spendCapReached(capUSD: 0.000_01))
        #expect(await transport.requests.count == 1)
    }

    @Test func stopsAfterTheMaximumToolRounds() async throws {
        let toolTurn = Fixtures.toolUseResponse([(id: "toolu_loop", input: #"{"text":"again"}"#)])
        let transport = FakeTransport(responses: [], repeating: toolTurn)
        let configuration = AgentConfiguration(maxToolRounds: 2)
        let result = await makeRunner(transport, configuration: configuration).run(startConversation()) { _ in }

        #expect(result.stop == .maxToolRoundsReached(2))
        #expect(await transport.requests.count == 3)
        // Two rounds of results, then error results for the call that did not run.
        let roles = result.conversation.messages.map { $0.role }
        #expect(roles == [.user, .assistant, .user, .assistant, .user, .assistant, .user])
        #expect(result.conversation.messages.last?.content.first?.fields["is_error"]?.boolValue == true)
    }

    @Test func invalidToolInputReturnsAnErrorResult() async throws {
        let transport = FakeTransport(responses: [
            Fixtures.toolUseResponse([(id: "toolu_bad", input: #"{"text": "cut"#)]),
            Fixtures.textResponse("Sorry.")
        ])
        let result = await makeRunner(transport).run(startConversation()) { _ in }
        #expect(result.stop == .completed)
        let bodies = try await transport.requestBodies()
        let resultBlock = try #require(bodies[1]["messages"]?.arrayValue?[2]["content"]?.arrayValue?.first)
        #expect(resultBlock["is_error"]?.boolValue == true)
        let content = try #require(resultBlock["content"]?.stringValue)
        let expected: JSONValue = ["INVALID_JSON": #"{"text": "cut"#]
        #expect(try JSONValue.parse(content) == expected)
    }

    @Test func schemaViolationsAndUnknownToolsAreErrors() async throws {
        var events = [Fixtures.messageStart()]
        events += Fixtures.toolUseBlock(index: 0, id: "toolu_1", name: "echo", inputChunks: [#"{"txt":"x"}"#])
        events += Fixtures.toolUseBlock(index: 1, id: "toolu_2", name: "missing_tool", inputChunks: ["{}"])
        events += [Fixtures.messageDelta(stopReason: "tool_use"), Fixtures.messageStop]
        let transport = FakeTransport(responses: [Fixtures.sse(events), Fixtures.textResponse("ok")])
        let log = EventLog()
        _ = await makeRunner(transport).run(startConversation()) { await log.append($0) }

        let errors = await log.events.compactMap { event -> String? in
            if case .toolResult(_, let output, true) = event { return output }
            return nil
        }
        #expect(errors.count == 2)
        #expect(errors[0].contains("Missing required property \"text\""))
        #expect(errors[0].contains("Unknown property \"txt\""))
        #expect(errors[1].hasPrefix("Unknown tool \"missing_tool\""))
    }

    @Test func refusalDiscardsThePartialResponse() async throws {
        var events = [Fixtures.messageStart()]
        events += Fixtures.textBlock(index: 0, chunks: ["Partial"])
        events.append(#"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"bio"}}}"#)
        events.append(Fixtures.messageStop)
        let transport = FakeTransport(responses: [Fixtures.sse(events)])
        let log = EventLog()
        let result = await makeRunner(transport).run(startConversation()) { await log.append($0) }

        #expect(result.stop == .refused(category: "bio"))
        #expect(result.conversation.messages.count == 1)
        #expect(await log.events.last == .responseDiscarded)
        #expect(result.conversation.usage.inputTokens == 100)
    }

    @Test func pauseTurnContinuesWithoutAUserMessage() async throws {
        let transport = FakeTransport(responses: [
            Fixtures.textResponse("Working", stopReason: "pause_turn"),
            Fixtures.textResponse("Finished")
        ])
        let result = await makeRunner(transport).run(startConversation()) { _ in }
        #expect(result.stop == .completed)
        #expect(result.conversation.messages.map { $0.role } == [.user, .assistant, .assistant])
    }

    @Test func httpErrorsStopTheRun() async throws {
        let transport = FakeTransport(responses: [])
        let result = await makeRunner(transport).run(startConversation()) { _ in }
        #expect(result.stop == .failed(ClaudeAPIError.invalidResponse.localizedDescription))
        #expect(result.conversation.messages.count == 1)
    }

    @Test func aStreamThatEndsEarlyIsAnError() async throws {
        let transport = FakeTransport(responses: [Fixtures.sse([Fixtures.messageStart()])])
        let result = await makeRunner(transport).run(startConversation()) { _ in }
        #expect(result.stop == .failed(ClaudeAPIError.incompleteStream.localizedDescription))
    }
}
