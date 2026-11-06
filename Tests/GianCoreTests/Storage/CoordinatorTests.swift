import Foundation
import Testing
@testable import GianCore

@MainActor
private final class CoordinatedService: ControlledService, GianClientLifecycle, GianClientEventSource, DirectoryReadinessReporting, SessionAccessRevalidating, DirectoryMembershipEpoch {
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
    var useNegotiatedDirectory = false
    var pageReplies: [DirectoryCollection: [DirectoryPageResponse]] = [:]
    var pageRequests: [DirectoryPageRequest] = []
    var holdNextList = false
    var heldList: CheckedContinuation<DirectoryPageResponse, Never>?
    var holdListCursor: String?
    var failConnect = false
    var directoryMembershipGeneration = 0
    var holdAccess = false
    var accessRequests: [SessionID] = []
    var accessWaiters: [CheckedContinuation<SessionAccessResult, Never>] = []

    func revalidateSessionAccess(scope: ClientScope, session: SessionID) async -> SessionAccessResult {
        accessRequests.append(session)
        if holdAccess { return await withCheckedContinuation { accessWaiters.append($0) } }
        return .authorized
    }

    override init() {
        let events = AsyncStream<InboundEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.events = events.stream; eventSink = events.continuation
        let diagnostics = AsyncStream<RemoteServiceDiagnostic>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.diagnostics = diagnostics.stream; diagnosticSink = diagnostics.continuation
        super.init()
    }
    func connect(scope: ClientScope) async throws {
        if failConnect { throw RemoteClientError.disconnected }
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
        if case .snapshot(var payload) = response {
            if useNegotiatedDirectory { payload.negotiatedFeatures.append(.sessionDirectoryV1) }
            acceptedDirectory = AcceptedDirectory(scope: scope, cursor: payload.cursor, catalogRevision: payload.catalogRevision)
            return .snapshot(payload)
        }
        return response
    }
    override func listDirectory(scope: ClientScope, request: DirectoryPageRequest) async -> DirectoryPageResponse {
        pageRequests.append(request)
        if holdNextList || (holdListCursor != nil && holdListCursor == request.cursor) {
            holdNextList = false
            holdListCursor = nil
            return await withCheckedContinuation { heldList = $0 }
        }
        if var queue = pageReplies[request.view], !queue.isEmpty {
            let response = queue.removeFirst(); pageReplies[request.view] = queue
            return response
        }
        return directoryPage(request.view)
    }
    override func connectServer(server: ServerAddress, enrollmentToken: String?) async -> ServerConnectResponse {
        if holdConnect { return await withCheckedContinuation { connectResult = $0 } }
        return await super.connectServer(server: server, enrollmentToken: enrollmentToken)
    }
}

