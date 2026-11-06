import Foundation
import Testing
@testable import GianCore

@MainActor
struct DraftBytesLifecycleTests {
    @Test func confirmedReleaseRespectsAnotherUncertainRemoteReference() {
        let bytes = Data("fixture".utf8)
        let local = PreviewFixtures.id("shared-intent-local", AttachmentID.self)
        let remote = PreviewFixtures.id("shared-intent-remote", AttachmentID.self)
        let attachment = DraftAttachment(id: local, filename: "a.txt", mime: "text/plain", byteCount: bytes.count,
                                         sha256: SHA256Hex.digest(bytes), state: .uploaded, remoteID: remote)
        let submitted = DraftDocument(id: PreviewFixtures.id("finished-draft", DraftID.self), hostID: PreviewFixtures.hostID,
                                      target: .conversation(PreviewFixtures.sessionID), text: "Sent", attachments: [attachment], updatedAt: PreviewFixtures.instant)
        let pendingID = PreviewFixtures.id("other-pending-draft", DraftID.self)
        var pending = DurableSendIntent(draftID: pendingID, stage: .send, sessionID: PreviewFixtures.sessionID)
        pending.sendID = PreviewFixtures.id("other-send", CommandID.self)
        pending.sendRequest = SessionSendRequest(commandID: pending.sendID!, sessionID: PreviewFixtures.sessionID,
                                                 text: "Pending", attachmentIDs: [remote], busy: nil, translation: nil)
        var bundle = StoredHostState()
        bundle.draftBytes[local] = bytes
        bundle.operations[pendingID] = .uncertain(pending)
        bundle.releaseConfirmedDraftBytes(submitted, currentDrafts: [])
        #expect(bundle.draftBytes[local] == bytes)
        pending.sendRequest = nil
        bundle.operations[pendingID] = .uncertain(pending)
        bundle.releaseConfirmedDraftBytes(submitted, currentDrafts: [])
        #expect(bundle.draftBytes[local] == bytes)
    }

    @Test func confirmedSendReleasesOnlyUnsharedSubmittedBytes() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let storage = InMemoryGianStorage()
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        _ = await store.dispatch(.editDraftText("Send"))
        let bytes = Data("fixture".utf8)
        let released = DraftAttachment(id: PreviewFixtures.id("sent-local", AttachmentID.self), filename: "a.txt", mime: "text/plain",
            byteCount: bytes.count, sha256: SHA256Hex.digest(bytes), state: .uploaded, remoteID: PreviewFixtures.id("sent-remote", AttachmentID.self))
        let shared = DraftAttachment(id: PreviewFixtures.id("shared-local", AttachmentID.self), filename: "b.txt", mime: "text/plain",
            byteCount: bytes.count, sha256: SHA256Hex.digest(bytes), state: .uploaded, remoteID: PreviewFixtures.id("shared-remote", AttachmentID.self))
        store.state.composer.draft.attachments = [released, shared]
        store.state.composer.draft.localRevision += 1
        store.rememberDraft()
        let other = DraftDocument(id: PreviewFixtures.id("other-draft", DraftID.self), hostID: PreviewFixtures.hostID,
            target: .newConversation, text: "Keep", attachments: [shared], updatedAt: clock.instant)
        store.state.drafts.append(other)
        let scope = try clientScope(store)
        store.memory.update(scope) { $0.draftBytes[released.id] = bytes; $0.draftBytes[shared.id] = bytes }
        _ = await store.dispatch(.send)
        guard case .succeeded = store.state.composer.send else { Issue.record("Expected confirmed send"); return }
        let saved = try #require(try storage.load(scope: scope))
        #expect(saved.draftBytes[released.id] == nil)
        #expect(saved.draftBytes[shared.id] == bytes)
    }

    @Test func sendRejectedBeforeDispatchDoesNotPinRemovedAttachmentBytes() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let storage = InMemoryGianStorage()
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.openNewChat)
        _ = await store.dispatch(.selectAgent(PreviewFixtures.agentID))
        _ = await store.dispatch(.selectTask(PreviewFixtures.taskID))
        _ = await store.dispatch(.editDraftText("No workspace yet"))
        #expect((await store.dispatch(.addDraftAttachment(AttachmentDraftInput(
            filename: "a.txt", mime: "text/plain", bytes: Data("fixture".utf8))))).isApplied)
        let id = try #require(store.state.composer.draft.attachments.first?.id)
        let scope = try clientScope(store)
        #expect(await store.dispatch(.send) == .rejected(.missingWorkspace))
        #expect(store.state.composer.send == .idle)
        #expect(store.memory.bundle(for: scope).submittedDrafts[store.state.composer.draft.id] == nil)

        #expect((await store.dispatch(.removeDraftAttachment(id))).isApplied)
        #expect(store.memory.bundle(for: scope).draftBytes[id] == nil)
        #expect(try storage.load(scope: scope)?.draftBytes[id] == nil)
        #expect(service.sessionCreateRequests.isEmpty)
    }

    @Test func unknownSendKeepsSubmittedBytesAndIdentity() async throws {
        let service = ControlledService(); service.base.script.commandBehavior = .lostAckStillUnknown
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let storage = InMemoryGianStorage()
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        _ = await store.dispatch(.editDraftText("Send"))
        let bytes = Data("fixture".utf8)
        let attachment = DraftAttachment(id: PreviewFixtures.id("unknown-local", AttachmentID.self), filename: "a.txt", mime: "text/plain",
            byteCount: bytes.count, sha256: SHA256Hex.digest(bytes), state: .uploaded, remoteID: PreviewFixtures.id("unknown-remote", AttachmentID.self))
        store.state.composer.draft.attachments = [attachment]
        store.state.composer.draft.localRevision += 1
        store.rememberDraft()
        let scope = try clientScope(store)
        store.memory.update(scope) { $0.draftBytes[attachment.id] = bytes }
        _ = await store.dispatch(.send)
        guard case .uncertain(let intent) = store.state.composer.send else { Issue.record("Expected uncertain send"); return }
        let saved = try #require(try storage.load(scope: scope))
        #expect(saved.draftBytes[attachment.id] == bytes)
        #expect(saved.submittedDrafts[intent.draftID]?.attachments.contains { $0.id == attachment.id } == true)
        #expect(saved.operations[intent.draftID]?.intent?.sendID == intent.sendID)
    }
}
