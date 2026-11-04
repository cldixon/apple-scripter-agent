import AppKit
import os
import Shared

/// Loads automations and starts the XPC listener as soon as the runner launches.
@MainActor
final class RunnerAppDelegate: NSObject, NSApplicationDelegate {
    let core = RunnerCore()
    var state: RunnerState { core.state }

    private let logger = Logger(subsystem: Identifiers.logSubsystem, category: "runner")
    private var listener: NSXPCListener?
    private var service: RunnerService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        core.reload()

        let service = RunnerService(core: core, startedAt: state.startedAt)
        let listener = NSXPCListener(machServiceName: Identifiers.runnerMachServiceName)
        listener.delegate = service
        listener.resume()

        self.service = service
        self.listener = listener
        logger.info("Runner started, listening on \(Identifiers.runnerMachServiceName, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        listener?.invalidate()
        logger.info("Runner quitting")
    }
}
