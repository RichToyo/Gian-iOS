import Foundation
import Testing
@testable import GianCore

@MainActor
struct DirectoryTimeFilterTests {
    @Test func boundariesRequireRealActivity() {
        let now = PreviewFixtures.instant
        for filter in DirectoryTimeFilter.allCases {
            let cutoff = now.addingTimeInterval(-filter.duration)
            let exact = makeSession(id: "exact", title: "Exact", taskID: nil, activity: cutoff)
            let earlier = makeSession(id: "earlier", title: "Earlier", taskID: nil, activity: cutoff.addingTimeInterval(-0.001))
            let viewed = makeSession(id: "viewed", title: "Viewed", taskID: nil, activity: now, real: false)
            #expect(filter.includes(exact, now: now))
            #expect(!filter.includes(earlier, now: now))
            #expect(!filter.includes(viewed, now: now))
        }
    }

    @Test func viewingAndDraftEditsDoNotAdvanceRealActivityButCanonicalMessageDoes() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        let old = clock.instant.addingTimeInterval(-8 * 24 * 60 * 60)
        let index = try #require(store.sessions.firstIndex(where: { $0.id == PreviewFixtures.sessionID }))
        store.sessions[index].lastActivityAt = old
        store.sessions[index].activityIsMessageOrExecution = true
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        _ = await store.dispatch(.editDraftText("Typing is not activity"))
        #expect(store.sessions.first(where: { $0.id == PreviewFixtures.sessionID })?.lastActivityAt == old)
        let item = transcriptItem(id: "canonical-real-activity", turn: 9, text: "New message", at: clock.instant)
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .transcript(sessionID: PreviewFixtures.sessionID, item: item)))
        #expect(store.sessions.first(where: { $0.id == PreviewFixtures.sessionID })?.lastActivityAt == clock.instant)
    }

    @Test func taskRecencyIncludesOlderMembersAndReposFilterIndividually() async throws {
        let now = PreviewFixtures.instant
        let service = DirectoryFixtureService()
        var recent = directoryEntry("Recent", task: true)
        recent.session.status = .new
        recent.session.lastActivityAt = now
        var older = directoryEntry("Older", task: true)
        older.session.status = .new
        older.session.lastActivityAt = now.addingTimeInterval(-8 * 24 * 60 * 60)
        service.pages[.tasks] = [directoryPage(.tasks, [recent, older])]
        service.pages[.repos] = [directoryPage(.repos, [recent, older])]
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        #expect(Set(store.state.directory.tasks.flatMap(\.conversations).map(\.title)) == Set(["Recent", "Older"]))
        _ = await store.dispatch(.selectDirectoryView(.repos))
        #expect(store.state.directory.repos.map(\.title) == ["Recent"])
    }

    @Test func independentFiltersPersistInTheHostScope() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let storage = InMemoryGianStorage()
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.setDirectoryTimeFilter(.tasks, .lastHour))
        _ = await store.dispatch(.setDirectoryTimeFilter(.repos, .last24Hours))
        let scope = try clientScope(store)
        let saved = try #require(try storage.load(scope: scope))
        #expect(saved.tasksTimeFilter == .lastHour)
        #expect(saved.reposTimeFilter == .last24Hours)
        store.tasksTimeFilter = .last7Days
        store.reposTimeFilter = .last7Days
        #expect(store.restore(host: try clientScope(store).host))
        #expect(store.tasksTimeFilter == .lastHour)
        #expect(store.reposTimeFilter == .last24Hours)
    }

    @Test func oldHostSearchResultIsTemporaryAndClearedOnAnotherSelection() async throws {
        let now = PreviewFixtures.instant
        let service = DirectoryFixtureService()
        var recent = directoryEntry("Recent", task: true)
        recent.session.status = .new
        recent.session.lastActivityAt = now
        var old = directoryEntry("Old result")
        old.session.lastActivityAt = now.addingTimeInterval(-9 * 24 * 60 * 60)
        service.pages[.tasks] = [directoryPage(.tasks, [recent])]
        service.pages[.search] = [directoryPage(.search, [old])]
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.search("old"))
        #expect(store.state.directory.searchResults.map(\.id) == [old.session.id])
        _ = await store.dispatch(.selectSearchResult(old.session.id))
        #expect(store.state.directory.searchQuery.isEmpty)
        #expect(store.state.directory.temporarySearchResult?.id == old.session.id)
        #expect(!store.state.directory.tasks.flatMap(\.conversations).contains { $0.id == old.session.id })
        _ = await store.dispatch(.selectConversation(recent.session.id))
        #expect(store.state.directory.temporarySearchResult == nil)
    }

    @Test func titleSearchUsesCaseInsensitiveCompatibilitySubstringOnly() {
        #expect(DirectoryFilter.titleMatches("Release Planning", query: "LEASE plan"))
        #expect(DirectoryFilter.titleMatches("Fullwidth Ｇｉａｎ", query: "gian"))
        #expect(DirectoryFilter.titleMatches("ΟΣ", query: "σ"))
        #expect(!DirectoryFilter.titleMatches("Unrelated title", query: "repository"))
        #expect(!DirectoryFilter.titleMatches("Unrelated title", query: ""))
    }

    @Test func titleSearchShowsAuthorizedCachedRowsWhileHostSearchIsPending() async throws {
        let service = DirectoryFixtureService()
        let entry = directoryEntry("0.6.12 Integration", task: true)
        service.pages[.tasks] = [directoryPage(.tasks, [entry])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        service.holdNextDirectory = true
        let search = Task { await store.dispatch(.search("0.6.12")) }
        for _ in 0..<100 where service.heldDirectory == nil { await Task.yield() }
        let completion = try #require(service.heldDirectory)
        #expect(store.state.directory.searchResults.map(\.id) == [entry.session.id])
        completion.resume(returning: directoryPage(.search, [entry]))
        service.heldDirectory = nil
        #expect((await search.value).isApplied)
        #expect(store.state.directory.searchResults.map(\.id) == [entry.session.id])
        let scope = try clientScope(store)
        _ = store.ingest(InboundEnvelope(scope: scope, event: .sessionUnavailable(entry.session.id)))
        #expect(store.state.directory.searchResults.isEmpty)
    }

    @Test func revokedTemporarySearchResultIsHiddenImmediately() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        let result = directoryEntry("Historical title")
        service.pages[.search] = [directoryPage(.search, [result])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.search("historical"))
        _ = await store.dispatch(.selectSearchResult(result.session.id))
        #expect(store.state.directory.temporarySearchResult?.id == result.session.id)
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .sessionUnavailable(result.session.id)))
        #expect(store.state.directory.temporarySearchResult == nil)
        #expect(store.state.conversation == nil)
    }

    @Test func selectedRepoRowRemainsWhenItAgesUntilSelectionChanges() async throws {
        let now = PreviewFixtures.instant
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        var aging = directoryEntry("Aging")
        aging.session.lastActivityAt = now.addingTimeInterval(-3599)
        let other = directoryEntry("Other")
        service.pages[.repos] = [directoryPage(.repos, [aging, other])]
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        _ = await store.dispatch(.setDirectoryTimeFilter(.repos, .lastHour))
        _ = await store.dispatch(.selectConversation(aging.session.id))
        clock.instant = now.addingTimeInterval(5)
        store.reproject()
        #expect(store.state.directory.repos.contains { $0.id == aging.session.id })
        _ = await store.dispatch(.selectConversation(other.session.id))
        #expect(!store.state.directory.repos.contains { $0.id == aging.session.id })
    }

    @Test func titleNarrowingPreservesIncompleteSearchContinuation() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.search] = (1...4).map { index in
            directoryPage(.search, [directoryEntry("Body-only-\(index)")], state: .incomplete, cursor: "search-\(index)")
        }
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.search("target"))
        #expect(store.state.directory.searchResults.isEmpty)
        #expect(store.state.directory.searchPage.phase == .incomplete)
        #expect(store.state.directory.searchPage.hasMore)
        service.pages[.search] = [directoryPage(.search, [directoryEntry("Target title")])]
        _ = await store.dispatch(.loadMoreDirectory(.search))
        #expect(service.requests.last?.cursor == "search-4")
        #expect(store.state.directory.searchResults.map(\.title) == ["Target title"])
        #expect(store.state.directory.searchPage.phase == .complete)
    }

    @Test func placeholderAndRepositoryOnlyMatchesAreNotTitleMatches() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        var placeholder = directoryEntry("Untitled")
        placeholder.searchName = nil
        var repoOnly = directoryEntry("Different conversation")
        repoOnly.workspace.name = "Untitled repository"
        service.pages[.search] = [directoryPage(.search, [placeholder, repoOnly])]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.search("untitled"))
        #expect(store.state.directory.searchResults.isEmpty)
        #expect(store.state.directory.searchPage.phase == .complete)
    }

    @Test func retentionRemovesOldHistoryButPreservesDraftAndRecoveryData() {
        let now = PreviewFixtures.instant
        let oldDate = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let old = makeSession(id: "old-history", title: "Old", taskID: nil, activity: oldDate)
        let draftSession = makeSession(id: "draft-history", title: "Draft", taskID: nil, activity: oldDate)
        let recovery = makeSession(id: "recovery-history", title: "Recovery", taskID: nil, activity: oldDate)
        let recent = makeSession(id: "recent-history", title: "Recent", taskID: nil, activity: now)
        let draftID = PreviewFixtures.id("retained-draft", DraftID.self)
        let attachmentID = PreviewFixtures.id("unsent-attachment", AttachmentID.self)
        let bytes = Data("Unsent attachment".utf8)
        let attachment = DraftAttachment(id: attachmentID, filename: "draft.txt", mime: "text/plain",
                                         byteCount: bytes.count, sha256: SHA256Hex.digest(bytes), state: .localOnly)
        var bundle = StoredHostState()
        bundle.sessions = [old, draftSession, recovery, recent]
        bundle.transcripts = [old.id: [transcriptItem(id: "old-item", turn: 1, text: "Old")],
                              draftSession.id: [transcriptItem(id: "draft-item", turn: 1, text: "Draft")],
                              recovery.id: [transcriptItem(id: "recovery-item", turn: 1, text: "Recovery")],
                              recent.id: [transcriptItem(id: "recent-item", turn: 1, text: "Recent")]]
        bundle.drafts = [DraftDocument(id: draftID, hostID: PreviewFixtures.hostID, target: .conversation(draftSession.id),
                                       text: "Unsent", attachments: [attachment], updatedAt: now)]
        bundle.draftBytes[attachmentID] = bytes
        let intent = DurableSendIntent(draftID: draftID, stage: .send, sessionID: recovery.id)
        bundle.operations[draftID] = .uncertain(intent)
        let retained = bundle.retainingRecentHistory(now: now)
        #expect(retained.transcripts[old.id] == nil)
        #expect(retained.transcripts[draftSession.id] == nil)
        #expect(retained.sessions.contains { $0.id == draftSession.id })
        #expect(retained.transcripts[recovery.id] != nil)
        #expect(retained.transcripts[recent.id] != nil)
        #expect(retained.drafts == bundle.drafts)
        #expect(retained.operations == bundle.operations)
        #expect(retained.draftBytes[attachmentID] == bytes)
        #expect(bundle.transcripts[old.id] != nil)
    }

    @Test func retentionKeepsTheExactSevenDayBoundary() {
        let now = PreviewFixtures.instant
        let cutoff = now.addingTimeInterval(-DirectoryTimeFilter.last7Days.duration)
        let exact = makeSession(id: "cutoff-exact", title: "Exact", taskID: nil, activity: cutoff)
        let old = makeSession(id: "cutoff-old", title: "Old", taskID: nil, activity: cutoff.addingTimeInterval(-0.001))
        var bundle = StoredHostState()
        bundle.sessions = [exact, old]
        bundle.transcripts = [exact.id: [transcriptItem(id: "exact-item", turn: 1, text: "Exact")],
                              old.id: [transcriptItem(id: "old-cutoff-item", turn: 1, text: "Old")]]
        let retained = bundle.retainingRecentHistory(now: now)
        #expect(retained.transcripts[exact.id] != nil)
        #expect(retained.transcripts[old.id] == nil)
    }

    @Test func ordinaryCatchUpDoesNotProtectExpiredOffscreenHistory() {
        let now = PreviewFixtures.instant
        let old = makeSession(id: "catchup-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        var bundle = StoredHostState()
        bundle.sessions = [old]
        bundle.transcripts[old.id] = [transcriptItem(id: "catchup-item", turn: 1, text: "History")]
        var cursor = StoredTranscriptCursor(cursor: "older", hasOlder: true)
        cursor.catchUp = StoredTranscriptCatchUp(anchorIDs: [PreviewFixtures.id("catchup-item", TranscriptItemID.self)])
        bundle.transcriptCursors[old.id] = cursor
        let retained = bundle.retainingRecentHistory(now: now)
        #expect(retained.transcripts[old.id] == nil)
        #expect(retained.transcriptCursors[old.id] == nil)
    }

    @Test func reconnectAndDirectoryChangeEvictAgedOffscreenCatchUp() async throws {
        for reconnect in [true, false] {
            let service = DirectoryFixtureService()
            service.pages[.tasks] = [directoryPage(.tasks)]
            let clock = ManualGianClock(instant: PreviewFixtures.instant)
            let storage = InMemoryGianStorage()
            let store = GianClientStore(service: service, clock: clock, storage: storage)
            _ = try await signIn(store, clock: clock)
            let scope = try clientScope(store)
            let old = makeSession(id: "reconnect-old", title: "Old", taskID: nil,
                                  activity: clock.instant.addingTimeInterval(-8 * 24 * 60 * 60))
            store.sessions.append(old)
            store.memory.update(scope) {
                $0.transcripts[old.id] = [transcriptItem(id: "reconnect-item", turn: 1, text: "History")]
            }
            if reconnect {
                store.markConnectionNotReady(.offline, reason: .cryptoResumed)
            } else {
                let generation = try #require(store.state.sync.cursor?.hostGeneration)
                _ = store.ingest(InboundEnvelope(scope: scope, event: .directoryChanged(generation: generation, revision: "changed")))
            }
            #expect(store.memory.bundle(for: scope).transcriptCursors[old.id]?.catchUp != nil)
            #expect(try storage.load(scope: scope)?.transcripts[old.id] == nil)
            #expect(try storage.load(scope: scope)?.transcriptCursors[old.id] == nil)
        }
    }

    @Test func laterUncertainSendOverridesPriorHistoryEviction() throws {
        let now = PreviewFixtures.instant
        let scope = fictionalScope()
        let old = makeSession(id: "protected-later", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = InMemoryGianStorage()
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        memory.update(scope) {
            $0.sessions = [old]
            $0.transcripts[old.id] = [transcriptItem(id: "protected-later-item", turn: 1, text: "History")]
        }
        try memory.commit(scope)
        #expect(try storage.load(scope: scope)?.transcripts[old.id] == nil)
        let draftID = PreviewFixtures.id("protected-later-draft", DraftID.self)
        let intent = DurableSendIntent(draftID: draftID, stage: .send, sessionID: old.id)
        memory.update(scope) { $0.operations[draftID] = .uncertain(intent) }
        try memory.commit(scope)
        #expect(try storage.load(scope: scope)?.transcripts[old.id]?.count == 1)
        #expect(try storage.load(scope: scope)?.operations[draftID] == .uncertain(intent))
        try memory.commit(scope)
        #expect(try storage.load(scope: scope)?.transcripts[old.id]?.count == 1)
    }

    @Test func downloadOwnerMetadataKeepsSharedCacheUntilAllOwnersExpire() {
        let now = PreviewFixtures.instant
        let old = makeSession(id: "owner-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let recent = makeSession(id: "owner-recent", title: "Recent", taskID: nil, activity: now)
        let attachment = PreviewFixtures.id("owner-shared", AttachmentID.self)
        var bundle = StoredHostState()
        bundle.sessions = [old, recent]
        bundle.cacheDownload(Data("x".utf8), id: attachment, session: old.id)
        bundle.noteDownloadOwner(attachment, session: recent.id)
        bundle.noteDownloadOwner(attachment, session: recent.id)
        #expect(bundle.downloadOwners?[attachment] == [old.id, recent.id])
        let retained = bundle.retainingRecentHistory(now: now)
        #expect(retained.downloads[attachment] != nil)
        #expect(retained.downloadOwners?[attachment] == [recent.id])
    }

    @Test func persistenceDoesNotDiscardUnreferencedUnsentBytes() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let storage = InMemoryGianStorage()
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let id = PreviewFixtures.id("orphan-unsent", AttachmentID.self)
        let bytes = Data("Unsent".utf8)
        store.memory.update(scope) { $0.draftBytes[id] = bytes }
        #expect(store.persist())
        #expect(try storage.load(scope: scope)?.draftBytes[id] == bytes)
    }

    @Test func uncertainTranslationTakesPrecedenceOverAnOldEvictionMarker() {
        let now = PreviewFixtures.instant
        let old = makeSession(id: "translation-protected", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let requestID = PreviewFixtures.id("protected-request", TranslationRequestID.self)
        var bundle = StoredHostState()
        bundle.sessions = [old]
        bundle.transcripts[old.id] = [transcriptItem(id: "translation-protected-item", turn: 1, text: "History")]
        var translation = translationState(revision: 1, configRevision: 1)
        translation.reading["turn:1"] = ReadingRequestState(requestID: requestID, pending: true, uncertain: true)
        bundle.translations[old.id] = translation
        bundle.readingIntents[old.id] = ["turn:1": StoredReadingIntent(requestID: requestID, sourceText: "History")]
        let retained = bundle.retainingRecentHistory(now: now, previouslyEvicted: [old.id])
        #expect(retained.transcripts[old.id]?.count == 1)
        #expect(retained.translations[old.id]?.reading["turn:1"]?.uncertain == true)
        #expect(retained.readingIntents[old.id]?["turn:1"]?.requestID == requestID)
    }

    @Test func committedRetentionDoesNotResurrectOnAnotherSnapshot() throws {
        let now = PreviewFixtures.instant
        let clock = ManualGianClock(instant: now)
        let storage = InMemoryGianStorage()
        let memory = ScopedMemory(storage: storage, retentionClock: clock)
        let scope = fictionalScope()
        let old = makeSession(id: "evicted-history", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        try memory.load(scope)
        memory.update(scope) {
            $0.sessions = [old]
            $0.transcripts[old.id] = [transcriptItem(id: "evicted-item", turn: 1, text: "Old")]
        }
        try memory.commit(scope)
        #expect(try storage.load(scope: scope)?.transcripts[old.id] == nil)
        #expect(memory.bundle(for: scope).transcripts[old.id] != nil)
        let draft = DraftDocument(id: PreviewFixtures.id("later-draft", DraftID.self), hostID: scope.host,
                                  target: .conversation(old.id), text: "Unsent", attachments: [], updatedAt: now)
        memory.update(scope) { $0.catalogRevision = "later-snapshot"; $0.drafts = [draft] }
        try memory.flushDirty()
        #expect(try storage.load(scope: scope)?.transcripts[old.id] == nil)
        #expect(try storage.load(scope: scope)?.drafts == [draft])
    }

    @Test func retentionDoesNotRequireAnotherUnrelatedCommit() throws {
        let now = PreviewFixtures.instant
        let storage = InMemoryGianStorage()
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        let scope = fictionalScope()
        let date = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let first = makeSession(id: "a-old", title: "A", taskID: nil, activity: date)
        let second = makeSession(id: "b-old", title: "B", taskID: nil, activity: date)
        try memory.load(scope)
        memory.update(scope) { bundle in
            bundle.sessions = [first, second]
            bundle.transcripts[first.id] = (0..<300).map { transcriptItem(id: "a-\($0)", turn: $0, text: "A") }
            bundle.transcripts[second.id] = (0..<300).map { transcriptItem(id: "b-\($0)", turn: $0, text: "B") }
        }
        try memory.commit(scope)
        #expect(try storage.load(scope: scope)?.transcripts[first.id] == nil)
        #expect(try storage.load(scope: scope)?.transcripts[second.id] == nil)
    }

    @Test func taskRecencyAggregatesAcrossIncompletePages() async throws {
        let now = PreviewFixtures.instant
        let service = DirectoryFixtureService()
        var old = directoryEntry("Old member", task: true)
        old.session.status = .new
        old.session.lastActivityAt = now.addingTimeInterval(-8 * 24 * 60 * 60)
        var recent = directoryEntry("Recent member", task: true)
        recent.session.status = .new
        recent.session.lastActivityAt = now
        service.pages[.tasks] = [directoryPage(.tasks, [old], state: .incomplete, cursor: "next"),
                                 directoryPage(.tasks, [recent])]
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        #expect(Set(store.state.directory.tasks.flatMap(\.conversations).map(\.title)) == Set(["Old member", "Recent member"]))
        #expect(store.state.directory.tasksPage.phase == .complete)
    }

    @Test func failedSQLiteRetentionCommitLeavesPreviousHistory() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "rollback-history", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var original = StoredHostState()
        original.sessions = [old]
        original.transcripts[old.id] = [transcriptItem(id: "rollback-item", turn: 1, text: "Old")]
        try storage.save(original, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        memory.update(scope) { $0.catalogRevision = "changed" }
        storage.beforeSaveCommit = { throw GianStorageError.unavailable }
        #expect(throws: (any Error).self) { try memory.commit(scope) }
        let reopened = try SQLiteGianStorage(directory: directory)
        #expect(try reopened.load(scope: scope)?.transcripts[old.id] == original.transcripts[old.id])
    }
}
