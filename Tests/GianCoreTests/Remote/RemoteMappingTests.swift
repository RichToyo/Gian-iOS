import Foundation
import Testing
@testable import GianCore

@MainActor
struct RemoteMappingTests {
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
        guard case .failed = await fixture.service.connectServer(server: fixture.server) else { Issue.record("An unavailable Server is not a connection"); return }
        #expect(fixture.service.lastFailure == .server(code: "HOST_OFFLINE", retryAfter: 45))
    }
}
