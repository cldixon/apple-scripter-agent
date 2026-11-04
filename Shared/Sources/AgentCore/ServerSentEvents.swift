import Foundation

/// Splits a byte stream into lines on `\n`, dropping a trailing `\r`. Blank lines are kept:
/// they end server-sent events. (`URLSession.AsyncBytes.lines` drops them, so the transport
/// splits bytes itself.)
public struct LineBuffer: Sendable {
    private var bytes: [UInt8] = []

    public init() {}

    /// Adds one byte; returns a complete line when the byte ends one.
    public mutating func append(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            bytes.append(byte)
            return nil
        }
        return takeLine()
    }

    /// The last line, if the stream did not end with a newline.
    public mutating func finish() -> String? {
        bytes.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        if bytes.last == 0x0D {
            bytes.removeLast()
        }
        let line = String(bytes: bytes, encoding: .utf8) ?? ""
        bytes.removeAll(keepingCapacity: true)
        return line
    }
}

/// One server-sent event: an optional event name and its data lines joined with `\n`.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Parses server-sent event lines (https://html.spec.whatwg.org/multipage/server-sent-events.html).
public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feeds one line; returns an event when a blank line ends one.
    public mutating func feed(_ rawLine: String) -> SSEEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil
        }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") {
                value = value.dropFirst()
            }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    /// Dispatches an event left open when the stream ended without a blank line.
    public mutating func finish() -> SSEEvent? {
        dispatch()
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}

/// A Messages API streaming event.
public enum StreamEvent: Sendable, Equatable {
    case messageStart(model: String?, usage: JSONValue?)
    case contentBlockStart(index: Int, block: JSONValue)
    case contentBlockDelta(index: Int, delta: JSONValue)
    case contentBlockStop(index: Int)
    case messageDelta(delta: JSONValue, usage: JSONValue?)
    case messageStop
    case ping
    case error(type: String, message: String)
    /// A type this client does not know; ignored, as the API's versioning policy asks.
    case unknown(String)

    /// Decodes an event's `data` JSON.
    public static func parse(_ data: String) throws -> StreamEvent {
        let json = try JSONValue.parse(data)
        let type = json["type"]?.stringValue ?? ""
        let index = json["index"]?.intValue ?? 0
        switch type {
        case "message_start":
            return .messageStart(model: json["message"]?["model"]?.stringValue, usage: json["message"]?["usage"])
        case "content_block_start":
            return .contentBlockStart(index: index, block: json["content_block"] ?? .object([:]))
        case "content_block_delta":
            return .contentBlockDelta(index: index, delta: json["delta"] ?? .object([:]))
        case "content_block_stop":
            return .contentBlockStop(index: index)
        case "message_delta":
            return .messageDelta(delta: json["delta"] ?? .object([:]), usage: json["usage"])
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            return .error(
                type: json["error"]?["type"]?.stringValue ?? "error",
                message: json["error"]?["message"]?.stringValue ?? "The stream reported an error."
            )
        default:
            return .unknown(type)
        }
    }
}
