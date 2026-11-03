import Foundation
import Testing
@testable import GianCore

private func phaseKind(_ phase: SendPhase) -> String {
    switch phase {
    case .idle: return "idle"
    case .creating: return "creating"
    case .awaitingTranslation: return "awaiting"
    case .sending: return "sending"
    case .uncertain: return "uncertain"
    case .failed: return "failed"
    case .succeeded: return "succeeded"
    }
}

@MainActor
struct ContractTests {
    @Test func serverAddressConnectsWithoutAnyAccountSignIn() async throws {
        #expect(GianCore.contractRevision == "0.1.0-contract.2")
        #expect(RemoteBaseline.inspectedCommit == "0c0f2f5c92bc70f78269b105e4e0b98cf99770d0")
        #expect(RemoteBaseline.serverIdentityProofType == "gian.remote.server_identity/1")
        #expect(KnownWireFeature.conversationTranslation.rawValue == "wire.conversation_translation")

        let (store, _, _) = makeHarness()
        #expect(store.state.phase == .signedOut)
        #expect(await store.dispatch(.setServerAddress("http://remote.example.test")) == .rejected(.invalidServerAddress))
        #expect(await store.dispatch(.setServerAddress("https://user:pass@remote.example.test")) == .rejected(.invalidServerAddress))
        #expect(await store.dispatch(.setServerAddress("https://remote.example.test/pair")) == .rejected(.invalidServerAddress))
        #expect(ServerAddress(parsing: "https://remote.example.test/")?.absoluteString == "https://remote.example.test")
        #expect(ServerAddress(parsing: "https://remote.example.test:8443")?.origin.port == 8443)

        // One step: the Server proves its identity, then Host pairing.
        #expect(await store.dispatch(.setServerAddress(PreviewFixtures.server)) == .applied)
        #expect(store.state.server?.absoluteString == "https://remote.example.test")
        #expect(store.state.phase == .awaitingHostPairing)
        #expect(store.state.account.status == .signedIn)
        #expect(store.state.account.accountID == PreviewFixtures.account)
        #expect(storedLabels(of: store.state.account) == Set(["status", "accountID", "installationID", "failure"]))
    }

    @Test func aChangedServerIdentityStopsSetupUntilForgotten() async {
        var script = PreviewScript.legacyContract
        script.serverIdentity = .changed
        let (store, service, _) = makeHarness(script: script)
        #expect(await store.dispatch(.setServerAddress(PreviewFixtures.server)) == .rejected(.serverIdentityChanged))
        #expect(store.state.phase == .serverEntered)
        #expect(store.state.account.status == .serverIdentityChanged)
        #expect(store.state.account.accountID == nil)
        #expect(await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr)) == .rejected(.notAuthorized))

        service.script.serverIdentity = .verified
        #expect(await store.dispatch(.forgetServerIdentity) == .applied)
        #expect(store.state.phase == .awaitingHostPairing)
    }

    @Test func unreachableServerDoesNotUsePreviewFixtures() async {
        let store = GianClientStore(
            service: RejectingService(),
            clock: ManualGianClock(instant: PreviewFixtures.instant),
            ids: SequenceIDGenerator(),
            storage: InMemoryGianStorage()
        )
        #expect((await store.dispatch(.setServerAddress(PreviewFixtures.server))).isApplied)
        #expect(store.state.phase == .serverEntered)
        #expect(store.state.account.status == .error)
        #expect(store.state.account.failure == "unreachable")
        #expect(store.state.directory.tasks.isEmpty)
        #expect(store.state.directory.repos.isEmpty)
        #expect(store.state.hosts.isEmpty)
    }

    @Test func qrPairsGrantNonceOnly() async throws {
        let (store, _, clock) = makeHarness()
        try await authenticate(store, clock: clock)
        let mismatch = "https://other.example.test/pair#nonce=abcdefghijklmnop"
        #expect(await store.dispatch(.beginHostPairingFromQR(mismatch)) == .rejected(.pairingServerMismatch))
        let password = "https://remote.example.test/pair?password=no&nonce=abcdefghijklmnop"
        #expect(await store.dispatch(.beginHostPairingFromQR(password)) == .rejected(.pairingQRInvalid))
        let both = "https://remote.example.test/pair?nonce=abcdefghijklmnop#nonce=abcdefghijklmnop"
        #expect(await store.dispatch(.beginHostPairingFromQR(both)) == .rejected(.pairingQRInvalid))
        #expect(store.state.phase == .awaitingHostPairing)
        #expect(store.state.pendingPairing == nil)
        #expect((await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))).isApplied)
        #expect(store.state.phase == .ready)
        #expect(store.state.hosts.contains { $0.id == PreviewFixtures.hostID })
    }

