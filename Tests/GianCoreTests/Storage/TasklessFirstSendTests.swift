import Foundation
import Testing
@testable import GianCore

@MainActor
struct TasklessFirstSendTests {
    @Test func confirmedFirstSendHasTransientRepoRowWithoutFabricatedActivity() async throws {
        let service = DirectoryFixtureService()
        service.createWithoutActivity = true
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.repos] = [directoryPage(.repos)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        await prepareComposer(store, text: "First message", task: false)
        _ = await store.dispatch(.send)
        let id = try #require(store.state.composer.send.intent?.sessionID)
        #expect(store.state.directory.temporaryCreatedResults.map(\.id) == [id])
        #expect(store.sessions.first(where: { $0.id == id })?.lastActivityAt == nil)
        #expect(store.sessions.first(where: { $0.id == id })?.activityIsMessageOrExecution == false)
        var idle = try #require(store.sessions.first(where: { $0.id == id }))
        idle.status = .done
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .sessionMetadata(idle, interactions: [])))
        #expect(store.state.directory.temporaryCreatedResults.map(\.id) == [id])
        idle.lastActivityAt = clock.instant
        idle.activityIsMessageOrExecution = true
        let workspace = try #require(store.state.workspaces.first(where: { $0.id == idle.workspaceID }))
        service.pages[.repos] = [directoryPage(.repos, [DirectoryEntry(session: idle, workspace: workspace, task: nil, searchName: idle.title)])]
        _ = await store.dispatch(.refreshDirectoryView(.repos))
        #expect(store.state.directory.temporaryCreatedResults.isEmpty)
        #expect(store.state.directory.repos.map(\.id) == [id])
        store.state.navigation.directoryView = .tasks
        store.reproject()
        #expect(store.state.directory.temporaryCreatedResults.isEmpty)
        #expect(!store.state.directory.tasks.flatMap(\.conversations).contains { $0.id == id })
    }

    @Test func unknownFirstSendDoesNotPromoteEmptyCreatedSession() async throws {
        let service = DirectoryFixtureService()
        service.createWithoutActivity = true
        service.base.script.commandBehavior = .createSucceedsSendUnknown
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.pages[.repos] = [directoryPage(.repos)]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectDirectoryView(.repos))
        await prepareComposer(store, text: "First message", task: false)
        _ = await store.dispatch(.send)
        #expect(store.state.directory.temporaryCreatedResults.isEmpty)
        #expect(store.locallyCreatedWithActivity.isEmpty)
    }
    @Test func tasklessFirstSendFreezesIndependentCreateAndSendBeforeEffects() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.base.script.commandBehavior = .createSucceedsSendUnknown
        let storage = InMemoryGianStorage()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store, text: "Original paid input", task: false)
        _ = await store.dispatch(.send)
        let intent = try #require(store.state.composer.send.intent)
        #expect(intent.createRequest?.taskID == nil)
        #expect(intent.creationID != intent.sendID)
        #expect(isUUIDv7(try #require(intent.creationID).rawValue))
        #expect(isUUIDv7(try #require(intent.sendID).rawValue))
        #expect(intent.createRequest == service.createRequests.first)
        #expect(intent.sendRequest == service.sendRequests.first)
        let scope = try clientScope(store)
        let retained = try #require(try storage.load(scope: scope)?.operations[intent.draftID]?.intent)
        #expect(retained.createRequest == intent.createRequest)
        #expect(retained.sendRequest?.text == "Original paid input")
        _ = await store.dispatch(.editDraftText("Newer draft"))
        service.commandStatuses[try #require(intent.sendID)] = .notSeen(try #require(intent.sendID))
        _ = await store.dispatch(.recoverUncertainOperation)
        #expect(store.state.composer.send.intent?.sendID == intent.sendID)
        #expect(store.state.composer.send.intent?.sendRequest?.text == "Original paid input")
        #expect(await store.dispatch(.send) == .rejected(.uncertainOutcome))
        #expect(service.createRequests.count == 1 && service.sendRequests.count == 1)
        #expect(store.state.composer.draft.text == "Newer draft")
    }

    @Test func explicitCreateRetryUsesOriginalParamsDespiteDraftAndCatalogEdits() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.base.script.commandBehavior = .lostAckNotSeen
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator())
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store, task: false)
        _ = await store.dispatch(.selectModel("original-model"))
        _ = await store.dispatch(.send)
        let original = try #require(service.createRequests.first)
        _ = await store.dispatch(.recoverUncertainOperation)
        _ = await store.dispatch(.selectModel("different-model"))
        _ = await store.dispatch(.editDraftText("Changed draft, no implicit send"))
        store.state.catalogRevision = "different-catalog"
        service.base.script.commandBehavior = .succeed
        _ = await store.dispatch(.retryUncertainCreate)
        #expect(service.createRequests == [original, original])
        #expect(store.state.composer.draft.boundSessionID != nil)
        #expect(service.sendRequests.isEmpty)
        #expect(store.state.composer.draft.text == "Changed draft, no implicit send")
        _ = await store.dispatch(.send)
        #expect(service.createRequests.count == 2)
        #expect(service.sendRequests.count == 1)
        #expect(service.sendRequests[0].commandID != original.commandID)
        #expect(store.state.composer.send.intent?.createRequest == original)
    }

    @Test func restartedUnknownCreateQueriesOriginalIdentityBeforeBinding() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.base.script.commandBehavior = .lostAckStillUnknown
        let storage = InMemoryGianStorage()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let first = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        _ = try await signIn(first, clock: clock)
        await prepareComposer(first, task: false)
        _ = await first.dispatch(.send)
        let original = try #require(first.state.composer.send.intent)
        let reopened = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        _ = reopened.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock))
        #expect(reopened.state.composer.send.intent?.createRequest == original.createRequest)
        #expect(!reopened.mutationsReady)
        service.pages[.tasks] = [directoryPage(.tasks)]
        _ = await reopened.dispatch(.refreshDirectory)
        let created = directoryEntry("Recovered original").session
        let id = try #require(original.creationID)
        service.commandStatuses[id] = .succeeded(CommandSuccess(commandID: id, session: created))
        _ = await reopened.dispatch(.recoverUncertainOperation)
        #expect(reopened.state.composer.draft.boundSessionID == created.id)
        #expect(service.createRequests.count == 1 && service.sendRequests.isEmpty)
    }

    @Test func fullDirectoryLabelAloneDoesNotNegotiateTasklessCreate() async throws {
        let (store, service, clock) = makeHarness(script: .fullDirectory)
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store, task: false)
        #expect(await store.dispatch(.send) == .rejected(.legacyTasklessCreateUnsupported))
        #expect(service.createCount == 0)
    }

    @Test func failedRetryCannotEraseAnOriginalUnknownCreate() async throws {
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        service.base.script.commandBehavior = .lostAckStillUnknown
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator())
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store, task: false)
        _ = await store.dispatch(.send)
        let original = try #require(store.state.composer.send.intent?.createRequest)
        service.base.script.commandBehavior = .fail
        _ = await store.dispatch(.retryUncertainCreate)
        #expect(store.state.composer.send.intent?.createRequest == original)
        #expect(await store.dispatch(.send) == .rejected(.uncertainOutcome))
        #expect(service.createRequests == [original, original])
        #expect(service.sendRequests.isEmpty)
    }
}
