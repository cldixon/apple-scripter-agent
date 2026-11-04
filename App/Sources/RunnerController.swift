import Foundation
import Observation
import ServiceManagement
import Shared

/// Owns the main app's view of the runner: its launchd registration and XPC health.
@MainActor
@Observable
final class RunnerController {
    struct PingResult {
        let response: PingResponse
        let roundTrip: Duration
    }

    enum PingState {
        case idle
        case pinging
        case succeeded(PingResult)
        case failed(String)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
    }

    private(set) var registration: SMAppService.Status = .notRegistered
    private(set) var pingState: PingState = .idle
    private(set) var log: [LogEntry] = []

    private let service = SMAppService.agent(plistName: Identifiers.runnerLaunchAgentPlistName)
    private let client = RunnerClient()
    private var hasLaunched = false

    var isPinging: Bool {
        if case .pinging = pingState { return true }
        return false
    }

    var isHealthy: Bool {
        if case .succeeded = pingState { return true }
        return false
    }

    /// Called once when the first window appears: make sure the runner is registered, then ping it.
    func onLaunch() async {
        guard !hasLaunched else { return }
        hasLaunched = true

        refreshStatus()
        if registration != .enabled {
            register()
        }
        await ping()
    }

    func refreshStatus() {
        registration = service.status
    }

    func register() {
        do {
            try service.register()
            record("Registered the runner launch agent")
        } catch {
            record("Could not register the runner: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    func unregister() {
        do {
            try service.unregister()
            record("Unregistered the runner launch agent; launchd stops it")
        } catch {
            record("Could not unregister the runner: \(error.localizedDescription)")
        }
        refreshStatus()
        pingState = .idle
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func ping() async {
        pingState = .pinging
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await client.ping()
            let result = PingResult(response: response, roundTrip: clock.now - start)
            pingState = .succeeded(result)
            record("Ping answered by runner pid \(response.processID) in \(result.roundTrip.millisecondsText)")
        } catch {
            pingState = .failed(error.localizedDescription)
            record("Ping failed: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    private func record(_ message: String) {
        log.append(LogEntry(date: Date(), message: message))
    }
}

extension SMAppService.Status {
    var label: String {
        switch self {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval"
        case .notFound: "Not found"
        @unknown default: "Unknown"
        }
    }

    var explanation: String {
        switch self {
        case .notRegistered:
            "launchd does not know about the runner yet. Register it to start it now and at every login."
        case .enabled:
            "launchd starts the runner at login and restarts it if it crashes. It keeps running when this app quits."
        case .requiresApproval:
            "macOS is waiting for you to allow the runner in System Settings > General > Login Items."
        case .notFound:
            "The launch agent plist is missing from the app bundle. Rebuild the app."
        @unknown default:
            "macOS reported a status this version of the app does not know."
        }
    }
}

extension Duration {
    var millisecondsText: String {
        let milliseconds = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
        return "\(milliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
    }
}
