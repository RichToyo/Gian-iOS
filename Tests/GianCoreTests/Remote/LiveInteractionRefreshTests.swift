import Foundation
import Testing
@testable import GianCore

@MainActor
func wireQuestion(_ fixture: RemoteFixture, id: String = "00000000-0000-7000-8000-000000000074") -> WireValue {
    .object(["id": .string(id), "revision": .string("r1"),
        "session_id": .string(fixture.sessionID), "turn_id": .string("00000000-0000-7000-8000-000000000075"), "kind": .string("question"),
        "presentation": .object(["title": .string("Choose"), "description": .string("Fictional question"), "risk": .string("low"),
            "actions": .array([.object(["id": .string("00000000-0000-7000-8000-000000000076"), "label": .string("Answer"), "tone": .string("default")])]),
            "inputs": .array([])])])
}

/// Polls on the main actor; the fixture relay answers asynchronously.
@MainActor
func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// The Host sends cards only for chats in an open task. These cover a chat
/// without one, which learns of a card only by subscribing again.
@MainActor
struct LiveInteractionRefreshTests {
    private func tasklessFixture() async throws -> (RemoteFixture, FixtureRelaySocket) {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let socket = FixtureRelaySocket(fixture)
        socket.directoryEnabled = true; socket.tasklessSession = true; socket.sessionStatus = "running"
        socket.defaultDirectoryEntries = [wireDirectoryEntry(fixture)]
        fixture.transport.socket = socket
        fixture.service.subscriptionRefreshDelay = .milliseconds(5)
        return (fixture, socket)
    }

    /// Subscribed to the taskless chat at the service level.
    private func subscribed() async throws -> (RemoteFixture, FixtureRelaySocket, SessionID) {
        let (fixture, socket) = try await tasklessFixture()
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        let session = try #require(SessionID(rawValue: fixture.sessionID))
        #expect(!(await fixture.service.pageTranscript(scope: fixture.scope, sessionID: session, cursor: nil)).failed)
        return (fixture, socket, session)
    }

    private func subscribes(_ socket: FixtureRelaySocket) -> Int { socket.commands.filter { $0 == "session.subscribe" }.count }

    private func delivered(_ fixture: RemoteFixture) async -> [InboundEvent] {
        await fixture.service.disconnect()
        fixture.service.eventContinuation.finish()
        var result: [InboundEvent] = []
        for await envelope in fixture.service.events { result.append(envelope.event) }
        return result
    }

    private func metadata(_ events: [InboundEvent]) -> [[InteractionRecord]] {
        events.compactMap { if case .sessionMetadata(_, let cards) = $0 { return cards }; return nil }
    }

    /// The store, coordinator and live service over the fixture relay, as the
    /// app composes them, signed in and online.
    static func liveStore(_ fixture: RemoteFixture, socket: FixtureRelaySocket) async throws -> (GianClientStore, GianClientCoordinator) {
        // The Host appears in the cached authorization after a first device login.
        fixture.transport.socket = FixtureRelaySocket(fixture)
        try await fixture.service.connect(scope: fixture.scope)
        await fixture.service.disconnect()
        fixture.transport.socket = socket
        let store = GianClientStore(service: fixture.service, clock: fixture.clock, storage: InMemoryGianStorage())
        let service = fixture.service
        let coordinator = try GianClientCoordinator(store: store, runtime: service, events: service.events,
            diagnostics: service.diagnostics, loadAuthorization: { try service.loadCachedAuthorization(server: $0, account: $1) })
        coordinator.directoryRefreshSleep = { _ in await Task.yield() }
        coordinator.accessRevalidationSleep = { _ in await Task.yield() }
        try #require((await coordinator.restoreCachedAuthorization(server: fixture.server, account: fixture.account)).isApplied)
        try #require(store.state.connection == .online)
        return (store, coordinator)
    }

    @Test func agentQuestionInTasklessChatShowsTheCardLive() async throws {
        let (fixture, socket) = try await tasklessFixture()
        let (store, coordinator) = try await Self.liveStore(fixture, socket: socket)
        // The session.page access re-check never finishes here: the card and
        // its access proof must come from the subscribe alone.
        coordinator.accessRevalidationSleep = { _ in try await Task.sleep(for: .seconds(60)) }
        #expect((await store.dispatch(.selectDirectoryView(.repos))).isApplied)
        let session = try #require(SessionID(rawValue: fixture.sessionID))
        #expect((await store.dispatch(.selectConversation(session))).isApplied)
        #expect(store.state.interactions.isEmpty)
        #expect(subscribes(socket) == 1)
        // Directory re-reads no longer list the chat (as when only other views
        // are loaded), so they can't vouch for it either.
        socket.defaultDirectoryEntries = []

        // The Agent asks: the Host marks the chat pending (for a taskless chat
        // that's a removal patch), registers the card and hints the directory.
        // It sends no interaction.updated and no interactions patch.
        socket.sessionStatus = "pending"
        socket.subscriptionInteractions = [wireQuestion(fixture)]
        try socket.removeSessionPatch(fixture.sessionID)
        try socket.directoryHint()

        #expect(await eventually { store.state.interactions.contains { $0.sessionID == session } })
        #expect(store.state.interactions.map(\.phase) == [.pending])
        #expect(store.state.interactions.first?.title == "Choose")
        #expect(store.pendingSessionAccess[session] == nil)
        #expect(!store.deniedSessionAccess.contains(session))
        #expect(store.currentSessionID == session)
        #expect(subscribes(socket) == 2)
        await coordinator.stop()
    }

