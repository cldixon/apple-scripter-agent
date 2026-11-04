import Foundation

/// The XPC interface the runner exports to the main app.
///
/// Requests and replies are JSON-encoded `Codable` messages (see `RunnerMessages.swift`),
/// which keeps the Objective-C surface tiny and lets the message types evolve as plain
/// Swift structs.
@objc public protocol RunnerXPCProtocol {
    /// Health check. `request` is an encoded `PingRequest`; the reply is an encoded `PingResponse`.
    func ping(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}
