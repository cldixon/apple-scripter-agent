import Foundation
import Observation
import Shared

/// What the runner shows in its menu bar item.
@MainActor
@Observable
final class RunnerState {
    let startedAt = Date()
    let processID = ProcessInfo.processInfo.processIdentifier

    private(set) var pingsServed = 0
    private(set) var lastPingAt: Date?
    private(set) var lastClientVersion: String?

    var automations: [AutomationSummary] = []
    private(set) var lastRun: RunRecord?

    /// Kill switch: while paused, triggers are ignored. Manual runs and tests still work.
    var isPaused = false

    func recordPing(at date: Date, clientVersion: String?) {
        pingsServed += 1
        lastPingAt = date
        lastClientVersion = clientVersion
    }

    func record(_ run: RunRecord) {
        lastRun = run
    }
}
