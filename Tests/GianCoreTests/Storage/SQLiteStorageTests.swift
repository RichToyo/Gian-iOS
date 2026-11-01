import Foundation
import CSQLite
import Testing
@testable import GianCore

@MainActor
func temporaryStorageDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gian-storage-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func fictionalScope(host: HostID = PreviewFixtures.hostID, account: AccountID = PreviewFixtures.account,
                    server: String = PreviewFixtures.server) -> ClientScope {
    ClientScope(server: ServerAddress(parsing: server)!, account: account, host: host)
}

func retainedFixture() -> StoredHostState {
    let source = PreviewScript.legacyContract.directory
    var state = StoredHostState()
    state.host = source.host
    state.sessions = source.sessions
    state.tasks = source.tasks
    state.workspaces = source.workspaces
    state.agents = source.agents
    state.interactions = source.interactions
    state.cursor = source.cursor
    state.capabilities = CapabilityProjection(grants: source.capabilities, negotiatedFeatures: source.negotiatedFeatures)
    state.catalogRevision = source.catalogRevision
    return state
}

@MainActor
struct SQLiteStorageTests {
    @Test func versionOneMigratesBarrierTableWithoutDeletingRetainedHistory() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let storage = try SQLiteGianStorage(directory: directory)
        try storage.save(retainedFixture(), scope: scope)
        try mutateTemporaryDatabase(directory, sql: "DROP TABLE authorization_invalidations; PRAGMA user_version = 1")
        let reopened = try SQLiteGianStorage(directory: directory)
        #expect(try reopened.load(scope: scope)?.sessions == retainedFixture().sessions)
        #expect(try reopened.authorizationInvalidatedAt(scope: scope.data) == nil)
        try reopened.invalidateAuthorization(scope: scope.data, at: PreviewFixtures.instant)
        #expect(try reopened.authorizationInvalidatedAt(scope: scope.data) == PreviewFixtures.instant)
    }

    private func mutateTemporaryDatabase(_ directory: URL, sql: String) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &database) == SQLITE_OK)
        let opened = try #require(database)
        defer { sqlite3_close_v2(opened) }
        try #require(sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK)
    }
    @Test func reopenRetainsHistoryDraftIntentAndTranslationLifecycle() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        var state = retainedFixture()
        let draft = DraftDocument(id: PreviewFixtures.id("draft-durable", DraftID.self), hostID: scope.host,
            target: .newConversation, text: "Original message", attachments: [], updatedAt: PreviewFixtures.instant)
        state.activeDraftID = draft.id
        state.drafts = [draft]
        state.submittedDrafts[draft.id] = draft
        let intent = DurableSendIntent(draftID: draft.id, stage: .create,
            creationID: PreviewFixtures.id("command-create", CommandID.self), createDispatched: true)
        state.operations[draft.id] = .creating(intent)
        let item = transcriptItem(id: "message-one", turn: 1, text: "Same words")
        state.transcripts[PreviewFixtures.sessionID] = [item, transcriptItem(id: "message-two", turn: 2, text: "Same words")]
        state.transcriptCursors[PreviewFixtures.sessionID] = StoredTranscriptCursor(cursor: "older-page", hasOlder: true)
        let fulltext = "Translated text"
        var translation = translationState(revision: 7, configRevision: 3)
        translation.records = [TranslationReducer.verifiedRecord(id: PreviewFixtures.id("translation-one", TranslationRecordID.self),
            sourceID: "message-one", targetLanguage: "en", text: fulltext, textLength: fulltext.utf16.count,
            textSHA256: SHA256Hex.digest(Data(fulltext.utf8)), sourceSHA256: SHA256Hex.digest(Data("source".utf8)), paged: true)]
        translation.reading["message-two"] = ReadingRequestState(requestID: PreviewFixtures.id("reading-request", TranslationRequestID.self), pending: true, uncertain: false)
        state.translations[PreviewFixtures.sessionID] = translation
        do { try SQLiteGianStorage(directory: directory).save(state, scope: scope) }
        let reopened = try SQLiteGianStorage(directory: directory)
        let loaded = try #require(try reopened.load(scope: scope))
        #expect(loaded.drafts == [draft])
        #expect(loaded.transcripts[PreviewFixtures.sessionID]?.count == 2)
        #expect(loaded.transcriptCursors[PreviewFixtures.sessionID]?.cursor == "older-page")
        #expect(loaded.operations[draft.id] == .uncertain(intent))
        #expect(loaded.translations[PreviewFixtures.sessionID]?.records.first?.presentableText == fulltext)
        #expect(loaded.translations[PreviewFixtures.sessionID]?.records.first?.integrity == .pagedVerified)
        #expect(loaded.translations[PreviewFixtures.sessionID]?.reading["message-two"]?.uncertain == true)
    }

    @Test func everyHostAccountAndServerIsANamespace() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let scope = fictionalScope()
        let original = retainedFixture()
        try storage.save(original, scope: scope)
        let otherHost = PreviewFixtures.id("other-host", HostID.self)
        #expect(try storage.load(scope: fictionalScope(host: otherHost)) == nil)
        #expect(try storage.load(scope: fictionalScope(account: PreviewFixtures.otherAccount)) == nil)
        #expect(try storage.load(scope: fictionalScope(server: "https://other.example.test")) == nil)
        #expect(throws: GianStorageError.scopeMismatch) { try storage.save(original, scope: fictionalScope(host: otherHost)) }
        #expect(try storage.load(scope: scope)?.sessions == original.sessions)
    }

    @Test func cacheEvictionPreservesUnsentBytesAndHistory() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let scope = fictionalScope()
        var state = retainedFixture()
        let id = PreviewFixtures.id("attachment-local", AttachmentID.self)
        let bytes = Data("An unsent original".utf8)
        let attachment = DraftAttachment(id: id, filename: "notes.txt", mime: "text/plain", byteCount: bytes.count,
            sha256: SHA256Hex.digest(bytes), state: .localOnly)
        state.drafts = [DraftDocument(id: PreviewFixtures.id("draft-with-file", DraftID.self), hostID: scope.host,
            target: .newConversation, text: "", attachments: [attachment], updatedAt: PreviewFixtures.instant)]
        state.draftBytes[id] = bytes
        state.downloads[id] = bytes
        state.transcripts[PreviewFixtures.sessionID] = [transcriptItem(id: "retained-message", turn: 1, text: "Retained")]
        try storage.save(state, scope: scope)
        try storage.clearDownloadCache(scope: scope)
        let loaded = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(loaded.downloads.isEmpty)
        #expect(loaded.draftBytes[id] == bytes)
        #expect(loaded.drafts == state.drafts)
        #expect(loaded.transcripts == state.transcripts)
        state.drafts[0].attachments[0].filename = "../escape"
        #expect(throws: GianStorageError.invalidAttachment) { try storage.save(state, scope: scope) }
    }

    @Test func differentialWriteAndCheckpointRecoverTogether() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let scope = fictionalScope()
        var state = retainedFixture()
        state.transcripts[PreviewFixtures.sessionID] = (0..<128).map {
            transcriptItem(id: "retained-\($0)", turn: $0, text: String(repeating: "z", count: 32_000))
        }
        try storage.save(state, scope: scope)
        try storage.save(state, scope: scope)
        #expect(storage.lastCommitChangedRowCount == 0)
        #expect(storage.lastCommitBytes == 0)
        let replayed = transcriptItem(id: "streamed-item", turn: 129, text: "Latest")
        // Abandon an uncommitted coalesced update, as if the process terminated.
        state.transcripts[PreviewFixtures.sessionID]?.append(replayed)
        state.cursor?.eventSequence += 1
        let beforeFlush = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(beforeFlush.cursor?.eventSequence == 4)
        #expect(beforeFlush.transcripts[PreviewFixtures.sessionID]?.count == 128)
        try storage.save(state, scope: scope)
        #expect(storage.lastCommitChangedRowCount == 2)
        #expect(storage.lastCommitBytes < 16_000)
        let afterFlush = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(afterFlush.cursor?.eventSequence == 5)
        #expect(afterFlush.transcripts[PreviewFixtures.sessionID]?.last == replayed)
        var duplicateReplay = afterFlush
        duplicateReplay.transcripts[PreviewFixtures.sessionID] = TranscriptLog.merge(
            existing: afterFlush.transcripts[PreviewFixtures.sessionID] ?? [], incoming: [replayed])
        try storage.save(duplicateReplay, scope: scope)
        #expect(storage.lastCommitChangedRowCount == 0)
    }

    @Test func rejectsSymbolicLinkAndNeverUsesHostFilenameAsAPath() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        #expect(throws: GianStorageError.unsafeLocation) { _ = try SQLiteGianStorage(directory: link) }
        #expect(!AttachmentRules.safeFilename("/private/data"))
        #expect(!AttachmentRules.safeFilename("..\\data"))
        #expect(!AttachmentRules.safeFilename("name\n.txt"))
        #expect(AttachmentRules.safeFilename("photo.png"))
    }

    @Test func failedCommitCannotAdvanceCheckpointOrPartiallyStoreAnIntent() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let scope = fictionalScope()
        var state = retainedFixture()
        try storage.save(state, scope: scope)
        state.cursor?.eventSequence = 5
        state.transcripts[PreviewFixtures.sessionID] = [transcriptItem(id: "not-committed", turn: 2, text: "Pending")]
        let draftID = PreviewFixtures.id("draft-failing", DraftID.self)
        state.operations[draftID] = .uncertain(DurableSendIntent(draftID: draftID, stage: .send,
            sendID: PreviewFixtures.id("send-failing", CommandID.self), sessionID: PreviewFixtures.sessionID, sendDispatched: true))
        storage.beforeSaveCommit = { throw GianStorageError.unavailable }
        #expect(throws: GianStorageError.unavailable) { try storage.save(state, scope: scope) }
        let loaded = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(loaded.cursor?.eventSequence == 4)
        #expect(loaded.transcripts[PreviewFixtures.sessionID] == nil)
        #expect(loaded.operations[draftID] == nil)
        storage.beforeSaveCommit = nil
        try storage.save(state, scope: scope)
        let retried = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(retried.cursor?.eventSequence == 5)
        #expect(retried.operations[draftID] != nil)
    }

    @Test func corruptEvictableCacheCannotPreventRetainedHistoryRestore() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        var state = retainedFixture()
        let id = PreviewFixtures.id("download-corrupt", AttachmentID.self)
        state.downloads[id] = Data("Cached bytes".utf8)
        state.transcripts[PreviewFixtures.sessionID] = [transcriptItem(id: "retained", turn: 1, text: "History")]
        try SQLiteGianStorage(directory: directory).save(state, scope: scope)
        try mutateTemporaryDatabase(directory, sql: "UPDATE components SET sha256='corrupt' WHERE kind='download'")
        let restored = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(restored.downloads.isEmpty)
        #expect(restored.transcripts == state.transcripts)
        #expect(restored.cursor == state.cursor)
    }

    @Test func retainedCorruptionFailsClosedWithoutOverwritingData() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        try SQLiteGianStorage(directory: directory).save(retainedFixture(), scope: scope)
        try mutateTemporaryDatabase(directory, sql: "UPDATE retained SET sha256='corrupt'")
        let reopened = try SQLiteGianStorage(directory: directory)
        #expect(throws: GianStorageError.corruptData) { _ = try reopened.load(scope: scope) }
        #expect(throws: GianStorageError.corruptData) { try reopened.save(StoredHostState(), scope: scope) }
    }

    @Test func initialLastAppliedSentinelSurvivesReopen() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        var state = retainedFixture()
        state.cursor?.eventSequence = -1
        try SQLiteGianStorage(directory: directory).save(state, scope: scope)
        let restored = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(restored.cursor?.eventSequence == -1)
        #expect(CanonicalSequence.advance(last: restored.cursor?.eventSequence, incoming: 0) == .next)
    }

    @Test func writerRejectsAStateThatWouldExceedItsColdRestoreBudget() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let storage = try SQLiteGianStorage(directory: directory)
        storage.retainedByteLimit = 20_000
        var state = retainedFixture()
        state.transcripts[PreviewFixtures.sessionID] = [transcriptItem(id: "within-budget", turn: 1, text: String(repeating: "x", count: 8_000))]
        try storage.save(state, scope: scope)
        state.transcripts[PreviewFixtures.sessionID]?.append(transcriptItem(id: "over-budget", turn: 2, text: String(repeating: "y", count: 16_000)))
        #expect(throws: GianStorageError.unavailable) { try storage.save(state, scope: scope) }
        let reopened = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(reopened.transcripts[PreviewFixtures.sessionID]?.count == 1)
        #expect(reopened.transcripts[PreviewFixtures.sessionID]?.first?.id.rawValue == "within-budget")
    }

    @Test func droppingHotScopeCopiesDoesNotDeleteRetainedRows() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let scopes = (0..<4).map { fictionalScope(host: PreviewFixtures.id("cache-host-\($0)", HostID.self)) }
        for (index, scope) in scopes.enumerated() {
            var state = StoredHostState()
            state.catalogRevision = "revision-\(index)"
            try storage.save(state, scope: scope)
        }
        for (index, scope) in scopes.enumerated() {
            #expect(try storage.load(scope: scope)?.catalogRevision == "revision-\(index)")
        }
        var changed = try #require(try storage.load(scope: scopes[0]))
        changed.catalogRevision = "updated"
        try storage.save(changed, scope: scopes[0])
        #expect(try SQLiteGianStorage(directory: directory).load(scope: scopes[0])?.catalogRevision == "updated")
    }

    @Test func dirtyScopesSurviveMemoryDiscardUntilExplicitCommit() throws {
        let storage = InMemoryGianStorage()
        let memory = ScopedMemory(storage: storage)
        let scope = fictionalScope()
        try memory.load(scope)
        memory.update(scope) { $0.catalogRevision = "not-yet-committed" }
        memory.discardCommitted()
        #expect(memory.bundle(for: scope).catalogRevision == "not-yet-committed")
        #expect(try storage.load(scope: scope) == nil)
        try memory.flushDirty()
        memory.discardCommitted()
        try memory.load(scope)
        #expect(memory.bundle(for: scope).catalogRevision == "not-yet-committed")
    }
}
