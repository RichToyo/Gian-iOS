#if DEBUG
import SwiftUI
import GianCore

enum DirectoryPreviewFixtures {
    static let instant = Date(timeIntervalSince1970: 1_781_000_000)

    static func id<Kind>(_ raw: String, _ type: ScopedID<Kind>.Type) -> ScopedID<Kind> {
        guard let value = ScopedID<Kind>(rawValue: raw) else {
            preconditionFailure("Invalid fictional preview ID")
        }
        return value
    }

    static var rows: [ConversationRowItem] {
        [
            ConversationRowItem(
                id: id("preview-session-1", SessionID.self),
                title: "Match in an older message",
                agent: .kimi,
                agentName: "Kimi",
                repoName: "Harbor Repo",
                badge: .idle,
                lastActivity: instant
            ),
            ConversationRowItem(
                id: id("preview-session-2", SessionID.self),
                title: "Review directory continuation",
                agent: .grok,
                agentName: "Grok",
                repoName: "Harbor Repo",
                badge: .working,
                lastActivity: instant.addingTimeInterval(-300)
            ),
        ]
    }

    static func presentation(
        view: DirectoryView = .tasks,
        tasksPage: DirectoryPageStatus = DirectoryPageStatus(phase: .complete, isStale: false),
        reposPage: DirectoryPageStatus = DirectoryPageStatus(phase: .complete, isStale: false),
        searchPage: DirectoryPageStatus = DirectoryPageStatus(phase: .complete, isStale: false),
        searchQuery: String = "",
        includeRows: Bool = true
    ) -> DirectoryPresentation {
        DirectoryPresentation(
            view: view,
            tasks: includeRows ? [
                TaskGroupItem(
                    id: id("preview-task", TaskID.self),
                    title: "Open directory work",
                    conversations: rows
                )
            ] : [],
            repos: includeRows ? [
                RepoGroupItem(
                    id: id("preview-workspace", WorkspaceID.self),
                    repoName: "Harbor Repo",
                    conversations: rows
                )
            ] : [],
            reposAvailability: .ready,
            searchQuery: searchQuery,
            searchResults: includeRows && !searchQuery.isEmpty ? rows : [],
            searchAvailability: .ready,
            tasksPage: tasksPage,
            reposPage: reposPage,
            searchPage: searchPage
        )
    }
}

#Preview("Tasks · complete") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(),
        onSelectConversation: { _ in }
    )
}

#Preview("Tasks · empty complete") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(includeRows: false),
        onSelectConversation: { _ in }
    )
}

#Preview("Directory · idle") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(
            tasksPage: DirectoryPageStatus(),
            includeRows: false
        ),
        onSelectConversation: { _ in }
    )
}

#Preview("Directory · loading retained rows") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(
            tasksPage: DirectoryPageStatus(phase: .loading, hasMore: true, isStale: true)
        ),
        onSelectConversation: { _ in }
    )
}

#Preview("Tasks · empty incomplete") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(
            tasksPage: DirectoryPageStatus(phase: .incomplete, hasMore: true, isStale: false),
            includeRows: false
        ),
        onSelectConversation: { _ in }
    )
}

#Preview("Repos · stale partial rows") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(
            view: .repos,
            reposPage: DirectoryPageStatus(phase: .incomplete, hasMore: true, isStale: true)
        ),
        onSelectConversation: { _ in }
    )
}

#Preview("Directory · cursor invalid") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(
            tasksPage: DirectoryPageStatus(phase: .cursorInvalid, isStale: true)
        ),
        onSelectConversation: { _ in }
    )
}

#Preview("Directory · failed with retained rows") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(
            tasksPage: DirectoryPageStatus(
                phase: .failed,
                isStale: true,
                error: "The Host did not answer. Saved rows remain available."
            )
        ),
        onSelectConversation: { _ in }
    )
}

#Preview("Directory · denied hides rows") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(
            tasksPage: DirectoryPageStatus(
                phase: .denied,
                error: "The Host has not granted conversation access."
            )
        ),
        onSelectConversation: { _ in }
    )
}

#Preview("Directory · unsupported") {
    DirectoryContent(
        directory: DirectoryPreviewFixtures.presentation(
            view: .repos,
            reposPage: DirectoryPageStatus(phase: .unsupported)
        ),
        onSelectConversation: { _ in }
    )
}

#Preview("Search · Host-authoritative rows") {
    SearchScreen(
        directory: DirectoryPreviewFixtures.presentation(searchQuery: "older words"),
        onQueryChange: { _ in },
        onSelectConversation: { _ in },
        onClose: {}
    )
}

#Preview("Search · empty incomplete") {
    SearchScreen(
        directory: DirectoryPreviewFixtures.presentation(
            searchPage: DirectoryPageStatus(phase: .incomplete, hasMore: true, isStale: false),
            searchQuery: "older words",
            includeRows: false
        ),
        onQueryChange: { _ in },
        onSelectConversation: { _ in },
        onClose: {}
    )
}
#endif
