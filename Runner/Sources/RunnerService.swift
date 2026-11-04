import Foundation
import os
import Shared
import Synchronization

/// Accepts XPC connections from the main app and implements `RunnerXPCProtocol`.
///
/// Called on XPC's own queues, so it keeps only thread-safe state and hops to the main
/// actor for anything that touches `RunnerCore`.
final class RunnerService: NSObject, NSXPCListenerDelegate, RunnerXPCProtocol, Sendable {
    private let core: RunnerCore
    private let startedAt: Date
    private let version = BundleVersion.of(.main)
    private let bundlePath = Bundle.main.bundlePath
    private let pingsServed = Mutex(0)
    private let logger = Logger(subsystem: Identifiers.logSubsystem, category: "xpc")

    init(core: RunnerCore, startedAt: Date) {
        self.core = core
        self.startedAt = startedAt
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The listener only lets through clients that satisfy CodeSigning.clientRequirement().
        newConnection.exportedInterface = NSXPCInterface(with: RunnerXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        logger.debug("Accepted connection from pid \(newConnection.processIdentifier)")
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
        let core = core
        let version = version
        let bundlePath = bundlePath
        let startedAt = startedAt

        Task { @MainActor in
            core.state.recordPing(at: receivedAt, clientVersion: clientVersion)
            let response = PingResponse(
                runnerVersion: version.description,
                processID: ProcessInfo.processInfo.processIdentifier,
                startedAt: startedAt,
                receivedAt: receivedAt,
                bundlePath: bundlePath,
                pingsServed: count,
                accessibilityTrusted: SystemActions.isAccessibilityTrusted
            )
            reply((try? XPCCoding.encode(response)) ?? Data())
        }
    }

    func send(_ command: Data, reply: @escaping @Sendable (Data) -> Void) {
        let decoded: RunnerCommand
        do {
            decoded = try XPCCoding.decode(RunnerCommand.self, from: command)
        } catch {
            reply(Self.encode(.failure("The runner could not read the command: \(error.localizedDescription)")))
            return
        }
        let core = core
        Task { @MainActor in
            reply(Self.encode(await core.handle(decoded)))
        }
    }

    private static func encode(_ reply: RunnerReply) -> Data {
        (try? XPCCoding.encode(reply)) ?? Data()
    }
}
