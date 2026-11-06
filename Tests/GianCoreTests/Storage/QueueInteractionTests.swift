import Foundation
import Testing
@testable import GianCore

@MainActor
struct QueueInteractionTests {
    private func prepare(_ service: ControlledService) {
        let index = service.base.script.directory.sessions.firstIndex { $0.id == PreviewFixtures.sessionID }!
        service.base.script.directory.sessions[index].status = .running
        service.base.script.directory.sessions[index].queue = SessionQueue(revision: "queue-1", entries: [
            QueuedMessage(id: "queue-item-1", text: "First"),
            QueuedMessage(id: "queue-item-2", text: "Second")
        ])
    }

    @Test func queueChangesUseHostRevisionAndUpdateVisibleSnapshot() async throws {
        let service = ControlledService()
        prepare(service)
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        #expect((await store.dispatch(.mutateQueue(.update(id: "queue-item-1", text: "Edited")))).isApplied)
        #expect(service.queueRequests.first?.revision == "queue-1")
        #expect(store.state.conversation?.session.queue?.entries.first?.text == "Edited")
        #expect((await store.dispatch(.mutateQueue(.remove(id: "queue-item-2")))).isApplied)
        #expect(store.state.conversation?.session.queue?.entries.map(\.id) == ["queue-item-1"])
        #expect((await store.dispatch(.mutateQueue(.sendNow))).isApplied)
        #expect(store.state.conversation?.session.queue?.entries.isEmpty == true)
    }

    @Test func unknownQueueOutcomeSurvivesRestartAndIsNotResent() async throws {
        let service = ControlledService()
        prepare(service)
        service.queueReturnsUnknown = true
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let storage = InMemoryGianStorage()
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        #expect(await store.dispatch(.mutateQueue(.sendNow)) == .rejected(.uncertainOutcome))
        let request = try #require(service.queueRequests.first)
        #expect(await store.dispatch(.mutateQueue(.sendNow)) == .rejected(.uncertainOutcome))
        #expect(service.queueRequests.count == 1)

        let restored = GianClientStore(service: service, clock: clock, storage: storage)
        #expect(restored.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect(restored.state.queueCommands[PreviewFixtures.sessionID] == .uncertain(request.commandID))
        #expect(service.queueRequests.count == 1)
        service.queueStatus = .succeeded(CommandSuccess(commandID: request.commandID))
        #expect((await store.dispatch(.recoverQueueCommand)).isApplied)
        #expect(store.state.queueCommands[PreviewFixtures.sessionID] == nil)
        #expect(service.queueRequests.count == 1)
    }

    @Test func unknownQueueCommandSurvivesSQLiteReopen() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = ControlledService()
        prepare(service)
        service.queueReturnsUnknown = true
        let command: CommandID
        do {
            let store = GianClientStore(service: service, clock: clock, storage: try SQLiteGianStorage(directory: directory))
            _ = try await signIn(store, clock: clock)
            _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
            #expect(await store.dispatch(.mutateQueue(.sendNow)) == .rejected(.uncertainOutcome))
            command = try #require(service.queueRequests.first?.commandID)
        }
        let reopened = GianClientStore(service: service, clock: clock, storage: try SQLiteGianStorage(directory: directory))
        #expect(reopened.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect(reopened.state.queueCommands[PreviewFixtures.sessionID] == .uncertain(command))
        #expect(service.queueRequests.count == 1)
    }

    @Test func steerRequiresHostCapability() async throws {
        let service = ControlledService()
        prepare(service)
        let index = service.base.script.directory.capabilities.firstIndex { $0.capability == .turnSteer }!
        service.base.script.directory.capabilities[index].state = .unsupported
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        #expect(await store.dispatch(.mutateQueue(.sendNow)) == .rejected(.capabilityUnsupported))
        #expect(service.queueRequests.isEmpty)
    }

    @Test func lateQueueReceiptDoesNotOverwriteNewerSnapshot() async throws {
        let service = ControlledService()
        prepare(service)
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        service.holdNextQueue = true
        let pending = Task { await store.dispatch(.mutateQueue(.remove(id: "queue-item-1"))) }
        for _ in 0..<100 where service.queueContinuation == nil { await Task.yield() }
        let reply = try #require(service.queueContinuation)
        let request = try #require(service.queueRequests.first)
        let index = try #require(store.sessions.firstIndex(where: { $0.id == PreviewFixtures.sessionID }))
        let newer = SessionQueue(revision: "newer", entries: [QueuedMessage(id: "new-item", text: "Newer")])
        store.sessions[index].queue = newer
        store.state.conversation?.session.queue = newer
        reply.resume(returning: .succeeded(CommandSuccess(commandID: request.commandID,
            queue: SessionQueue(revision: "older-reply", entries: []))))
        #expect((await pending.value).isApplied)
        #expect(store.state.conversation?.session.queue == newer)
    }

    @Test func directoryMetadataWithoutQueueDoesNotDiscardQueueSnapshot() async throws {
        let service = ControlledService()
        prepare(service)
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        var row = directoryEntry("Fictional session")
        row.session = try #require(store.sessions.first { $0.id == PreviewFixtures.sessionID })
        row.session.queue = nil
        store.mergeDirectoryMetadata([row])
        #expect(store.sessions.first { $0.id == PreviewFixtures.sessionID }?.queue?.revision == "queue-1")
        #expect((await store.dispatch(.mutateQueue(.remove(id: "queue-item-1")))).isApplied)
    }

    @Test func queuePatchUpdatesOnlyAuthorizedSession() async throws {
        let service = ControlledService()
        prepare(service)
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        let cursor = try #require(store.state.sync.cursor)
        var patch = CanonicalStatePatch()
        let next = SessionQueue(revision: "other-device", entries: [QueuedMessage(id: "entry-3", text: "Updated")])
        patch.queues[PreviewFixtures.sessionID] = next
        #expect(store.applyStatePatch(sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration,
                                      baseRevision: cursor.revision, revision: "queue-update", patch: patch).isApplied)
        #expect(store.state.conversation?.session.queue == next)
    }
}
