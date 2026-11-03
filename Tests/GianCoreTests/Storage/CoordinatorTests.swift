import Foundation
import Testing
@testable import GianCore

@MainActor
private final class CoordinatedService: ControlledService, GianClientLifecycle, GianClientEventSource, DirectoryReadinessReporting {
    var eventEpoch = 0
    var acceptedDirectory: AcceptedDirectory?
    let events: AsyncStream<InboundEnvelope>
    let diagnostics: AsyncStream<RemoteServiceDiagnostic>
    let eventSink: AsyncStream<InboundEnvelope>.Continuation
    let diagnosticSink: AsyncStream<RemoteServiceDiagnostic>.Continuation
    var connected: ClientScope?
    var connections = 0
    var directoryReads = 0
    var logoutCalls = 0
    var holdDirectory = false
    var holdLogout = false
    var holdConnect = false
    var forgotServers: [ServerAddress] = []
    var directoryResult: CheckedContinuation<DirectoryRefreshResponse, Never>?
    var logoutResult: CheckedContinuation<Void, any Error>?
    var connectResult: CheckedContinuation<ServerConnectResponse, Never>?

    override init() {
        let events = AsyncStream<InboundEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.events = events.stream; eventSink = events.continuation
        let diagnostics = AsyncStream<RemoteServiceDiagnostic>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.diagnostics = diagnostics.stream; diagnosticSink = diagnostics.continuation
        super.init()
    }
    func connect(scope: ClientScope) async throws {
        if connected == scope { return }
        eventEpoch += 1; connections += 1; connected = scope; acceptedDirectory = nil
    }
    func disconnect() async { eventEpoch += 1; connected = nil; acceptedDirectory = nil }
    func forgetServer(_ server: ServerAddress) async throws { forgotServers.append(server) }
    func logout(server: ServerAddress, account: AccountID) async throws {
        logoutCalls += 1
        await disconnect()
        if holdLogout { try await withCheckedThrowingContinuation { logoutResult = $0 } }
    }
    func revoke(scope: ClientScope) async throws { await disconnect() }
    override func refreshDirectory(scope: ClientScope) async -> DirectoryRefreshResponse {
        directoryReads += 1
        let response: DirectoryRefreshResponse
        if holdDirectory { response = await withCheckedContinuation { directoryResult = $0 } }
        else { response = await super.refreshDirectory(scope: scope) }
        if case .snapshot(let payload) = response {
            acceptedDirectory = AcceptedDirectory(scope: scope, cursor: payload.cursor, catalogRevision: payload.catalogRevision)
        }
        return response
    }
    override func connectServer(server: ServerAddress, enrollmentToken: String?) async -> ServerConnectResponse {
        if holdConnect { return await withCheckedContinuation { connectResult = $0 } }
        return await super.connectServer(server: server, enrollmentToken: enrollmentToken)
    }
}

