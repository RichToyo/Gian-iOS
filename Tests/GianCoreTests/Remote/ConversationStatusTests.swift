import Foundation
import Observation
import Testing
@testable import GianCore

/// What the chat title's status is made of, recorded the way the app's
/// presentation observes the store: after each main-actor turn that changed it.
@MainActor
final class StatusRecorder {
    struct Step: Equatable, CustomStringConvertible {
        var connection: ConnectionProjection
        var diagnostic: RemoteDiagnosticStatus?
        var sync: TranscriptSyncState?
        var description: String {
            "\(connection)/\(diagnostic.map { "\($0)" } ?? "-")/\(sync.map { "\($0)" } ?? "-")"
        }
        var connectionLost: Bool { if case .connectionClosed = diagnostic { true } else { false } }
    }
    private(set) var steps: [Step] = []
    private let store: GianClientStore

    init(_ store: GianClientStore) { self.store = store; observe() }

    private func observe() {
        let step = Step(connection: store.state.connection, diagnostic: store.serviceDiagnostic?.status,
                        sync: store.state.conversation?.transcriptSync)
        if steps.last != step { steps.append(step) }
        withObservationTracking {
            _ = store.state
            _ = store.serviceDiagnostic
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }
}

/// The Host is fine throughout: opening a chat, coming back to the app and a
/// dropped connection only ever show syncing, never offline or failed.
@MainActor
struct ConversationStatusTests {
    @MainActor
    final class Live {
        let fixture: RemoteFixture
        var store: GianClientStore!
        var coordinator: GianClientCoordinator!
        let session: SessionID
        /// What `session.page` returns on every connection made from now on.
        var pageItems: [WireValue]
        var socket: FixtureRelaySocket { fixture.transport.socket as! FixtureRelaySocket }

        init(_ fixture: RemoteFixture) {
            self.fixture = fixture
            session = SessionID(rawValue: fixture.sessionID)!
            pageItems = [.object(["kind": .string("user"), "id": .string("00000000-0000-7000-8000-000000000061"),
                "turn_id": .string("00000000-0000-7000-8000-000000000062"), "turn": .int(1),
                "ts": .int(fixture.milliseconds), "text": .string("Fixture message")])]
        }

        /// Every connection gets a fresh socket: the Host is reachable.
        func hostReachable() {
            fixture.transport.makeSocket = { [unowned self] in
                let socket = FixtureRelaySocket(self.fixture)
                socket.directoryEnabled = true; socket.tasklessSession = true; socket.sessionStatus = "running"
                socket.defaultDirectoryEntries = [wireDirectoryEntry(self.fixture)]
                socket.pageItems = self.pageItems
                return socket
            }
        }

        func hostUnreachable() { fixture.transport.makeSocket = nil; fixture.transport.socket = nil }

        /// Online, caught up, and no read or reconnect left in flight.
        func settled() async -> Bool {
            await eventually {
                store.state.connection == .online && store.serviceDiagnostic == nil
                    && store.state.conversation.map { $0.transcriptSync == .idle && !$0.hydratedFromCache } ?? true
                    && fixture.service.reconnect == nil && fixture.service.subscriptionRefresh == nil
            }
        }

        func open() async throws {
            #expect((await store.dispatch(.selectConversation(session))).isApplied)
            #expect(await settled())
            try #require(store.state.conversation?.items.count == 1)
        }
    }

    private func online() async throws -> Live {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let live = Live(fixture)
        live.hostReachable()
        fixture.service.subscriptionRefreshDelay = .milliseconds(5)
        fixture.service.reconnectBackoffUnit = .milliseconds(4)
        (live.store, live.coordinator) = try await LiveInteractionRefreshTests.liveStore(fixture, socket: FixtureRelaySocket(fixture))
        #expect((await live.store.dispatch(.selectDirectoryView(.repos))).isApplied)
        return live
    }

    private func expectOnlySyncing(_ steps: [StatusRecorder.Step], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!steps.contains { $0.connection == .offline }, "\(steps)", sourceLocation: sourceLocation)
        #expect(!steps.contains { $0.sync == .failed }, "\(steps)", sourceLocation: sourceLocation)
        #expect(!steps.contains { $0.connectionLost }, "\(steps)", sourceLocation: sourceLocation)
    }

