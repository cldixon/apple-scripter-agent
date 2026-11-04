import SwiftUI

/// The background runner: no Dock icon, one menu bar item.
///
/// It is started by launchd (registered by the main app through `SMAppService`) and keeps
/// running after the main app quits. It holds the privacy permissions, registers each
/// automation's trigger and runs it.
@main
struct RunnerApp: App {
    @NSApplicationDelegateAdaptor(RunnerAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Automation Agent Runner", systemImage: "gearshape.2") {
            RunnerMenu(core: appDelegate.core, state: appDelegate.state)
        }
    }
}