    @Test func pendingChatWithoutCardIsReadAgainUntilTheCardIsRegistered() async throws {
        let (fixture, socket, _) = try await subscribed()
        socket.sessionStatus = "pending"
        // The card lands just after the Host marks the chat pending.
        socket.subscriptionInteractionReplies = [[], [wireQuestion(fixture)]]
        try socket.removeSessionPatch(fixture.sessionID)
        #expect(await eventually { self.subscribes(socket) == 3 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(subscribes(socket) == 3)
        let cards = metadata(await delivered(fixture))
        #expect(cards.map(\.count) == [0, 0, 1])
    }

    @Test func pendingChatThatNeverListsACardStopsAfterBoundedRetries() async throws {
        let (fixture, socket, _) = try await subscribed()
        socket.sessionStatus = "pending"
        try socket.removeSessionPatch(fixture.sessionID)
        // One read for the update, then four backed-off retries.
        #expect(await eventually { self.subscribes(socket) == 6 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(subscribes(socket) == 6)
        #expect(fixture.service.subscriptionRefresh == nil)
        await fixture.service.disconnect()
    }

    @Test func waitingDirectoryEntryReadsCardsOncePerRevision() async throws {
        let (fixture, socket, _) = try await subscribed()
        socket.subscriptionInteractions = [wireQuestion(fixture)]
        guard case .object(var entry) = wireDirectoryEntry(fixture) else { throw RemoteClientError.invalidPayload }
        entry["waiting_for_user"] = .bool(true); entry["revision"] = .string("session-r2")
        let page = wireDirectoryPage(fixture, entries: [.object(entry)])
        socket.directoryReplies = [page, page]
        _ = await fixture.service.listDirectory(scope: fixture.scope, request: DirectoryPageRequest(view: .repos))
        #expect(await eventually { self.subscribes(socket) == 2 })
        _ = await fixture.service.listDirectory(scope: fixture.scope, request: DirectoryPageRequest(view: .repos))
        try await Task.sleep(for: .milliseconds(100))
        #expect(subscribes(socket) == 2)
        #expect(metadata(await delivered(fixture)).map(\.count) == [0, 1])
    }

    @Test func removalOfAnotherChatOrAHintDoesNotRetireTheOpenChatsSubscribe() async throws {
        let (fixture, socket) = try await tasklessFixture()
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        socket.holdSubscriptionReplies = true
        socket.subscriptionInteractions = [wireQuestion(fixture)]
        let session = try #require(SessionID(rawValue: fixture.sessionID))
        let read = Task { await fixture.service.pageTranscript(scope: fixture.scope, sessionID: session, cursor: nil) }
        _ = try await socket.subscriptionHeld.next()
        try socket.removeSessionPatch("00000000-0000-7000-8000-000000000098")
        try socket.directoryHint()
        #expect(await eventually { fixture.service.cursor?.eventSequence == 0 })
        try socket.releaseSubscription()
        #expect(!(await read.value).failed)
        #expect(metadata(await delivered(fixture)).map(\.count) == [1])
    }

    @Test func removalOfTheOpenChatStillRetiresItsInflightSubscribe() async throws {
        let (fixture, socket) = try await tasklessFixture()
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        socket.holdSubscriptionReplies = true
        let session = try #require(SessionID(rawValue: fixture.sessionID))
        let read = Task { await fixture.service.pageTranscript(scope: fixture.scope, sessionID: session, cursor: nil) }
        _ = try await socket.subscriptionHeld.next()
        try socket.removeSessionPatch(fixture.sessionID)
        #expect(await eventually { fixture.service.cursor?.eventSequence == 0 })
        try socket.releaseSubscription()
        #expect((await read.value).failed)
        #expect(!socket.commands.contains("session.page"))
        #expect(metadata(await delivered(fixture)).isEmpty)
    }

    @Test func refreshDeniedByTheHostHidesTheChat() async throws {
        let (fixture, socket, session) = try await subscribed()
        socket.subscribeDenied = true
        try socket.removeSessionPatch(fixture.sessionID)
        #expect(await eventually { self.subscribes(socket) == 2 && fixture.service.subscriptionRefresh == nil })
        let events = await delivered(fixture)
        #expect(events.contains(.sessionUnavailable(session)))
        #expect(metadata(events).count == 1)
    }
}
