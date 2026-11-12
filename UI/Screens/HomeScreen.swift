import SwiftUI
import GianCore

/// Conversation directory shared by the compact home screen and the wide
/// sidebar. Controls are system toolbar items (symbol + title), so on iPhone
/// Duo they move into the vertical bar, in two groups: the global New chat +
/// Settings (also present in every other screen) and the list's own Search +
/// List options. The current Host has a status dot; tap it to switch or add
/// Hosts. The expanded portrait directory places Search and List options on
/// the left and global actions on the right; the wide landscape sidebar keeps
/// its list actions on the right and global actions in the detail column.
struct HomeScreen: View {
    let hosts: [HostItem]
    let directory: DirectoryPresentation
    /// Highlighted row in the wide layout; nil on compact screens.
    var selectedConversationID: SessionID? = nil
    /// The wide layout's sidebar: no global group (the detail column's bar
    /// carries it).
    var isSidebar: Bool = false
    /// Hides the sidebar; nil where it isn't collapsible (landscape, compact).
    var onToggleSidebar: (() -> Void)? = nil

    var onOpenSettings: () -> Void = {}
    var onOpenSearch: () -> Void = {}
    var onSelectHost: (HostID) -> Void = { _ in }
    var onSelectDirectoryView: (DirectoryView) -> Void = { _ in }
    var onSelectTimeFilter: (DirectoryTimeFilter) -> Void = { _ in }
    var onSelectConversation: (SessionID) -> Void = { _ in }
    var onLoadMoreDirectory: (DirectoryCollection) -> Void = { _ in }
    var onRefreshDirectory: (DirectoryCollection) -> Void = { _ in }
    /// Pull-to-refresh awaits this so the spinner lasts until the read ends.
    var onPullToRefresh: (DirectoryCollection) async -> Void = { _ in }
    var onOpenNewChat: () -> Void = {}
    var onAddHost: () -> Void = {}
    /// The Host connection is ready; an unloaded list loads then.
    var canLoad: Bool = true

    @Environment(\.globalActionsAtBottom) private var globalActionsAtBottom
    @Environment(\.titlesLeading) private var titlesLeading

    private var currentHost: HostItem? {
        hosts.first(where: \.isCurrent)
    }

    private var currentCollection: DirectoryCollection {
        directory.view == .tasks ? .tasks : .repos
    }

    var body: some View {
        DirectoryContent(
            directory: directory,
            selectedConversationID: selectedConversationID,
            onSelectConversation: onSelectConversation,
            onLoadMore: onLoadMoreDirectory,
            onRefresh: onRefreshDirectory,
            onPullToRefresh: onPullToRefresh,
            canLoad: canLoad
        )
        // Per Host, so a newly switched-to (or added) Host's list loads on
        // sight like the first one did.
        .id(currentHost?.id)
        .navigationTitle(currentHost?.name ?? "Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSidebar, let onToggleSidebar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Hide sidebar", systemImage: "sidebar.left", action: onToggleSidebar)
                    CurrentHostMenu(hosts: hosts, onSelect: onSelectHost, onAddHost: onAddHost, onManage: onOpenSettings)
                }
            } else {
                ScreenTitleItem(leading: titlesLeading) {
                    CurrentHostMenu(hosts: hosts, onSelect: onSelectHost, onAddHost: onAddHost, onManage: onOpenSettings)
                }
            }
            if !isSidebar {
                GlobalToolbarActions(atBottom: globalActionsAtBottom, onNewChat: onOpenNewChat, onSettings: onOpenSettings)
                if !globalActionsAtBottom {
                    // Keeps the global pair and the list actions as separate groups.
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
            }
            // List actions: they operate on this conversation list.
            ToolbarItemGroup(placement: .topBarTrailing) { directoryActions }
        }
    }

    @ViewBuilder
    private var directoryActions: some View {
        Button("Search conversations", systemImage: "magnifyingglass", action: onOpenSearch)
        DirectoryListMenu(
            selection: Binding(get: { directory.view }, set: onSelectDirectoryView),
            timeFilter: directory.timeFilter,
            onSelectTimeFilter: onSelectTimeFilter,
            onRefresh: { onRefreshDirectory(currentCollection) }
        )
    }
}
