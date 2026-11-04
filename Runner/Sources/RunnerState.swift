import Foundation
import Observation

/// What the runner shows in its menu bar item.
@MainActor
@Observable
final class RunnerState {
    let startedAt = Date()
    let processID = ProcessInfo.processInfo.processIdentifier

    private(set) var pingsServed = 0
    private(set) var lastPingAt: Date?
    private(set) var lastClientVersion: String?

    /// Kill switch from the handoff doc. M0 has no automations, so it only records intent.
    var isPaused = false

    func recordPing(at date: Date, clientVersion: String?) {
        pingsServed += 1
        lastPingAt = date
        lastClientVersion = clientVersion
    }
}
