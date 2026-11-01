import Foundation
import Testing
@testable import GianCore

@MainActor
struct DirectorySupersessionTests {
    private func makeFixture() async throws -> (RemoteFixture, FixtureRelaySocket) {
        let fixture = RemoteFixture()
        try await fixture.loginAndClaim()
        let socket = FixtureRelaySocket(fixture)
        socket.holdCatalogReplies = true
        fixture.transport.socket = socket
        return (fixture, socket)
    }

    private func delivered(_ fixture: RemoteFixture) async -> [InboundEnvelope] {
        await fixture.service.disconnect()
        fixture.service.eventContinuation.finish()
        var result: [InboundEnvelope] = []
        for await envelope in fixture.service.events { result.append(envelope) }
        return result
    }

    @Test func sameEpochInvalidationWhileCatalogIsDelayedCannotInstallDirectory() async throws {
        for kind in ["state.patch", "snapshot.required", "state.snapshot"] {
            let (fixture, socket) = try await makeFixture()
            let refresh = Task { await fixture.service.refreshDirectory(scope: fixture.scope) }
            _ = try await socket.catalogHeld.next()
            let producerEpoch = fixture.service.eventEpoch
            switch kind {
            case "state.patch":
                try fixture.service.receive(.object(["type": .string(kind), "host_generation": .string(fixture.generation), "event_sequence": .int(0),
                    "base_revision": .string("state-r1"), "revision": .string("state-r2"),
                    "patch": .object(["sessions": .object(["upsert": .array([]), "remove_ids": .strings([fixture.sessionID])])])]), scope: fixture.scope)
            case "snapshot.required":
                try fixture.service.receive(.object(["type": .string(kind), "reason": .string("revision_mismatch")]), scope: fixture.scope)
            default:
                socket.stateRevision = "state-r2"
                try fixture.service.receive(socket.snapshot, scope: fixture.scope)
            }
            #expect(fixture.service.eventEpoch == producerEpoch)
            try socket.releaseCatalog()
            #expect(await refresh.value == .unknownOutcome)
            #expect(fixture.service.snapshot == nil)
            #expect(fixture.service.catalog == nil)
            #expect(fixture.service.cursor == nil)
            let envelopes = await delivered(fixture)
            #expect(!envelopes.contains { if case .directory = $0.event { return true }; return false })
            #expect(envelopes.allSatisfy { $0.serviceEpoch == producerEpoch })
        }
    }

    @Test func olderRefreshCannotOverwriteNewerSuccessfulRefreshInSameEpoch() async throws {
        let (fixture, socket) = try await makeFixture()
        let older = Task { await fixture.service.refreshDirectory(scope: fixture.scope) }
        _ = try await socket.catalogHeld.next()
        try fixture.service.receive(.object(["type": .string("snapshot.required"), "reason": .string("revision_mismatch")]), scope: fixture.scope)
        socket.stateRevision = "state-r2"
        socket.eventSequence = 1
        let newer = Task { await fixture.service.refreshDirectory(scope: fixture.scope) }
        _ = try await socket.catalogHeld.next()
        try socket.releaseCatalog(at: 1)
        guard case .snapshot(let expected) = await newer.value else { throw RemoteClientError.invalidPayload }
        #expect(expected.cursor.revision == "state-r2")
        #expect(expected.cursor.eventSequence == 0)
        try socket.releaseCatalog()
        #expect(await older.value == .unknownOutcome)
        #expect(try fixture.service.snapshot?.string("revision") == "state-r2")
        #expect(fixture.service.cursor == expected.cursor)
        let envelopes = await delivered(fixture)
        let revisions = envelopes.compactMap { envelope -> String? in
            if case .directory(let payload) = envelope.event { return payload.cursor.revision }
            return nil
        }
        #expect(revisions == ["state-r2"])
    }