@MainActor
struct CoordinatorTests {
    @Test func newSameEpochResyncIsNotIgnoredAndOldClearedCannotEraseIt() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService()
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        let scope = try clientScope(store)
        service.holdDirectory = true
        service.acceptedDirectory = nil
        #expect(!store.mutationsReady)
        service.diagnosticSink.yield(RemoteServiceDiagnostic(server: scope.server, account: scope.account,
            host: scope.host, epoch: service.eventEpoch, status: .resyncRequired(.gapEvicted)))
        service.diagnosticSink.yield(RemoteServiceDiagnostic(server: scope.server, account: scope.account,
            host: scope.host, epoch: service.eventEpoch, status: .cleared))
        for _ in 0..<100 where service.directoryResult == nil { await Task.yield() }
        let completion = try #require(service.directoryResult)
        service.directoryResult = nil
        #expect(store.state.sync.needsSnapshot)
        #expect(store.state.sync.reason == .gapEvicted)
        #expect(!store.mutationsReady)
        #expect(store.serviceDiagnostic?.status == .resyncRequired(.gapEvicted))
        service.holdDirectory = false
        completion.resume(returning: .unknownOutcome)
        for _ in 0..<100 where store.state.sync.needsSnapshot { await Task.yield() }
        #expect(store.mutationsReady)
        // The old signal on the event stream must also be harmless now.
        service.eventSink.yield(InboundEnvelope(scope: scope, event: .snapshotRequired(.gapEvicted), serviceEpoch: service.eventEpoch))
        for _ in 0..<30 { await Task.yield() }
        #expect(store.mutationsReady)
        await coordinator.stop()
    }

    @Test func awaitedPageChecksActualProducerEpochBeforeDelayedStreamsArrive() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService()
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        service.holdNextPage = true
        let pending = Task { await store.dispatch(.selectConversation(PreviewFixtures.sessionID)) }
        for _ in 0..<100 where service.page == nil { await Task.yield() }
        let completion = try #require(service.page)
        service.page = nil
        service.eventEpoch += 1
        service.acceptedDirectory = nil
        let stale = transcriptItem(id: "old-connection-result", turn: 1, text: "Do not apply")
        completion.resume(returning: TranscriptPageResponse(items: [stale], cursor: nil, hasOlder: false))
        #expect(await pending.value == .rejected(.staleOperation))
        #expect(store.state.conversation?.items.contains(where: { $0.id == stale.id }) != true)
        #expect(!store.mutationsReady)
        await coordinator.stop()
    }

    @Test func constructionIsInertAndOnlyOneCoordinatorOwnsTheStreams() throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService()
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        #expect(!coordinator.isRunning)
        #expect(service.connections == 0)
        #expect(service.directoryReads == 0)
        #expect(throws: GianCoordinatorError.alreadyBound) {
            _ = try GianClientCoordinator(store: store, runtime: service, events: service.events,
                diagnostics: service.diagnostics, loadAuthorization: { _, _ in nil })
        }
        let foreign = CoordinatedService()
        #expect(throws: GianCoordinatorError.serviceMismatch) {
            _ = try GianClientCoordinator(store: store, runtime: foreign, events: foreign.events,
                diagnostics: foreign.diagnostics, loadAuthorization: { _, _ in nil })
        }
    }

    @Test func manyResyncSignalsShareOneInFlightDirectoryRead() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService()
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        let before = service.directoryReads
        service.holdDirectory = true
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        coordinator.start()
        let pending = Task { await coordinator.refreshConnection() }
        for _ in 0..<100 where service.directoryResult == nil { await Task.yield() }
        let completion = try #require(service.directoryResult)
        service.directoryResult = nil
        let scope = try clientScope(store)
        for _ in 0..<10 {
            service.eventSink.yield(InboundEnvelope(scope: scope, event: .snapshotRequired(.revisionMismatch), serviceEpoch: service.eventEpoch))
        }
        for _ in 0..<30 { await Task.yield() }
        #expect(service.directoryReads == before + 1)
        service.holdDirectory = false
        completion.resume(returning: .snapshot(service.base.script.directory))
        #expect((await pending.value).isApplied)
        #expect(store.mutationsAllowed())
        await coordinator.stop()
    }

    @Test func logoutHidesImmediatelyEvenWhenServerConfirmationFails() async throws {
        let storage = InMemoryGianStorage()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService()
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store, text: "Retained draft")
        let scope = try clientScope(store)
        service.holdLogout = true
        let pending = Task { await store.dispatch(.logout) }
        for _ in 0..<100 where service.logoutResult == nil { await Task.yield() }
        let completion = try #require(service.logoutResult)
        service.logoutResult = nil
        #expect(store.state.phase == .signedOut)
        #expect(store.state.conversation == nil)
        #expect(store.state.drafts.isEmpty)
        #expect(store.serverOutcomeUnconfirmed)
        #expect(try storage.load(scope: scope)?.drafts.contains(where: { $0.text == "Retained draft" }) == true)
        completion.resume(throwing: RemoteClientError.transport)
        #expect((await pending.value).isApplied)
        #expect(store.serverOutcomeUnconfirmed)
        #expect(service.logoutCalls == 1)
        #expect(store.state.phase == .signedOut)
        await coordinator.stop()
    }

    @Test func backgroundingFencesALateServerConnection() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService()
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        service.holdConnect = true
        let pending = Task { await store.dispatch(.setServerAddress(PreviewFixtures.server, enrollmentToken: PreviewFixtures.enrollmentToken)) }
        for _ in 0..<100 where service.connectResult == nil { await Task.yield() }
        let completion = try #require(service.connectResult)
        service.connectResult = nil
        #expect(store.state.account.status == .pending)
        _ = await store.dispatch(.setForeground(.background))
        completion.resume(returning: .connected(PreviewScript.legacyContract.account))
        #expect(await pending.value == .rejected(.staleOperation))
        #expect(store.state.phase == .serverEntered)
        #expect(store.state.account.status == .error)
        #expect(store.state.account.accountID == nil)
    }

    @Test func lateConnectionDiagnosticsCannotUndoFreshSameEpochDirectoryReadiness() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService()
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = await coordinator.refreshConnection()
        let before = service.directoryReads
        let scope = try clientScope(store)
        service.diagnosticSink.yield(RemoteServiceDiagnostic(server: scope.server, account: scope.account,
            host: scope.host, epoch: service.eventEpoch, status: .cleared))
        service.diagnosticSink.yield(RemoteServiceDiagnostic(server: scope.server, account: scope.account,
            host: scope.host, epoch: service.eventEpoch, status: .resyncRequired(.cryptoResumed)))
        for _ in 0..<50 { await Task.yield() }
        #expect(store.state.connection == .online)
        #expect(!store.state.sync.needsSnapshot)
        #expect(service.directoryReads == before)
        await coordinator.stop()
    }

    @Test func terminatedStreamCannotSilentlyBecomeMutationReadyAgain() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService()
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = await coordinator.refreshConnection()
        #expect(store.mutationsAllowed())
        service.eventSink.finish()
        for _ in 0..<100 where coordinator.isRunning { await Task.yield() }
        #expect(!coordinator.isRunning)
        #expect(!store.mutationsAllowed())
        #expect(await store.dispatch(.refreshDirectory) == .rejected(.mutationsDisabled))
        #expect(!store.mutationsAllowed())
        #expect(service.base.sendCount == 0)
    }
}
