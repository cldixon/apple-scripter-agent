import Foundation

/// Sent by the main app to check that the runner is alive.
public struct PingRequest: Codable, Sendable, Equatable {
    public var sentAt: Date
    public var clientVersion: String

    public init(sentAt: Date, clientVersion: String) {
        self.sentAt = sentAt
        self.clientVersion = clientVersion
    }
}

/// The runner's answer to a `PingRequest`: who it is and how long it has been up.
public struct PingResponse: Codable, Sendable, Equatable {
    public var runnerVersion: String
    public var processID: Int32
    public var startedAt: Date
    public var receivedAt: Date
    public var bundlePath: String
    public var pingsServed: Int

    public init(
        runnerVersion: String,
        processID: Int32,
        startedAt: Date,
        receivedAt: Date,
        bundlePath: String,
        pingsServed: Int
    ) {
        self.runnerVersion = runnerVersion
        self.processID = processID
        self.startedAt = startedAt
        self.receivedAt = receivedAt
        self.bundlePath = bundlePath
        self.pingsServed = pingsServed
    }
}

/// JSON coding used for every message that crosses the XPC boundary.
public enum XPCCoding {
    public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(message)
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from data: Data) throws -> Message {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
