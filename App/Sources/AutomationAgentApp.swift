import SwiftUI

@main
struct AutomationAgentApp: App {
    @State private var runner = RunnerController()
    @State private var catalog = CatalogController()

    var body: some Scene {
        WindowGroup("Automation Agent") {
            RootView()
                .environment(runner)
                .environment(catalog)
                .task { await runner.onLaunch() }
        }
        .defaultSize(width: 960, height: 640)
    }
}
