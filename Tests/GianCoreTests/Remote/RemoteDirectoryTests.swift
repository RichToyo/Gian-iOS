import Foundation
import Testing
@testable import GianCore

@MainActor
func wireDirectoryEntry(_ fixture: RemoteFixture, task: Bool = false, name: WireValue = .string("Unrelated title")) -> WireValue {
    .object(["id": .string(fixture.sessionID), "revision": .string("session-r1"), "name": name,
        "workspace": .object(["id": .string(fixture.workspaceID), "name": .string("Repository")]),
        "task": task ? .object(["id": .string(fixture.taskID), "name": .string("Incomplete Task"), "status": .string("open")]) : .null,
        "agent": .object(["id": .string(fixture.agentID), "name": .string("Agent"), "proxy": .string("fixture")]),
        "status": .string("done"), "unread": .bool(false), "waiting_for_user": .bool(false),
        "last_activity_at": .null, "completed_at": .string("2026-09-01T00:00:00Z")])
}

@MainActor
func wireDirectoryPage(_ fixture: RemoteFixture, view: String = "repos", state: String = "complete",
                       entries: [WireValue] = [], cursor: WireValue = .null) -> WireValue {
    .object(["version": .int(1), "view": .string(view), "as_of": .int(fixture.milliseconds), "revision": .string("directory-r1"),
        "state": .string(state), "entries": .array(entries), "next_cursor": cursor])
}

@MainActor
struct RemoteDirectoryTests {
    @Test func accessRevalidationUsesOnePageWithoutChangingSubscription() async throws {
        let (fixture, socket) = try await connected()
        let session = try #require(SessionID(rawValue: fixture.sessionID))
        fixture.service.subscribedSession = session
        let before = socket.commandRequests.count
        let outcome = await fixture.service.revalidateSessionAccess(scope: fixture.scope, session: session)
        #expect(outcome == .authorized)
        #expect(fixture.service.subscribedSession == session)
        let commands = Array(socket.commandRequests.dropFirst(before))
        #expect(commands.count == 1)
        #expect(try commands.first?.string("method") == "session.page")
        #expect(try commands.first?["params"].integer("turns") == 1)
        socket.pageDenied = true
        #expect(await fixture.service.revalidateSessionAccess(scope: fixture.scope, session: session) == .unavailable)
        #expect(fixture.service.subscribedSession == session)
        await fixture.service.disconnect()
    }
    @Test func directoryHintDoesNotDiscardActiveTranscriptSubscription() async throws {
        let (fixture, _) = try await connected()
        let session = try #require(SessionID(rawValue: fixture.sessionID))
        fixture.service.subscribedSession = session
        let before = fixture.service.directoryMembershipGeneration
        try fixture.service.receive(.object(["type": .string("directory.changed"), "version": .int(1),
            "host_generation": .string(fixture.generation), "revision": .string("directory-change")]), scope: fixture.scope)
        #expect(fixture.service.subscribedSession == session)
        #expect(fixture.service.directoryMembershipGeneration == before + 1)
        await fixture.service.disconnect()
    }
    @Test func nullWireNameDoesNotBecomeASearchablePlaceholder() throws {
        let fixture = RemoteFixture()
        let entry = try RemoteMapping.directoryEntry(wireDirectoryEntry(fixture, name: .null),
                                                     host: fixture.scope.host, asOf: PreviewFixtures.instant)
        #expect(entry.session.title == "Untitled")
        #expect(entry.searchName == nil)
    }

    private func connected(enabled: Bool = true) async throws -> (RemoteFixture, FixtureRelaySocket) {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let socket = FixtureRelaySocket(fixture); socket.directoryEnabled = enabled
        fixture.transport.socket = socket
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        return (fixture, socket)
    }

