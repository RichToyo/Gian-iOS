import Foundation
import Testing
@testable import GianCore

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
    /// Regression: login stored the vault with two separate clock reads, so on
    /// a real clock authorizationCreatedAt landed after lastVerifiedAt, the
    /// invalidation barrier threw `integrity`, and every real sign-in surfaced
    /// as "The sign-in code expired".
    @Test func loginSucceedsWhenTheClockMovesBetweenReads() async throws {
        let fixture = RemoteFixture()
        fixture.clock.advancesOnRead = 0.000_1
        guard case .started(let challenge) = await fixture.service.startGitHubDeviceLogin(server: fixture.server) else {
            Issue.record("Login did not start"); return
        }
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(5)
        let polled = await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID)
        guard case .authorized(let identity) = polled else { Issue.record("Expected authorization, got \(polled)"); return }
        #expect(identity.account == fixture.account)
    }
    @Test func signedDeviceFlowAndGrantAreSeparate() async throws {
        let fixture = RemoteFixture()
        try await fixture.loginAndClaim()
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
        #expect(paths.contains("/api/v1/account/start"))
        #expect(!paths.contains { $0.contains("password") || $0.contains("enrollment") })
    }
    @Test func transientPollBackoffIsNotDenialOrAuthorization() async throws {
        let fixture = RemoteFixture()
        guard case .started(let challenge) = await fixture.service.startGitHubDeviceLogin(server: fixture.server) else { Issue.record("Missing challenge"); return }
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(5)
        fixture.pollFailure = .server(code: "HOST_OFFLINE", retryAfter: 30)
        let result = await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID)
        #expect(result == .pending(intervalSeconds: 30))
        #expect(fixture.service.lastFailure == fixture.pollFailure)
        fixture.clock.instant = challenge.expiresAt
        #expect(await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) == .expired)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
    }
    @Test func cancellationCannotBeFollowedByAStaleAuthorization() async throws {
        let fixture = RemoteFixture()
        guard case .started(let challenge) = await fixture.service.startGitHubDeviceLogin(server: fixture.server) else { Issue.record("Missing challenge"); return }
        do { try await fixture.service.cancelLogin(server: fixture.server, loginID: challenge.loginID); Issue.record("Canonical cancellation is unsupported") }
        catch { #expect(error as? RemoteClientError == .unsupported) }
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(5)
        #expect(await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) == .expired)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
    }
    @Test func accountMismatchFailsBeforePairingAndLogoutIsLocalEvenOffline() async throws {
        let fixture = RemoteFixture()
        try await fixture.loginAndClaim()
        fixture.differentAccount = true
        let result = await fixture.service.refreshHostPairing(server: fixture.server, account: fixture.account, pairingID: PairingID(rawValue: fixture.pairingID)!)
        guard case .failed = result else { Issue.record("Cross-account device login must fail"); return }
        do { try await fixture.service.logout(server: fixture.server, account: fixture.account); Issue.record("Offline logout must not claim server success") } catch {}
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
    }
    @Test func unreadableAndMalformedKeychainAreNotAbsentCredentials() throws {
        let fixture = RemoteFixture()
        fixture.secrets.failure = .integrity
        #expect(throws: RemoteClientError.self) { try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) }
        fixture.secrets.failure = nil
        try fixture.secrets.write(Data("not-json".utf8), for: fixture.service.activeKey(fixture.server))
        #expect(throws: (any Error).self) { try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) }
    }
    @Test func aCancelledInFlightPollCannotReinstallCredentials() async throws {
        let fixture = RemoteFixture()
        guard case .started(let challenge) = await fixture.service.startGitHubDeviceLogin(server: fixture.server) else { Issue.record("Missing challenge"); return }
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(5)
        let gate = RemoteMailbox()
        let original = try #require(fixture.transport.handler)
        fixture.transport.handler = { request in
            if request.url?.path == "/api/v1/account/poll" { _ = try await gate.next() }
            return try await original(request)
        }
        let task = Task { await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) }
        while gate.waiter == nil { await Task.yield() }
        do { try await fixture.service.cancelLogin(server: fixture.server, loginID: challenge.loginID) } catch {}
        try gate.push(.null)
        #expect(await task.value == .expired)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
    }
    @Test func nonHTTPSValidatedInitializerIsStillRejectedByTransportBoundary() async {
        let fixture = RemoteFixture()
        let invalid = ServerAddress(validated: URL(string: "http://fixture.test")!)
        guard case .failed = await fixture.service.startGitHubDeviceLogin(server: invalid) else { Issue.record("HTTPS is required"); return }
        #expect(fixture.transport.requests.isEmpty)
    }
    @Test func unconfirmedPairingStopsPollingWithoutInventingGrantExpiry() async throws {
        let fixture = RemoteFixture()
        try await fixture.loginAndClaim()
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
