import Foundation
import os
import Shared
import UserNotifications

/// Posts a notification when an automation becomes broken (M6).
enum FailureNotifier {
    private static let logger = Logger(subsystem: Identifiers.logSubsystem, category: "monitor")

    static func postBroken(name: String, failures: Int, lastError: String?) {
        let detail = lastError.map { String($0.prefix(200)) } ?? "No error message."
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    logger.info("Notifications are off; not announcing that \(name, privacy: .public) is broken")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "\(name) is broken"
                content.body = "It failed \(failures) times in a row. \(detail)\n"
                    + "Open Automation Agent > Catalog and choose Fix with Agent."
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try await center.add(request)
            } catch {
                logger.error("Could not post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
