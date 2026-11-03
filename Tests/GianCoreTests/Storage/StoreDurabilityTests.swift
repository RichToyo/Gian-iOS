import Foundation
import Testing
@testable import GianCore

private func sendIsUncertain(_ phase: SendPhase) -> Bool {
    if case .uncertain = phase { return true }
    return false
}

@MainActor
private final class FailingStorage: GianStorage {
    let backing = InMemoryGianStorage()
    var rejectWrites = false
    var loadCount = 0
    func load(scope: ClientScope) throws -> StoredHostState? {
        loadCount += 1
        return try backing.load(scope: scope)
    }
    func save(_ state: StoredHostState, scope: ClientScope) throws {
        if rejectWrites { throw GianStorageError.unavailable }
        try backing.save(state, scope: scope)
    }
    func clearDownloadCache(scope: ClientScope) throws { try backing.clearDownloadCache(scope: scope) }
    func invalidateAuthorization(scope: DataScope, at date: Date) throws {
        if rejectWrites { throw GianStorageError.unavailable }
        try backing.invalidateAuthorization(scope: scope, at: date)
    }
    func authorizationInvalidatedAt(scope: DataScope) throws -> Date? {
        try backing.authorizationInvalidatedAt(scope: scope)
    }
}

@MainActor
func fictionalAuthorization(
    clock: ManualGianClock,
    account: AccountIdentity = PreviewScript.legacyContract.account,
    server: String = PreviewFixtures.server,
    hosts: [HostSummary] = [PreviewScript.legacyContract.directory.host],
    verifiedAt: Date? = nil
) -> AuthorizedSessionRestoration {
    AuthorizedSessionRestoration(server: ServerAddress(parsing: server)!, serverIdentityFingerprint: "fictional-server-pin",
        identity: account, accountKeyFingerprint: "fictional-account-key", accountLastVerifiedAt: verifiedAt ?? clock.now(),
        hosts: hosts.map { AuthorizedHostRestoration(host: $0, deviceID: PreviewFixtures.deviceID,
            hostKeyFingerprint: "fictional-host-key-" + $0.id.rawValue, deviceKeyFingerprint: "fictional-device-key",
            lastVerifiedAt: clock.now(), validation: .cached) })
}

