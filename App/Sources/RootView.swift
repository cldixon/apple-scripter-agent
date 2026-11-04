import SwiftUI

/// The app's top-level areas. Each maps to a milestone in the handoff doc.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case chat
    case catalog
    case runner
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .catalog: "Catalog"
        case .runner: "Runner"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .catalog: "list.bullet.rectangle"
        case .runner: "gearshape.2"
        case .settings: "gear"
        }
    }
}

/// Sidebar on the left, the selected area on the right, runner status pinned under the sidebar.
struct RootView: View {
    @State private var selection: SidebarItem? = .runner

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                RunnerStatusBadge()
                    .padding(10)
            }
        } detail: {
            detail(for: selection ?? .runner)
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .chat:
            PlaceholderView(
                title: "Chat",
                milestone: "M4 and M5",
                summary: "Describe an automation in plain words. The agent researches, drafts, "
                    + "validates and asks you to approve it here.",
                plannedItems: [
                    "Streamed replies from Claude",
                    "Inline cards for approvals, test requests and validation reports",
                    "Per-conversation token usage and spend cap"
                ]
            )
        case .catalog:
            CatalogView()
        case .runner:
            RunnerView()
        case .settings:
            PlaceholderView(
                title: "Settings",
                milestone: "M4",
                summary: "Your Claude API key, model choice and permissions.",
                plannedItems: [
                    "API key, stored in the Keychain",
                    "Model and spend cap",
                    "Live status of each macOS permission the runner needs"
                ]
            )
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
            Spacer()
        }
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
