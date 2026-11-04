import SwiftUI

@main
struct AutomationAgentApp: App {
    @State private var runner = RunnerController()

    var body: some Scene {
        WindowGroup("Automation Agent") {
            RootView()
                .environment(runner)
                .task { await runner.onLaunch() }
        }
        .defaultSize(width: 960, height: 640)
    }
}
