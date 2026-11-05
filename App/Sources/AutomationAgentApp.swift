import SwiftUI

@main
struct AutomationAgentApp: App {
    @State private var runner = RunnerController()
    @State private var catalog: CatalogController
    @State private var settings: AgentSettings
    @State private var apiKey = APIKeyController()
    @State private var navigator = AppNavigator()
    @State private var chat: ChatController

    init() {
        let settings = AgentSettings()
        let catalog = CatalogController()
        _settings = State(initialValue: settings)
        _catalog = State(initialValue: catalog)
        _chat = State(initialValue: ChatController(settings: settings, catalog: catalog))
    }

    var body: some Scene {
        WindowGroup("Automation Agent") {
            Group {
                if apiKey.hasKey {
                    RootView()
                } else {
                    OnboardingView()
                }
            }
            .environment(runner)
            .environment(catalog)
            .environment(settings)
            .environment(apiKey)
            .environment(chat)
            .environment(navigator)
            .task { await runner.onLaunch() }
        }
        .defaultSize(width: 960, height: 640)
    }
}
