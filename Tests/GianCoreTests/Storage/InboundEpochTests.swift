import Foundation
import Testing
@testable import GianCore

@MainActor
struct InboundEpochTests {
    @Test func oldConnectionCannotAppendIntoSameScopeAfterReconnect() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        store.expectedServiceEpoch = 10
        let item = TranscriptItem(id: PreviewFixtures.id("assistant", TranscriptItemID.self),
            turnID: PreviewFixtures.id("turn", TurnID.self), turn: 1, timestamp: clock.now(), body: .assistant(text: "A", delta: true))
        #expect(store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: item), serviceEpoch: 10)).isApplied)
        store.expectedServiceEpoch = 11
        #expect(store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: item), serviceEpoch: 10)) == .rejected(.staleOperation))
        #expect(store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: item))) == .rejected(.staleOperation))
        #expect(store.memory.bundle(for: scope).transcripts[PreviewFixtures.sessionID]?.first?.body == .assistant(text: "A", delta: false))
        #expect(store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: item), serviceEpoch: 11)).isApplied)
        #expect(store.memory.bundle(for: scope).transcripts[PreviewFixtures.sessionID]?.first?.body == .assistant(text: "AA", delta: false))
        #expect(store.flushStorage().isApplied)
    }

    @Test func freshDirectoryRemovesRowsButStaleEpochSnapshotCannotReplaceIt() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        store.expectedServiceEpoch = 2
        var current = PreviewScript.legacyContract.directory
        current.sessions = []
        current.cursor.eventSequence = 5
        #expect(store.ingest(InboundEnvelope(scope: scope, event: .directory(current), serviceEpoch: 2)).isApplied)
        #expect(store.sessions.isEmpty)
        #expect(store.state.sync.cursor?.eventSequence == 5)
        #expect(store.ingest(InboundEnvelope(scope: scope, event: .directory(PreviewScript.legacyContract.directory), serviceEpoch: 1)) == .rejected(.staleOperation))
        #expect(store.sessions.isEmpty)
        #expect(store.state.sync.cursor?.eventSequence == 5)
    }
}
