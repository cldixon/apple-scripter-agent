import Foundation
import Shared
import UserNotifications

/// The real `AutomationEnvironment`: primitives act on this Mac.
struct SystemEnvironment: AutomationEnvironment {
    func now() -> Date { Date() }

    func typeText(_ text: String) async throws {
        try await SystemActions.type(text)
    }

    func pasteText(_ text: String) async throws {
        try await SystemActions.paste(text)
    }

    func readClipboard() async throws -> String {
        await SystemActions.readClipboard()
    }

    func writeClipboard(_ text: String) async throws {
        await SystemActions.writeClipboard(text)
    }

    func notify(title: String, text: String) async throws {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw AutomationError.system("Notifications are turned off for Automation Agent Runner in System Settings.")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func openURL(_ url: URL) async throws {
        try await SystemActions.open(url)
    }

    func launchApp(_ app: String) async throws {
        try await SystemActions.launch(app)
    }

    func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    func runScript(_ request: ScriptRequest) async throws -> String {
        try await checkAutomationTargets(request)
        return try await ScriptRunner.run(request)
    }

    /// The runner refuses a script that controls an app the manifest did not declare.
    private func checkAutomationTargets(_ request: ScriptRequest) async throws {
        guard request.language == .applescript || request.language == .jxa else { return }
        let source = request.source ?? request.file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let declared = Set(request.declaredPermissions.compactMap(\.automationTarget))
        for target in ScriptAnalysis.targetApplications(in: source, language: request.language)
        where !ScriptAnalysis.exemptTargets.contains(target) {
            let bundleID = await SystemActions.bundleIdentifier(forApp: target) ?? target
            guard declared.contains(bundleID) || declared.contains(target) else {
                throw AutomationError.permissionMissing(.automation(bundleID))
            }
        }
    }
}
