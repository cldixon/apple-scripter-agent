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
}
