import Foundation
import Testing
@testable import GianCore

@MainActor
private final class FailingBarrierStorage: GianStorage {
    let backing = InMemoryGianStorage()
    var failReads = false
    var invalidationAttempts = 0
    func load(scope: ClientScope) throws -> StoredHostState? { try backing.load(scope: scope) }
    func save(_ state: StoredHostState, scope: ClientScope) throws { try backing.save(state, scope: scope) }
    func clearDownloadCache(scope: ClientScope) throws { try backing.clearDownloadCache(scope: scope) }
    func invalidateAuthorization(scope: DataScope, at: Date) throws {
        invalidationAttempts += 1
        throw GianStorageError.unavailable
    }
    func authorizationInvalidatedAt(scope: DataScope) throws -> Date? {
        if failReads { throw GianStorageError.unavailable }
        return try backing.authorizationInvalidatedAt(scope: scope)
    }
}

@MainActor
struct RemoteBarrierBridgeTests {
    @Test func readableKeychainCannotRestoreAfterFailedSecureLogoutAndSQLiteReopen() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let fixture = RemoteFixture(invalidations: storage)
        try await fixture.loginAndClaim()
        fixture.secrets.mutationFailure = { _, _ in .transport }
        do { try await fixture.service.logout(server: fixture.server, account: fixture.account); Issue.record("Secure cleanup must throw") }
        catch { #expect(error as? RemoteClientError == .transport) }
        #expect(try fixture.service.activeAuthorization(server: fixture.server) != nil)
        let reopened = try SQLiteGianStorage(directory: directory)
        #expect(try reopened.authorizationInvalidatedAt(scope: fixture.scope.data) != nil)
        let restarted = LiveGianClientService(transport: fixture.transport, secrets: fixture.secrets,
            authorizationInvalidations: reopened, clock: fixture.clock)
        #expect(try restarted.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
    }

    @Test func coreBarrierPrecedesHidingButDoesNotPreventExplicitRemoteLogoutCleanup() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let fixture = RemoteFixture(invalidations: storage)
        try await fixture.loginAndClaim()
        let evidence = try #require(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account))
        let store = GianClientStore(service: fixture.service, clock: fixture.clock, storage: storage)
        #expect(store.restoreAuthorizedSession(authorization: evidence).isApplied)
        #expect((await store.dispatch(.logout)).isApplied)
        #expect(store.state.phase == .signedOut)
        #expect(!store.authorizationInvalidationUnconfirmed)
        // The fictional endpoint loses its response. Local cleanup and remote
        // acknowledgement are deliberately separate outcomes.
        #expect(store.serverOutcomeUnconfirmed)
        #expect(fixture.transport.requests.contains { $0.url?.path == "/api/v1/account/logout" })
    }

    @Test func cancellationNeverRollsBackToAnExplicitlySignedOutPreviousAccount() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let fixture = RemoteFixture(invalidations: storage)
        try await fixture.loginAndClaim()
        fixture.loginID = "00000000-0000-7000-8000-000000000090"
        fixture.differentAccount = true
        guard case .started(let challenge) = await fixture.service.startGitHubDeviceLogin(server: fixture.server) else {
            Issue.record("Missing fictional login"); return
        }
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(5)
        guard case .authorized = await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) else {
            Issue.record("Missing fictional authorization"); return
        }
        // Simulate the independent Core logout barrier even when old secure
        // records remain readable. Attempt rollback must consult the same loader.
        try storage.invalidateAuthorization(scope: fixture.scope.data, at: fixture.clock.now())
        do { try await fixture.service.cancelLogin(server: fixture.server, loginID: challenge.loginID) }
        catch { #expect(error as? RemoteClientError == .unsupported) }
        #expect(try fixture.service.activeAuthorization(server: fixture.server) == nil)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
    }

    @Test func laterVerificationTimestampIsNotANewAuthorizationProof() async throws {
        let fixture = RemoteFixture()
        try await fixture.loginAndClaim()
        var old = try fixture.service.requireVault(server: fixture.server, account: fixture.account)
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(1)
        try fixture.invalidations.invalidateAuthorization(scope: fixture.scope.data, at: fixture.clock.now())
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(1)
        old.lastVerifiedAt = fixture.clock.now()
        #expect(throws: RemoteClientError.notAuthorized) {
            try fixture.service.saveVault(old, server: fixture.server, account: fixture.account, epoch: fixture.service.eventEpoch)
        }
    }

    @Test func totalDurableWriteFailureIsExplicitlyUnconfirmedNotRestartSafety() async throws {
        let storage = FailingBarrierStorage()
        let fixture = RemoteFixture(invalidations: storage)
        try await fixture.loginAndClaim()
        let evidence = try #require(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account))
        let store = GianClientStore(service: fixture.service, clock: fixture.clock, storage: storage)
        #expect(store.restoreAuthorizedSession(authorization: evidence).isApplied)
        fixture.secrets.mutationFailure = { _, _ in .transport }
        #expect((await store.dispatch(.logout)).isApplied)
        #expect(storage.invalidationAttempts >= 2)
        #expect(store.state.phase == .signedOut)
        #expect(store.authorizationInvalidationUnconfirmed)
        #expect(store.serverOutcomeUnconfirmed)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
        let restarted = LiveGianClientService(transport: fixture.transport, secrets: fixture.secrets,
            authorizationInvalidations: storage, clock: fixture.clock)
        // Neither independent barrier could be written. A future process cannot
        // infer an unwritten logout; documenting this residual is intentional.
        #expect(try restarted.loadCachedAuthorization(server: fixture.server, account: fixture.account) != nil)
        storage.failReads = true
        #expect(throws: GianStorageError.unavailable) {
            _ = try restarted.loadCachedAuthorization(server: fixture.server, account: fixture.account)
        }
    }
}