    @Test func helloOptInAndRealPaginatedSearchWireMapping() async throws {
        let (fixture, socket) = try await connected()
        #expect(socket.advertisedFeatures.contains(.string("wire.session_directory_v1")))
        #expect(fixture.service.relay?.features.contains(.sessionDirectoryV1) == true)
        socket.directoryReplies = [wireDirectoryPage(fixture, view: "search", state: "incomplete", cursor: .string("opaque-one")),
            wireDirectoryPage(fixture, view: "search", entries: [wireDirectoryEntry(fixture)])]
        let baseline = fixture.service.cursor
        let first = await fixture.service.listDirectory(scope: fixture.scope, request: DirectoryPageRequest(view: .search, query: "old message"))
        guard case .page(let page) = first else { Issue.record("Expected actual directory wire page"); return }
        #expect(page.state == .incomplete && page.entries.isEmpty && page.nextCursor == "opaque-one")
        guard case .page(let next) = await fixture.service.listDirectory(scope: fixture.scope,
            request: DirectoryPageRequest(view: .search, query: "old message", cursor: page.nextCursor)) else { Issue.record("Expected continuation"); return }
        #expect(next.entries.first?.session.title == "Unrelated title")
        #expect(next.entries.first?.searchName == "Unrelated title")
        #expect(next.entries.first?.session.archived == false)
        #expect(next.entries.first?.session.completedAt != nil)
        #expect(next.entries.first?.session.lastActivityAt == nil)
        #expect(try socket.commandRequests.last?["params"].string("cursor") == "opaque-one")
        #expect(fixture.service.cursor == baseline)
        await fixture.service.disconnect()
    }

    @Test func missingNegotiationNeverCallsDirectoryList() async throws {
        let (fixture, socket) = try await connected(enabled: false)
        #expect(await fixture.service.listDirectory(scope: fixture.scope, request: DirectoryPageRequest(view: .repos)) == .unsupported)
        #expect(!socket.commands.contains("directory.list"))
        await fixture.service.disconnect()
    }

    @Test func directoryHintSupersedesDelayedReadWithoutConsumingCanonicalSequence() async throws {
        let (fixture, socket) = try await connected()
        socket.holdDirectoryReplies = true
        let read = Task { await fixture.service.listDirectory(scope: fixture.scope, request: DirectoryPageRequest(view: .repos)) }
        _ = try await socket.directoryHeld.next()
        let cursor = fixture.service.cursor
        let canonicalInvalidation = fixture.service.directoryInvalidationGeneration
        try fixture.service.receive(.object(["type": .string("directory.changed"), "version": .int(1),
            "host_generation": .string(fixture.generation), "revision": .string("directory-r2")]), scope: fixture.scope)
        try socket.releaseDirectory(wireDirectoryPage(fixture, entries: [wireDirectoryEntry(fixture)]))
        guard case .failed = await read.value else { Issue.record("Retired directory read must not install rows"); return }
        #expect(fixture.service.cursor == cursor)
        #expect(fixture.service.directoryInvalidationGeneration == canonicalInvalidation)
        #expect(fixture.service.acceptedDirectory != nil)
        await fixture.service.disconnect()
    }

    @Test func subscribeRefreshesNegotiatedInteractionsAfterHint() async throws {
        let (fixture, socket) = try await connected()
        let interaction = WireValue.object(["id": .string("00000000-0000-7000-8000-000000000074"), "revision": .string("r1"),
            "session_id": .string(fixture.sessionID), "turn_id": .string("00000000-0000-7000-8000-000000000075"), "kind": .string("question"),
            "presentation": .object(["title": .string("Choose"), "description": .string("Fictional question"), "risk": .string("low"),
                "actions": .array([]), "inputs": .array([])])])
        socket.subscriptionInteractions = [interaction]
        let session = SessionID(rawValue: fixture.sessionID)!
        _ = await fixture.service.pageTranscript(scope: fixture.scope, sessionID: session, cursor: nil)
        let count = socket.commands.filter { $0 == "session.subscribe" }.count
        socket.subscriptionInteractions = []
        try fixture.service.receive(.object(["type": .string("directory.changed"), "version": .int(1),
            "host_generation": .string(fixture.generation), "revision": .string("directory-r2")]), scope: fixture.scope)
        _ = await fixture.service.pageTranscript(scope: fixture.scope, sessionID: session, cursor: nil)
        #expect(socket.commands.filter { $0 == "session.subscribe" }.count == count + 1)
        #expect(fixture.service.cursor?.eventSequence == -1)
        await fixture.service.disconnect()
        fixture.service.eventContinuation.finish()
        var metadata = 0
        for await envelope in fixture.service.events {
            if case .sessionMetadata(let record, let interactions) = envelope.event {
                #expect(record.id == session)
                #expect(interactions.count == (metadata == 0 ? 1 : 0))
                metadata += 1
            }
        }
        #expect(metadata == 2)
    }

