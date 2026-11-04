import Foundation

/// An automation's row in the index.
public struct IndexedAutomation: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var request: String?
    public var triggerSummary: String
    public var status: AutomationStatus
    public var currentVersion: Int
    public var created: Date
    public var updated: Date

    public init(
        id: String,
        name: String,
        description: String? = nil,
        request: String? = nil,
        triggerSummary: String,
        status: AutomationStatus,
        currentVersion: Int,
        created: Date,
        updated: Date
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.request = request
        self.triggerSummary = triggerSummary
        self.status = status
        self.currentVersion = currentVersion
        self.created = created
        self.updated = updated
    }

    public init(manifest: AutomationManifest, status: AutomationStatus, created: Date, updated: Date) {
        self.init(
            id: manifest.id,
            name: manifest.name,
            description: manifest.description,
            request: manifest.request,
            triggerSummary: manifest.trigger.summary,
            status: status,
            currentVersion: manifest.version,
            created: created,
            updated: updated
        )
    }
}

/// A run's row in the index (the full record stays in `runs.jsonl`).
public struct IndexedRun: Sendable, Equatable, Identifiable {
    public var id: String
    public var automationID: String
    public var version: Int
    public var cause: String
    public var startedAt: Date
    public var duration: Double
    public var outcome: String
    public var error: String?
    public var outputExcerpt: String?
}

extension IndexedRun {
    public init(record: RunRecord) {
        id = record.id.uuidString
        automationID = record.automationID
        version = record.version
        cause = record.cause.rawValue
        startedAt = record.startedAt
        duration = record.duration
        outcome = record.outcome.rawValue
        error = record.error
        let output = record.steps.last(where: { $0.output != nil })?.output
        outputExcerpt = output.map { String($0.prefix(RunRecord.outputExcerptLimit)) }
    }
}
