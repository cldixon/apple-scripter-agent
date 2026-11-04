import Foundation

/// The log entry for one run of an automation.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case succeeded, failed, skipped
    }

    public enum Cause: String, Codable, Sendable {
        case hotkey, manual, test
    }

    public struct StepResult: Codable, Sendable, Equatable {
        public var index: Int
        public var type: String
        public var outcome: Outcome
        public var output: String?
        public var error: String?
        public var duration: Double

        public init(index: Int, type: String, outcome: Outcome, output: String?, error: String?, duration: Double) {
            self.index = index
            self.type = type
            self.outcome = outcome
            self.output = output
            self.error = error
            self.duration = duration
        }
    }

    public var id: UUID
    public var automationID: String
    public var version: Int
    public var cause: Cause
    public var startedAt: Date
    /// Seconds.
    public var duration: Double
    public var outcome: Outcome
    public var error: String?
    public var steps: [StepResult]

    public init(
        id: UUID = UUID(),
        automationID: String,
        version: Int,
        cause: Cause,
        startedAt: Date,
        duration: Double,
        outcome: Outcome,
        error: String?,
        steps: [StepResult]
    ) {
        self.id = id
        self.automationID = automationID
        self.version = version
        self.cause = cause
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
        self.error = error
        self.steps = steps
    }

    /// Longest output kept in the log per step.
    public static let outputExcerptLimit = 500
}
