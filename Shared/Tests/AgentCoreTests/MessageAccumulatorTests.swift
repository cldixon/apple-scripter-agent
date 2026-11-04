@testable import AgentCore
import Foundation
import Testing

struct MessageAccumulatorTests {
    private func accumulate(_ events: [String]) throws -> (response: AssistantResponse, text: String) {
        var parser = SSEParser()
        var accumulator = MessageAccumulator()
        var text = ""
        for line in Fixtures.sse(events) {
            if let event = parser.feed(line), let delta = try accumulator.apply(StreamEvent.parse(event.data)) {
                text += delta
            }
        }
        #expect(accumulator.isComplete)
        return (accumulator.finish(), text)
    }

    private static let unknownBlockEvents = [
        #"{"type":"content_block_start","index":3,"content_block":{"type":"server_widget","data":{"n":[1,2.5,null]}}}"#,
        #"{"type":"content_block_delta","index":3,"delta":{"type":"widget_delta","value":"ignored"}}"#,
        #"{"type":"content_block_stop","index":3}"#
    ]

    @Test func assemblesTextToolUseThinkingAndUnknownBlocks() throws {
        var events = [Fixtures.messageStart(input: 120, cacheRead: 900), Fixtures.ping]
        events += Fixtures.thinkingBlock(index: 0)
        events += Fixtures.textBlock(index: 1, chunks: ["Let me ", "check."])
        events += Fixtures.toolUseBlock(index: 2, id: "toolu_1", name: "echo", inputChunks: [#"{"te"#, #"xt": "hi"}"#])
        events += Self.unknownBlockEvents
        events += [Fixtures.messageDelta(stopReason: "tool_use", output: 77), Fixtures.messageStop]

        let (response, text) = try accumulate(events)

        #expect(text == "Let me check.")
        #expect(response.content.map { $0.type } == ["thinking", "text", "tool_use", "server_widget"])
        #expect(response.content[0].fields["signature"]?.stringValue == "sig==")
        #expect(response.content[1].text == "Let me check.")
        let expectedUse = ToolUse(id: "toolu_1", name: "echo", input: ["text": "hi"])
        #expect(response.toolUses == [expectedUse])
        let widgetData: JSONValue = ["n": [1, .double(2.5), .null]]
        #expect(response.content[3].fields["data"] == widgetData)
        #expect(response.stopReason == "tool_use")
        #expect(response.model == "claude-opus-5-5")
        #expect(response.usage == TokenUsage(input: 120, output: 77, cacheRead: 900, cacheCreation: 0))
        #expect(response.invalidToolInputs.isEmpty)
    }

    @Test func unknownBlocksRoundTripThroughJSON() throws {
        var events = [Fixtures.messageStart()]
        events += Self.unknownBlockEvents
        events += [Fixtures.messageDelta(stopReason: "end_turn"), Fixtures.messageStop]
        let block = try accumulate(events).response.content[0]
        let decoded = try JSONDecoder().decode(ContentBlock.self, from: JSONEncoder().encode(block))
        #expect(decoded == block)
    }

    @Test func recordsInvalidToolInputWithoutFailing() throws {
        var events = [Fixtures.messageStart()]
        let badInput = #"{"text": "unterminated"#
        events += Fixtures.toolUseBlock(index: 0, id: "toolu_bad", name: "echo", inputChunks: [badInput])
        events += [Fixtures.messageDelta(stopReason: "tool_use"), Fixtures.messageStop]
        let response = try accumulate(events).response
        #expect(response.invalidToolInputs == ["toolu_bad": badInput])
        #expect(response.toolUses.first?.input == .object([:]))
    }

    @Test func emptyToolInputIsAnEmptyObject() throws {
        var events = [Fixtures.messageStart()]
        events += Fixtures.toolUseBlock(index: 0, id: "toolu_2", name: "list", inputChunks: [""])
        events += [Fixtures.messageDelta(stopReason: "tool_use"), Fixtures.messageStop]
        let response = try accumulate(events).response
        #expect(response.toolUses.first?.input == .object([:]))
        #expect(response.invalidToolInputs.isEmpty)
    }

    @Test func streamErrorEventsThrow() {
        #expect(throws: ClaudeAPIError.stream(type: "overloaded_error", message: "busy")) {
            var accumulator = MessageAccumulator()
            _ = try accumulator.apply(.error(type: "overloaded_error", message: "busy"))
        }
    }

    @Test func refusalKeepsStopDetails() throws {
        var events = [Fixtures.messageStart()]
        events += Fixtures.textBlock(index: 0, chunks: ["Part"])
        events.append(
            #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"category":"cyber"}}}"#
        )
        events.append(Fixtures.messageStop)
        let response = try accumulate(events).response
        #expect(response.stopReason == "refusal")
        #expect(response.refusalCategory == "cyber")
    }

    @Test func dropsDeclinedModelsBlocksBeforeAFallbackBoundary() {
        let content: [ContentBlock] = [
            ContentBlock(fields: ["type": "thinking", "thinking": "", "signature": "a"]),
            .text("partial"),
            ContentBlock(fields: ["type": "tool_use", "id": "t1", "name": "echo", "input": [:]]),
            ContentBlock(fields: ["type": "fallback", "from": ["model": "x"], "to": ["model": "y"]]),
            ContentBlock(fields: ["type": "thinking", "thinking": "", "signature": "b"]),
            .text("rest")
        ]
        let kept = MessageAccumulator.contentForHistory(content)
        #expect(kept.map { $0.type } == ["text", "fallback", "thinking", "text"])
        #expect(kept[2].fields["signature"]?.stringValue == "b")
    }
}
