import Foundation

public enum DirectoryCollection: String, Codable, Sendable, CaseIterable {
    case tasks, repos, search
}

public enum DirectoryPagePhase: String, Codable, Sendable {
    case idle, loading, incomplete, complete, cursorInvalid, failed, denied, unsupported
}

public struct DirectoryPageStatus: Codable, Sendable, Equatable {
    public var phase: DirectoryPagePhase
    public var hasMore: Bool
    public var isStale: Bool
    public var error: String?

    public init(phase: DirectoryPagePhase = .idle, hasMore: Bool = false,
                isStale: Bool = true, error: String? = nil) {
        self.phase = phase; self.hasMore = hasMore; self.isStale = isStale; self.error = error
    }
    public var isLoading: Bool { phase == .loading }
}

public struct RepositorySection: Sendable, Equatable, Identifiable {
    public var id: WorkspaceID
    public var title: String
    public var conversations: [ConversationSummary]

    public init(id: WorkspaceID, title: String, conversations: [ConversationSummary]) {
        self.id = id; self.title = title; self.conversations = conversations
    }
}

public struct DirectoryEntry: Codable, Sendable, Equatable {
    public var session: SessionRecord
    public var workspace: WorkspaceRecord
    public var task: TaskRecord?

    public init(session: SessionRecord, workspace: WorkspaceRecord, task: TaskRecord?) {
        self.session = session; self.workspace = workspace; self.task = task
    }
}

public struct DirectoryPageRequest: Sendable, Equatable {
    public var view: DirectoryCollection
    public var query: String?
    public var cursor: String?
    public var limit: Int

    public init(view: DirectoryCollection, query: String? = nil, cursor: String? = nil, limit: Int = 30) {
        self.view = view; self.query = query; self.cursor = cursor; self.limit = limit
    }
}

public enum DirectoryPageState: String, Sendable, Equatable {
    case complete, incomplete, cursorInvalid
}

public struct DirectoryPagePayload: Sendable, Equatable {
    public var view: DirectoryCollection
    public var asOf: Date
    public var revision: String
    public var state: DirectoryPageState
    public var entries: [DirectoryEntry]
    public var nextCursor: String?

    public init(view: DirectoryCollection, asOf: Date, revision: String, state: DirectoryPageState,
                entries: [DirectoryEntry], nextCursor: String?) {
        self.view = view; self.asOf = asOf; self.revision = revision; self.state = state
        self.entries = entries; self.nextCursor = nextCursor
    }
}

public enum DirectoryPageResponse: Sendable, Equatable {
    case page(DirectoryPagePayload)
    case unsupported
    case denied
    case failed(String)
}

/// A traversal is independent of legacy snapshots and canonical replay. Cursors
/// are opaque and are discarded across reconnects, query changes and restarts.
public struct StoredDirectoryView: Codable, Sendable, Equatable {
    public var entries: [DirectoryEntry] = []
    public var pendingEntries: [DirectoryEntry]?
    public var query: String?
    public var cursor: String?
    public var revision: String?
    public var asOf: Date?
    public var visitedCursors: [String] = []
    public var status = DirectoryPageStatus()

    public init() {}
    public var visibleEntries: [DirectoryEntry] { entries.isEmpty ? pendingEntries ?? [] : entries }

    mutating func invalidate() {
        if entries.isEmpty { entries = pendingEntries ?? [] }
        pendingEntries = nil; cursor = nil; revision = nil; asOf = nil; visitedCursors = []
        status = DirectoryPageStatus()
    }

    mutating func apply(_ page: DirectoryPagePayload, scope: ClientScope, view: DirectoryCollection) -> Bool {
        guard page.view == view, page.asOf.timeIntervalSince1970.isFinite, !page.revision.isEmpty,
              page.entries.count <= 64,
              Set(page.entries.map { $0.session.id }).count == page.entries.count,
              page.entries.allSatisfy({ entry in
                  entry.session.hostID == scope.host && entry.session.authorized && !entry.session.archived
                      && entry.session.workspaceID == entry.workspace.id && entry.session.taskID == entry.task?.id
                      && (view != .tasks || entry.task?.status == .open)
              }) else { return false }
        if page.state == .cursorInvalid {
            guard page.entries.isEmpty, page.nextCursor == nil else { return false }
            invalidate(); status.phase = .cursorInvalid
            return true
        }
        guard (page.state == .incomplete) == (page.nextCursor != nil),
              page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 4096 && !visitedCursors.contains($0) }) ?? true,
              revision == nil || (revision == page.revision && asOf == page.asOf) else { return false }
        var merged = (pendingEntries ?? []).reduce(into: [SessionID: DirectoryEntry]()) { $0[$1.session.id] = $1 }
        for entry in page.entries { merged[entry.session.id] = entry }
        guard merged.count <= 4096, visitedCursors.count < 4096 else { return false }
        pendingEntries = merged.values.sorted { $0.session.id.rawValue < $1.session.id.rawValue }
        revision = page.revision; asOf = page.asOf; cursor = page.nextCursor
        if let cursor { visitedCursors.append(cursor) }
        if page.state == .complete { entries = pendingEntries ?? []; pendingEntries = nil }
        status = DirectoryPageStatus(phase: page.state == .complete ? .complete : .incomplete,
                                     hasMore: cursor != nil, isStale: page.state != .complete && !entries.isEmpty)
        return true
    }
}
