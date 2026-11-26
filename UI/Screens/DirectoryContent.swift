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
    var connectionNotice: ListConnectionNotice? = nil
    var onRetryConnection: () -> Void = {}
    var onAddHost: () -> Void = {}

    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("directory-top")
                    if let connectionNotice {
                        ListConnectionNoticeView(notice: connectionNotice, onRetry: onRetryConnection, onPair: onAddHost)
                    }
                    if let result = directory.temporarySearchResult,
                       currentPage.phase != .denied, currentPage.phase != .unsupported {
                        ConversationRow(item: result, isSelected: result.id == selectedConversationID,
                                        showsRepo: true, isLive: connectionNotice == nil, onSelect: { onSelectConversation(result.id) })
                            .equatable()
                    }
                    if currentPage.phase != .denied && currentPage.phase != .unsupported {
                        ForEach(directory.temporaryCreatedResults) { result in
                            ConversationRow(item: result, isSelected: result.id == selectedConversationID,
                                            showsRepo: true, isLive: connectionNotice == nil, onSelect: { onSelectConversation(result.id) })
                                .equatable()
                        }
                    }
                    switch directory.view {
                    case .tasks:
                        directoryGroups(
                            collection: .tasks,
                            page: directory.tasksPage,
                            groups: directory.tasks.map { ($0.id.rawValue, $0.title, $0.conversations) },
                            unsupportedMessage: "Tasks are unavailable on this Host.",
                            emptyTitle: "Nothing in open tasks \(filterPhrase)",
                            emptyDescription: "Older conversations are hidden by the time filter (List options)."
                        )
                    case .repos:
                        directoryGroups(
                            collection: .repos,
                            page: directory.reposPage,
                            groups: directory.repos.map { ($0.id.rawValue, $0.repoName, $0.conversations) },
                            unsupportedMessage: unsupportedMessage(directory.reposAvailability),
                            emptyTitle: "Nothing \(filterPhrase)",
                            emptyDescription: "Older conversations are hidden by the time filter (List options)."
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

    private var filterPhrase: String {
        switch directory.timeFilter {
        case .lastHour: "in the last hour"
        case .last24Hours: "in the last 24 hours"
        case .last7Days: "in the last 7 days"
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
                canLoad: canLoad,
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
                            isLive: connectionNotice == nil,
                            onSelect: { onSelectConversation(conversation.id) }
                        )
                        // Unchanged rows skip re-rendering when the directory updates.
                        .equatable()
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
                canLoad: canLoad,
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
        return "This Host doesn't support this list."
    }
}

struct DirectoryPageStatusView: View {
    let collection: DirectoryCollection
    let page: DirectoryPageStatus
    let isEmpty: Bool
    let unsupportedMessage: String
    let emptyTitle: String
    let emptyDescription: String
    /// False while the Host connection isn't ready: a never-loaded list
    /// says it is connecting instead of offering a Load that can't work.
    var canLoad = true
    var onLoadMore: (DirectoryCollection) -> Void
    var onRefresh: (DirectoryCollection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GianTheme.Metrics.paddingSmall) {
            switch page.phase {
            case .idle:
                if isEmpty {
                    if canLoad {
                        message("Not loaded yet", detail: nil, systemImage: "arrow.clockwise")
                        refreshButton("Load")
                    } else {
                        HStack(spacing: GianTheme.Metrics.paddingSmall) {
                            ProgressView().controlSize(.small)
                            Text("Connecting to the Host…")
                                .font(GianTheme.Typography.caption)
                                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                        }
                        .accessibilityElement(children: .combine)
                    }
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
                        detail: "The Host has more to look through.",
                        systemImage: "ellipsis.circle"
                    )
                }
                if page.hasMore {
                    actionButton("Load more", systemImage: "chevron.down") {
                        onLoadMore(collection)
                    }
                    .accessibilityHint("Loads more conversations.")
                } else {
                    message(
                        "Couldn't load the rest",
                        detail: "Refresh to try again.",
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
                    "The list changed",
                    detail: "Refresh to see the latest.",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: GianTheme.Colors.warning
                )
                refreshButton("Refresh")
            case .failed:
                message(
                    isEmpty ? "Couldn't load conversations" : "Couldn't refresh conversations",
                    detail: page.error ?? "The Host didn't answer.",
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
                    "Conversations unavailable",
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
        collection == .search ? "No matches yet" : "Nothing found yet"
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
    @State private var searching = false

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
                                .equatable()
                            }
                            DirectoryPageStatusView(
                                collection: .search,
                                page: directory.searchPage,
                                isEmpty: directory.searchResults.isEmpty,
                                unsupportedMessage: searchUnsupportedMessage,
                                emptyTitle: "No results",
                                emptyDescription: "No conversation titles match \"\(directory.searchQuery)\".",
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
        // Ready to type as soon as it opens (it took an extra tap).
        .searchable(text: $queryText, isPresented: $searching, prompt: "Conversation title")
        .onAppear {
            queryText = directory.searchQuery
            searching = true
        }
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

/// The connection while it isn't live, above the list: what's wrong, that
/// the list is saved history, and what to do.
struct ListConnectionNoticeView: View {
    let notice: ListConnectionNotice
    var onRetry: () -> Void
    var onPair: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GianTheme.Metrics.paddingSmall) {
            if notice == .reconnecting {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: notice.systemImage)
                    .foregroundStyle(notice == .revoked ? GianTheme.Colors.failure : GianTheme.Colors.secondaryLabel)
            }
            Text(notice.text)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if notice.canRetry {
                Button("Retry", action: onRetry)
                    .foregroundStyle(GianTheme.Colors.tint)
                    .gianHitTarget()
            } else if notice == .revoked {
                Button("Pair", action: onPair)
                    .foregroundStyle(GianTheme.Colors.tint)
                    .gianHitTarget()
            }
        }
        .font(GianTheme.Typography.caption)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.vertical, GianTheme.Metrics.paddingSmall)
        .background(GianTheme.Colors.secondaryLabel.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusMedium, style: .continuous))
        .padding(.horizontal, GianTheme.Metrics.paddingSmall)
        .padding(.bottom, GianTheme.Metrics.paddingSmall)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("list-connection-notice")
    }
}
