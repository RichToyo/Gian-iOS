import Foundation
import Testing
@testable import GianCore

@MainActor
struct LiveReconnectTests {
    private func connected() async throws -> (RemoteFixture, FixtureRelaySocket) {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let socket = FixtureRelaySocket(fixture)
        fixture.transport.socket = socket
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        fixture.service.reconnectBackoffUnit = .milliseconds(4)
        return (fixture, socket)
    }

    private func socketsOpened(_ fixture: RemoteFixture) -> Int { fixture.transport.requests.filter { $0.url?.path == "/ws" }.count }

    /// The Host drops the connection; the next socket the fixture hands out is `next`.
    private func drop(_ socket: FixtureRelaySocket, next: FixtureRelaySocket?, _ fixture: RemoteFixture) {
        fixture.transport.socket = next
        socket.incoming.fail(.disconnected)
    }

    @Test func reconnectReadsAgainWhenLiveActivitySupersedesItsSnapshot() async throws {
        let (fixture, socket) = try await connected()
        let replacement = FixtureRelaySocket(fixture); replacement.holdCatalogReplies = true
        drop(socket, next: replacement, fixture)
        // A busy Host: a patch lands while the reconnect reads the directory.
        _ = try await replacement.catalogHeld.next()
        try replacement.patch([:])
        try replacement.releaseCatalog()
        _ = try await replacement.catalogHeld.next()
        try replacement.releaseCatalog()
        #expect(await eventually { fixture.service.acceptedDirectory != nil && fixture.service.reconnect == nil })
        #expect(fixture.service.relay?.isOpen == true)
        #expect(fixture.service.reconnectAttempt == 0)
        #expect(replacement.commands.filter { $0 == "state.refresh" }.count == 2)
        #expect(socketsOpened(fixture) == 2)
        await fixture.service.disconnect()
    }

    @Test func reconnectKeepsAWorkingConnectionWhenEveryReadIsSuperseded() async throws {
        let (fixture, socket) = try await connected()
        let replacement = FixtureRelaySocket(fixture); replacement.holdCatalogReplies = true
        drop(socket, next: replacement, fixture)
        for _ in 0..<4 {
            _ = try await replacement.catalogHeld.next()
            try replacement.patch([:])
            try replacement.releaseCatalog()
        }
        #expect(await eventually { fixture.service.reconnect == nil && fixture.service.reconnectAttempt == 0 })
        try await Task.sleep(for: .milliseconds(100))
        // Still the same connection, and nothing counted against it. The store
        // reads the directory again while it still needs a snapshot.
        #expect(fixture.service.relay?.isOpen == true)
        #expect(fixture.service.reconnectAttempt == 0)
        #expect(socketsOpened(fixture) == 2)
        #expect(fixture.service.acceptedDirectory == nil)
        await fixture.service.disconnect()
    }

    @Test func reconnectKeepsTryingPastFiveFailedAttempts() async throws {
        let (fixture, socket) = try await connected()
        fixture.service.reconnectBackoffUnit = .milliseconds(1)
        // The Host stays unreachable for longer than five attempts.
        drop(socket, next: nil, fixture)
        #expect(await eventually { self.socketsOpened(fixture) >= 8 })
        fixture.transport.socket = FixtureRelaySocket(fixture)
        #expect(await eventually { fixture.service.relay?.isOpen == true && fixture.service.acceptedDirectory != nil })
        #expect(await eventually { fixture.service.reconnectAttempt == 0 })
        await fixture.service.disconnect()
    }

    @Test func changedServerIdentityIsNotRetriedAutomatically() async throws {
        let (fixture, socket) = try await connected()
        let checks = fixture.transport.requests.filter { $0.url?.path == "/api/v1/server-identity" }.count
        fixture.serverKeyChanged = true
        drop(socket, next: FixtureRelaySocket(fixture), fixture)
        #expect(await eventually { fixture.service.lastFailure == .serverIdentityChanged })
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.transport.requests.filter { $0.url?.path == "/api/v1/server-identity" }.count == checks + 1)
        #expect(fixture.service.reconnect == nil)
        #expect(socketsOpened(fixture) == 1)
        await fixture.service.disconnect()
    }
}

/// "Retry connection" in a chat dispatches `.retrySynchronization`.
@MainActor
struct RetryConnectionTests {
    @Test func retryReconnectsAfterAConnectionLossThatIsNotRetriedAutomatically() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let socket = FixtureRelaySocket(fixture)
        let (store, coordinator) = try await LiveInteractionRefreshTests.liveStore(fixture, socket: socket)
        // A frame that fails verification ends the connection for good.
        try socket.push(.object(["type": .string("event"), "host_generation": .string("00000000-0000-7000-8000-000000000099"),
            "event_sequence": .int(0), "event": .object(["kind": .string("attention.updated"), "attention": .array([])])]))
        #expect(await eventually { store.serviceDiagnostic?.status == .connectionClosed(.integrity) })
        #expect(store.state.connection == .offline)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.service.reconnect == nil)
        #expect(fixture.service.relay == nil)

        let replacement = FixtureRelaySocket(fixture)
        fixture.transport.socket = replacement
        #expect((await store.dispatch(.retrySynchronization)).isApplied)
        #expect(fixture.service.relay?.isOpen == true)
        #expect(replacement.commands.contains("state.refresh"))
        #expect(store.state.connection == .online)
        #expect(store.serviceDiagnostic == nil)
        await coordinator.stop()
    }
}
