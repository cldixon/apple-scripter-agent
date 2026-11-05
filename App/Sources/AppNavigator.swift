import Observation

/// Which sidebar area is showing. Shared so one screen can send the user to another
/// (the Catalog's "Fix with Agent" opens Chat).
@MainActor
@Observable
final class AppNavigator {
    var selection: SidebarItem? = .chat
}