    @Test func pendingPairingDoesNotInventDirectory() async throws {
        var script = PreviewScript.legacyContract
        script.confirmation = .onRefresh
        let (store, _, clock) = makeHarness(script: script)
        try await authenticate(store, clock: clock)
        #expect((await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))).isApplied)
        #expect(store.state.phase == .awaitingHostPairing)
        #expect(store.state.pendingPairing != nil)
        #expect(store.state.directory.tasks.isEmpty)
        #expect((await store.dispatch(.refreshHostPairing)).isApplied)
        #expect(store.state.phase == .ready)
        #expect(store.state.directory.tasks.contains { $0.title == "Paint the harbor" })
    }

    @Test func legacyDirectoryHidesReposAndSearch() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        #expect(store.state.directory.tasks.contains { section in
            section.title == "Paint the harbor" && section.conversations.contains { $0.title == "Mooring notes" }
        })
        #expect(store.state.directory.repos.isEmpty)
        #expect(store.state.directory.reposSupport == .unsupported(.reposDirectory))
        #expect(store.state.directory.searchSupport == .unsupported(.olderSearch))
        #expect(store.state.directory.legacyLimitations.map(\.surface).contains(.tasklessFirstSend))
        #expect((await store.dispatch(.selectDirectoryView(.repos))).isApplied)
        #expect(store.state.navigation.directoryView == .repos)
        #expect(await store.dispatch(.search("Old log")) == .rejected(.legacySearchUnsupported))
        #expect(service.searchCount == 0)
    }

    @Test func fullDirectoryKeepsRecentReposAndOlderSearch() async throws {
        let (store, service, clock) = makeHarness(script: .fullDirectory)
        _ = try await signIn(store, clock: clock)
        let repos = Set(store.state.directory.repos.map(\.title))
        #expect(repos.contains("Mooring notes"))
        #expect(repos.contains("Night watch"))
        #expect(repos.contains("Unassigned"))
        #expect(!repos.contains("Old quiet"))
        #expect(!repos.contains("Only viewed"))
        #expect(!repos.contains("Archived log"))
        #expect(store.state.directory.tasks.map(\.title) == ["Paint the harbor"])
        let taskTitles = Set(store.state.directory.tasks.flatMap { $0.conversations.map(\.title) })
        #expect(!taskTitles.contains("Unassigned"))
        #expect((await store.dispatch(.search("Old log"))).isApplied)
        #expect(service.searchCount == 1)
        #expect(store.state.directory.searchResults.map(\.title) == ["Old log"])
    }

    @Test func draftsSurviveNavigationLogoutAndStayScoped() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        #expect((await store.dispatch(.openNewChat)).isApplied)
        #expect((await store.dispatch(.editDraftText("harbor draft"))).isApplied)
        #expect((await store.dispatch(.openSettings)).isApplied)
        #expect(store.state.navigation.settingsOpen)
        #expect(store.state.composer.draft.text == "harbor draft")
        #expect((await store.dispatch(.closeSettings)).isApplied)
        #expect((await store.dispatch(.selectConversation(PreviewFixtures.sessionID))).isApplied)
        #expect(store.state.composer.draft.text != "harbor draft")
        #expect((await store.dispatch(.openNewChat)).isApplied)
        #expect(store.state.composer.draft.text == "harbor draft")

        let server = try #require(ServerAddress(parsing: PreviewFixtures.server))
        let original = ClientScope(server: server, account: PreviewFixtures.account, host: PreviewFixtures.hostID)
        #expect((await store.dispatch(.logout)).isApplied)
        #expect(store.state.phase == .signedOut)
        #expect(store.state.drafts.isEmpty)
        try store.memory.load(original)
        #expect(store.memory.bundle(for: original).drafts.contains { $0.text == "harbor draft" })

        _ = try await signIn(store, clock: clock)
        #expect(store.state.composer.draft.text == "harbor draft")

        #expect((await store.dispatch(.logout)).isApplied)
        service.script.refreshBehavior = .fail
        let failedRefresh = try await signIn(store, clock: clock)
        #expect(failedRefresh == .rejected(.notFound))
        #expect(store.state.phase == .ready)
        #expect(store.state.composer.draft.text == "harbor draft")
        #expect(store.state.directory.tasks.contains { section in
            section.conversations.contains { $0.title == "Mooring notes" }
        })

        #expect((await store.dispatch(.logout)).isApplied)
        service.script.account = AccountIdentity(
            account: PreviewFixtures.otherAccount,
            installationID: PreviewFixtures.id("install-2", InstallationID.self)
        )
        _ = try await signIn(store, clock: clock)
        #expect(store.state.account.accountID == PreviewFixtures.otherAccount)
        #expect(store.state.composer.draft.text != "harbor draft")
        let other = ClientScope(server: server, account: PreviewFixtures.otherAccount, host: PreviewFixtures.hostID)
        try store.memory.load(original)
        #expect(store.memory.bundle(for: original).drafts.contains { $0.text == "harbor draft" })
        #expect(!store.memory.bundle(for: other).drafts.contains { $0.text == "harbor draft" })
        #expect(!store.state.drafts.contains { $0.text == "harbor draft" })
    }

    @Test func offlineSendKeepsTheDraft() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store)
        #expect((await store.dispatch(.noteLocalConnectivity(.unavailable))).isApplied)
        #expect(await store.dispatch(.send) == .rejected(.offlineDraftRetained))
        #expect(service.createCount == 0)
        #expect(service.sendCount == 0)
        #expect(store.state.composer.draft.text == "Check the line")
    }

    @Test func firstSendUsesIndependentCreateAndSendIDs() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store)
        #expect((await store.dispatch(.send)).isApplied)
        #expect(phaseKind(store.state.composer.send) == "succeeded")
        let intent = try #require(store.state.composer.send.intent)
        let creationID = try #require(intent.creationID)
        let sendID = try #require(intent.sendID)
        #expect(creationID != sendID)
        #expect(isUUIDv7(creationID.rawValue))
        #expect(isUUIDv7(sendID.rawValue))
        #expect(intent.createDispatched)
        #expect(intent.sendDispatched)
        #expect(service.createCount == 1)
        #expect(service.sendCount == 1)
        #expect(store.state.composer.draft.text.isEmpty)
    }

    @Test func legacyHostRejectsTasklessCreateAndEmptyCatalog() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store, task: false)
        #expect(await store.dispatch(.send) == .rejected(.legacyTasklessCreateUnsupported))
        #expect(service.createCount == 0)
        #expect(store.state.composer.notice == .legacyTaskRequired)

        service.script.directory.catalogRevision = ""
        #expect((await store.dispatch(.refreshDirectory)).isApplied)
        #expect(store.state.catalogRevision.isEmpty)
        await prepareComposer(store)
        #expect(await store.dispatch(.send) == .rejected(.missingCatalog))
        #expect(service.createCount == 0)
    }

    @Test func notSeenDoesNotAuthorizeAnotherCreateIdentity() async throws {
        let (store, service, clock) = makeHarness()
        service.script.commandBehavior = .lostAckNotSeen
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store)
        #expect((await store.dispatch(.send)).isApplied)
        #expect(phaseKind(store.state.composer.send) == "uncertain")
        #expect(service.createCount == 1)
        #expect(service.sendCount == 0)
        let firstCreation = try #require(store.state.composer.send.intent?.creationID)
        #expect(await store.dispatch(.send) == .rejected(.uncertainOutcome))
        #expect(service.createCount == 1)

        #expect((await store.dispatch(.recoverUncertainOperation)).isApplied)
        #expect(phaseKind(store.state.composer.send) == "uncertain")
        #expect(store.state.composer.send.intent?.creationID == firstCreation)
        #expect(store.state.composer.draft.text == "Check the line")

        #expect(await store.dispatch(.send) == .rejected(.uncertainOutcome))
        #expect(service.createCount == 1)
        #expect(service.sendCount == 0)
        #expect(store.state.composer.send.intent?.creationID == firstCreation)
    }

    @Test func unknownCreateAndUnknownSendAreNotRetried() async throws {
        let (store, service, clock) = makeHarness()
        service.script.commandBehavior = .lostAckStillUnknown
        _ = try await signIn(store, clock: clock)
        await prepareComposer(store)
        #expect((await store.dispatch(.send)).isApplied)
        #expect((await store.dispatch(.recoverUncertainOperation)).isApplied)
        #expect(phaseKind(store.state.composer.send) == "uncertain")
        #expect(await store.dispatch(.send) == .rejected(.uncertainOutcome))
        #expect(service.createCount == 1)
        #expect(service.sendCount == 0)
        #expect(store.state.composer.draft.text == "Check the line")

        let again = makeHarness()
        again.1.script.commandBehavior = .createSucceedsSendUnknown
        _ = try await signIn(again.0, clock: again.2)
        await prepareComposer(again.0)
        #expect((await again.0.dispatch(.send)).isApplied)
        #expect(again.1.createCount == 1)
        #expect(again.1.sendCount == 1)
        #expect(again.0.state.composer.send.intent?.stage == .send)
        #expect(phaseKind(again.0.state.composer.send) == "uncertain")
        #expect((await again.0.dispatch(.recoverUncertainOperation)).isApplied)
        #expect(phaseKind(again.0.state.composer.send) == "uncertain")
        #expect(again.1.createCount == 1)
        #expect(again.1.sendCount == 1)
    }

    @Test func interactionResponsesUseHostActionIDs() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let missing = try #require(ActionID(rawValue: "action-nope"))
        #expect(await store.dispatch(.respondToInteraction(PreviewFixtures.interactionID, actionID: missing, values: [:])) == .rejected(.unknownActionID))
        #expect(await store.dispatch(.respondToInteraction(
            PreviewFixtures.interactionID,
            actionID: PreviewFixtures.actionID,
            values: ["extra": .text("no")]
        )) == .rejected(.unknownInputID))
        #expect(service.respondCount == 0)
    }

    @Test func unconfiguredTranslationBlocksSend() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        #expect((await store.dispatch(.selectConversation(PreviewFixtures.sessionID))).isApplied)
        var translation = TranslationSessionState.unsupported
        translation.supported = true
        translation.enabled = true
        translation.configured = false
        translation.revision = 1
        translation.configRevision = 1
        let ingested = store.ingest(InboundEnvelope(
            scope: try clientScope(store),
            event: .translation(
                sessionID: PreviewFixtures.sessionID,
                update: .state(translation, authoritativeBaseline: true)
            )
        ))
        #expect(ingested.isApplied)
        #expect((await store.dispatch(.editDraftText("Translate this"))).isApplied)
        #expect(await store.dispatch(.send) == .rejected(.translationNotConfigured))
        #expect(store.state.composer.notice == .translationNeedsChoice)
        #expect(service.sendCount == 0)
        #expect(service.translationRequestCount == 0)
        #expect(service.createCount == 0)
        #expect(store.state.composer.draft.text == "Translate this")
    }

    @Test func canonicalGapsAndGenerationAreNotApplied() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        var shifted = try #require(store.sessions.first { $0.id == PreviewFixtures.sessionID })
        shifted.title = "Shifted title"
        let skipped = store.ingest(InboundEnvelope(
            scope: scope,
            event: .canonical(sequence: 6, generation: PreviewFixtures.generationID, body: .session(shifted))
        ))
        #expect(skipped.isApplied)
        #expect(store.state.sync.needsSnapshot)
        #expect(store.state.sync.reason == .gapEvicted)
        #expect(store.state.sync.cursor?.eventSequence == 4)
        #expect(conversationTitles(store).contains("Mooring notes"))
        #expect(!conversationTitles(store).contains("Shifted title"))

        shifted.title = "Late title"
        _ = store.ingest(InboundEnvelope(
            scope: scope,
            event: .canonical(sequence: 5, generation: PreviewFixtures.generationID, body: .session(shifted))
        ))
        #expect(store.state.sync.needsSnapshot)
        #expect(!conversationTitles(store).contains("Late title"))

        let ordered = makeHarness()
        _ = try await signIn(ordered.0, clock: ordered.2)
        let orderedScope = try clientScope(ordered.0)
        var applied = try #require(ordered.0.sessions.first { $0.id == PreviewFixtures.sessionID })
        applied.title = "Applied title"
        _ = ordered.0.ingest(InboundEnvelope(
            scope: orderedScope,
            event: .canonical(sequence: 5, generation: PreviewFixtures.generationID, body: .session(applied))
        ))
        #expect(ordered.0.state.sync.cursor?.eventSequence == 5)
        #expect(!ordered.0.state.sync.needsSnapshot)
        #expect(conversationTitles(ordered.0).contains("Applied title"))
        applied.title = "Duplicate title"
        _ = ordered.0.ingest(InboundEnvelope(
            scope: orderedScope,
            event: .canonical(sequence: 5, generation: PreviewFixtures.generationID, body: .session(applied))
        ))
        #expect(ordered.0.state.sync.needsSnapshot)
        #expect(ordered.0.state.sync.reason == .gapEvicted)
        #expect(conversationTitles(ordered.0).contains("Applied title"))
        #expect(!conversationTitles(ordered.0).contains("Duplicate title"))

        let restarted = makeHarness()
        _ = try await signIn(restarted.0, clock: restarted.2)
        var renamed = try #require(restarted.0.sessions.first { $0.id == PreviewFixtures.sessionID })
        renamed.title = "Other generation"
        let generation = try #require(HostGenerationID(rawValue: "generation-2"))
        _ = restarted.0.ingest(InboundEnvelope(
            scope: try clientScope(restarted.0),
            event: .canonical(sequence: 5, generation: generation, body: .session(renamed))
        ))
        #expect(restarted.0.state.sync.reason == .generationChanged)
        #expect(restarted.0.state.sync.cursor?.eventSequence == 4)
        #expect(!conversationTitles(restarted.0).contains("Other generation"))
        renamed.title = "After restart"
        _ = restarted.0.ingest(InboundEnvelope(
            scope: try clientScope(restarted.0),
            event: .canonical(sequence: 5, generation: PreviewFixtures.generationID, body: .session(renamed))
        ))
        #expect(!conversationTitles(restarted.0).contains("After restart"))

        var outsider = scope
        outsider.host = try #require(HostID(rawValue: "host-other"))
        let foreign = store.ingest(InboundEnvelope(
            scope: outsider,
            event: .canonical(sequence: 5, generation: PreviewFixtures.generationID, body: .session(shifted))
        ))
        #expect(foreign == .rejected(.scopeMismatch))
    }

    @Test func bannersAreForegroundCrossChatAndCoalesced() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let missing = PreviewFixtures.id("session-missing", SessionID.self)
        let unknown = store.ingest(InboundEnvelope(
            scope: scope,
            event: .transcript(sessionID: missing, item: transcriptItem(id: "item-missing", turn: 4, text: "Missing"))
        ))
        #expect(unknown == .rejected(.notFound))
        #expect(store.state.banners.isEmpty)

        #expect((await store.dispatch(.openNewChat)).isApplied)
        let first = transcriptItem(id: "item-banner-1", turn: 8, text: "Line check")
        let firstEvent = InboundEvent.transcript(sessionID: PreviewFixtures.sessionID, item: first)
        #expect(store.ingest(InboundEnvelope(scope: scope, event: firstEvent)).isApplied)
        #expect(store.state.banners.count == 1)
        #expect(store.state.banners[0].eventCount == 1)
        let bannerID = store.state.banners[0].id
        #expect(store.ingest(InboundEnvelope(scope: scope, event: firstEvent)).isApplied)
        #expect(store.state.banners[0].eventCount == 1)
        let second = transcriptItem(id: "item-banner-2", turn: 9, text: "Second line")
        #expect(store.ingest(InboundEnvelope(
            scope: scope,
            event: .transcript(sessionID: PreviewFixtures.sessionID, item: second)
        )).isApplied)
        #expect(store.state.banners.count == 1)
        #expect(store.state.banners[0].id == bannerID)
        #expect(store.state.banners[0].eventCount == 2)

        #expect((await store.dispatch(.selectConversation(PreviewFixtures.sessionID))).isApplied)
        let current = transcriptItem(id: "item-banner-3", turn: 10, text: "Already here")
        #expect(store.ingest(InboundEnvelope(
            scope: scope,
            event: .transcript(sessionID: PreviewFixtures.sessionID, item: current)
        )).isApplied)
        #expect(store.state.banners.count == 1)
        #expect(store.state.banners[0].eventCount == 2)

        #expect((await store.dispatch(.openNewChat)).isApplied)
        #expect((await store.dispatch(.setForeground(.background))).isApplied)
        let background = transcriptItem(id: "item-banner-4", turn: 11, text: "Background")
        #expect(store.ingest(InboundEnvelope(
            scope: scope,
            event: .transcript(sessionID: PreviewFixtures.sessionID, item: background)
        )).isApplied)
        #expect(store.state.banners.count == 1)
        #expect(store.state.banners[0].eventCount == 2)
        let stored = store.memory.bundle(for: try dataScope(store)).transcripts[PreviewFixtures.sessionID] ?? []
        #expect(stored.contains { $0.id == background.id })
    }

    @Test func attachmentsKeepIntegrityAndDraftBytes() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        #expect(await store.dispatch(.addDraftAttachment(AttachmentDraftInput(filename: "empty.txt", mime: "text/plain", bytes: Data()))) == .rejected(.attachmentRejected))
        #expect((await store.dispatch(.selectConversation(PreviewFixtures.sessionID))).isApplied)
        #expect(store.state.conversation?.items.isEmpty == false)
        #expect((await store.dispatch(.openNewChat)).isApplied)
        #expect((await store.dispatch(.editDraftText("keep me"))).isApplied)
        let added = await store.dispatch(.addDraftAttachment(
            AttachmentDraftInput(filename: "hello.txt", mime: "text/plain", bytes: Data("hello".utf8))
        ))
        #expect(added.isApplied)
        let id = try #require(store.state.composer.draft.attachments.first?.id)
        #expect(store.state.composer.draft.attachments.first?.state == .uploaded)
        #expect((await store.dispatch(.downloadAttachment(id))).isApplied)
        #expect(store.state.composer.draft.attachments.first?.state == .cached)
        #expect((await store.dispatch(.clearAttachmentCache)).isApplied)
        #expect(store.state.composer.draft.text == "keep me")
        #expect(store.state.composer.draft.attachments.first?.state == .uploaded)
        let scope = try dataScope(store)
        #expect(store.memory.bundle(for: scope).draftBytes[id] == Data("hello".utf8))
        #expect(store.memory.bundle(for: scope).downloads[id] == nil)
        #expect(!(store.memory.bundle(for: scope).transcripts[PreviewFixtures.sessionID] ?? []).isEmpty)
        #expect(store.state.conversation?.items.isEmpty == false)

        let mismatched = makeHarness()
        mismatched.1.script.uploadSHA256Override = String(repeating: "ab", count: 32)
        _ = try await signIn(mismatched.0, clock: mismatched.2)
        #expect((await mismatched.0.dispatch(.openNewChat)).isApplied)
        #expect((await mismatched.0.dispatch(.editDraftText("keep me"))).isApplied)
        #expect((await mismatched.0.dispatch(.addDraftAttachment(
            AttachmentDraftInput(filename: "hello.txt", mime: "text/plain", bytes: Data("hello".utf8))
        ))).isApplied)
        #expect(mismatched.0.state.composer.draft.attachments.first?.state == .hashMismatch)
        #expect(mismatched.1.uploadCount == 1)
        let localID = try #require(mismatched.0.state.composer.draft.attachments.first?.id)
        #expect((await mismatched.0.dispatch(.clearAttachmentCache)).isApplied)
        #expect(mismatched.0.state.composer.draft.text == "keep me")
        #expect(mismatched.0.memory.bundle(for: try dataScope(mismatched.0)).draftBytes[localID] == Data("hello".utf8))

        let lied = makeHarness()
        _ = try await signIn(lied.0, clock: lied.2)
        #expect((await lied.0.dispatch(.openNewChat)).isApplied)
        #expect((await lied.0.dispatch(.addDraftAttachment(
            AttachmentDraftInput(filename: "note.txt", mime: "text/plain", bytes: Data("note".utf8))
        ))).isApplied)
        #expect(lied.0.state.composer.draft.attachments.first?.state == .uploaded)
        let noteID = try #require(lied.0.state.composer.draft.attachments.first?.id)
        #expect((await lied.0.dispatch(.downloadAttachment(noteID))).isApplied)
        #expect(lied.0.state.composer.draft.attachments.first?.state == .hashMismatch)
    }
}

@MainActor
private func conversationTitles(_ store: GianClientStore) -> Set<String> {
    Set(store.state.directory.tasks.flatMap { $0.conversations.map(\.title) })
}
