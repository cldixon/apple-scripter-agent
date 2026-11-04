import Foundation
import Shared

enum RunnerClientError: LocalizedError {
    case timedOut(seconds: Double)
    case unexpectedProxy

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "The runner did not answer within \(seconds.formatted()) seconds."
        case .unexpectedProxy:
            "The XPC connection returned an object that is not the runner interface."
        }
    }
}

/// Talks to the runner over XPC. Opens a fresh connection per call; calls are rare and
/// launchd starts the runner on demand when its Mach service is looked up.
struct RunnerClient: Sendable {
    func ping() async throws -> PingResponse {
        let request = PingRequest(sentAt: Date(), clientVersion: BundleVersion.of(.main).description)
        let reply = try await call(payload: XPCCoding.encode(request), timeout: 3) { runner, payload, completion in
            runner.ping(payload, reply: completion)
        }
        return try XPCCoding.decode(PingResponse.self, from: reply)
    }

    /// Sends a command. Tests can take a while (they open the harness window), so the
    /// timeout is generous.
    func send(_ command: RunnerCommand, timeout: Double = 60) async throws -> RunnerReply {
        let payload = try XPCCoding.encode(command)
        let reply = try await call(payload: payload, timeout: timeout) { runner, payload, completion in
            runner.send(payload, reply: completion)
        }
        return try XPCCoding.decode(RunnerReply.self, from: reply)
    }

    /// Sends one request and waits for the first of: the reply, a connection error, or the timeout.
    private func call(
        payload: Data,
        timeout: Double,
        invoke: (any RunnerXPCProtocol, Data, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> Data {
        let connection = NSXPCConnection(machServiceName: Identifiers.runnerMachServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: RunnerXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(error))
            }
            guard let runner = proxy as? any RunnerXPCProtocol else {
                once.resume(with: .failure(RunnerClientError.unexpectedProxy))
                return
            }
            invoke(runner, payload) { reply in
                once.resume(with: .success(reply))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(with: .failure(RunnerClientError.timedOut(seconds: timeout)))
            }
        }
    }
}
