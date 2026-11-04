import AppKit
import ApplicationServices
import CoreServices
import Shared

/// Checks the runner's privacy permissions without prompting. `check_permissions` uses it so
/// the agent can say what a new automation will need before it runs.
enum PermissionChecker {
    private static let settings = "System Settings > Privacy & Security"

    static func check(_ permissions: [Permission]) async -> [PermissionStatus] {
        var statuses: [PermissionStatus] = []
        for permission in permissions {
            statuses.append(await status(of: permission))
        }
        return statuses
    }

    static func status(of permission: Permission) async -> PermissionStatus {
        if let bundleID = permission.automationTarget {
            // Asking tccd can block briefly; keep it off the caller's actor.
            let (state, detail) = await Task.detached { PermissionChecker.automation(bundleID: bundleID) }.value
            return PermissionStatus(permission: permission, state: state, detail: detail)
        }
        switch permission {
        case .accessibility:
            let trusted = AXIsProcessTrusted()
            return PermissionStatus(
                permission: permission, state: trusted ? .granted : .denied,
                detail: trusted ? "Allowed." : "Not allowed. Turn on Automation Agent Runner in \(settings) > "
                    + "Accessibility (the runner's menu has \"Allow Accessibility…\")."
            )
        case .screenRecording:
            let allowed = CGPreflightScreenCaptureAccess()
            return PermissionStatus(
                permission: permission, state: allowed ? .granted : .denied,
                detail: allowed ? "Allowed." : "Not allowed. Turn on Automation Agent Runner in \(settings) > "
                    + "Screen & System Audio Recording."
            )
        case .fullDiskAccess:
            let (state, detail) = fullDiskAccess()
            return PermissionStatus(permission: permission, state: state, detail: detail)
        default:
            return PermissionStatus(
                permission: permission, state: .unknown,
                detail: "Unknown permission. Use accessibility, automation:<bundle id>, fullDiskAccess or "
                    + "screenRecording."
            )
        }
    }

    /// Whether the runner may send Apple Events to `bundleID`, without asking the user.
    static func automation(bundleID: String) -> (PermissionStatus.State, String) {
        let pane = "\(settings) > Automation > Automation Agent Runner"
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else {
            return (.unknown, "Could not address \(bundleID).")
        }
        let status = AEDeterminePermissionToAutomateTarget(
            address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false
        )
        switch status {
        case 0:
            return (.granted, "Allowed. Change it in \(pane).")
        case -1_743:
            return (.denied, "Denied. Turn on \(bundleID) under \(pane).")
        case -1_744:
            return (.notDetermined, "Not asked yet: macOS asks the first time an automation controls the app.")
        case -600:
            return (.unknown, "The app is not running; launch the app to check.")
        default:
            return (.unknown, "Could not check (status \(status)).")
        }
    }

    /// Full Disk Access, judged by opening files that only it unlocks.
    static func fullDiskAccess() -> (PermissionStatus.State, String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "\(home)/Library/Mail"
        ]
        var refused = false
        for path in protected {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return (.granted, "Allowed.")
            }
            if errno == EPERM || errno == EACCES { refused = true }
        }
        if refused {
            return (.denied, "Not allowed. Add Automation Agent Runner in \(settings) > Full Disk Access.")
        }
        return (.unknown, "Could not tell: none of the protected files it checks exist.")
    }
}
