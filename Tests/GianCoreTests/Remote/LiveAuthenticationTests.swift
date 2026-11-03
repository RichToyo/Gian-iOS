import Foundation
import Testing
@testable import GianCore

/// Remote 1.5: no account sign-in. The Server proves its identity (pinned on
/// first use), this app keeps a controller identity for it, and Hosts are
/// paired by key possession plus the Host's confirmation.
@MainActor
struct LiveAuthenticationTests {
    @Test func defaultAndInjectedConstructionAreInert() {
        let transport = FixtureTransport()
        let secrets = FixtureSecrets()
        _ = LiveGianClientService(transport: transport, secrets: secrets, authorizationInvalidations: InMemoryGianStorage())
        _ = LiveGianClientService(authorizationInvalidations: InMemoryGianStorage())
        #expect(transport.requests.isEmpty)
        #expect(secrets.reads == 0)
        #expect(secrets.records.isEmpty)
    }

    @Test func connectingPinsTheServerIdentityWithoutAnyAccount() async throws {
        let fixture = RemoteFixture()
        try await fixture.connect()
        #expect(fixture.account.provider == .controller)
        #expect(try fixture.secrets.read(fixture.service.pinKey(fixture.server)) != nil)
        // Connecting again (same Server key) keeps the same controller identity.
        let first = fixture.account
        try await fixture.connect()
        #expect(fixture.account == first)
        let paths = fixture.transport.requests.compactMap { $0.url?.path }
        #expect(paths == ["/api/v1/server-identity", "/api/v1/server-identity"])
        #expect(fixture.transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-gian-account-token") == nil })
    }

    /// Regression for the vault's proof times on a real clock: creation must
    /// not land after the last verification.
    @Test func connectingSucceedsWhenTheClockMovesBetweenReads() async throws {
        let fixture = RemoteFixture()
        fixture.clock.advancesOnRead = 0.000_1
        try await fixture.connect()
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) != nil)
    }

    @Test func aChangedServerIdentityIsRefusedUntilForgotten() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        fixture.serverKeyChanged = true
        #expect(await fixture.service.connectServer(server: fixture.server) == .identityChanged)
        let claim = await fixture.service.claimHostQR(server: fixture.server, account: fixture.account,
            qr: HostPairingQR(grantNonce: "fictional-qr-nonce"))
        guard case .failed = claim else { Issue.record("A changed Server must not receive a claim"); return }

        try await fixture.service.forgetServer(fixture.server)
        let previous = fixture.account
        try await fixture.connect()
        #expect(fixture.account != previous, "Forgetting starts a new controller identity")
    }

    @Test func aForgedOrMismatchedProofIsNotAConnection() async throws {
        let fixture = RemoteFixture()
        let original = try #require(fixture.transport.handler)
        fixture.transport.handler = { request in
            var response = try await original(request)
            if request.url?.path == "/api/v1/server-identity", case .object(var body) = try WireValue.decode(response.body) {
                body["signature"] = .string(RemoteWire.base64(Data(repeating: 7, count: 64)))
                response = RemoteHTTPResponse(status: 200, body: try WireValue.object(body).encoded())
            }
            return response
        }
        guard case .failed = await fixture.service.connectServer(server: fixture.server) else {
            Issue.record("A bad signature must not connect"); return
        }
        #expect(try fixture.secrets.read(fixture.service.pinKey(fixture.server)) == nil, "Nothing is pinned from a bad proof")
    }

    @Test func pairingAndDeviceLoginCarryNoAccountToken() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let cached = try #require(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account))
        #expect(cached.identity.account == fixture.account)
        #expect(cached.hosts.isEmpty)
        let result = await fixture.service.refreshHostPairing(server: fixture.server, account: fixture.account,
            pairingID: PairingID(rawValue: fixture.pairingID)!)
        guard case .confirmed(_, let device) = result else { Issue.record("Expected verified device grant"); return }
        #expect(device.rawValue == fixture.pairingID)
        // A device access-token lease alone must not manufacture cached Host handshake evidence.
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account)?.hosts.isEmpty == true)
        let paths = fixture.transport.requests.compactMap { $0.url?.path }
        #expect(!paths.contains { $0.contains("/account/") || $0.contains("enrollment") })
        #expect(fixture.transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-gian-account-token") == nil })
        let claim = try #require(fixture.transport.requests.first { $0.url?.path == "/api/v1/pairings/claim" })
        #expect(claim.value(forHTTPHeaderField: "Origin") == fixture.server.absoluteString)
    }

    @Test func signingOutIsLocalAndStartsANewIdentityNextTime() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let requests = fixture.transport.requests.count
        let previous = fixture.account
        try await fixture.service.logout(server: fixture.server, account: fixture.account)
        #expect(fixture.transport.requests.count == requests, "Sign-out makes no Server request")
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: previous) == nil)
        // The Server pin stays; a new controller identity is created.
        #expect(try fixture.secrets.read(fixture.service.pinKey(fixture.server)) != nil)
        try await fixture.connect()
        #expect(fixture.account != previous)
    }

    @Test func unreadableAndMalformedKeychainAreNotAbsentCredentials() async throws {
        let fixture = RemoteFixture()
        try await fixture.connect()
        fixture.secrets.failure = .integrity
        #expect(throws: RemoteClientError.self) { try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) }
        fixture.secrets.failure = nil
        try fixture.secrets.write(Data("not-json".utf8), for: fixture.service.activeKey(fixture.server))
        #expect(throws: (any Error).self) { try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) }
    }

    @Test func nonHTTPSValidatedInitializerIsStillRejectedByTransportBoundary() async {
        let fixture = RemoteFixture()
        let invalid = ServerAddress(validated: URL(string: "http://fixture.test")!)
        guard case .failed = await fixture.service.connectServer(server: invalid) else { Issue.record("HTTPS is required"); return }
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func unconfirmedPairingStopsPollingWithoutInventingGrantExpiry() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        fixture.deviceConfirmed = false
        let pairing = PairingID(rawValue: fixture.pairingID)!
        #expect(await fixture.service.refreshHostPairing(server: fixture.server, account: fixture.account, pairingID: pairing)
            == .pendingConfirmation(pairing, fixture.scope.host))
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(301)
        guard case .failed = await fixture.service.refreshHostPairing(server: fixture.server, account: fixture.account, pairingID: pairing) else {
            Issue.record("Confirmation timeout must not become a fabricated confirmed/expired grant")
            return
        }
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account)?.hosts.isEmpty == true)
    }
}
