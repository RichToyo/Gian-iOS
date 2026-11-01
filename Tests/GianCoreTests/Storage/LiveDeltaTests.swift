import Foundation
import Testing
@testable import GianCore

@MainActor
struct LiveDeltaTests {
    @Test func identicalLiveChunksAppendWhilePagedItemsReplaceIdempotently() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let id = PreviewFixtures.id("assistant-stable", TranscriptItemID.self)
        let turn = PreviewFixtures.id("turn-stable", TurnID.self)
        let first = TranscriptItem(id: id, turnID: turn, turn: 1, timestamp: clock.now(), body: .assistant(text: "la", delta: true))
        let second = first
        // Distinct authenticated transport deliveries may contain identical text.
        _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: first)))
        _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: second)))
        let live = try #require(store.memory.bundle(for: scope).transcripts[PreviewFixtures.sessionID]?.first)
        #expect(live.body == .assistant(text: "lala", delta: false))
        #expect(live.timestamp == first.timestamp)
        #expect(store.memory.bundle(for: scope).transcripts[PreviewFixtures.sessionID]?.count == 1)
        var canonical = first
        canonical.body = .assistant(text: "Final canonical text", delta: false)
        service.script.transcript = [canonical]
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        #expect(store.state.conversation?.items == [canonical])
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        #expect(store.state.conversation?.items == [canonical])
        #expect(store.flushStorage().isApplied)
    }

    @Test func deltaKeepsStableTurnIdentityAndNewerLiveTextSurvivesAnOldPage() {
        let id = PreviewFixtures.id("assistant", TranscriptItemID.self)
        let turn = PreviewFixtures.id("turn-one", TurnID.self)
        let baseline = TranscriptItem(id: id, turnID: turn, turn: 1, timestamp: PreviewFixtures.instant,
            body: .assistant(text: "First ", delta: false))
        let chunk = TranscriptItem(id: id, turnID: turn, turn: 1, timestamp: PreviewFixtures.instant,
            body: .assistant(text: "second", delta: true))
        let current = TranscriptLog.applyingLive(existing: [baseline], item: chunk)!
        #expect(current.first?.body == .assistant(text: "First second", delta: false))
        #expect(TranscriptLog.mergePage(baseline: [baseline], current: current, page: [baseline]) == current)
        var foreign = chunk
        foreign.turnID = PreviewFixtures.id("turn-other", TurnID.self)
        #expect(TranscriptLog.applyingLive(existing: current, item: foreign) == nil)
    }
}
