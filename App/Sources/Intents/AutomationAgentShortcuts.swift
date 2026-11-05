import AppIntents

/// One parameterised App Shortcut covers every installed automation, so new automations
/// appear in Shortcuts, Spotlight and Siri without per-automation code. The catalog calls
/// `updateAppShortcutParameters()` whenever its list changes so the phrases name them.
struct AutomationAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAutomationIntent(),
            phrases: [
                "Run \(\.$automation) in \(.applicationName)",
                "Run \(\.$automation) with \(.applicationName)",
                "Run an automation in \(.applicationName)"
            ],
            shortTitle: "Run Automation",
            systemImageName: "bolt.fill"
        )
    }
}
