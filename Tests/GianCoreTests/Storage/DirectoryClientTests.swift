import Foundation
import Testing
@testable import GianCore

@MainActor
final class DirectoryFixtureService: ControlledService {
    var pages: [DirectoryCollection: [DirectoryPageResponse]] = [:]
    var requests: [DirectoryPageRequest] = []
    var heldDirectory: CheckedContinuation<DirectoryPageResponse, Never>?
    var holdNextDirectory = false
    var createRequests: [SessionCreateRequest] = []
    var sendRequests: [SessionSendRequest] = []
    var commandStatuses: [CommandID: CommandStatusResponse] = [:]
    var directoryMembershipGeneration = 0
    var retireNextDirectoryRead = false

    override func createSession(scope: ClientScope, request: SessionCreateRequest) async -> CommandDispatchResponse {
        createRequests.append(request)
        return await super.createSession(scope: scope, request: request)
    }
    override func sendMessage(scope: ClientScope, request: SessionSendRequest) async -> CommandDispatchResponse {
        sendRequests.append(request)
        return await super.sendMessage(scope: scope, request: request)
    }
    override func queryCommand(scope: ClientScope, commandID: CommandID) async -> CommandStatusResponse {
        if let status = commandStatuses[commandID] { return status }
        return await super.queryCommand(scope: scope, commandID: commandID)
    }

    override func refreshDirectory(scope: ClientScope) async -> DirectoryRefreshResponse {
        guard case .snapshot(var payload) = await super.refreshDirectory(scope: scope) else { return .failed("Missing fixture snapshot") }
        payload.negotiatedFeatures.append(.sessionDirectoryV1)
        return .snapshot(payload)
    }
    override func listDirectory(scope: ClientScope, request: DirectoryPageRequest) async -> DirectoryPageResponse {
        requests.append(request)
        if holdNextDirectory {
            holdNextDirectory = false
            return await withCheckedContinuation { heldDirectory = $0 }
        }
        guard var queue = pages[request.view], !queue.isEmpty else { return .failed("Missing fixture page") }
        let result = queue.removeFirst(); pages[request.view] = queue
        if retireNextDirectoryRead {
            retireNextDirectoryRead = false
            directoryMembershipGeneration += 1
        }
        return result
    }
}

extension DirectoryFixtureService: DirectoryMembershipEpoch {}

func directoryEntry(_ title: String, task: Bool = false) -> DirectoryEntry {
    let session = makeSession(id: title, title: title, taskID: task ? PreviewFixtures.taskID : nil)
    return DirectoryEntry(session: session, workspace: WorkspaceRecord(id: session.workspaceID, name: "Repository"),
        task: task ? TaskRecord(id: PreviewFixtures.taskID, title: "Incomplete Task", status: .open, updatedAt: PreviewFixtures.instant) : nil)
}

func directoryPage(_ view: DirectoryCollection, _ entries: [DirectoryEntry] = [],
                   state: DirectoryPageState = .complete, cursor: String? = nil, revision: String = "directory-1") -> DirectoryPageResponse {
    .page(DirectoryPagePayload(view: view, asOf: PreviewFixtures.instant, revision: revision,
        state: state, entries: entries, nextCursor: cursor))
}

