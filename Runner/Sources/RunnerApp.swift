import SwiftUI

/// The background runner: no Dock icon, one menu bar item.
///
/// It is started by launchd (registered by the main app through `SMAppService`) and keeps
/// running after the main app quits. In later milestones it holds every privacy permission
/// and executes automations; in M0 it only answers pings over XPC.
@main
struct RunnerApp: App {
    @NSApplicationDelegateAdaptor(RunnerAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Automation Agent Runner", systemImage: "gearshape.2") {
            RunnerMenu(state: appDelegate.state)
        }
    }
}