@MainActor
struct StoreDurabilityTests {
    @Test func failedIntentWriteBlocksCreateSendAndPaidTranslation() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = PreviewGianClientService(script: .legacyContract)
        let storage = FailingStorage()
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store)
        storage.rejectWrites = true
        #expect(await store.dispatch(.send) == .rejected(.mutationsDisabled))
        #expect(service.createCount == 0)
        #expect(service.sendCount == 0)
        #expect(store.state.storageError == "Local storage is unavailable. Changes have not been saved.")

        storage.rejectWrites = false
        #expect((await store.dispatch(.refreshDirectory)).isApplied)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        _ = await store.dispatch(.editDraftText("An existing conversation"))
        storage.rejectWrites = true
        #expect(await store.dispatch(.send) == .rejected(.mutationsDisabled))
        #expect(service.sendCount == 0)
        storage.rejectWrites = false
        #expect((await store.dispatch(.refreshDirectory)).isApplied)
        _ = await store.dispatch(.recoverUncertainOperation)
        // Use a separate draft; canonical unknown must not be bypassed on the old one.
        _ = await store.dispatch(.openNewChat)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        var translation = translationState(revision: 1, configRevision: 1)
        translation.enabled = true
        store.state.composer.send = .idle
        store.state.translations[PreviewFixtures.sessionID] = translation
        _ = await store.dispatch(.editDraftText("Paid request"))
        storage.rejectWrites = true
        #expect(await store.dispatch(.requestReadingTranslation(sourceID: "source-1", text: "Paid request")) == .rejected(.mutationsDisabled))
        storage.rejectWrites = false
        #expect((await store.dispatch(.refreshDirectory)).isApplied)
        storage.rejectWrites = true
        #expect(await store.dispatch(.send) == .rejected(.mutationsDisabled))
        #expect(service.translationRequestCount == 0)
        #expect(service.sendCount == 0)
    }

    @Test func processReopenRestoresUnknownSendWithoutResendingOrRecreating() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        var script = PreviewScript.legacyContract
        script.commandBehavior = .createSucceedsSendUnknown
        let service = PreviewGianClientService(script: script)
        let intent: DurableSendIntent
        do {
            let original = try GianClientStore(service: service, clock: clock,
                ids: SequenceIDGenerator(), storage: SQLiteGianStorage(directory: directory))
            _ = try await signIn(original, clock: clock)
            await prepareComposer(original, text: "A durable first message")
            _ = await original.dispatch(.send)
            intent = try #require(original.state.composer.send.intent)
        }
        #expect(intent.stage == .send)
        #expect(service.createCount == 1)
        #expect(service.sendCount == 1)
        let reopened = try GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(),
            storage: SQLiteGianStorage(directory: directory))
        #expect(reopened.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect(reopened.state.composer.send == .uncertain(intent))
        #expect(reopened.state.composer.draft.text == "A durable first message")
        #expect(reopened.state.conversation?.session.id == intent.sessionID)
        #expect(reopened.state.connection == .offline)
        #expect(reopened.state.capabilities.grants.isEmpty)
        #expect(service.createCount == 1)
        #expect(service.sendCount == 1)
        #expect(await reopened.dispatch(.send) == .rejected(.offlineDraftRetained))
        // A cached capability set cannot authorize a side effect, even after a
        // local connectivity hint. A fresh validated snapshot is still required.
        _ = await reopened.dispatch(.noteLocalConnectivity(.available))
        #expect(await reopened.dispatch(.send) == .rejected(.mutationsDisabled))
        #expect(service.createCount == 1)
        #expect(service.sendCount == 1)
    }

    @Test func recoveredSuccessKeepsNewerDraftAndDoesNotCreateAgain() async throws {
        let (store, service, clock) = makeHarness()
        service.script.commandBehavior = .createSucceedsSendUnknown
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store, text: "Original submission")
        _ = await store.dispatch(.send)
        let intent = try #require(store.state.composer.send.intent)
        _ = await store.dispatch(.editDraftText("Newer draft at the same clock instant"))
        let scope = try clientScope(store)
        _ = store.ingest(InboundEnvelope(scope: scope, event: .commandStatus(.succeeded(
            CommandSuccess(commandID: try #require(intent.sendID), deliveryID: "canonical-delivery")))))
        #expect(store.state.composer.draft.text == "Newer draft at the same clock instant")
        #expect(store.state.composer.send == .succeeded(intent))
        #expect(service.createCount == 1)
        #expect(service.sendCount == 1)
    }

    @Test func recoveredCreateBindsBeforeAnotherExplicitSend() async throws {
        let (store, service, clock) = makeHarness()
        service.script.commandBehavior = .lostAckStillUnknown
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store)
        _ = await store.dispatch(.send)
        let intent = try #require(store.state.composer.send.intent)
        let created = makeSession(id: "canonical-created-session", title: "Canonical", taskID: PreviewFixtures.taskID)
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .commandStatus(.succeeded(
            CommandSuccess(commandID: try #require(intent.creationID), session: created)))))
        #expect(store.state.composer.draft.boundSessionID == created.id)
        #expect(service.createCount == 1)
        #expect(service.sendCount == 0)
        service.script.commandBehavior = .succeed
        _ = await store.dispatch(.send)
        #expect(service.createCount == 1)
        #expect(service.sendCount == 1)
    }

    @Test func futureOrLoggedOutEvidenceCannotRevealCachedHistory() async throws {
        let storage = InMemoryGianStorage()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = PreviewGianClientService(script: .legacyContract)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        var saved = retainedFixture()
        saved.transcripts[PreviewFixtures.sessionID] = [transcriptItem(id: "private-message", turn: 1, text: "Scoped content")]
        try storage.save(saved, scope: fictionalScope())
        let fromTheFuture = fictionalAuthorization(clock: clock, verifiedAt: clock.now().addingTimeInterval(60))
        #expect(store.restoreAuthorizedSession(authorization: fromTheFuture) == .rejected(.notAuthorized))
        #expect(store.state.directory.tasks.isEmpty)
        let valid = fictionalAuthorization(clock: clock)
        #expect(store.restoreAuthorizedSession(authorization: valid).isApplied)
        #expect(!store.state.directory.tasks.isEmpty)
        _ = await store.dispatch(.logout)
        #expect(store.restoreAuthorizedSession(authorization: valid) == .rejected(.notAuthorized))
        #expect(store.state.directory.tasks.isEmpty)
        #expect(store.state.conversation == nil)
        #expect(try storage.load(scope: fictionalScope())?.transcripts[PreviewFixtures.sessionID]?.count == 1)
    }

    @Test func hostSwitchDoesNotBorrowCursorInteractionsCapabilitiesOrTranslations() async throws {
        let storage = InMemoryGianStorage()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = PreviewGianClientService(script: .legacyContract)
        service.script.refreshBehavior = .fail
        let a = retainedFixture()
        let secondHost = HostSummary(id: PreviewFixtures.id("host-two", HostID.self), name: "Second", online: false, version: "0.6.9")
        var b = StoredHostState()
        b.host = secondHost
        b.cursor = SyncCursor(hostGeneration: PreviewFixtures.id("generation-two", HostGenerationID.self), eventSequence: 99, revision: "host-two-revision")
        try storage.save(a, scope: fictionalScope())
        try storage.save(b, scope: fictionalScope(host: secondHost.id))
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        let authorization = fictionalAuthorization(clock: clock, hosts: [a.host!, secondHost])
        _ = store.restoreAuthorizedSession(authorization: authorization, selectedHost: PreviewFixtures.hostID)
        #expect(store.state.interactions.count == a.interactions.count)
        _ = await store.dispatch(.selectHost(secondHost.id))
        #expect(store.state.sync.cursor == b.cursor)
        #expect(store.state.interactions.isEmpty)
        #expect(store.state.translations.isEmpty)
        #expect(store.state.capabilities == .empty)
        #expect(store.state.directory.tasks.isEmpty)
        #expect(store.state.drafts.allSatisfy { $0.hostID == secondHost.id })
        #expect(!store.mutationsAllowed())
    }

    @Test func failedOrExpiredStatusIsNotAnAcknowledgedSuccess() async throws {
        let (store, service, clock) = makeHarness()
        service.script.commandBehavior = .lostAckStillUnknown
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store)
        _ = await store.dispatch(.send)
        let id = try #require(store.state.composer.send.intent?.creationID)
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .commandStatus(.accepted(id))))
        #expect(sendIsUncertain(store.state.composer.send))
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .commandStatus(.expired(id))))
        #expect(sendIsUncertain(store.state.composer.send))
        #expect(await store.dispatch(.send) == .rejected(.uncertainOutcome))
        #expect(service.createCount == 1)
        #expect(!store.state.composer.draft.isEmpty)
    }

    @Test func coalescedStoreCheckpointNeverLeadsItsTranscriptRows() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = PreviewGianClientService(script: .legacyContract)
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = try GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(),
            storage: SQLiteGianStorage(directory: directory))
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let session = try #require(store.sessions.first)
        _ = store.ingest(InboundEnvelope(scope: scope, event: .canonical(sequence: 5,
            generation: PreviewFixtures.generationID, body: .session(session))))
        let item = transcriptItem(id: "checkpoint-item", turn: 1, text: "Covered by checkpoint")
        _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: session.id, item: item)))
        // No actor suspension between ingestion and reopening: the coalesced
        // timer cannot run in this deterministic unflushed observation.
        let before = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(before.cursor?.eventSequence == 4)
        #expect(before.transcripts[session.id] == nil)
        #expect(store.flushStorage().isApplied)
        let after = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(after.cursor?.eventSequence == 5)
        #expect(after.transcripts[session.id] == [item])
    }

    @Test func reconnectHintNeverResendsOrReusesCachedMutationReadiness() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store, text: "Retained offline draft")
        _ = await store.dispatch(.noteLocalConnectivity(.unavailable))
        _ = await store.dispatch(.noteLocalConnectivity(.available))
        #expect(store.state.connection == .resyncing)
        #expect(store.state.sync.needsSnapshot)
        #expect(await store.dispatch(.send) == .rejected(.mutationsDisabled))
        #expect(store.state.composer.draft.text == "Retained offline draft")
        #expect(service.createCount == 0)
        #expect(service.sendCount == 0)
        _ = await store.dispatch(.refreshDirectory)
        #expect(store.mutationsAllowed())
        #expect(service.createCount == 0)
        #expect(service.sendCount == 0)
    }

    @Test func hotLogoutRecoveryFencesStopInteractionAndReadingWithoutAutomaticSideEffects() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let stopID = PreviewFixtures.id("stop-unknown", CommandID.self)
        let intent = DurableSendIntent(draftID: store.state.composer.draft.id, stage: .send,
            sendID: stopID, sessionID: PreviewFixtures.sessionID, sendDispatched: true)
        store.state.pendingStop = .sending(intent)
        let interactionID = try #require(store.state.interactions.first?.id)
        store.state.interactions[0].phase = .responding
        store.memory.update(try clientScope(store)) { $0.interactionCommands[interactionID] = PreviewFixtures.id("respond-unknown", CommandID.self) }
        var translation = translationState(revision: 1, configRevision: 1)
        translation.reading["source"] = ReadingRequestState(requestID: PreviewFixtures.id("reading-unknown", TranslationRequestID.self), pending: true, uncertain: false)
        store.state.translations[PreviewFixtures.sessionID] = translation
        _ = await store.dispatch(.logout)
        _ = try await signIn(store, clock: clock)
        #expect(store.state.pendingStop == .uncertain(intent))
        #expect(store.state.interactions.first?.phase == .uncertain)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.reading["source"]?.uncertain == true)
        _ = await store.dispatch(.recoverUncertainOperation)
        #expect(store.state.pendingStop == .succeeded(intent))
        _ = await store.dispatch(.recoverUncertainOperation)
        #expect(store.state.interactions.first?.phase == .resolvedHere)
        _ = await store.dispatch(.recoverUncertainOperation)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.reading["source"]?.pending == false)
        #expect(service.sendCount == 0)
        #expect(service.respondCount == 0)
        #expect(service.translationRequestCount == 0)
    }

    @Test func accountSetupWithoutHostEvidenceCannotReadAnyHostCache() {
        let storage = FailingStorage()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: PreviewGianClientService(script: .legacyContract), clock: clock,
            ids: SequenceIDGenerator(), storage: storage)
        let authorization = fictionalAuthorization(clock: clock, hosts: [])
        #expect(store.restoreAuthorizedSession(authorization: authorization).isApplied)
        #expect(store.state.phase == .awaitingHostPairing)
        #expect(store.state.currentHostID == nil)
        #expect(store.state.directory.tasks.isEmpty)
        #expect(storage.loadCount == 0)
    }
}
