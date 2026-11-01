import Foundation
import Testing
@testable import GianCore

@MainActor
struct AuthorizationInvalidationTests {
    @Test func logoutBarrierSurvivesReopenWithoutDeletingHistoryOrCacheClear() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let storage = try SQLiteGianStorage(directory: directory)
        try storage.save(retainedFixture(), scope: scope)
        let at = PreviewFixtures.instant
        try storage.invalidateAuthorization(scope: scope.data, at: at)
        try storage.invalidateAuthorization(scope: scope.data, at: at.addingTimeInterval(-10))
        try storage.clearDownloadCache(scope: scope)
        let reopened = try SQLiteGianStorage(directory: directory)
        #expect(try reopened.authorizationInvalidatedAt(scope: scope.data) == at)
        #expect(try reopened.load(scope: scope)?.sessions.isEmpty == false)
        let foreign = DataScope(server: ServerAddress(parsing: "https://other.fixture.test")!, account: scope.account)
        #expect(try reopened.authorizationInvalidatedAt(scope: foreign) == nil)
    }

    @Test func rolledBackBarrierIsNotReportedAsPersisted() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        storage.beforeAuthorizationInvalidationCommit = { throw GianStorageError.unavailable }
        #expect(throws: GianStorageError.unavailable) {
            try storage.invalidateAuthorization(scope: fictionalScope().data, at: PreviewFixtures.instant)
        }
        #expect(try storage.authorizationInvalidatedAt(scope: fictionalScope().data) == nil)
    }

    @Test func staleEvidenceCannotRestoreAfterProcessReopen() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let evidence = fictionalAuthorization(clock: clock)
        let store = GianClientStore(service: PreviewGianClientService(script: .legacyContract), clock: clock, storage: storage)
        #expect(store.restoreAuthorizedSession(authorization: evidence).isApplied)
        #expect(store.logout(invalidateRemote: false).isApplied)
        let reopened = GianClientStore(service: PreviewGianClientService(script: .legacyContract), clock: clock,
            storage: try SQLiteGianStorage(directory: directory))
        #expect(reopened.restoreAuthorizedSession(authorization: evidence) == .rejected(.notAuthorized))
        #expect(reopened.state.phase == .signedOut)
        clock.instant = clock.instant.addingTimeInterval(1)
        #expect(reopened.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
    }

    @Test func failedBarrierStillHidesImmediatelyAndReportsUnconfirmedDurability() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: PreviewGianClientService(script: .legacyContract), clock: clock, storage: storage)
        let evidence = fictionalAuthorization(clock: clock)
        #expect(store.restoreAuthorizedSession(authorization: evidence).isApplied)
        storage.beforeAuthorizationInvalidationCommit = { throw GianStorageError.unavailable }
        #expect(store.logout(invalidateRemote: false).isApplied)
        #expect(store.state.phase == .signedOut)
        #expect(store.state.drafts.isEmpty)
        #expect(store.authorizationInvalidationUnconfirmed)
        #expect(store.restoreAuthorizedSession(authorization: evidence) == .rejected(.notAuthorized))
    }
}
