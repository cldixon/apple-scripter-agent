import Foundation
import os
import Shared
import Synchronization

/// Accepts XPC connections from the main app and implements `RunnerXPCProtocol`.
///
/// Called on XPC's own queues, so it keeps only thread-safe state and hops to the main
/// actor to update the menu.
final class RunnerService: NSObject, NSXPCListenerDelegate, RunnerXPCProtocol, Sendable {
    private let state: RunnerState
    private let startedAt: Date
    private let version = BundleVersion.of(.main)
    private let bundlePath = Bundle.main.bundlePath
    private let pingsServed = Mutex(0)
    private let logger = Logger(subsystem: Identifiers.logSubsystem, category: "xpc")

    init(state: RunnerState, startedAt: Date) {
        self.state = state
        self.startedAt = startedAt
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Not yet restricted to our own signed app: see docs/ARCHITECTURE.md, "Known gaps".
        newConnection.exportedInterface = NSXPCInterface(with: RunnerXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        logger.info("Accepted connection from pid \(newConnection.processIdentifier)")
        return true
    }

    // MARK: RunnerXPCProtocol

    func ping(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let receivedAt = Date()
        let count = pingsServed.withLock { served in
            served += 1
            return served
        }
        let clientVersion = (try? XPCCoding.decode(PingRequest.self, from: request))?.clientVersion

        let response = PingResponse(
            runnerVersion: version.description,
            processID: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            receivedAt: receivedAt,
            bundlePath: bundlePath,
            pingsServed: count
        )

        do {
            reply(try XPCCoding.encode(response))
        } catch {
            logger.error("Could not encode ping reply: \(error.localizedDescription, privacy: .public)")
            reply(Data())
        }

        let state = state
        Task { @MainActor in
            state.recordPing(at: receivedAt, clientVersion: clientVersion)
        }
    }
}
