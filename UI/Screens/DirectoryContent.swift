import SwiftUI
import GianCore

/// Directory content shared by the narrow home screen and the wide sidebar.
/// Membership and search rows come from Core; this view only renders their
/// exact page state and emits bounded, user-initiated paging actions.
struct DirectoryContent: View {
    let directory: DirectoryPresentation
    var selectedConversationID: SessionID? = nil
    var onSelectConversation: (SessionID) -> Void
    var onLoadMore: (DirectoryCollection) -> Void = { _ in }
    var onRefresh: (DirectoryCollection) -> Void = { _ in }
    /// Awaited by pull-to-refresh so the spinner lasts until the read ends.
    var onPullToRefresh: (DirectoryCollection) async -> Void = { _ in }
    /// The Host connection can serve reads; a never-loaded list waits for it.
    var canLoad: Bool = true

    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("directory-top")
                    if let result = directory.temporarySearchResult,
                       currentPage.phase != .denied, currentPage.phase != .unsupported {
                        ConversationRow(item: result, isSelected: result.id == selectedConversationID,
                                        showsRepo: true, onSelect: { onSelectConversation(result.id) })
                    }
                    if currentPage.phase != .denied && currentPage.phase != .unsupported {
                        ForEach(directory.temporaryCreatedResults) { result in
                            ConversationRow(item: result, isSelected: result.id == selectedConversationID,
                                            showsRepo: true, onSelect: { onSelectConversation(result.id) })
                        }
                    }
                    switch directory.view {
                    case .tasks:
                        directoryGroups(
                            collection: .tasks,
                            page: directory.tasksPage,
                            groups: directory.tasks.map { ($0.id.rawValue, $0.title, $0.conversations) },
                            unsupportedMessage: "Tasks are unavailable on this Host.",
                            emptyTitle: "No conversations in open tasks",
                            emptyDescription: "Conversations associated with open tasks will appear here."
                        )
                    case .repos:
                        directoryGroups(
                            collection: .repos,
                            page: directory.reposPage,
                            groups: directory.repos.map { ($0.id.rawValue, $0.repoName, $0.conversations) },
                            unsupportedMessage: unsupportedMessage(directory.reposAvailability),
                            emptyTitle: "No recent conversations",
                            emptyDescription: "Authorized conversations with recent activity will appear here."
                        )
                    }
                }
                .padding(.vertical, GianTheme.Metrics.paddingSmall)
            }
            .refreshable {
                await onPullToRefresh(currentCollection)
            }
            .task(id: AutoLoad(view: directory.view, canLoad: canLoad)) {
                // A never-loaded view loads on first sight (or as soon as a just
                // switched-to Host connects) instead of asking for a manual
                // refresh. Later reads stay user-initiated.
                if canLoad, currentPage.phase == .idle, currentIsEmpty {
                    onRefresh(currentCollection)
                }
            }
            .onChange(of: directory.temporarySearchGeneration) { _, _ in
                if directory.temporarySearchResult != nil { proxy.scrollTo("directory-top", anchor: .top) }
            }
        }
    }

    private struct AutoLoad: Equatable {
        let view: DirectoryView
        let canLoad: Bool
    }

    private var currentCollection: DirectoryCollection {
        directory.view == .tasks ? .tasks : .repos
    }

    private var currentPage: DirectoryPageStatus {
        directory.view == .tasks ? directory.tasksPage : directory.reposPage
    }

    private var currentIsEmpty: Bool {
        directory.view == .tasks ? directory.tasks.isEmpty : directory.repos.isEmpty
    }

    @ViewBuilder
    private func directoryGroups(
        collection: DirectoryCollection,
        page: DirectoryPageStatus,
        groups: [(String, String, [ConversationRowItem])],
        unsupportedMessage: String,
        emptyTitle: String,
        emptyDescription: String
    ) -> some View {
        if page.phase == .denied || page.phase == .unsupported {
            DirectoryPageStatusView(
                collection: collection,
                page: page,
                isEmpty: true,
                unsupportedMessage: unsupportedMessage,
                emptyTitle: emptyTitle,
                emptyDescription: emptyDescription,
                onLoadMore: onLoadMore,
                onRefresh: onRefresh
            )
        } else {
            ForEach(groups, id: \.0) { id, title, conversations in
                DirectoryGroupHeader(
                    title: title,
                    count: conversations.count,
                    isExpanded: expansionBinding(for: id)
                )
                if !collapsedGroups.contains(id) {
                    ForEach(conversations) { conversation in
                        ConversationRow(
                            item: conversation,
                            isSelected: conversation.id == selectedConversationID,
                            showsRepo: collection != .repos,
                            onSelect: { onSelectConversation(conversation.id) }
                        )
                    }
                }
            }
            DirectoryPageStatusView(
                collection: collection,
                page: page,
                isEmpty: groups.isEmpty && directory.temporarySearchResult == nil && directory.temporaryCreatedResults.isEmpty,
                unsupportedMessage: unsupportedMessage,
                emptyTitle: emptyTitle,
                emptyDescription: emptyDescription,
                onLoadMore: onLoadMore,
                onRefresh: onRefresh
            )
        }
    }

    private func expansionBinding(for groupID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(groupID) },
            set: { expanded in
                if expanded {
                    collapsedGroups.remove(groupID)
                } else {
                    collapsedGroups.insert(groupID)
                }
            }
        )
    }

    private func unsupportedMessage(_ availability: SurfaceAvailability) -> String {
        if case .unsupported(let message) = availability { return message }
        return "This directory is not supported by the connected Host."
    }
}

