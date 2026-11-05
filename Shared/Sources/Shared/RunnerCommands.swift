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

    // MARK: Agent tools (M5)

    /// Full-text search of the reference library.
    case searchReference(query: String, limit: Int)
    case readReference(id: String)
    /// Summary of an app's scripting dictionary (name or bundle id), filtered by `query`.
    case introspectApp(app: String, query: String?)
    case listApps
    case listShortcuts
    case checkPermissions([Permission])
    case readAutomation(id: String)
    /// Create or replace the draft with the manifest's id in `drafts/`, with its files.
    case writeDraft(manifest: Data, files: [DraftFile])
    /// Static, compile, unit and harness checks on a draft.
    case validateDraft(id: String)
    /// Install a draft after the user approved it (the main app asks first).
    case installDraft(id: String)
    case discardDraft(id: String)
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
    case referenceHits([ReferenceHit])
    case referenceChunk(ReferenceChunk)
    case appDictionary(AppDictionarySummary)
    case apps([AppInfo])
    case shortcuts([String])
    case permissions([PermissionStatus])
    case automation(AutomationDetail)
    case draftWritten(id: String, issues: [ValidationIssue])
    case draftValidated(TestReport)
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
    /// Recent consecutive failures of real runs (M6); broken at `FailureMonitor.brokenThreshold`.
    public var failureStreak: FailureStreak

    /// `status` defaults to what the runner computes: disabled, broken (validation errors or
    /// a trigger that could not be registered) or active.
    public init(
        manifest: AutomationManifest,
        issues: [ValidationIssue],
        registrationError: String?,
        folderPath: String,
        enabled: Bool = true,
        status: AutomationStatus? = nil,
        failureStreak: FailureStreak = FailureStreak()
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
        self.failureStreak = failureStreak
        self.status = status ?? .installed(
            enabled: enabled,
            issues: issues,
            registrationError: registrationError,
            failingRuns: failureStreak.failures
        )
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
