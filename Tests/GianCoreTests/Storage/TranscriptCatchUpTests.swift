import Foundation
import Testing
@testable import GianCore

@MainActor
struct TranscriptCatchUpTests {
    @Test func liveChunkDuringCatchUpCannotHideMissingMiddleBehindLiveWinsMerge() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        let old = transcriptItem(id: "raced-assistant", turn: 1, text: "A")
        service.transcriptPages = [TranscriptPageResponse(items: [old], cursor: nil, hasOlder: false)]
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
        let scope = try clientScope(store)
        _ = store.ingest(InboundEnvelope(scope: scope, event: .directory(service.base.script.directory)))
        service.holdNextPage = true
        let pending = Task { await store.reconcileActiveTranscript() }
        for _ in 0..<100 where service.page == nil { await Task.yield() }
        let completion = try #require(service.page)
        service.page = nil
        var delta = old
        delta.body = .assistant(text: "C", delta: true)
        _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: delta)))
        var canonical = old
        canonical.body = .assistant(text: "ABC", delta: false)
        completion.resume(returning: TranscriptPageResponse(items: [canonical], cursor: nil, hasOlder: false))
        #expect(await pending.value == .rejected(.staleOperation))
        #expect(!store.mutationsReady)
        service.transcriptPages = [TranscriptPageResponse(items: [canonical], cursor: nil, hasOlder: false)]
        #expect((await store.reconcileActiveTranscript()).isApplied)
        #expect(store.state.conversation?.items.first?.body == .assistant(text: "ABC", delta: false))
        #expect(store.mutationsReady)
        #expect(service.base.sendCount == 0)
        #expect(service.base.translationRequestCount == 0)
    }

    @Test func gapReadPagesToStableOldIdentityWithoutLosingDraftOrPagingBoundary() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        let old = transcriptItem(id: "old-anchor", turn: 1, text: "Already retained")
        service.transcriptPages = [TranscriptPageResponse(items: [old], cursor: "oldest-retained", hasOlder: true)]
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        _ = await store.dispatch(.editDraftText("Newer unsent draft"))
        let draft = store.state.composer.draft
        store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
        let scope = try clientScope(store)
        #expect(store.memory.bundle(for: scope).transcriptCursors[PreviewFixtures.sessionID]?.catchUp?.anchorIDs == [old.id])
        _ = store.ingest(InboundEnvelope(scope: scope, event: .directory(service.base.script.directory)))
        #expect(!store.mutationsReady)
        let latest = transcriptItem(id: "latest", turn: 3, text: "Latest")
        let middle = transcriptItem(id: "middle", turn: 2, text: "Missed while offline")
        service.transcriptPages = [
            TranscriptPageResponse(items: [latest], cursor: "gap-page-two", hasOlder: true),
            TranscriptPageResponse(items: [old, middle], cursor: "older-server-boundary", hasOlder: true),
        ]
        #expect((await store.reconcileActiveTranscript()).isApplied)
        #expect(store.mutationsReady)
        #expect(store.state.conversation?.items.map(\.id) == [old.id, middle.id, latest.id])
        #expect(store.state.conversation?.cursor == "oldest-retained")
        #expect(store.state.conversation?.hydratedFromCache == false)
        #expect(store.state.composer.draft == draft)
        #expect(store.memory.bundle(for: scope).transcriptCursors[PreviewFixtures.sessionID]?.catchUp == nil)
        #expect(service.transcriptRequestCursors.suffix(2).elementsEqual([nil, "gap-page-two"]))
        #expect(service.base.sendCount == 0)
        #expect(service.base.translationRequestCount == 0)
    }

    @Test func interruptedReadRetainsGapAnchorAcrossProcessReopen() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let old = transcriptItem(id: "retained-anchor", turn: 1, text: "Retained")
        let latest = transcriptItem(id: "new-head", turn: 3, text: "New head")
        do {
            let service = ControlledService()
            let store = try GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: SQLiteGianStorage(directory: directory))
            _ = try await signIn(store, clock: clock)
            service.transcriptPages = [TranscriptPageResponse(items: [old], cursor: nil, hasOlder: false)]
            _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
            store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
            service.transcriptPages = [
                TranscriptPageResponse(items: [latest], cursor: "missing-middle", hasOlder: true),
                TranscriptPageResponse(items: [], cursor: nil, hasOlder: false, failed: true),
            ]
            #expect(await store.reconcileActiveTranscript() == .rejected(.notFound))
        }
        let service = ControlledService()
        let storage = try SQLiteGianStorage(directory: directory)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        _ = store.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock))
        let scope = try clientScope(store)
        #expect(store.memory.bundle(for: scope).transcriptCursors[PreviewFixtures.sessionID]?.catchUp?.anchorIDs == [old.id])
        _ = store.ingest(InboundEnvelope(scope: scope, event: .directory(service.base.script.directory)))
        service.transcriptPages = [TranscriptPageResponse(items: [latest], cursor: "older", hasOlder: true)]
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        service.transcriptPages = [
            TranscriptPageResponse(items: [latest], cursor: "older", hasOlder: true),
            TranscriptPageResponse(items: [old], cursor: nil, hasOlder: false),
        ]
        #expect((await store.reconcileActiveTranscript()).isApplied)
        let saved = try #require(try storage.load(scope: scope))
        #expect(saved.transcripts[PreviewFixtures.sessionID]?.map(\.id) == [old.id, latest.id])
        #expect(saved.transcriptCursors[PreviewFixtures.sessionID]?.catchUp == nil)
    }

    @Test func resyncMarksOffscreenRetainedChatsToo() async throws {
        let service = ControlledService()
        let other = makeSession(id: "other-chat", title: "Other", taskID: PreviewFixtures.taskID)
        service.base.script.directory.sessions.append(other)
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        service.transcriptPages = [TranscriptPageResponse(items: [transcriptItem(id: "first-chat-item", turn: 1, text: "First")], cursor: nil, hasOlder: false)]
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        service.transcriptPages = [TranscriptPageResponse(items: [transcriptItem(id: "other-chat-item", turn: 1, text: "Other")], cursor: nil, hasOlder: false)]
        _ = await store.dispatch(.selectConversation(other.id))
        _ = await store.dispatch(.openNewChat)
        store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
        let saved = store.memory.bundle(for: try clientScope(store))
        #expect(saved.transcriptCursors[PreviewFixtures.sessionID]?.catchUp != nil)
        #expect(saved.transcriptCursors[other.id]?.catchUp != nil)
    }
}
