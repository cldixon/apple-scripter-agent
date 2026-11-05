import Foundation

/// How an automation's recent real runs have gone (M6 monitoring).
public struct FailureStreak: Codable, Sendable, Equatable {
    /// Failed runs in a row, newest backwards, for the current version.
    public var failures: Int
    public var lastError: String?
    public var lastFailureAt: Date?

    public init(failures: Int = 0, lastError: String? = nil, lastFailureAt: Date? = nil) {
        self.failures = failures
        self.lastError = lastError
        self.lastFailureAt = lastFailureAt
    }

    public var isBroken: Bool { failures >= FailureMonitor.brokenThreshold }
}

/// Counts consecutive failures from the run log. Only real runs count (hotkey, manual):
/// test runs and skipped runs are ignored, and only runs of the current version count, so
/// installing a fixed version clears the streak.
public enum FailureMonitor {
    /// Failures in a row that mark an automation broken.
    public static let brokenThreshold = 3

    /// The streak for one automation. `runs` are newest first and may include other ids.
    public static func streak(automationID: String, version: Int, runs: [RunRecord]) -> FailureStreak {
        var streak = FailureStreak()
        for run in runs where run.automationID == automationID && run.version == version {
            guard run.cause != .test else { continue }
            switch run.outcome {
            case .skipped:
                continue
            case .succeeded:
                return streak
            case .failed:
                if streak.failures == 0 {
                    streak.lastError = run.error
                    streak.lastFailureAt = run.startedAt
                }
                streak.failures += 1
            }
        }
        return streak
    }

    /// The streak after one more run, without rereading the log.
    public static func updated(_ streak: FailureStreak, with run: RunRecord) -> FailureStreak {
        guard run.cause != .test else { return streak }
        switch run.outcome {
        case .skipped:
            return streak
        case .succeeded:
            return FailureStreak()
        case .failed:
            return FailureStreak(failures: streak.failures + 1, lastError: run.error, lastFailureAt: run.startedAt)
        }
    }

    /// True when `run` is the one that took the streak to the threshold (notify once).
    public static func justBroke(before: FailureStreak, after: FailureStreak) -> Bool {
        !before.isBroken && after.isBroken
    }
}

/// The opening message of a "Fix with agent" conversation.
public enum FixRequest {
    public static func message(for automation: AutomationSummary, recentRuns: [RunRecord]) -> String {
        let failures = recentRuns
            .filter { $0.automationID == automation.id && $0.outcome == .failed }
            .prefix(5)
            .map { run in
                let when = run.startedAt.formatted(.iso8601)
                return "- \(when) (\(run.cause.rawValue)): \(run.error ?? "no error message")"
            }
        let failureText = failures.isEmpty ? "- (no failed runs in the recent log)" : failures.joined(separator: "\n")
        return """
        The automation "\(automation.name)" (id: \(automation.id), version \(automation.version), \
        trigger: \(automation.trigger)) is failing. It has failed \(automation.failureStreak.failures) \
        time(s) in a row.

        Recent failures:
        \(failureText)

        Please fix it: read it with read_automation and its log with read_run_log, find the cause \
        (check permissions with check_permissions and assumptions with run_snippet if needed), then \
        write a corrected draft with the same id and version \(automation.version + 1), validate it, and \
        ask me to approve the install. If the cause is outside the automation (for example a \
        permission I need to grant), tell me what to do instead.
        """
    }
}