@MainActor
struct CoordinatorTests {
    @Test func ambiguousRemovalRevalidationIsFencedByNewPatchAndServiceEpoch() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.directoryRefreshSleep = { _ in await Task.yield() }
        coordinator.accessRevalidationSleep = { _ in await Task.yield() }
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        let scope = try clientScope(store)
        let session = directoryEntry("coordinator-taskless").session
        store.sessions.append(session)
        service.holdAccess = true
        let baseline = try #require(store.state.sync.cursor)
        var removal = CanonicalStatePatch(); removal.removedSessions = [session.id]
        func publish(_ sequence: Int, _ base: String, _ revision: String) {
            let cursor = SyncCursor(hostGeneration: baseline.hostGeneration, eventSequence: sequence, revision: revision)
            service.acceptedDirectory = AcceptedDirectory(scope: scope, cursor: cursor, catalogRevision: store.state.catalogRevision)
            service.eventSink.yield(InboundEnvelope(scope: scope,
                event: .statePatch(sequence: sequence, generation: baseline.hostGeneration, baseRevision: base, revision: revision, patch: removal),
                serviceEpoch: service.eventEpoch))
        }
        publish(baseline.eventSequence + 1, baseline.revision, "access-1")
        for _ in 0..<2_000 where service.accessWaiters.isEmpty { await Task.yield() }
        #expect(service.accessWaiters.count == 1)
        let oldVersion = try #require(store.pendingSessionAccess[session.id])
        publish(baseline.eventSequence + 2, "access-1", "access-2")
        for _ in 0..<2_000 where store.pendingSessionAccess[session.id] == oldVersion { await Task.yield() }
        let newer = try #require(store.pendingSessionAccess[session.id])
        #expect(newer != oldVersion)
        service.accessWaiters.removeFirst().resume(returning: .authorized)
        for _ in 0..<2_000 where service.accessWaiters.isEmpty { await Task.yield() }
        #expect(store.pendingSessionAccess[session.id] == newer)
        #expect(service.accessWaiters.count == 1)
        service.eventEpoch += 1
        store.synchronizeServiceEpoch()
        service.accessWaiters.removeFirst().resume(returning: .authorized)
        for _ in 0..<20 { await Task.yield() }
        #expect(store.pendingSessionAccess[session.id] == newer)
        _ = store.ingest(InboundEnvelope(scope: scope, event: .sessionUnavailable(session.id), serviceEpoch: service.eventEpoch))
        #expect(store.deniedSessionAccess.contains(session.id))
        await coordinator.stop()
    }
    @Test func manualRefreshRecoversSnapshotBeforeReadingDirectory() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.directoryRefreshSleep = { _ in await Task.yield() }
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        let before = service.directoryReads
        var fresh = directoryEntry("Manual recovered", task: true); fresh.session.status = .new
        service.pageReplies[.tasks] = [directoryPage(.tasks, [fresh])]
        store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
        let result = await store.dispatch(.refreshDirectoryView(.tasks))
        #expect(result.isApplied)
        #expect(service.directoryReads > before)
        #expect(!store.state.sync.needsSnapshot)
        #expect(store.state.directory.tasks.flatMap(\.conversations).contains { $0.id == fresh.session.id })
        await coordinator.stop()
    }

    @Test func manualRefreshWhileAutomaticReadIsInFlightDoesNotResetIt() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.directoryRefreshSleep = { _ in await Task.yield() }
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        let scope = try clientScope(store)
        service.holdNextList = true
        service.eventSink.yield(InboundEnvelope(scope: scope, event: .directoryChanged(generation: PreviewFixtures.generationID, revision: "auto"), serviceEpoch: service.eventEpoch))
        for _ in 0..<1_000 where service.heldList == nil { await Task.yield() }
        let held = try #require(service.heldList); service.heldList = nil
        let requests = service.pageRequests.count
        #expect(await store.dispatch(.refreshDirectoryView(.tasks)) == .rejected(.operationInFlight))
        #expect(store.state.directory.tasksPage.phase == .loading)
        #expect(service.pageRequests.count == requests)
        held.resume(returning: directoryPage(.tasks))
        for _ in 0..<1_000 where store.directoryRefreshPending { await Task.yield() }
        #expect(!store.directoryRefreshPending)
        await coordinator.stop()
    }

    @Test func manualRefreshJoinsInFlightConnectionRecovery() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
        service.holdDirectory = true
        let reads = service.directoryReads
        let automatic = Task { await coordinator.refreshConnection() }
        for _ in 0..<1_000 where service.directoryResult == nil { await Task.yield() }
        let held = try #require(service.directoryResult); service.directoryResult = nil
        let manual = Task { await store.dispatch(.refreshDirectoryView(.tasks)) }
        for _ in 0..<1_000 where store.manualDirectoryRecoveries[.tasks]?.isEmpty != false { await Task.yield() }
        #expect(store.state.directory.tasksPage.phase == .loading)
        #expect(service.directoryReads == reads + 1)
        service.holdDirectory = false
        held.resume(returning: .snapshot(service.base.script.directory))
        #expect((await automatic.value).isApplied)
        let result = await manual.value
        #expect(result.isApplied || result == .rejected(.operationInFlight))
        #expect(service.directoryReads == reads + 1)
        await coordinator.stop()
    }

    @Test func manualRefreshReportsOfflineAndReconnectFailure() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        store.state.localConnectivity = .unavailable
        #expect(await store.dispatch(.refreshDirectoryView(.tasks)) == .rejected(.mutationsDisabled))
        #expect(store.state.directory.tasksPage.phase == .failed)
        #expect(store.state.directory.tasksPage.error?.contains("Network unavailable") == true)
        store.state.localConnectivity = .available
        store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
        service.failConnect = true
        #expect(await store.dispatch(.refreshDirectoryView(.tasks)) == .rejected(.mutationsDisabled))
        #expect(store.state.directory.tasksPage.phase == .failed)
        #expect(store.state.directory.tasksPage.error?.contains("reconnect") == true)
        await coordinator.stop()
    }

    @Test func repeatedManualRefreshContinuesBeyondFourPages() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.directoryRefreshSleep = { _ in await Task.yield() }
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        service.pageReplies[.tasks] = (1...4).map { directoryPage(.tasks, state: .incomplete, cursor: "manual-\($0)") }
        service.holdListCursor = "manual-4"
        #expect((await store.dispatch(.refreshDirectoryView(.tasks))).isApplied)
        for _ in 0..<1_000 where service.heldList == nil { await Task.yield() }
        let held = try #require(service.heldList); service.heldList = nil
        let count = service.pageRequests.count
        #expect(await store.dispatch(.refreshDirectoryView(.tasks)) == .rejected(.operationInFlight))
        #expect(service.pageRequests.count == count)
        var target = directoryEntry("Later manual page", task: true); target.session.status = .new
        held.resume(returning: directoryPage(.tasks, [target]))
        for _ in 0..<1_000 where store.state.directory.tasksPage.phase != .complete { await Task.yield() }
        #expect(store.state.directory.tasks.flatMap(\.conversations).contains { $0.id == target.session.id })
        #expect(service.pageRequests.last?.cursor == "manual-4")
        await coordinator.stop()
    }

    @Test func manualRefreshShowsStorageAndGrantFailuresWithoutReading() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        let requests = service.pageRequests.count
        store.storageWritesBlocked = true
        #expect(await store.dispatch(.refreshDirectoryView(.tasks)) == .rejected(.mutationsDisabled))
        #expect(store.state.directory.tasksPage.phase == .failed)
        #expect(store.state.directory.tasksPage.error?.contains("storage") == true)
        #expect(service.pageRequests.count == requests)
        store.storageWritesBlocked = false
        let grant = try #require(store.state.capabilities.grants.firstIndex(where: { $0.capability == .sessionRead }))
        store.state.capabilities.grants[grant].state = .denied
        #expect(await store.dispatch(.refreshDirectoryView(.tasks)) == .rejected(.capabilityDenied))
        #expect(store.state.directory.tasksPage.phase == .denied)
        #expect(service.pageRequests.count == requests)
        await coordinator.stop()
    }

    @Test func manualRecoveryAfterLogoutCannotExposeOldScopeFailureOrRows() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        service.holdDirectory = true
        store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
        let pending = Task { await store.dispatch(.refreshDirectoryView(.tasks)) }
        for _ in 0..<1_000 where service.directoryResult == nil { await Task.yield() }
        let held = try #require(service.directoryResult); service.directoryResult = nil
        _ = await store.dispatch(.logout)
        held.resume(returning: .snapshot(service.base.script.directory))
        #expect(await pending.value == .rejected(.staleOperation))
        #expect(store.state.phase == .signedOut)
        #expect(store.state.directory.tasks.isEmpty)
        #expect(store.state.directory.tasksPage.error == nil)
        await coordinator.stop()
    }
    @Test func directoryInvalidationsDuringThreeReadsStillProduceTrailingRefresh() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.directoryRefreshSleep = { _ in await Task.yield() }
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        let scope = try clientScope(store)
        var latest = directoryEntry("Newest", task: true); latest.session.status = .new
        service.pageReplies[.tasks] = [directoryPage(.tasks, [latest])]
        service.holdNextList = true
        service.eventSink.yield(InboundEnvelope(scope: scope, event: .directoryChanged(generation: PreviewFixtures.generationID, revision: "start"), serviceEpoch: service.eventEpoch))
        for index in 0..<3 {
            for _ in 0..<1_000 where service.heldList == nil { await Task.yield() }
            let held = try #require(service.heldList); service.heldList = nil
            let generation = store.directorySequence
            service.eventSink.yield(InboundEnvelope(scope: scope, event: .directoryChanged(generation: PreviewFixtures.generationID, revision: "hint-\(index)"), serviceEpoch: service.eventEpoch))
            for _ in 0..<1_000 where store.directorySequence == generation { await Task.yield() }
            #expect(store.directorySequence > generation)
            if index < 2 { service.holdNextList = true }
            held.resume(returning: directoryPage(.tasks))
        }
        for _ in 0..<1_000 where store.directoryRefreshPending { await Task.yield() }
        #expect(!store.directoryRefreshPending)
        #expect(store.state.directory.tasks.flatMap(\.conversations).contains { $0.id == latest.session.id })
        await coordinator.stop()
    }

    @Test func transientDirectoryFailureAndLongTraversalContinueWithoutAnotherHint() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.directoryRefreshSleep = { _ in await Task.yield() }
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        let scope = try clientScope(store)
        var latest = directoryEntry("Later page", task: true); latest.session.status = .new
        service.pageReplies[.tasks] = [.failed("Temporary")] + (1...4).map {
            directoryPage(.tasks, state: .incomplete, cursor: "page-\($0)")
        } + [directoryPage(.tasks, [latest])]
        service.eventSink.yield(InboundEnvelope(scope: scope, event: .directoryChanged(generation: PreviewFixtures.generationID, revision: "once"), serviceEpoch: service.eventEpoch))
        for _ in 0..<2_000 where !store.state.directory.tasks.flatMap(\.conversations).contains(where: { $0.id == latest.session.id }) { await Task.yield() }
        #expect(store.state.directory.tasks.flatMap(\.conversations).contains { $0.id == latest.session.id })
        #expect(store.state.directory.tasksPage.phase == .complete)
        #expect(service.pageRequests.contains { $0.cursor == "page-4" })
        await coordinator.stop()
    }

    @Test func directoryReplyAfterLogoutCannotPublishRows() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = CoordinatedService(); service.useNegotiatedDirectory = true
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { _, _ in fictionalAuthorization(clock: clock) })
        coordinator.directoryRefreshSleep = { _ in await Task.yield() }
        coordinator.start()
        _ = try await signIn(store, clock: clock)
        _ = await coordinator.refreshConnection()
        let scope = try clientScope(store)
        service.holdNextList = true
        service.eventSink.yield(InboundEnvelope(scope: scope, event: .directoryChanged(generation: PreviewFixtures.generationID, revision: "before-logout"), serviceEpoch: service.eventEpoch))
        for _ in 0..<1_000 where service.heldList == nil { await Task.yield() }
        let held = try #require(service.heldList); service.heldList = nil
        _ = await store.dispatch(.logout)
        var forbidden = directoryEntry("Old scope", task: true); forbidden.session.status = .new
        held.resume(returning: directoryPage(.tasks, [forbidden]))
        for _ in 0..<20 { await Task.yield() }
        #expect(store.state.phase == .signedOut)
        #expect(store.state.directory.tasks.isEmpty)
        #expect(store.state.directory.temporaryCreatedResults.isEmpty)
        await coordinator.stop()
    }
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
        #expect(store.serviceDiagnostic == nil)
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
        let manualRetry = Task { await store.dispatch(.retrySynchronization) }
        for _ in 0..<30 { await Task.yield() }
        #expect(service.directoryReads == before + 1)
        service.holdDirectory = false
        completion.resume(returning: .snapshot(service.base.script.directory))
        #expect((await pending.value).isApplied)
        #expect((await manualRetry.value).isApplied)
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
