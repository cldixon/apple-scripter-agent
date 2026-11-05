import SwiftUI

/// The app's top-level areas. Each maps to a milestone in the handoff doc.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case chat
    case catalog
    case runner
    case setup
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .catalog: "Catalog"
        case .runner: "Runner"
        case .setup: "Setup"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .catalog: "list.bullet.rectangle"
        case .runner: "gearshape.2"
        case .setup: "checklist"
        case .settings: "gear"
        }
    }
}

/// Sidebar on the left, the selected area on the right, runner status pinned under the sidebar.
struct RootView: View {
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $navigator.selection) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                RunnerStatusBadge()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            }
        } detail: {
            detail(for: navigator.selection ?? .chat)
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .chat:
            ChatView()
        case .catalog:
            CatalogView()
        case .runner:
            RunnerView()
        case .setup:
            SetupView()
        case .settings:
            SettingsView()
        }
    }
}

/// One line under the sidebar so runner health is visible from every screen.
struct RunnerStatusBadge: View {
    @Environment(RunnerController.self) private var runner

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runner.isHealthy ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(runner.isHealthy ? "Runner connected" : "Runner not connected")
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Stands in for an area that a later milestone builds, saying what will live there.
struct PlaceholderView: View {
    let title: String
    let milestone: String
    let summary: String
    let plannedItems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .bold()
            Text("Not built yet. Planned for \(milestone).")
                .foregroundStyle(.secondary)
            Text(summary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plannedItems, id: \.self) { item in
                    Label(item, systemImage: "circle.dotted")
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle(title)
    }
}
