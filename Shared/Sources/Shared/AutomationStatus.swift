import Foundation

/// Where an automation is in its life cycle. Stored in the catalog index as the raw value.
///
/// The runner computes `active`, `disabled` and `broken` (validation errors, a trigger that
/// could not be registered, or `FailureMonitor.brokenThreshold` failed runs in a row). `draft`, `validating` and
/// `awaitingApproval` belong to the agent's drafting flow (M5/M6).
public enum AutomationStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case draft
    case validating
    case awaitingApproval = "awaiting_approval"
    case active
    case disabled
    case broken

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .draft: "Draft"
        case .validating: "Validating"
        case .awaitingApproval: "Awaiting approval"
        case .active: "Active"
        case .disabled: "Disabled"
        case .broken: "Broken"
        }
    }

    /// The status the runner reports for an installed automation.
    public static func installed(
        enabled: Bool,
        issues: [ValidationIssue],
        registrationError: String?,
        failingRuns: Int = 0
    ) -> AutomationStatus {
        guard enabled else { return .disabled }
        if ManifestValidator.hasErrors(issues) || registrationError != nil { return .broken }
        if failingRuns >= FailureMonitor.brokenThreshold { return .broken }
        return .active
    }
}

/// One committed version of an automation in the catalog's git history.
public struct AutomationVersion: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// The full commit hash.
    public var id: String
    public var date: Date
    public var message: String
    /// The manifest's `version` at that commit, or nil when the folder did not exist
    /// there (for example, the commit that removed it).
    public var version: Int?

    public init(id: String, date: Date, message: String, version: Int?) {
        self.id = id
        self.date = date
        self.message = message
        self.version = version
    }

    public var shortHash: String { String(id.prefix(7)) }
}
