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
    var createWithoutActivity = false

    override func createSession(scope: ClientScope, request: SessionCreateRequest) async -> CommandDispatchResponse {
        createRequests.append(request)
        let response = await super.createSession(scope: scope, request: request)
        if createWithoutActivity, case .succeeded(var success) = response {
            success.session?.lastActivityAt = nil
            success.session?.activityIsMessageOrExecution = false
            return .succeeded(success)
        }
        return response
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
    // Titles may contain spaces, which are not valid ID characters.
    let id = String(title.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    let session = makeSession(id: id, title: title, taskID: task ? PreviewFixtures.taskID : nil, activity: PreviewFixtures.instant)
    return DirectoryEntry(session: session, workspace: WorkspaceRecord(id: session.workspaceID, name: "Repository"),
        task: task ? TaskRecord(id: PreviewFixtures.taskID, title: "Incomplete Task", status: .open, updatedAt: PreviewFixtures.instant) : nil,
        searchName: title)
}

func directoryPage(_ view: DirectoryCollection, _ entries: [DirectoryEntry] = [],
                   state: DirectoryPageState = .complete, cursor: String? = nil, revision: String = "directory-1") -> DirectoryPageResponse {
    .page(DirectoryPagePayload(view: view, asOf: PreviewFixtures.instant, revision: revision,
        state: state, entries: entries, nextCursor: cursor))
}

@MainActor
struct DirectoryClientTests {
    @Test func removalBeforeCreateReceiptFencesUnknownSessionWithoutResending() async throws {
        let service = DirectoryFixtureService(); service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let session = directoryEntry("inflight-created").session
        let command = PreviewFixtures.id("inflight-create-command", CommandID.self)
        var intent = DurableSendIntent(draftID: store.state.composer.draft.id, stage: .create, creationID: command)
        intent.createDispatched = true
        store.state.composer.draft.text = "Fictional unsent draft"
        store.state.composer.send = .creating(intent)
        let cursor = try #require(store.state.sync.cursor)
        var removal = CanonicalStatePatch(); removal.removedSessions = [session.id]
        _ = store.applyStatePatch(sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration,
                                  baseRevision: cursor.revision, revision: "inflight-removal", patch: removal)
        let version = try #require(store.pendingSessionAccess[session.id])
        store.resolveSessionAccess(.unavailable, session: session.id, version: version, scope: scope)
        store.resolveCommand(.succeeded(CommandSuccess(commandID: command, session: session)))
        #expect(store.currentSessionID == nil)
        #expect(store.deniedSessionAccess.contains(session.id))
        #expect(store.state.composer.draft.boundSessionID == session.id)
        #expect(store.state.composer.draft.text == "Fictional unsent draft")
        #expect(service.sendRequests.isEmpty)
    }
    @Test func ambiguousAccessFenceSurvivesLocalReload() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = DirectoryFixtureService(); service.pages[.tasks] = [directoryPage(.tasks)]
        let store = GianClientStore(service: service, clock: clock, storage: try SQLiteGianStorage(directory: directory))
        _ = try await signIn(store, clock: clock)
        let session = directoryEntry("reload-access-fence").session
        store.sessions.append(session)
        let cursor = try #require(store.state.sync.cursor)
        var removal = CanonicalStatePatch(); removal.removedSessions = [session.id]
        #expect(store.applyStatePatch(sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration,
                                      baseRevision: cursor.revision, revision: "reload-removal", patch: removal).isApplied)
        let restored = GianClientStore(service: DirectoryFixtureService(), clock: clock,
                                       storage: try SQLiteGianStorage(directory: directory))
        #expect(restored.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect(restored.pendingSessionAccess[session.id] != nil)
        #expect(restored.sessions.first(where: { $0.id == session.id })?.authorized == true)
        let version = try #require(restored.pendingSessionAccess[session.id])
        restored.resolveSessionAccess(.unavailable, session: session.id, version: version, scope: try clientScope(restored))
        let denied = GianClientStore(service: DirectoryFixtureService(), clock: clock,
                                     storage: try SQLiteGianStorage(directory: directory))
        #expect(denied.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect(denied.deniedSessionAccess.contains(session.id))
        let recoveredCursor = try #require(denied.state.sync.cursor)
        var later = CanonicalStatePatch(); later.sessions = [session]
        _ = denied.applyStatePatch(sequence: recoveredCursor.eventSequence + 1, generation: recoveredCursor.hostGeneration,
                                   baseRevision: recoveredCursor.revision, revision: "later-legacy-upsert", patch: later)
        #expect(denied.sessions.first(where: { $0.id == session.id })?.authorized == false)
    }
    @Test func legacyRemovalKeepsNegotiatedTasklessAndCompletedChatsPendingAccessProof() async throws {
        for completed in [false, true] {
            let service = DirectoryFixtureService(); service.pages[.tasks] = [directoryPage(.tasks)]
            let clock = ManualGianClock(instant: PreviewFixtures.instant)
            let store = GianClientStore(service: service, clock: clock)
            _ = try await signIn(store, clock: clock)
            var entry = directoryEntry(completed ? "completed-chat" : "taskless-chat")
            if completed { entry.session.completedAt = "2026-09-01T00:00:00Z" }
            let session = entry.session
            store.sessions.append(session)
            var repos = StoredDirectoryView(); repos.entries = [entry]
            var search = StoredDirectoryView(); search.entries = [entry]
            store.directoryViews[.repos] = repos; store.directoryViews[.search] = search
            service.transcriptPages = [TranscriptPageResponse(items: [], cursor: nil, hasOlder: false)]
            #expect((await store.dispatch(.selectConversation(session.id))).isApplied)
            let cursor = try #require(store.state.sync.cursor)
            let activity = store.sessions.first(where: { $0.id == session.id })?.lastActivityAt
            var removal = CanonicalStatePatch(); removal.removedSessions = [session.id]
            #expect(store.applyStatePatch(sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration,
                                         baseRevision: cursor.revision, revision: "legacy-remove", patch: removal).isApplied)
            #expect(store.currentSessionID == session.id)
            #expect(store.sessions.first(where: { $0.id == session.id })?.authorized == true)
            #expect(store.directoryViews[.repos]?.visibleEntries.contains(where: { $0.session.id == session.id }) == true)
            #expect(store.directoryViews[.search]?.visibleEntries.contains(where: { $0.session.id == session.id }) == true)
            #expect(!store.mutationsReady)
            let pending = try #require(store.pendingSessionAccess[session.id])
            store.resolveSessionAccess(.authorized, session: session.id, version: pending, scope: try clientScope(store))
            #expect(store.pendingSessionAccess[session.id] == nil)
            #expect(store.currentSessionID == session.id)
            #expect(store.sessions.first(where: { $0.id == session.id })?.lastActivityAt == activity)
            let next = try #require(store.state.sync.cursor)
            _ = store.applyStatePatch(sequence: next.eventSequence + 1, generation: next.hostGeneration,
                                      baseRevision: next.revision, revision: "access-denied", patch: removal)
            let denialVersion = try #require(store.pendingSessionAccess[session.id])
            store.resolveSessionAccess(.unavailable, session: session.id, version: denialVersion, scope: try clientScope(store))
            #expect(store.currentSessionID == nil)
            #expect(store.sessions.first(where: { $0.id == session.id })?.authorized == false)
            #expect(store.deniedSessionAccess.contains(session.id))
        }
    }

    @Test func legacyOnlyPatchRemovalStillRetiresItsNarrowMembership() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: ControlledService(), clock: clock)
        _ = try await signIn(store, clock: clock)
        #expect(!store.negotiatedDirectory)
        let cursor = try #require(store.state.sync.cursor)
        let id = PreviewFixtures.sessionID
        var removal = CanonicalStatePatch(); removal.removedSessions = [id]
        _ = store.applyStatePatch(sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration,
                                  baseRevision: cursor.revision, revision: "legacy-removed", patch: removal)
        #expect(store.sessions.first(where: { $0.id == id })?.authorized == false)
        #expect(store.pendingSessionAccess.isEmpty)
    }

    @Test func staleAccessResponseCannotUndoNewerRemovalOrDenial() async throws {
        let service = DirectoryFixtureService(); service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let session = directoryEntry("access-race").session
        store.sessions.append(session)
        let cursor = try #require(store.state.sync.cursor)
        var patch = CanonicalStatePatch(); patch.removedSessions = [session.id]
        _ = store.applyStatePatch(sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration,
                                  baseRevision: cursor.revision, revision: "remove-1", patch: patch)
        let oldVersion = try #require(store.pendingSessionAccess[session.id])
        _ = store.applyStatePatch(sequence: cursor.eventSequence + 2, generation: cursor.hostGeneration,
                                  baseRevision: "remove-1", revision: "remove-2", patch: patch)
        let newVersion = try #require(store.pendingSessionAccess[session.id])
        store.resolveSessionAccess(.authorized, session: session.id, version: oldVersion, scope: scope)
        #expect(store.pendingSessionAccess[session.id] == newVersion)
        let otherScope = fictionalScope(host: PreviewFixtures.id("other-access-host", HostID.self))
        store.resolveSessionAccess(.authorized, session: session.id, version: newVersion, scope: otherScope)
        #expect(store.pendingSessionAccess[session.id] == newVersion)
        _ = store.ingest(InboundEnvelope(scope: scope, event: .sessionUnavailable(session.id)))
        store.resolveSessionAccess(.authorized, session: session.id, version: newVersion, scope: scope)
        #expect(store.deniedSessionAccess.contains(session.id))
        #expect(store.sessions.first(where: { $0.id == session.id })?.authorized == false)
        var upsert = CanonicalStatePatch(); upsert.sessions = [session]
        _ = store.applyStatePatch(sequence: cursor.eventSequence + 3, generation: cursor.hostGeneration,
                                  baseRevision: "remove-2", revision: "later-upsert", patch: upsert)
        #expect(store.sessions.first(where: { $0.id == session.id })?.authorized == false)
        #expect(store.logout(invalidateRemote: false).isApplied)
        store.resolveSessionAccess(.authorized, session: session.id, version: newVersion, scope: scope)
        #expect(store.readyScope() == nil)
        #expect(store.sessions.isEmpty)
    }
    @Test func directoryHintsDoNotMarkTranscriptForCatchUp() async throws {
        let service = DirectoryFixtureService(); service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let cursor = try #require(store.state.sync.cursor)
        let id = PreviewFixtures.sessionID
        store.memory.update(scope) {
            $0.transcripts[id] = [transcriptItem(id: "hint-stable", turn: 1, text: "Fictional")]
            $0.transcriptCursors[id] = StoredTranscriptCursor(cursor: nil, hasOlder: false)
        }
        for _ in 0..<8 {
            #expect(store.ingest(InboundEnvelope(scope: scope, event: .directoryChanged(generation: cursor.hostGeneration, revision: "hint"))).isApplied)
        }
        #expect(store.memory.bundle(for: scope).transcriptCursors[id]?.catchUp == nil)
        #expect(!store.state.sync.needsSnapshot)
        #expect(store.directoryRefreshPending)
    }
    @Test func incompleteRefreshKeepsVerifiedRowsAndPublishesNewRowsUntilComplete() throws {
        let scope = fictionalScope()
        let existing = directoryEntry("Existing")
        let added = directoryEntry("Added")
        func page(_ entries: [DirectoryEntry], _ state: DirectoryPageState, _ cursor: String?) -> DirectoryPagePayload {
            DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "revision",
                                 state: state, entries: entries, nextCursor: cursor)
        }
        var view = StoredDirectoryView()
        let initialApplied = view.apply(page([existing], .complete, nil), scope: scope, view: .repos)
        #expect(initialApplied)
        view.invalidate()
        let firstApplied = view.apply(page([], .incomplete, "next-1"), scope: scope, view: .repos)
        #expect(firstApplied)
        #expect(view.visibleEntries.map(\.session.id) == [existing.session.id])
        #expect(view.status.isStale && view.status.hasMore)
        let secondApplied = view.apply(page([added], .incomplete, "next-2"), scope: scope, view: .repos)
        #expect(secondApplied)
        #expect(Set(view.visibleEntries.map(\.session.id)) == Set([existing.session.id, added.session.id]))
        view.invalidate()
        #expect(Set(view.visibleEntries.map(\.session.id)) == Set([existing.session.id, added.session.id]))
        let finalApplied = view.apply(page([added], .complete, nil), scope: scope, view: .repos)
        #expect(finalApplied)
        #expect(view.visibleEntries.map(\.session.id) == [added.session.id])
        #expect(view.status.phase == .complete)
    }

    @Test func orderedPatchUpdatesAndRemovalsDoNotRequireSnapshotButGapsDo() async throws {
        let service = DirectoryFixtureService(); service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        let cursor = try #require(store.state.sync.cursor)
        let entry = directoryEntry("patch-session")
        let session = entry.session
        var repos = StoredDirectoryView(); repos.entries = [entry]
        repos.pendingEntries = [entry]; repos.status = DirectoryPageStatus(phase: .incomplete, hasMore: true)
        store.directoryViews[.repos] = repos
        var patch = CanonicalStatePatch(); patch.sessions = [session]
        for index in 1...8 {
            let base = index == 1 ? cursor.revision : "revision-\(index - 1)"
            #expect(store.applyStatePatch(sequence: cursor.eventSequence + index, generation: cursor.hostGeneration,
                                          baseRevision: base, revision: "revision-\(index)", patch: patch).isApplied)
            #expect(!store.state.sync.needsSnapshot)
        }
        var removal = CanonicalStatePatch(); removal.removedSessions = [session.id]
        _ = store.applyStatePatch(sequence: cursor.eventSequence + 9, generation: cursor.hostGeneration,
                                  baseRevision: "revision-8", revision: "revision-9", patch: removal)
        #expect(store.sessions.first(where: { $0.id == session.id })?.authorized == true)
        #expect(store.pendingSessionAccess[session.id] != nil)
        #expect(store.directoryViews[.repos]?.visibleEntries.contains(where: { $0.session.id == session.id }) == true)
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .sessionUnavailable(session.id)))
        #expect(store.sessions.first(where: { $0.id == session.id })?.authorized == false)
        #expect(store.directoryViews[.repos]?.visibleEntries.contains(where: { $0.session.id == session.id }) == false)
        _ = store.applyStatePatch(sequence: cursor.eventSequence + 10, generation: cursor.hostGeneration,
                                  baseRevision: "revision-9", revision: "revision-10", patch: patch)
        #expect(store.sessions.first(where: { $0.id == session.id })?.authorized == false)
        _ = store.applyStatePatch(sequence: cursor.eventSequence + 11, generation: cursor.hostGeneration,
                                  baseRevision: "wrong-base", revision: "revision-11", patch: patch)
        #expect(store.state.sync.needsSnapshot)
        #expect(store.sessions.first(where: { $0.id == session.id })?.authorized == false)
    }
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

    @Test func messageOnlySearchDoesNotAppearInTitleResults() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.search] = [directoryPage(.search, [directoryEntry("Unrelated title")])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.search("text inside an old message"))
        #expect(store.state.directory.searchResults.isEmpty)
        #expect(store.state.directory.searchPage.phase == .complete)
        #expect(service.requests.last?.query == "text inside an old message")
        var narrow = service.base.script.directory
        narrow.negotiatedFeatures.append(.sessionDirectoryV1)
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .directory(narrow)))
        #expect(store.state.directory.searchResults.isEmpty)
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
        let applied = view.apply(page, scope: scope, view: .repos)
        #expect(applied)
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

    @Test func tasksHideCompletedConversationsWhileReposApplyActivityFilter() async throws {
        let service = DirectoryFixtureService()
        var finished = directoryEntry("Finished turn in incomplete Task", task: true)
        finished.session.status = .new
        finished.session.completedAt = "2026-01-01T00:00:00Z"
        finished.session.attention = .running
        let idle = directoryEntry("Idle conversation in incomplete Task", task: true)
        var active = directoryEntry("Active conversation in incomplete Task", task: true)
        active.session.status = .running
        service.pages[.tasks] = [directoryPage(.tasks, [finished, active, idle])]
        var reopened = directoryEntry("Reopened old conversation")
        reopened.session.completedAt = "2026-01-01T00:00:00Z"
        reopened.session.status = .running
        var waiting = directoryEntry("Old real waiting exception")
        waiting.session.attention = .interaction
        waiting.session.lastActivityAt = nil
        service.pages[.repos] = [directoryPage(.repos, [reopened, waiting, finished])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        #expect(store.state.directory.repos.count == 2)
        #expect(store.state.directory.tasks.count == 1)
        #expect(Set(store.state.directory.tasks[0].conversations.map(\.title)) == Set(["Active conversation in incomplete Task", "Idle conversation in incomplete Task"]))
        var completed = active.session
        completed.status = .done
        completed.completedAt = "2026-01-02T00:00:00Z"
        store.state.navigation.destination = .conversation(active.session.id)
        #expect(store.ingest(InboundEnvelope(scope: try clientScope(store), event: .sessionMetadata(completed, interactions: []))).isApplied)
        #expect(store.state.directory.tasks[0].conversations.map(\.title) == ["Idle conversation in incomplete Task"])
        let cursor = store.state.sync.cursor
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .sessionUnavailable(reopened.session.id)))
        #expect(Set(store.state.directory.repos.map(\.title)) == Set([finished.session.title]))
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
        let firstApplied = traversal.apply(first, scope: scope, view: .repos)
        #expect(firstApplied)
        let repeatedApplied = traversal.apply(first, scope: scope, view: .repos)
        #expect(!repeatedApplied)
        var changed = first; changed.revision = "r2"; changed.nextCursor = "new"
        let changedApplied = traversal.apply(changed, scope: scope, view: .repos)
        #expect(!changedApplied)
        var archived = directoryEntry("Archived"); archived.session.archived = true
        let invalid = DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r1", state: .complete,
            entries: [archived], nextCursor: nil)
        let invalidApplied = traversal.apply(invalid, scope: scope, view: .repos)
        #expect(!invalidApplied)
        #expect(traversal.status.phase == .incomplete)
    }

    /// A new traversal's verified prefix joins the retained rows, which stay
    /// (marked stale) until the traversal completes; see
    /// incompleteRefreshKeepsVerifiedRowsAndPublishesNewRowsUntilComplete.
    @Test func verifiedPrefixJoinsRetainedRowsWithoutClaimingCompletion() throws {
        var traversal = StoredDirectoryView()
        let scope = fictionalScope()
        let complete = DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r1", state: .complete,
            entries: [directoryEntry("Coherent old row")], nextCursor: nil)
        let completeApplied = traversal.apply(complete, scope: scope, view: .repos)
        #expect(completeApplied)
        traversal.invalidate()
        let prefix = DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r2", state: .incomplete,
            entries: [directoryEntry("New prefix")], nextCursor: "next")
        let prefixApplied = traversal.apply(prefix, scope: scope, view: .repos)
        #expect(prefixApplied)
        #expect(traversal.visibleEntries.map { $0.session.title } == ["Coherent old row", "New prefix"])
        #expect(traversal.status.phase == .incomplete)
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
            let applied = traversal.apply(DirectoryPagePayload(view: .repos, asOf: PreviewFixtures.instant, revision: "r", state: .incomplete,
                entries: [entry], nextCursor: "scope-bound"), scope: target, view: .repos)
            #expect(applied)
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
        var open = directoryEntry("Open task row", task: true)
        open.session.status = .running
        var done = directoryEntry("Repos history", task: true)
        done.task?.status = .completed
        service.pages[.tasks] = [directoryPage(.tasks, [open])]
        service.pages[.repos] = [directoryPage(.repos, [done])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        #expect(store.state.directory.tasks.first?.conversations.map(\.title) == ["Open task row"])
        #expect(store.state.directory.repos.isEmpty)
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
