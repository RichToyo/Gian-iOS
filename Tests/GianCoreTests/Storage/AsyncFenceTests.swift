import Foundation
import Testing
@testable import GianCore

@MainActor
struct AsyncFenceTests {
    @Test func latePageCannotReplaceAnotherConversationOrNewerLiveItem() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        service.holdNextPage = true
        let pending = Task { await store.dispatch(.selectConversation(PreviewFixtures.sessionID)) }
        for _ in 0..<100 where service.page == nil { await Task.yield() }
        let page = try #require(service.page)
        service.page = nil
        let item = transcriptItem(id: "live-id", turn: 2, text: "Live after the read began")
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .transcript(sessionID: PreviewFixtures.sessionID, item: item)))
        _ = await store.dispatch(.openNewChat)
        _ = await store.dispatch(.editDraftText("A different draft"))
        let stale = transcriptItem(id: "live-id", turn: 2, text: "Older page version")
        page.resume(returning: TranscriptPageResponse(items: [stale], cursor: "page-2", hasOlder: true))
        _ = await pending.value
        #expect(store.state.navigation.destination == .newChat)
        #expect(store.state.composer.draft.text == "A different draft")
        let retained = store.memory.bundle(for: try clientScope(store)).transcripts[PreviewFixtures.sessionID]
        #expect(retained?.first(where: { $0.id == item.id }) == item)
    }

    @Test func lateSendCannotClearNewChatDraftAndOriginalOperationRemainsRecoverable() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        _ = await store.dispatch(.editDraftText("Submitted"))
        service.holdNextSend = true
        let pending = Task { await store.dispatch(.send) }
        for _ in 0..<100 where service.send == nil { await Task.yield() }
        let completion = try #require(service.send)
        let request = try #require(service.sendRequest)
        service.send = nil
        _ = await store.dispatch(.openNewChat)
        _ = await store.dispatch(.editDraftText("New chat draft"))
        completion.resume(returning: .succeeded(CommandSuccess(commandID: request.commandID, deliveryID: "canonical-delivery")))
        #expect(await pending.value == .rejected(.staleOperation))
        #expect(store.state.composer.draft.text == "New chat draft")
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        if case .uncertain = store.state.composer.send {} else { Issue.record("Original send must remain recoverable.") }
        _ = await store.dispatch(.recoverUncertainOperation)
        _ = await store.dispatch(.openNewChat)
        #expect(store.state.composer.draft.text == "New chat draft")
    }

    /// A transfer reply that arrives after its draft left the composer is
    /// dropped. The attachment must not stay in flight, or Send rejects it.
    @Test func droppedTransferReplyLeavesAttachmentRetryable() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        _ = await store.dispatch(.editDraftText("With a file"))
        service.holdNextUpload = true
        let adding = Task { await store.dispatch(.addDraftAttachment(AttachmentDraftInput(
            filename: "notes.txt", mime: "text/plain", bytes: Data("hello".utf8)))) }
        for _ in 0..<100 where service.transfer == nil { await Task.yield() }
        let upload = try #require(service.transfer)
        service.transfer = nil
        let id = try #require(store.state.composer.draft.attachments.first?.id)
        _ = await store.dispatch(.openNewChat)
        upload.resume(returning: .failed("Connection lost"))
        #expect(await adding.value == .rejected(.staleOperation))
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        #expect(store.state.composer.draft.attachments.first?.state == .localOnly)
        #expect(store.memory.bundle(for: try clientScope(store)).drafts
            .flatMap(\.attachments).first(where: { $0.id == id })?.state == .localOnly)
        #expect((await store.dispatch(.retryAttachmentUpload(id))).isApplied)
        #expect(store.state.composer.draft.attachments.first?.state == .uploaded)

        service.holdNextDownload = true
        let downloading = Task { await store.dispatch(.downloadAttachment(id)) }
        for _ in 0..<100 where service.transfer == nil { await Task.yield() }
        let download = try #require(service.transfer)
        service.transfer = nil
        _ = await store.dispatch(.openNewChat)
        download.resume(returning: .failed("Connection lost"))
        #expect(await downloading.value == .rejected(.staleOperation))
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        #expect(store.state.composer.draft.attachments.first?.state == .uploaded)
        #expect((await store.dispatch(.send)).isApplied)
        #expect(service.sendRequest?.attachmentIDs.count == 1)
    }

    @Test func reclaimedTranslationCannotSendOnALateSettlement() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        store.state.translations[PreviewFixtures.sessionID] = translationState(revision: 1, configRevision: 1)
        _ = await store.dispatch(.editDraftText("Original"))
        service.holdNextTranslation = true
        let pending = Task { await store.dispatch(.send) }
        for _ in 0..<100 where service.translation == nil { await Task.yield() }
        let completion = try #require(service.translation)
        let request = try #require(service.translationRequest)
        service.translation = nil
        #expect((await store.dispatch(.reclaimTranslationDraft)).isApplied)
        let text = "Translation"
        let record = TranslationReducer.verifiedRecord(id: PreviewFixtures.id("late-translation", TranslationRecordID.self),
            sourceID: nil, targetLanguage: "en", text: text, textLength: text.utf16.count,
            textSHA256: SHA256Hex.digest(Data(text.utf8)), sourceSHA256: SHA256Hex.digest(Data(request.text.utf8)), paged: false)
        completion.resume(returning: .settled(request.requestID, record: record, error: nil))
        #expect(await pending.value == .rejected(.staleOperation))
        #expect(service.base.sendCount == 0)
        #expect(store.state.composer.draft.text == "Original")
        #expect(store.state.composer.send == .idle)
    }

    @Test func canonicalSuccessBeforeLostAckIsNotRegressedToUnknown() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        _ = await store.dispatch(.editDraftText("Original"))
        service.holdNextSend = true
        let pending = Task { await store.dispatch(.send) }
        for _ in 0..<100 where service.send == nil { await Task.yield() }
        let completion = try #require(service.send)
        let request = try #require(service.sendRequest)
        service.send = nil
        _ = store.ingest(InboundEnvelope(scope: try clientScope(store), event: .commandStatus(.succeeded(
            CommandSuccess(commandID: request.commandID, deliveryID: "canonical-delivery")))))
        completion.resume(returning: .unknownOutcome(request.commandID))
        #expect((await pending.value).isApplied)
        if case .succeeded = store.state.composer.send {} else { Issue.record("Canonical success must not regress.") }
        #expect(store.state.composer.draft.text.isEmpty)
    }
}
