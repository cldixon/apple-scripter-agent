import Foundation

/// Requests the main app sends the runner through `RunnerXPCProtocol.send`.
public enum RunnerCommand: Codable, Sendable, Equatable {
    case listAutomations
    /// Install from a `manifest.json` path; its folder's other files are copied too.
    case installFromFile(path: String)
    /// Install from manifest JSON (no script files).
    case installManifest(Data)
    case remove(id: String)
    case run(id: String)
    case test(id: String)
    case recentRuns(limit: Int)
    case setPaused(Bool)
    /// Show the Accessibility prompt and open its System Settings pane.
    case requestAccessibility
}

/// The runner's answer to a `RunnerCommand`.
public enum RunnerReply: Codable, Sendable, Equatable {
    case automations([AutomationSummary], paused: Bool)
    case installed(InstallReport)
    case removed(id: String)
    case ran(RunRecord)
    case tested(TestReport)
    case runs([RunRecord])
    case done
    case failure(String)
}

/// An installed automation as the main app sees it.
public struct AutomationSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var trigger: String
    public var stepTypes: [String]
    public var permissions: [Permission]
    public var destructive: Bool
    public var version: Int
    public var testCount: Int
    public var issues: [ValidationIssue]
    /// Why the trigger could not be registered (for example, a hotkey another app owns).
    public var registrationError: String?
    public var folderPath: String

    public init(
        manifest: AutomationManifest,
        issues: [ValidationIssue],
        registrationError: String?,
        folderPath: String
    ) {
        id = manifest.id
        name = manifest.name
        description = manifest.description
        trigger = manifest.trigger.summary
        stepTypes = manifest.steps.map(\.body.typeName)
        permissions = manifest.permissions
        destructive = manifest.destructive
        version = manifest.version
        testCount = manifest.tests.count
        self.issues = issues
        self.registrationError = registrationError
        self.folderPath = folderPath
    }

    public var isActive: Bool {
        registrationError == nil && !ManifestValidator.hasErrors(issues)
    }
}

/// Result of an install request.
public struct InstallReport: Codable, Sendable, Equatable {
    public var automationID: String?
    public var installed: Bool
    public var issues: [ValidationIssue]
    public var message: String

    public init(automationID: String?, installed: Bool, issues: [ValidationIssue], message: String) {
        self.automationID = automationID
        self.installed = installed
        self.issues = issues
        self.message = message
    }
}