    @Test func subscriptionEventsDoNotSupersedeCanonicalSnapshotRead() async throws {
        let (fixture, socket) = try await makeFixture()
        let refresh = Task { await fixture.service.refreshDirectory(scope: fixture.scope) }
        _ = try await socket.catalogHeld.next()
        let generation = fixture.service.directoryInvalidationGeneration
        let source = WireValue.object(["kind": .string("assistant"), "id": .string("00000000-0000-7000-8000-000000000080"),
            "turn_id": .string("00000000-0000-7000-8000-000000000081"), "turn": .int(1), "ts": .int(fixture.milliseconds), "text": .string("live"), "delta": .bool(true)])
        try fixture.service.receive(.object(["type": .string("event"), "host_generation": .string(fixture.generation), "event_sequence": .int(0),
            "event": .object(["kind": .string("transcript.item"), "session_id": .string(fixture.sessionID), "item": source])]), scope: fixture.scope)
        #expect(fixture.service.directoryInvalidationGeneration == generation)
        try socket.releaseCatalog()
        guard case .snapshot(let payload) = await refresh.value else { throw RemoteClientError.invalidPayload }
        #expect(payload.cursor.eventSequence == -1)
        let envelopes = await delivered(fixture)
        #expect(envelopes.contains { if case .transcript = $0.event { return true }; return false })
        #expect(envelopes.contains { if case .directory = $0.event { return true }; return false })
        #expect(envelopes.allSatisfy { $0.serviceEpoch != nil })
    }

    @Test func ownFragmentedSnapshotDoesNotSupersedeItsRead() async throws {
        let (fixture, socket) = try await makeFixture()
        socket.holdCatalogReplies = false
        socket.splitSnapshots = true
        guard case .snapshot(let payload) = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        #expect(payload.cursor.eventSequence == -1)
        #expect(fixture.service.pendingReadSnapshots.isEmpty)
        let envelopes = await delivered(fixture)
        #expect(envelopes.filter { if case .directory = $0.event { return true }; return false }.count == 1)
        #expect(envelopes.allSatisfy { $0.serviceEpoch != nil })
    }

    @Test func overflowPublishesResyncWithNewEpochAndDropsRetiredProducer() async throws {
        let (fixture, socket) = try await makeFixture()
        socket.holdCatalogReplies = false
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        let retiredEpoch = fixture.service.eventEpoch
        for _ in 0..<513 { fixture.service.emit(.snapshotRequired(.cryptoResumed), scope: fixture.scope) }
        #expect(fixture.service.overflowed)
        #expect(fixture.service.eventEpoch > retiredEpoch)
        #expect(fixture.service.snapshot == nil)
        // A producer continuing synchronously after overflow must not stamp old
        // business content with the newly advanced service epoch.
        fixture.service.emit(.canonical(sequence: 0, generation: HostGenerationID(rawValue: fixture.generation)!,
            body: .session(try RemoteMapping.session(socket.session, host: fixture.scope.host))), scope: fixture.scope)
        let currentEpoch = fixture.service.eventEpoch
        fixture.service.eventContinuation.finish()
        var current: [InboundEnvelope] = []
        for await envelope in fixture.service.events {
            #expect(envelope.serviceEpoch != nil)
            if envelope.serviceEpoch == currentEpoch { current.append(envelope) }
        }
        #expect(current.count == 1)
        #expect(current.first?.event == .snapshotRequired(.gapEvicted))
    }

    @Test func identicalLiveChunksInDistinctCryptoFramesAreBothDelivered() async throws {
        let (fixture, socket) = try await makeFixture()
        socket.holdCatalogReplies = false
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        let invalidation = fixture.service.directoryInvalidationGeneration
        let item = WireValue.object(["kind": .string("assistant"), "id": .string("00000000-0000-7000-8000-000000000082"),
            "turn_id": .string("00000000-0000-7000-8000-000000000083"), "turn": .int(1), "ts": .int(fixture.milliseconds), "text": .string("ha"), "delta": .bool(true)])
        let message = WireValue.object(["type": .string("event"), "host_generation": .string(fixture.generation), "event_sequence": .int(0),
            "event": .object(["kind": .string("transcript.item"), "session_id": .string(fixture.sessionID), "item": item])])
        // push seals each message with its own actual transport sequence.
        try socket.push(message)
        try socket.push(message)
        var events = fixture.service.events.makeAsyncIterator()
        var chunks: [String] = []
        while chunks.count < 2, let envelope = await events.next() {
            #expect(envelope.serviceEpoch == fixture.service.eventEpoch)
            if case .transcript(_, let item) = envelope.event, case .assistant(let text, let delta) = item.body {
                #expect(delta)
                chunks.append(text)
            }
        }
        #expect(chunks == ["ha", "ha"])
        #expect(fixture.service.cursor?.eventSequence == -1)
        #expect(fixture.service.directoryInvalidationGeneration == invalidation)
        await fixture.service.disconnect()
    }
}