@MainActor
struct DirectoryClientTests {
    @Test func emptyIncompletePagesRemainResumableAndNotExhaustive() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.repos] = (1...4).map { directoryPage(.repos, state: .incomplete, cursor: "opaque-\($0)") }
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        #expect(store.state.directory.repos.isEmpty)
        #expect(store.state.directory.reposPage.phase == .incomplete)
        #expect(store.state.directory.reposPage.hasMore)
        service.pages[.repos] = [directoryPage(.repos, [directoryEntry("History")])]
        _ = await store.dispatch(.loadMoreDirectory(.repos))
        #expect(service.requests.last?.cursor == "opaque-4")
        #expect(store.state.directory.reposPage.phase == .complete)
        #expect(store.state.directory.repositories.first?.conversations.first?.title == "History")
    }

    @Test func messageOnlySearchUsesHostMembershipNotLocalTitleMatching() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.search] = [directoryPage(.search, [directoryEntry("Unrelated title")])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.search("text inside an old message"))
        #expect(store.state.directory.searchResults.map(\.title) == ["Unrelated title"])
        #expect(store.state.directory.searchPage.phase == .complete)
        #expect(service.requests.last?.query == "text inside an old message")
        var narrow = service.base.script.directory
        narrow.negotiatedFeatures.append(.sessionDirectoryV1)
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .directory(narrow)))
        #expect(store.state.directory.searchResults.map(\.title) == ["Unrelated title"])
    }

    @Test func invalidCursorRestartsAtMostTwiceAndRetainsLastCoherentRows() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.repos] = [directoryPage(.repos, [directoryEntry("Retained")])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        service.pages[.repos] = (0..<3).map { _ in directoryPage(.repos, state: .cursorInvalid) }
        let before = service.requests.count
        _ = await store.dispatch(.refreshDirectoryView(.repos))
        #expect(service.requests.count - before == 3)
        #expect(service.requests.suffix(3).allSatisfy { $0.cursor == nil })
        #expect(store.state.directory.repos.map(\.title) == ["Retained"])
        #expect(store.state.directory.reposPage.phase == .cursorInvalid)
        #expect(store.state.directory.reposPage.isStale)
        #expect(store.state.directory.reposPage.error != nil)
    }

    @Test func queryChangeFencesSuspendedSearchAndClearsPriorMembership() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        service.holdNextDirectory = true
        let old = Task { await store.dispatch(.search("old")) }
        while service.heldDirectory == nil { await Task.yield() }
        #expect(store.state.directory.searchPage.isLoading)
        service.pages[.search] = [directoryPage(.search, [directoryEntry("New result")])]
        _ = await store.dispatch(.search("new"))
        service.heldDirectory?.resume(returning: directoryPage(.search, [directoryEntry("Old result")]))
        #expect(await old.value == .rejected(.staleOperation))
        #expect(store.state.directory.searchResults.map(\.title) == ["New result"])
    }

    @Test func legacyViewsRemainExplicitlyUnsupported() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        #expect(await store.dispatch(.loadMoreDirectory(.repos)) == .rejected(.capabilityUnsupported))
        #expect(store.state.directory.reposPage.phase == .unsupported)
        #expect(store.state.directory.reposSupport == .unsupported(.reposDirectory))
    }

    @Test func persistenceRetainsMembershipButNeverRevivesAnOpaqueContinuation() throws {
        let scope = fictionalScope()
        var view = StoredDirectoryView()
        let page = DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r",
            state: .incomplete, entries: [directoryEntry("Cached")], nextCursor: "opaque")
        #expect(view.apply(page, scope: scope, view: .repos))
        var state = StoredHostState(); state.directoryViews = [.repos: view]
        let decoded = try JSONDecoder().decode(StoredHostState.self, from: JSONEncoder().encode(state)).recovered()
        #expect(decoded.directoryViews?[.repos]?.visibleEntries.map { $0.session.title } == ["Cached"])
        #expect(decoded.directoryViews?[.repos]?.cursor == nil)
        #expect(decoded.directoryViews?[.repos]?.status.isStale == true)
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StoredHostState())) as! [String: Any]
        #expect(legacy["directoryViews"] == nil)
        _ = try JSONDecoder().decode(StoredHostState.self, from: JSONSerialization.data(withJSONObject: legacy))
    }

    @Test func hintFencesInflightMembershipAndPreservesCanonicalCursor() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        service.holdNextDirectory = true
        let read = Task { await store.dispatch(.selectDirectoryView(.repos)) }
        while service.heldDirectory == nil { await Task.yield() }
        let cursor = store.state.sync.cursor
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store),
            event: .directoryChanged(generation: PreviewFixtures.generationID, revision: "new")))
        service.heldDirectory?.resume(returning: directoryPage(.repos, [directoryEntry("Stale")]))
        #expect(await read.value == .rejected(.staleOperation))
        #expect(store.state.directory.repos.isEmpty)
        #expect(store.state.sync.cursor == cursor)
        #expect(store.directoryRefreshPending)
    }

    @Test func hostMembershipKeepsOlderWaitingAndReopenedRowsWithoutInventingTasklessGroups() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks, [directoryEntry("Finished turn in incomplete Task", task: true)])]
        var reopened = directoryEntry("Reopened old conversation")
        reopened.session.completedAt = "2026-01-01T00:00:00Z"
        reopened.session.status = .running
        var waiting = directoryEntry("Old real waiting exception")
        waiting.session.attention = .interaction
        waiting.session.lastActivityAt = nil
        service.pages[.repos] = [directoryPage(.repos, [reopened, waiting])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        #expect(store.state.directory.repos.count == 2)
        #expect(store.state.directory.tasks.count == 1)
        #expect(store.state.directory.tasks[0].conversations.map(\.title) == ["Finished turn in incomplete Task"])
        let cursor = store.state.sync.cursor
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .sessionUnavailable(reopened.session.id)))
        #expect(store.state.directory.repos.map(\.title) == [waiting.session.title])
        #expect(store.state.sync.cursor == cursor)
    }

    @Test func clearingSearchFencesPendingReplyAndClearsPersistedSearch() async throws {
        let actions: [GianClientAction] = [.clearSearch, .search("")]
        for clear in actions {
            let service = DirectoryFixtureService()
            service.pages[.tasks] = [directoryPage(.tasks)]
            let clock = ManualGianClock(instant: PreviewFixtures.instant)
            let storage = InMemoryGianStorage()
            let store = GianClientStore(service: service, clock: clock, storage: storage)
            _ = try await signIn(store, clock: clock)
            service.holdNextDirectory = true
            let pending = Task { await store.dispatch(.search("old")) }
            while service.heldDirectory == nil { await Task.yield() }
            _ = await store.dispatch(clear)
            service.heldDirectory?.resume(returning: directoryPage(.search, [directoryEntry("Obsolete")]))
            #expect(await pending.value == .rejected(.staleOperation))
            #expect(store.state.directory.searchResults.isEmpty)
            #expect(store.state.directory.searchPage.phase == .idle)
            #expect(try storage.load(scope: clientScope(store))?.directoryViews?[.search] == nil)
        }
    }

    @Test func malformedContinuationAndKnownArchivedRowsCannotBecomeComplete() async throws {
        var traversal = StoredDirectoryView()
        let scope = fictionalScope()
        let first = DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r1", state: .incomplete,
            entries: [directoryEntry("First")], nextCursor: "same")
        #expect(traversal.apply(first, scope: scope, view: .repos))
        #expect(!traversal.apply(first, scope: scope, view: .repos))
        var changed = first; changed.revision = "r2"; changed.nextCursor = "new"
        #expect(!traversal.apply(changed, scope: scope, view: .repos))
        var archived = directoryEntry("Archived"); archived.session.archived = true
        let invalid = DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r1", state: .complete,
            entries: [archived], nextCursor: nil)
        #expect(!traversal.apply(invalid, scope: scope, view: .repos))
        #expect(traversal.status.phase == .incomplete)
    }

    @Test func refreshedPrefixDoesNotClaimRetainedCoherentRowsAreFresh() throws {
        var traversal = StoredDirectoryView()
        let scope = fictionalScope()
        let complete = DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r1", state: .complete,
            entries: [directoryEntry("Coherent old row")], nextCursor: nil)
        #expect(traversal.apply(complete, scope: scope, view: .repos))
        traversal.invalidate()
        let prefix = DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r2", state: .incomplete,
            entries: [directoryEntry("New prefix")], nextCursor: "next")
        #expect(traversal.apply(prefix, scope: scope, view: .repos))
        #expect(traversal.visibleEntries.map { $0.session.title } == ["Coherent old row"])
        #expect(traversal.status.isStale && traversal.status.hasMore)
    }

    @Test func permissionDenialHidesExpandedRowsRatherThanRetainingAnAuthorizedCache() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks, [directoryEntry("Task row", task: true)])]
        service.pages[.repos] = [directoryPage(.repos, [directoryEntry("Repository row")])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        service.pages[.repos] = [.denied]
        _ = await store.dispatch(.refreshDirectoryView(.repos))
        #expect(store.state.directory.reposPage.phase == .denied)
        #expect(store.state.directory.tasks.isEmpty && store.state.directory.repos.isEmpty)
        #expect(store.state.directory.searchResults.isEmpty)
        #expect(store.state.conversation == nil)
    }

    @Test func sqlitePersistsScopedMembershipWithoutRevivingRestartCursors() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let second = fictionalScope(host: PreviewFixtures.id("second-directory-host", HostID.self))
        let storage = try SQLiteGianStorage(directory: directory)
        for (target, name) in [(scope, "First Host"), (second, "Second Host")] {
            var entry = directoryEntry(name); entry.session.hostID = target.host
            var traversal = StoredDirectoryView()
            #expect(traversal.apply(DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r", state: .incomplete,
                entries: [entry], nextCursor: "scope-bound"), scope: target, view: .repos))
            var state = StoredHostState()
            state.directoryViews = [.repos: traversal]; state.sessions = [entry.session]
            state.authority = .negotiatedDirectoryV1
            try storage.save(state, scope: target)
        }
        let reopened = try SQLiteGianStorage(directory: directory)
        let first = try #require(try reopened.load(scope: scope)?.directoryViews?[.repos])
        let other = try #require(try reopened.load(scope: second)?.directoryViews?[.repos])
        #expect(first.visibleEntries.map { $0.session.title } == ["First Host"])
        #expect(other.visibleEntries.map { $0.session.title } == ["Second Host"])
        #expect(first.cursor == nil && other.cursor == nil)
        #expect(first.status.isStale && other.status.isStale)
    }

    @Test func legacySnapshotDoesNotReplacePublishedDirectoryRows() async throws {
        let service = DirectoryFixtureService()
        var row = directoryEntry("Directory row")
        row.session.completedAt = "2026-01-01T00:00:00Z"
        row.session.attention = .interaction
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.repos] = [directoryPage(.repos, [row])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        var narrow = service.base.script.directory
        narrow.negotiatedFeatures.append(.sessionDirectoryV1)
        narrow.catalogRevision = "snapshot-must-apply"
        var replacement = row.session
        replacement.title = "Narrow snapshot"
        replacement.completedAt = nil
        replacement.attention = nil
        var outsider = row.session
        outsider.id = PreviewFixtures.id("snapshot-only-row", SessionID.self)
        outsider.title = "Snapshot only"
        outsider.completedAt = nil
        narrow.sessions = [replacement, outsider]
        let result = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .directory(narrow)))
        #expect(result.isApplied)
        #expect(store.state.catalogRevision == "snapshot-must-apply")
        #expect(store.state.directory.repos.map(\.title) == ["Directory row"])
        #expect(store.state.directory.repos.first?.attention == .interaction)
        #expect(store.directoryViews[.repos]?.entries.first?.session.completedAt == "2026-01-01T00:00:00Z")
        #expect(store.sessions.first { $0.id == outsider.id }?.title == "Snapshot only")
        #expect(!store.state.directory.repos.contains { $0.title == "Narrow snapshot" || $0.title == "Snapshot only" })
    }

    @Test func reposTaskRecordDoesNotHideOpenTasksPage() async throws {
        let service = DirectoryFixtureService()
        let open = directoryEntry("Open task row", task: true)
        var done = directoryEntry("Repos history", task: true)
        done.task?.status = .completed
        service.pages[.tasks] = [directoryPage(.tasks, [open])]
        service.pages[.repos] = [directoryPage(.repos, [done])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        #expect(store.state.directory.tasks.first?.conversations.map(\.title) == ["Open task row"])
        #expect(store.state.directory.repos.map(\.title) == ["Repos history"])
    }

    @Test func retiredDirectoryReadDoesNotInstallOrFailThePage() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.repos] = [directoryPage(.repos, [directoryEntry("Should not install")])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        service.retireNextDirectoryRead = true
        #expect(await store.dispatch(.selectDirectoryView(.repos)) == .rejected(.staleOperation))
        #expect(store.state.directory.repos.isEmpty)
        #expect(store.state.directory.reposPage.phase != .failed)
        #expect(store.directoryViews[.repos]?.entries.isEmpty ?? true)
    }
}
