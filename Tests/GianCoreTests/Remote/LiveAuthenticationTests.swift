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
        // Once admitted, connecting again needs no token and keeps the identity.
        let first = fixture.account
        try await fixture.connect(enrollmentToken: nil)
        #expect(fixture.account == first)
        let paths = fixture.transport.requests.compactMap { $0.url?.path }
        #expect(paths == ["/api/v1/server-identity", "/api/v1/controller-enrollments/claim", "/api/v1/server-identity"])
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

    @Test func aFirstConnectionNeedsAValidSingleUseEnrollmentToken() async throws {
        let fixture = RemoteFixture()
        #expect(await fixture.service.connectServer(server: fixture.server, enrollmentToken: nil) == .failed(ControllerEnrollment.tokenRequired))
        #expect(await fixture.service.connectServer(server: fixture.server, enrollmentToken: "wrong")
            == .failed("That enrollment token isn't valid for this server."))
        fixture.enrollmentError = "ENROLLMENT_EXPIRED"
        #expect(await fixture.service.connectServer(server: fixture.server, enrollmentToken: "fixture-enrollment-token")
            == .failed("That enrollment token expired. Tokens last 5 minutes; generate a new one."))
        fixture.enrollmentError = "ENROLLMENT_CONSUMED"
        #expect(await fixture.service.connectServer(server: fixture.server, enrollmentToken: "fixture-enrollment-token")
            == .failed("That enrollment token was already used. Generate a new one."))
        fixture.enrollmentError = nil
        try await fixture.connect()
        let claim = try #require(fixture.transport.requests.first { $0.url?.path == "/api/v1/controller-enrollments/claim" })
        #expect(claim.value(forHTTPHeaderField: "x-gian-account-token") == nil)
    }

    @Test func hostsArePairedAsTheAdmittedControllerByQROrOneTimeCode() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim(.code("7k3m q9tx"))
        #expect(fixture.lastClaim["code"] == .string("7K3M-Q9TX"))
        #expect(fixture.lastClaim["grant_nonce"] == .null)
        #expect(fixture.lastClaim["controller_admission"] == .int(1))
        let claim = try #require(fixture.transport.requests.last { $0.url?.path == "/api/v1/pairings/claim" })
        #expect(claim.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-controller-access")
        // The controller sign-in is reused for the next claim.
        let signIns = fixture.transport.requests.filter { $0.url?.path == "/api/v1/sessions/controller-login" }.count
        _ = await fixture.service.claimHost(server: fixture.server, account: fixture.account, invitation: .grantNonce("another-nonce-value"))
        #expect(fixture.lastClaim["grant_nonce"] == .string("another-nonce-value"))
        #expect(fixture.transport.requests.filter { $0.url?.path == "/api/v1/sessions/controller-login" }.count == signIns)
    }

    @Test func pairingCodesAreNormalizedLikeTheServer() {
        #expect(PairingCode.canonical("7K3M-Q9TX") == "7K3M-Q9TX")
        #expect(PairingCode.canonical("7k3mq9tx") == "7K3M-Q9TX")
        #expect(PairingCode.canonical(" 7k3m q9tx ") == "7K3M-Q9TX")
        #expect(PairingCode.canonical("ILO0-0000") == "1100-0000")
        #expect(PairingCode.canonical("7K3M-Q9T") == nil)
        #expect(PairingCode.canonical("7K3M-Q9TU") == nil)
        #expect(PairingCode.canonical("7K3M-Q9TX1") == nil)
        #expect(PairingCode.canonical("7K3M_Q9TX") == nil)
        #expect(PairingCode.characters(from: "7k3-m!q9tx99") == "7K3MQ9TX")
    }

    @Test func aChangedServerIdentityIsRefusedUntilForgotten() async throws {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        fixture.serverKeyChanged = true
        #expect(await fixture.service.connectServer(server: fixture.server, enrollmentToken: "fixture-enrollment-token") == .identityChanged)
        let claim = await fixture.service.claimHost(server: fixture.server, account: fixture.account,
            invitation: .grantNonce("fictional-qr-nonce"))
        guard case .failed = claim else { Issue.record("A changed Server must not receive a claim"); return }

        try await fixture.service.forgetServer(fixture.server)
        let previous = fixture.account
        fixture.enrollmentTokens.insert("second-token")
        try await fixture.connect(enrollmentToken: "second-token")
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
        guard case .failed = await fixture.service.connectServer(server: fixture.server, enrollmentToken: "fixture-enrollment-token") else {
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
        #expect(!paths.contains { $0.contains("/account/") })
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
        // A new identity is a new controller: it needs a new enrollment token.
        #expect(await fixture.service.connectServer(server: fixture.server, enrollmentToken: nil) == .failed(ControllerEnrollment.tokenRequired))
        fixture.enrollmentTokens.insert("second-token")
        try await fixture.connect(enrollmentToken: "second-token")
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
        guard case .failed = await fixture.service.connectServer(server: invalid, enrollmentToken: "fixture-enrollment-token") else { Issue.record("HTTPS is required"); return }
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
