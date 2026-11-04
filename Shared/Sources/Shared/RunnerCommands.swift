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
    /// Run a short script for exploration and return its output (`run_snippet`). The main app
    /// asks the user before sending this.
    case runSnippet(language: ScriptLanguage, source: String, timeout: Double)
    /// Compile-check a script without running it.
    case compile(language: ScriptLanguage, source: String)
    /// Enable or disable an automation. Disabling unregisters its trigger but keeps it installed.
    case setEnabled(id: String, enabled: Bool)
    /// Committed versions of an automation, newest first.
    case history(id: String)
    /// The diff from commit `base` to commit `target`, or from `target`'s parent when `base` is nil.
    case diff(id: String, base: String?, target: String)
    /// Restore the automation's folder as it was at a commit, and commit that.
    case rollback(id: String, toCommit: String)
    /// Recreate the SQLite index from the automation folders and the run log.
    case rebuildIndex
}

/// The runner's answer to a `RunnerCommand`.
public enum RunnerReply: Codable, Sendable, Equatable {
    case automations([AutomationSummary], paused: Bool)
    case installed(InstallReport)
    case removed(id: String)
    case ran(RunRecord)
    case tested(TestReport)
    case runs([RunRecord])
    case enabledChanged(id: String, enabled: Bool)
    case history(id: String, versions: [AutomationVersion])
    case diff(id: String, text: String)
    case rolledBack(id: String, version: Int)
    case done
    case snippet(ScriptResult)
    /// Empty `errors` means the script compiled.
    case compiled(errors: String)
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
    public var status: AutomationStatus

    /// `status` defaults to what the runner computes: disabled, broken (validation errors or
    /// a trigger that could not be registered) or active.
    public init(
        manifest: AutomationManifest,
        issues: [ValidationIssue],
        registrationError: String?,
        folderPath: String,
        enabled: Bool = true,
        status: AutomationStatus? = nil
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
        self.status = status ?? .installed(enabled: enabled, issues: issues, registrationError: registrationError)
    }

    public var isActive: Bool {
        status == .active
    }

    public var isEnabled: Bool {
        status != .disabled
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
