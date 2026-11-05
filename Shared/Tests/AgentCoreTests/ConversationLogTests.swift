@testable import AgentCore
import Foundation
import Testing

struct ConversationLogTests {
    private func makeLog() throws -> ConversationLog {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ConversationLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try ConversationLog(directory: directory)
    }

    private func entries(_ log: ConversationLog) throws -> [JSONValue] {
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }

    @Test func recordsTheWholeAgentRunInOrder() async throws {
        let log = try makeLog()
        let transport = FakeTransport(responses: [
            Fixtures.toolUseResponse([(id: "toolu_a", input: #"{"text":"one"}"#)]),
            Fixtures.textResponse("Done.")
        ])
        let runner = AgentRunner(
            transport: transport, tools: ToolRegistry([EchoTool()]), configuration: AgentConfiguration(), log: log
        )
        var conversation = Conversation()
        conversation.appendUserText("Echo once")
        log.record("user_message", ["text": "Echo once"])
        _ = await runner.run(conversation) { _ in }

        let lines = try entries(log)
        #expect(lines.map { $0["type"]?.stringValue } == [
            "user_message", "request", "response", "tool_call", "tool_result", "request", "response", "stop"
        ])
        #expect(lines.map { $0["seq"]?.intValue } == Array(1...8).map(Optional.some))

        // The first request carries the settings and the user message.
        let first = lines[1]
        #expect(first["settings"]?["system"] != nil)
        #expect(first["settings"]?["tools"] != nil)
        #expect(first["newMessages"]?.arrayValue?.count == 1)

        // Thinking is kept in the response as streamed.
        let blocks = try #require(lines[2]["content"]?.arrayValue)
        #expect(blocks.map { $0["type"]?.stringValue } == ["thinking", "tool_use"])

        let toolResult = lines[4]
        #expect(toolResult["output"]?.stringValue == "one")
        #expect(toolResult["isError"]?.boolValue == false)

        // The second request has unchanged settings, so only the two new messages.
        let second = lines[5]
        #expect(second["settings"] == nil)
        #expect(second["messageCount"]?.intValue == 3)
        let added = try #require(second["newMessages"]?.arrayValue)
        #expect(added.map { $0["role"]?.stringValue } == ["assistant", "user"])

        #expect(lines[7]["reason"]?.stringValue == "completed")
    }

    @Test func recordsAFailedResponse() async throws {
        let log = try makeLog()
        let transport = FakeTransport(responses: [])
        let runner = AgentRunner(
            transport: transport, tools: ToolRegistry([EchoTool()]), configuration: AgentConfiguration(), log: log
        )
        var conversation = Conversation()
        conversation.appendUserText("Hi")
        _ = await runner.run(conversation) { _ in }

        let lines = try entries(log)
        #expect(lines.map { $0["type"]?.stringValue } == ["request", "response_failed", "stop"])
        #expect(lines[2]["reason"]?.stringValue?.hasPrefix("failed:") == true)
    }

    @Test func ignoresRecordsAfterClose() throws {
        let log = try makeLog()
        log.record("one")
        log.close()
        log.record("two")
        #expect(try entries(log).map { $0["type"]?.stringValue } == ["one"])
    }
}
