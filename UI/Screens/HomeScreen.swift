import SwiftUI
import GianCore

/// Narrow home: GitHub avatar (opens Settings) top-left, search top-right,
/// Host selector pills, Tasks/Repos segmented views, and the long new-chat
/// composer entry at the bottom. No screen title, no bottom gear.
struct HomeScreen: View {
    let accountLogin: String
    let hosts: [HostItem]
    let directory: DirectoryPresentation

    var onOpenSettings: () -> Void = {}
    var onOpenSearch: () -> Void = {}
    var onSelectHost: (HostID) -> Void = { _ in }
    var onSelectDirectoryView: (DirectoryView) -> Void = { _ in }
    var onSelectConversation: (SessionID) -> Void = { _ in }
    var onLoadMoreDirectory: (DirectoryCollection) -> Void = { _ in }
    var onRefreshDirectory: (DirectoryCollection) -> Void = { _ in }
    var onOpenNewChat: () -> Void = {}

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingSmall) {
            header
            HostPillSelector(hosts: hosts, onSelect: onSelectHost)
            DirectorySegmentedControl(selection: Binding(
                get: { directory.view },
                set: onSelectDirectoryView
            ))
            DirectoryContent(
                directory: directory,
                onSelectConversation: onSelectConversation,
                onLoadMore: onLoadMoreDirectory,
                onRefresh: onRefreshDirectory
            )
            NewChatEntryBar(onOpen: onOpenNewChat)
                .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                .padding(.bottom, GianTheme.Metrics.paddingSmall)
        }
        .background(GianTheme.Colors.background)
    }

    private var header: some View {
        HStack {
            Button(action: onOpenSettings) {
                UserAvatar(login: accountLogin, size: GianTheme.Metrics.avatarMedium)
            }
            .buttonStyle(.plain)
            .gianHitTarget()
            Spacer()
            Button(action: onOpenSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(GianTheme.Colors.label)
                    .gianHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search conversations")
        }
        .padding(.horizontal, GianTheme.Metrics.paddingLarge)
        .padding(.top, GianTheme.Metrics.paddingSmall)
    }
}
