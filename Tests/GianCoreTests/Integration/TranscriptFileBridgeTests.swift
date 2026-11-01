import Foundation
import Testing
@testable import GianCore

@MainActor
private final class FileBridgeService: ControlledService, TranscriptFileProviding {
    var descriptor: RemoteFileDescriptor?
    var requestedDownload: AttachmentDownloadRequest?
    var response: AttachmentTransferResponse = .unavailable("Fictional file unavailable")
    var held: CheckedContinuation<AttachmentTransferResponse, Never>?
    var hold = false

    func fileDescriptor(scope: ClientScope, id: AttachmentID) -> RemoteFileDescriptor? {
        descriptor?.id == id ? descriptor : nil
    }

    override func downloadAttachment(scope: ClientScope, request: AttachmentDownloadRequest) async -> AttachmentTransferResponse {
        requestedDownload = request
        if hold { return await withCheckedContinuation { held = $0 } }
        return response
    }
}

@MainActor
struct TranscriptFileBridgeTests {
    private func configured() async throws -> (GianClientStore, FileBridgeService, RemoteFileDescriptor, Data) {
        let service = FileBridgeService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let session = SessionID(rawValue: "00000000-0000-7000-8000-000000000081")!
        let id = "00000000-0000-7000-8000-000000000082"
        let bytes = Data("Fictional file".utf8)
        let descriptor = try RemoteFileDescriptor(.object([
            "id": .string(id), "session_id": .string(session.rawValue), "name": .string("fixture.txt"),
            "mime": .string("text/plain"), "size": .int(bytes.count), "revision": .string("file-r1"),
            "previewable": .bool(true), "downloadable": .bool(true), "expires_at": .string("2099-01-01T00:00:00Z"),
        ]), session: session)
        service.descriptor = descriptor
        service.base.script.directory.sessions[0].id = session
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        var item = transcriptItem(id: "file-message", turn: 1, text: "File")
        item.body = .user(text: "File", deliveryID: nil, attachmentIDs: [descriptor.id], translation: nil)
        service.transcriptPages = [TranscriptPageResponse(items: [item], cursor: nil, hasOlder: false)]
        _ = await store.dispatch(.selectConversation(session))
        return (store, service, descriptor, bytes)
    }

    @Test func transcriptFileUsesMetadataHashNotInventedDescriptorSHAAndClearsIndependently() async throws {
        let (store, service, descriptor, bytes) = try await configured()
        service.response = .downloaded(sha256: SHA256Hex.digest(bytes), bytes: bytes)
        #expect(store.transcriptFileDescriptor(for: descriptor.id) == descriptor)
        #expect((await store.dispatch(.downloadAttachment(descriptor.id))).isApplied)
        #expect(service.requestedDownload?.sha256 == "")
        #expect(store.transcriptFileStates[descriptor.id] == .cached)
        #expect(store.attachmentData(for: descriptor.id) == bytes)
        let draft = store.state.composer.draft
        #expect((await store.dispatch(.clearAttachmentCache)).isApplied)
        #expect(store.attachmentData(for: descriptor.id) == nil)
        #expect(store.state.composer.draft == draft)
    }

    @Test func logoutFencesLateFileBytesAndDoesNotExposeThemToAnotherAccount() async throws {
        let (store, service, descriptor, bytes) = try await configured()
        service.hold = true
        let pending = Task { await store.dispatch(.downloadAttachment(descriptor.id)) }
        for _ in 0..<100 where service.held == nil { await Task.yield() }
        let completion = try #require(service.held)
        service.held = nil
        _ = await store.dispatch(.logout)
        completion.resume(returning: .downloaded(sha256: SHA256Hex.digest(bytes), bytes: bytes))
        #expect(await pending.value == .rejected(.staleOperation))
        #expect(store.attachmentData(for: descriptor.id) == nil)
        #expect(store.transcriptFileDescriptor(for: descriptor.id) == nil)
        #expect(store.transcriptFileStates.isEmpty)
    }

    @Test func liveCompositionRequiresExplicitSQLiteAndIsInert() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try GianLiveClient(storage: SQLiteGianStorage(directory: directory))
        #expect(client.store.state.phase == .signedOut)
        #expect(client.store.memory.usesSQLite)
        #expect(!client.coordinator.isRunning)
    }
}
