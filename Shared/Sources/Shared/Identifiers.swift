import Foundation

/// Every name that has to match across the app bundle, the runner bundle and launchd.
///
/// The same strings appear in `project.yml`, the Info.plist files and the launch agent
/// plist; `IdentifiersTests` checks they stay in sync.
public enum Identifiers {
    public static let appBundleID = "dev.cldixon.AutomationAgent"
    public static let runnerBundleID = "dev.cldixon.AutomationAgent.Runner"

    /// Product (and executable) name of the runner app embedded in the main app.
    public static let runnerProductName = "AutomationAgentRunner"

    /// launchd label of the runner's launch agent.
    public static let runnerLaunchAgentLabel = runnerBundleID

    /// File name of the launch agent plist inside `Contents/Library/LaunchAgents`.
    public static let runnerLaunchAgentPlistName = "\(runnerBundleID).plist"

    /// Mach service the runner listens on for XPC connections from the main app.
    public static let runnerMachServiceName = "\(runnerBundleID).xpc"

    /// Path of the runner executable relative to the main app bundle.
    public static let runnerBundleProgram =
        "Contents/Library/LoginItems/\(runnerProductName).app/Contents/MacOS/\(runnerProductName)"

    /// `os.Logger` subsystem shared by both processes.
    public static let logSubsystem = appBundleID
}
