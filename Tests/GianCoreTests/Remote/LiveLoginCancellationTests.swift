import Foundation
import Testing
@testable import GianCore

@MainActor
struct LiveLoginCancellationTests {
    private func begin(_ fixture: RemoteFixture) async throws -> GitHubDeviceLoginChallenge {
        guard case .started(let challenge) = await fixture.service.startGitHubDeviceLogin(server: fixture.server) else { throw RemoteClientError.invalidPayload }
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(5)
        return challenge
    }

    @Test func cancelAtPointerPersistenceBeforeCoreConsumesAuthorization() async throws {
        let fixture = RemoteFixture()
        let challenge = try await begin(fixture)
        let persisted = RemoteMailbox(limit: 1)
        let deliverToCore = RemoteMailbox(limit: 1)
        fixture.secrets.didWrite = { key in
            if key == fixture.service.activeKey(fixture.server) {
                fixture.secrets.didWrite = nil
                try persisted.push(.null)
            }
        }
        let pendingCoreResult = Task {
            let result = await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID)
            _ = try await deliverToCore.next()
            return result
        }
        _ = try await persisted.next()
        #expect(fixture.service.login == nil)
        let pointer = try #require(try fixture.service.activeAuthorization(server: fixture.server))
        let oldEpoch = fixture.service.eventEpoch
        do { try await fixture.service.cancelLogin(server: fixture.server, loginID: challenge.loginID); Issue.record("No server cancellation endpoint exists") }
        catch { #expect(error as? RemoteClientError == .unsupported) }
        #expect(fixture.service.eventEpoch > oldEpoch)
        #expect(try fixture.service.activeAuthorization(server: fixture.server) == nil)
        #expect(fixture.secrets.records[fixture.service.vaultKey(server: fixture.server, account: fixture.account,
            installation: pointer.installation, authorizationID: pointer.authorizationID)] == nil)
        try deliverToCore.push(.null)
        guard case .authorized = try await pendingCoreResult.value else { Issue.record("The stale identity result was deliberately held outside Core"); return }
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
        let restarted = LiveGianClientService(transport: fixture.transport, secrets: fixture.secrets, authorizationInvalidations: fixture.invalidations, clock: fixture.clock)
        #expect(try restarted.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
        #expect(await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) == .expired)
    }

    @Test func reentrantCancellationAfterVaultWriteCannotInstallActivePointer() async throws {
        let fixture = RemoteFixture()
        let challenge = try await begin(fixture)
        fixture.secrets.didWrite = { key in
            guard key.purpose.hasPrefix("account-and-grants:") else { return }
            fixture.secrets.didWrite = nil
            let attempt = try #require(fixture.service.loginAttempts[RemoteLoginAttemptKey(server: fixture.server, loginID: challenge.loginID)])
            try fixture.service.cancelLoginLocally(attempt)
        }
        #expect(await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) == .expired)
        #expect(try fixture.service.activeAuthorization(server: fixture.server) == nil)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
    }

    @Test func cancellingNewAuthorizationPreservesPreviouslyAuthorizedAccount() async throws {
        let fixture = RemoteFixture()
        try await fixture.loginAndClaim()
        let previous = try #require(try fixture.service.activeAuthorization(server: fixture.server))
        let previousKey = fixture.service.vaultKey(server: fixture.server, account: fixture.account,
            installation: previous.installation, authorizationID: previous.authorizationID)
        let previousBytes = try #require(fixture.secrets.records[previousKey])
        fixture.loginID = "00000000-0000-7000-8000-000000000070"
        fixture.differentAccount = true
        let challenge = try await begin(fixture)
        guard case .authorized(let other) = await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) else { throw RemoteClientError.invalidPayload }
        #expect(other.account != fixture.account)
        do { try await fixture.service.cancelLogin(server: fixture.server, loginID: challenge.loginID) } catch { #expect(error as? RemoteClientError == .unsupported) }
        #expect(try fixture.service.activeAuthorization(server: fixture.server) == previous)
        #expect(fixture.secrets.records[previousKey] == previousBytes)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) != nil)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: other.account) == nil)
    }

    @Test func cancellingOldAttemptDoesNotEraseNewerAuthorization() async throws {
        let fixture = RemoteFixture()
        try await fixture.loginAndClaim()
        let oldID = LoginID(rawValue: fixture.loginID)!
        fixture.loginID = "00000000-0000-7000-8000-000000000071"
        let challenge = try await begin(fixture)
        guard case .authorized = await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) else { throw RemoteClientError.invalidPayload }
        let current = try fixture.service.activeAuthorization(server: fixture.server)
        let currentEpoch = fixture.service.eventEpoch
        do { try await fixture.service.cancelLogin(server: fixture.server, loginID: oldID) } catch { #expect(error as? RemoteClientError == .unsupported) }
        #expect(try fixture.service.activeAuthorization(server: fixture.server) == current)
        #expect(fixture.service.eventEpoch == currentEpoch)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) != nil)
        do { try await fixture.service.cancelLogin(server: fixture.server, loginID: challenge.loginID) } catch { #expect(error as? RemoteClientError == .unsupported) }
        #expect(try fixture.service.activeAuthorization(server: fixture.server) == nil)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
    }

    @Test func failedSecureCleanupIsUnconfirmedAndProcessLocallyDenied() async throws {
        let fixture = RemoteFixture()
        let challenge = try await begin(fixture)
        guard case .authorized = await fixture.service.pollGitHubDeviceLogin(server: fixture.server, loginID: challenge.loginID) else { throw RemoteClientError.invalidPayload }
        let pointer = try fixture.service.activeAuthorization(server: fixture.server)
        fixture.secrets.mutationFailure = { _, _ in .transport }
        do { try await fixture.service.cancelLogin(server: fixture.server, loginID: challenge.loginID); Issue.record("Cleanup failure must not be reported as confirmed") }
        catch { #expect(error as? RemoteClientError == .transport) }
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
        #expect(try fixture.service.activeAuthorization(server: fixture.server) == pointer)
        // Failed writes are not a durable repository barrier. The caller must retain
        // the unconfirmed outcome; a new process cannot infer an unwritten tombstone.
        #expect(fixture.secrets.mutations.contains { $0.1 == .remove })
    }
}
