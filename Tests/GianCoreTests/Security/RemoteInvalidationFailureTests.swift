import Foundation
import Testing
@testable import GianCore

@MainActor
struct RemoteInvalidationFailureTests {
    private func authorized() async throws -> RemoteFixture {
        let fixture = RemoteFixture()
        try await fixture.loginAndClaim()
        fixture.transport.socket = FixtureRelaySocket(fixture)
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account)?.hosts.count == 1)
        return fixture
    }

    @Test func logoutReportsFailedTombstoneOrDeletionAndDeniesLocalRestoration() async throws {
        for failing in [FixtureSecretOperation.write, .remove] {
            let fixture = try await authorized()
            fixture.secrets.mutationFailure = { _, operation in operation == failing ? .transport : nil }
            do { try await fixture.service.logout(server: fixture.server, account: fixture.account); Issue.record("Secure cleanup was not confirmed") }
            catch { #expect(error as? RemoteClientError == .transport) }
            #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
            #expect(!fixture.transport.requests.contains { $0.url?.path == "/api/v1/account/logout" })
            let marker = fixture.service.tombstoneKey(server: fixture.server, account: fixture.account)
            if failing == .write {
                // This process denies restoration, but failed persistence does not
                // constitute a durable barrier that a future process can observe.
                #expect(fixture.secrets.records[marker] == nil)
                #expect(try fixture.service.activeAuthorization(server: fixture.server) != nil)
            } else {
                #expect(fixture.secrets.records[marker] != nil)
                let restarted = LiveGianClientService(transport: fixture.transport, secrets: fixture.secrets, authorizationInvalidations: fixture.invalidations, clock: fixture.clock)
                #expect(try restarted.loadCachedAuthorization(server: fixture.server, account: fixture.account) == nil)
            }
        }
    }

    @Test func revokeDoesNotClaimDurabilityWhenHostMarkerOrVaultWriteFails() async throws {
        for failMarker in [true, false] {
            let fixture = try await authorized()
            let marker = fixture.service.tombstoneKey(server: fixture.server, account: fixture.account, host: fixture.scope.host)
            fixture.secrets.mutationFailure = { key, _ in
                if failMarker { return key == marker ? .transport : nil }
                return key.purpose.hasPrefix("account-and-grants:") ? .transport : nil
            }
            do { try await fixture.service.revoke(scope: fixture.scope); Issue.record("Secure revocation cleanup was not confirmed") }
            catch { #expect(error as? RemoteClientError == .transport) }
            let current = try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account)
            if failMarker { #expect(current == nil) }
            else { #expect(current?.hosts.isEmpty == true) }
            #expect(!fixture.transport.requests.contains { $0.httpMethod == "DELETE" })
            if failMarker { #expect(fixture.secrets.records[marker] == nil) }
            else {
                #expect(fixture.secrets.records[marker] != nil)
                let restarted = LiveGianClientService(transport: fixture.transport, secrets: fixture.secrets, authorizationInvalidations: fixture.invalidations, clock: fixture.clock)
                #expect(try restarted.loadCachedAuthorization(server: fixture.server, account: fixture.account)?.hosts.isEmpty == true)
            }
        }
    }
}