    @Test func malformedPageStatesAndUnnegotiatedHintsFailClosed() async throws {
        let fixture = RemoteFixture()
        let request = DirectoryPageRequest(view: .repos)
        for value in [
            wireDirectoryPage(fixture, state: "incomplete"),
            wireDirectoryPage(fixture, cursor: .string("not-complete")),
            wireDirectoryPage(fixture, state: "cursor_invalid", entries: [wireDirectoryEntry(fixture)]),
            wireDirectoryPage(fixture, view: "tasks"),
        ] {
            #expect(throws: RemoteClientError.self) { try RemoteMapping.directoryPage(value, scope: fixture.scope, request: request) }
        }
        let (legacy, _) = try await connected(enabled: false)
        #expect(throws: RemoteClientError.self) {
            try legacy.service.receive(.object(["type": .string("directory.changed"), "version": .int(1),
                "host_generation": .string(legacy.generation), "revision": .string("r")]), scope: legacy.scope)
        }
        await legacy.service.disconnect()
    }

    @Test func tasklessWireCreateRecoversLostResultWithoutCreatingAnotherSession() async throws {
        let (fixture, socket) = try await connected()
        let command = CommandID(rawValue: fixture.service.newID())!
        let request = SessionCreateRequest(commandID: command, catalogRevision: "catalog-r1",
            workspaceID: WorkspaceID(rawValue: fixture.workspaceID)!, agentID: AgentID(rawValue: fixture.agentID)!, taskID: nil, model: nil)
        socket.loseCreateResult = true
        #expect(await fixture.service.createSession(scope: fixture.scope, request: request) == .unknownOutcome(command))
        #expect(socket.commandRequests.first(where: { (try? $0.string("method")) == "session.create" })?["params"]["task_id"].isNull == true)
        let replacement = FixtureRelaySocket(fixture)
        replacement.directoryEnabled = true; replacement.ledger = socket.ledger
        fixture.transport.socket = replacement
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { Issue.record("Expected reconnect snapshot"); return }
        guard case .succeeded(let receipt) = await fixture.service.createSession(scope: fixture.scope, request: request) else {
            Issue.record("Expected original create ledger recovery"); return
        }
        #expect(receipt.commandID == command && receipt.session?.id.rawValue == fixture.sessionID)
        #expect(socket.commands.filter { $0 == "session.create" }.count == 1)
        #expect(!replacement.commands.contains("session.create"))
        #expect(!replacement.commands.contains("session.send"))
        await fixture.service.disconnect()
    }

    /// The Host hints after every event it broadcasts, so a hint cannot retire
    /// a chat's subscribe; a change of that chat itself does.
    @Test func hintDoesNotRetireInflightSubscriptionButItsOwnCardUpdateDoes() async throws {
        let (fixture, socket) = try await connected()
        socket.holdSubscriptionReplies = true
        let session = SessionID(rawValue: fixture.sessionID)!
        var read = Task { await fixture.service.pageTranscript(scope: fixture.scope, sessionID: session, cursor: nil) }
        _ = try await socket.subscriptionHeld.next()
        try fixture.service.receive(.object(["type": .string("directory.changed"), "version": .int(1),
            "host_generation": .string(fixture.generation), "revision": .string("new")]), scope: fixture.scope)
        try socket.releaseSubscription()
        #expect(!(await read.value).failed)
        read = Task { await fixture.service.pageTranscript(scope: fixture.scope, sessionID: session, cursor: nil) }
        _ = try await socket.subscriptionHeld.next()
        try fixture.service.receive(.object(["type": .string("event"), "host_generation": .string(fixture.generation), "event_sequence": .int(0),
            "event": .object(["kind": .string("interaction.updated"), "interaction": wireQuestion(fixture)])]), scope: fixture.scope)
        try socket.releaseSubscription()
        #expect(await read.value.failed)
        #expect(socket.commands.filter { $0 == "session.page" }.count == 1)
        await fixture.service.disconnect()
        fixture.service.eventContinuation.finish()
        var metadata = 0
        for await envelope in fixture.service.events {
            if case .sessionMetadata = envelope.event { metadata += 1 }
        }
        #expect(metadata == 1)
    }
}