struct DirectoryPageStatusView: View {
    let collection: DirectoryCollection
    let page: DirectoryPageStatus
    let isEmpty: Bool
    let unsupportedMessage: String
    let emptyTitle: String
    let emptyDescription: String
    var onLoadMore: (DirectoryCollection) -> Void
    var onRefresh: (DirectoryCollection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GianTheme.Metrics.paddingSmall) {
            switch page.phase {
            case .idle:
                if isEmpty {
                    message(
                        "Not loaded yet",
                        detail: nil,
                        systemImage: "arrow.clockwise"
                    )
                    refreshButton("Load")
                }
            case .loading:
                if isEmpty {
                    HStack(spacing: GianTheme.Metrics.paddingSmall) {
                        ProgressView().controlSize(.small)
                        Text(loadingTitle)
                            .font(GianTheme.Typography.caption)
                            .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    }
                    .accessibilityElement(children: .combine)
                }
            case .incomplete:
                if isEmpty {
                    message(
                        emptyIncompleteTitle,
                        detail: "The Host reports more directory data to scan. This is not an empty result.",
                        systemImage: "ellipsis.circle"
                    )
                }
                if page.hasMore {
                    actionButton("Load more", systemImage: "chevron.down") {
                        onLoadMore(collection)
                    }
                    .accessibilityHint("Loads the next bounded set of directory pages.")
                } else {
                    message(
                        "Continuation unavailable",
                        detail: "This page is incomplete. Refresh to restart the directory read.",
                        systemImage: "exclamationmark.circle",
                        tint: GianTheme.Colors.warning
                    )
                    refreshButton("Refresh")
                }
            case .complete:
                if isEmpty {
                    message(emptyTitle, detail: emptyDescription, systemImage: "tray")
                    refreshButton("Refresh")
                }
            case .cursorInvalid:
                message(
                    "Directory changed",
                    detail: page.error ?? "The continuation is no longer valid. Restart the directory read.",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: GianTheme.Colors.warning
                )
                refreshButton("Restart")
            case .failed:
                message(
                    isEmpty ? "Directory couldn't load" : "Directory refresh failed",
                    detail: page.error ?? "The Host could not provide this directory page.",
                    systemImage: "exclamationmark.circle",
                    tint: GianTheme.Colors.failure
                )
                refreshButton("Retry")
            case .denied:
                message(
                    "Conversation access denied",
                    detail: page.error ?? "The Host has not granted conversation access.",
                    systemImage: "lock.shield",
                    tint: GianTheme.Colors.failure
                )
                refreshButton("Check access")
            case .unsupported:
                message(
                    "Directory unavailable",
                    detail: unsupportedMessage,
                    systemImage: "exclamationmark.triangle",
                    tint: GianTheme.Colors.warning
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GianTheme.Metrics.paddingLarge)
        .padding(.vertical, GianTheme.Metrics.paddingMedium)
    }

    private var loadingTitle: String {
        switch collection {
        case .tasks: "Loading tasks…"
        case .repos: "Loading repositories…"
        case .search: "Searching…"
        }
    }

    private var emptyIncompleteTitle: String {
        collection == .search ? "No matches loaded yet" : "No rows loaded yet"
    }

    private func message(
        _ title: String,
        detail: String?,
        systemImage: String,
        tint: Color = GianTheme.Colors.secondaryLabel
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(GianTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(tint)
            if let detail {
                Text(detail)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refreshButton(_ title: String) -> some View {
        actionButton(title, systemImage: "arrow.clockwise") {
            onRefresh(collection)
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(GianTheme.Typography.caption.weight(.semibold))
                .frame(minHeight: GianTheme.Metrics.minHitTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(GianTheme.Colors.tint)
        .accessibilityLabel(title)
    }
}

/// Host results are narrowed to conversation titles by Core.
struct SearchScreen: View {
    let directory: DirectoryPresentation
    var onQueryChange: (String) -> Void
    var onSelectConversation: (SessionID) -> Void
    var onLoadMore: (DirectoryCollection) -> Void = { _ in }
    var onRefresh: (DirectoryCollection) -> Void = { _ in }
    var onClose: () -> Void
    @State private var queryText = ""

    private var normalizedQuery: String {
        queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Group {
                if directory.searchPage.phase == .denied || directory.searchPage.phase == .unsupported {
                    DirectoryPageStatusView(
                        collection: .search,
                        page: directory.searchPage,
                        isEmpty: true,
                        unsupportedMessage: searchUnsupportedMessage,
                        emptyTitle: "No results",
                        emptyDescription: "",
                        onLoadMore: onLoadMore,
                        onRefresh: onRefresh
                    )
                } else if normalizedQuery.isEmpty {
                    ContentUnavailableView(
                        "Search conversations",
                        systemImage: "magnifyingglass",
                        description: Text("Find conversations by title.")
                    )
                } else if directory.searchQuery != normalizedQuery {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(directory.searchResults) { conversation in
                                ConversationRow(
                                    item: conversation,
                                    onSelect: { onSelectConversation(conversation.id) }
                                )
                            }
                            DirectoryPageStatusView(
                                collection: .search,
                                page: directory.searchPage,
                                isEmpty: directory.searchResults.isEmpty,
                                unsupportedMessage: searchUnsupportedMessage,
                                emptyTitle: "No results",
                                emptyDescription: "The Host returned no matching conversation titles for \"\(directory.searchQuery)\".",
                                onLoadMore: onLoadMore,
                                onRefresh: onRefresh
                            )
                        }
                        .padding(.vertical, GianTheme.Metrics.paddingSmall)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
        }
        .searchable(text: $queryText, prompt: "Conversation title")
        .onAppear { queryText = directory.searchQuery }
        .task(id: queryText) {
            let value = queryText
            if !value.isEmpty {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            onQueryChange(value)
        }
        .background(GianTheme.Colors.background)
    }

    private var searchUnsupportedMessage: String {
        if case .unsupported(let message) = directory.searchAvailability { return message }
        return "Search is not supported by the connected Host."
    }
}
