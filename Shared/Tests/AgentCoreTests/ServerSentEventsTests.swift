@testable import AgentCore
import Foundation
import Testing

struct ServerSentEventsTests {
    private func parseAll(_ lines: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var events = lines.compactMap { parser.feed($0) }
        if let last = parser.finish() {
            events.append(last)
        }
        return events
    }

    @Test func joinsMultiLineData() {
        let events = parseAll(["event: message", "data: first", "data:second", "data:  third", ""])
        #expect(events == [SSEEvent(event: "message", data: "first\nsecond\n third")])
    }

    @Test func ignoresCommentsAndUnknownFields() {
        let events = parseAll([": keep-alive", "id: 7", "retry: 1000", "data: {}", ""])
        #expect(events == [SSEEvent(event: nil, data: "{}")])
    }

    @Test func blankLinesWithoutDataDispatchNothing() {
        #expect(parseAll(["", "event: ping", "", ""]).isEmpty)
    }

    @Test func handlesCarriageReturnsAndAMissingFinalBlankLine() {
        let events = parseAll(["event: a\r", "data: 1\r", "\r", "event: b", "data: 2"])
        #expect(events == [SSEEvent(event: "a", data: "1"), SSEEvent(event: "b", data: "2")])
    }

    @Test func parsesPingAndUnknownEvents() throws {
        let events = parseAll(Fixtures.sse([Fixtures.ping, #"{"type":"something_new","x":1}"#]))
        #expect(events.count == 2)
        #expect(try StreamEvent.parse(events[0].data) == .ping)
        #expect(try StreamEvent.parse(events[1].data) == .unknown("something_new"))
    }

    @Test func parsesErrorEvents() throws {
        let data = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(try StreamEvent.parse(data) == .error(type: "overloaded_error", message: "Overloaded"))
    }

    @Test func lineBufferSplitsBytesKeepingBlankLinesAndUTF8() {
        var buffer = LineBuffer()
        var lines: [String] = []
        for byte in Array("data: café ✓\r\n\r\nevent: x\ntail".utf8) {
            if let line = buffer.append(byte) {
                lines.append(line)
            }
        }
        if let rest = buffer.finish() {
            lines.append(rest)
        }
        #expect(lines == ["data: café ✓", "", "event: x", "tail"])
    }
}