    @Test func comingBackToTheAppReconnectsRightAway() async throws {
        let live = try await online()
        try await live.open()
        // Going to the background (or the app switcher) disconnects on purpose.
        _ = await live.store.dispatch(.setForeground(.background))
        #expect(live.store.state.connection == .offline)
        _ = await live.store.dispatch(.setForeground(.foreground))
        let recorder = StatusRecorder(live.store)
        // No network change is reported: coming back alone reconnects.
        #expect(await live.settled())
        expectOnlySyncing(recorder.steps)
        await live.coordinator.stop()
    }

    @Test func aChatOpenedWhileReconnectingIsReadOnceConnected() async throws {
        let live = try await online()
        _ = await live.store.dispatch(.setForeground(.background))
        _ = await live.store.dispatch(.setForeground(.foreground))
        let recorder = StatusRecorder(live.store)
        // Opened before the connection is back, and never read before.
        #expect((await live.store.dispatch(.selectConversation(live.session))).isApplied)
        #expect(live.store.state.conversation?.transcriptSync == .syncing)
        #expect(await live.settled())
        #expect(live.store.state.conversation?.items.count == 1)
        expectOnlySyncing(recorder.steps)
        await live.coordinator.stop()
    }

    @Test func anUpdateOfTheChatWhileItOpensIsReadAgain() async throws {
        let live = try await online()
        let recorder = StatusRecorder(live.store)
        let socket = live.socket
        socket.holdSubscriptionReplies = true
        let open = Task { await live.store.dispatch(.selectConversation(live.session)) }
        _ = try await socket.subscriptionHeld.next()
        // How the Host reports any update of a chat outside an open task.
        try socket.removeSessionPatch(live.fixture.sessionID)
        #expect(await eventually { live.fixture.service.cursor?.eventSequence == 0 })
        socket.holdSubscriptionReplies = false
        try socket.releaseSubscription()
        #expect((await open.value).isApplied)
        #expect(await live.settled())
        #expect(live.store.state.conversation?.items.count == 1)
        #expect(live.store.currentSessionID == live.session)
        expectOnlySyncing(recorder.steps)
        await live.coordinator.stop()
    }

    @Test func aDroppedConnectionIsReconnectingNotOffline() async throws {
        let live = try await online()
        try await live.open()
        let recorder = StatusRecorder(live.store)
        live.socket.incoming.fail(.disconnected)
        #expect(await eventually { recorder.steps.contains { $0.connection == .reconnecting } })
        #expect(await live.settled())
        expectOnlySyncing(recorder.steps)
        await live.coordinator.stop()
    }

    @Test func aReconnectThatFailsTooIsOfflineUntilTheHostIsBack() async throws {
        let live = try await online()
        try await live.open()
        let socket = live.socket
        live.hostUnreachable()
        socket.incoming.fail(.disconnected)
        #expect(await eventually { live.store.state.connection == .offline })
        #expect(live.store.serviceDiagnostic?.status == .connectionClosed(.transport))
        #expect(live.store.state.conversation?.transcriptSync != .failed)
        // The service keeps trying, and the chat is read again once it's back.
        live.hostReachable()
        #expect(await live.settled())
        await live.coordinator.stop()
    }

    @Test func restoringAnOpenChatShowsSyncingNotOffline() async throws {
        let live = try await online()
        try await live.open()
        let recorder = StatusRecorder(live.store)
        // As at launch: cached authorization, then the first connection.
        #expect((await live.coordinator.restoreCachedAuthorization(server: live.fixture.server, account: live.fixture.account)).isApplied)
        #expect(live.store.currentSessionID == live.session)
        #expect(await live.settled())
        expectOnlySyncing(recorder.steps)
        await live.coordinator.stop()
    }

    @Test func aFailedReadIsReadAgainAfterReconnecting() async throws {
        let live = try await online()
        // A page the app can't map: an actual failure, and shown as one.
        live.pageItems = [.object(["kind": .string("unknown")])]
        live.socket.pageItems = live.pageItems
        #expect((await live.store.dispatch(.selectConversation(live.session))).isApplied)
        #expect(live.store.state.conversation?.transcriptSync == .failed)
        live.pageItems = Live(live.fixture).pageItems
        let recorder = StatusRecorder(live.store)
        live.socket.incoming.fail(.disconnected)
        // Catching up reads the chat again, so it is syncing, not failed, meanwhile.
        #expect(await live.settled())
        #expect(live.store.state.conversation?.items.count == 1)
        #expect(Array(recorder.steps.dropFirst()).allSatisfy { $0.sync != .failed }, "\(recorder.steps)")
        await live.coordinator.stop()
    }
}
