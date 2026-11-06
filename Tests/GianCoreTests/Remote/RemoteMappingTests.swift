import Foundation
import Testing
@testable import GianCore

@MainActor
struct RemoteMappingTests {
    @Test func queuePatchIsAcceptedAsOrderedStateUpdate() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let socket = FixtureRelaySocket(fixture)
        fixture.transport.socket = socket
        guard case .snapshot(let payload) = await fixture.service.refreshDirectory(scope: fixture.scope) else {
            Issue.record("Missing snapshot"); return
        }
        var events = fixture.service.events.makeAsyncIterator()
        _ = await events.next(); _ = await events.next()
        let item: WireValue = .object(["id": .string("00000000-0000-7000-8000-000000000002"),
            "session_id": .string(fixture.sessionID), "text": .string("Fictional queue item"),
            "created_at": .string("2026-01-01T00:00:00Z")])
        let patch: WireValue = .object(["queues": .array([.object([
            "session_id": .string(fixture.sessionID), "queue_revision": .string("queue-r2"), "entries": .array([item])
        ])])])
        try socket.push(.object(["type": .string("state.patch"), "host_generation": .string(fixture.generation),
            "event_sequence": .int(payload.cursor.eventSequence + 1), "base_revision": .string(payload.cursor.revision),
            "revision": .string("state-r2"), "patch": patch]))
        guard let event = await events.next(), case .statePatch(_, _, _, _, let update) = event.event else {
            Issue.record("Expected an ordered queue patch"); await fixture.service.disconnect(); return
        }
        let id = try #require(SessionID(rawValue: fixture.sessionID))
        #expect(update.queues[id]?.revision == "queue-r2")
        #expect(update.queues[id]?.entries.first?.text == "Fictional queue item")
        #expect(fixture.service.acceptedDirectory != nil)
        await fixture.service.disconnect()
    }

    @Test func queueSnapshotRejectsForeignAndMalformedEntries() throws {
        let session = try #require(SessionID(rawValue: "00000000-0000-7000-8000-000000000001"))
        let valid: WireValue = .object([
            "id": .string("00000000-0000-7000-8000-000000000002"), "session_id": .string(session.rawValue),
            "text": .string("Fictional input"), "created_at": .string("2026-01-01T00:00:00Z"),
            "items": .array([.object(["type": .string("attachment"), "attachment_id": .string("00000000-0000-7000-8000-000000000003")])])
        ])
        let queue: WireValue = .object(["revision": .string("queue-revision-1"), "entries": .array([valid])])
        let mapped = try RemoteMapping.queue(queue, session: session)
        #expect(mapped.entries.first?.attachmentCount == 1)
        let foreign: WireValue = .object([
            "id": .string("00000000-0000-7000-8000-000000000004"), "session_id": .string("00000000-0000-7000-8000-000000000005"),
            "text": .string("Fictional input"), "created_at": .string("2026-01-01T00:00:00Z")
        ])
        #expect(throws: (any Error).self) {
            try RemoteMapping.queue(.object(["revision": .string("r"), "entries": .array([foreign])]), session: session)
        }
        #expect(throws: (any Error).self) {
            try RemoteMapping.queue(.object(["revision": .string("r"), "entries": .array([valid, valid])]), session: session)
        }
    }

    @Test func normalPatchStreamKeepsBaselineAndRejectsRevisionGaps() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let socket = FixtureRelaySocket(fixture)
        fixture.transport.socket = socket
        guard case .snapshot(let payload) = await fixture.service.refreshDirectory(scope: fixture.scope) else { Issue.record("Missing snapshot"); return }
        var events = fixture.service.events.makeAsyncIterator()
        _ = await events.next(); _ = await events.next()
        var base = payload.cursor.revision
        for index in 0..<8 {
            let revision = "patch-\(index)"
            let body: WireValue = .object(["sessions": .object(["upsert": .array([socket.session]), "remove_ids": .array([])])])
            try socket.push(.object(["type": .string("state.patch"), "host_generation": .string(fixture.generation),
                "event_sequence": .int(payload.cursor.eventSequence + index + 1), "base_revision": .string(base),
                "revision": .string(revision), "patch": body]))
            guard let event = await events.next(), case .statePatch(let sequence, _, _, _, _) = event.event else { Issue.record("Expected a validated patch"); return }
            #expect(sequence == payload.cursor.eventSequence + index + 1)
            #expect(fixture.service.acceptedDirectory != nil)
            base = revision
        }
        try socket.push(.object(["type": .string("state.patch"), "host_generation": .string(fixture.generation),
            "event_sequence": .int(payload.cursor.eventSequence + 9), "base_revision": .string("wrong"),
            "revision": .string("next"), "patch": .object([:])]))
        guard let gap = await events.next(), case .snapshotRequired(.revisionMismatch) = gap.event else { Issue.record("Expected recovery on revision mismatch"); return }
        #expect(fixture.service.acceptedDirectory == nil)
        await fixture.service.disconnect()
    }
    @Test func snapshotNextSequenceAndLiveOnlyEventsDoNotInventCanonicalGaps() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let socket = FixtureRelaySocket(fixture)
        fixture.transport.socket = socket
        guard case .snapshot(let payload) = await fixture.service.refreshDirectory(scope: fixture.scope) else { Issue.record("Missing snapshot"); return }
        #expect(payload.cursor.eventSequence == -1)
        var events = fixture.service.events.makeAsyncIterator()
        _ = await events.next() // Fresh crypto requires an authoritative snapshot.
        guard let baseline = await events.next(), case .directory = baseline.event else { Issue.record("Expected validated directory baseline"); return }
        #expect(baseline.serviceEpoch == fixture.service.eventEpoch)
        try socket.push(.object(["type": .string("event"), "host_generation": .string(fixture.generation), "event_sequence": .int(0),
            "event": .object(["kind": .string("session.updated"), "session": socket.session])]))
        guard let delivered = await events.next(), case .canonical(let sequence, _, _) = delivered.event else { Issue.record("Expected canonical sequence zero"); return }
        #expect(sequence == 0)
        #expect(fixture.service.cursor?.eventSequence == 0)
        await fixture.service.disconnect()
    }
    @Test func pagedAssistantChunksAreFoldedAsReplaceableBaseline() throws {
        let id = "00000000-0000-7000-8000-000000000061"
        func item(_ text: String, delta: Bool) -> WireValue {
            .object(["id": .string(id), "turn_id": .string("00000000-0000-7000-8000-000000000062"), "turn": .int(1),
                "ts": .int(1_790_000_000_000), "kind": .string("assistant"), "text": .string(text), "delta": .bool(delta)])
        }
        let page = try RemoteMapping.transcriptPage([item("First", delta: false), item(" second", delta: true), item(" third", delta: true)])
        #expect(page.count == 1)
        #expect(page[0].body == .assistant(text: "First second third", delta: false))
        #expect(try RemoteMapping.transcript(item(" live", delta: true)).body == .assistant(text: " live", delta: true))
    }
    @Test func retryAfterAppliesEvenToNonJSONAvailabilityResponses() async throws {
        let fixture = RemoteFixture()
        fixture.transport.handler = { _ in RemoteHTTPResponse(status: 503, body: Data("temporarily unavailable".utf8), retryAfterSeconds: 45) }
        guard case .failed = await fixture.service.connectServer(server: fixture.server, enrollmentToken: "fixture-enrollment-token") else { Issue.record("An unavailable Server is not a connection"); return }
        #expect(fixture.service.lastFailure == .server(code: "HOST_OFFLINE", retryAfter: 45))
    }
}
