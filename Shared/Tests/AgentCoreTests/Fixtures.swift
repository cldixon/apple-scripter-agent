@testable import AgentCore
import Foundation

/// Builds SSE lines for scripted responses, the way the API sends them.
enum Fixtures {
    static func sse(_ events: [String]) -> [String] {
        events.flatMap { data -> [String] in
            let type = (try? JSONValue.parse(data))?["type"]?.stringValue ?? "unknown"
            return ["event: \(type)", "data: \(data)", ""]
        }
    }

    static func messageStart(model: String = "claude-opus-5-5", input: Int = 100, cacheRead: Int = 0) -> String {
        """
        {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"\(model)",\
        "content":[],"stop_reason":null,"usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":0,"output_tokens":1}}}
        """
    }

    static func messageDelta(stopReason: String, output: Int = 10) -> String {
        """
        {"type":"message_delta","delta":{"stop_reason":"\(stopReason)","stop_sequence":null},\
        "usage":{"output_tokens":\(output)}}
        """
    }

    static let messageStop = #"{"type":"message_stop"}"#
    static let ping = #"{"type":"ping"}"#

    static func textBlock(index: Int, chunks: [String]) -> [String] {
        var events = [#"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#]
        for chunk in chunks {
            events.append(
                #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(chunk)"}}"#
            )
        }
        events.append(#"{"type":"content_block_stop","index":\#(index)}"#)
        return events
    }

    static func toolUseBlock(index: Int, id: String, name: String, inputChunks: [String]) -> [String] {
        var events = [
            #"{"type":"content_block_start","index":\#(index),"#
                + #""content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#
        ]
        for chunk in inputChunks {
            let escaped = JSONValue.string(chunk).compactText
            events.append(
                #"{"type":"content_block_delta","index":\#(index),"#
                    + #""delta":{"type":"input_json_delta","partial_json":\#(escaped)}}"#
            )
        }
        events.append(#"{"type":"content_block_stop","index":\#(index)}"#)
        return events
    }

    static func thinkingBlock(index: Int) -> [String] {
        [
            #"{"type":"content_block_start","index":\#(index),"#
                + #""content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"signature_delta","signature":"sig=="}}"#,
            #"{"type":"content_block_stop","index":\#(index)}"#
        ]
    }

    /// A response that asks for tools.
    static func toolUseResponse(_ calls: [(id: String, input: String)], output: Int = 10) -> [String] {
        var events = [messageStart()]
        events += thinkingBlock(index: 0)
        for (offset, call) in calls.enumerated() {
            events += toolUseBlock(index: offset + 1, id: call.id, name: "echo", inputChunks: [call.input])
        }
        events += [messageDelta(stopReason: "tool_use", output: output), messageStop]
        return sse(events)
    }

    static func textResponse(_ text: String, stopReason: String = "end_turn") -> [String] {
        var events = [messageStart()]
        events += textBlock(index: 0, chunks: [text])
        events += [messageDelta(stopReason: stopReason), messageStop]
        return sse(events)
    }
}

/// Replays scripted responses and records each request body.
actor FakeTransport: MessagesTransport {
    private var responses: [[String]]
    private(set) var requests: [MessagesRequest] = []
    /// Used once the scripted responses run out.
    private let repeating: [String]?

    init(responses: [[String]], repeating: [String]? = nil) {
        self.responses = responses
        self.repeating = repeating
    }

    func lines(for request: MessagesRequest) async throws -> AsyncThrowingStream<String, any Error> {
        requests.append(request)
        let lines: [String]
        if responses.isEmpty {
            guard let repeating else { throw ClaudeAPIError.invalidResponse }
            lines = repeating
        } else {
            lines = responses.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }

    func requestBodies() throws -> [JSONValue] {
        try requests.map { try JSONValue.parse($0.body) }
    }
}

/// Collects the events a run emits.
actor EventLog {
    private(set) var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        events.append(event)
    }
}
