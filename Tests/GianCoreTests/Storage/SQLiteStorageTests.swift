import Foundation
import CSQLite
import Testing
@testable import GianCore

@MainActor
private final class RetentionYieldGate {
    var continuation: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            observer?.resume(); observer = nil
        }
    }
    func untilWaiting() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class RetentionEpochService: ControlledService, GianClientEventSource {
    var eventEpoch = 0
}

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
    @Test func expiryTimerRearmsAcrossRepeatedServiceEpochChanges() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "expiry-epoch", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState(); seed.sessions = [old]
        seed.transcripts[old.id] = [transcriptItem(id: "expiry-epoch-item", turn: 1, text: "Old")]
        try storage.save(seed, scope: scope)
        let clock = ManualGianClock(instant: now)
        let memory = ScopedMemory(storage: storage, retentionClock: clock)
        try memory.load(scope); try memory.commit(scope)
        var active = old; active.lastActivityAt = now
        memory.noteRetentionActivity(active, scope: scope, at: now)
        memory.update(scope) { $0.sessions = [] }; try memory.commit(scope)
        let service = RetentionEpochService()
        let store = GianClientStore(service: service, clock: clock, storage: try SQLiteGianStorage(directory: directory))
        let gates = [RetentionYieldGate(), RetentionYieldGate(), RetentionYieldGate()]
        var count = 0
        store.retentionExpirySleep = { _ in
            let gate = gates[count]; count += 1
            await gate.wait()
        }
        store.retentionRecoveryYield = { await Task.yield() }
        #expect(store.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        store.synchronizeServiceEpoch()
        await gates[0].untilWaiting()
        let oldTask = try #require(store.retentionExpiryTask)
        let deadline = store.retentionExpiryDeadline
        service.eventEpoch += 1; store.synchronizeServiceEpoch()
        await gates[1].untilWaiting()
        let secondTask = try #require(store.retentionExpiryTask)
        let secondGeneration = store.retentionExpiryGeneration
        #expect(store.retentionExpiryDeadline == deadline)
        gates[0].resume(); await oldTask.value
        #expect(store.retentionExpiryGeneration == secondGeneration)
        #expect(store.retentionExpiryTask != nil)
        service.eventEpoch += 1; store.synchronizeServiceEpoch()
        await gates[2].untilWaiting()
        let current = try #require(store.retentionExpiryTask)
        let currentGeneration = store.retentionExpiryGeneration
        gates[1].resume(); await secondTask.value
        #expect(store.retentionExpiryGeneration == currentGeneration)
        #expect(store.retentionExpiryEpoch == store.epoch)
        clock.instant = now.addingTimeInterval(7 * 24 * 60 * 60 + 2)
        gates[2].resume(); await current.value
        if let cleanup = store.retentionRecoveryTasks[scope] { await cleanup.value }
        #expect(try transcriptRowCount(directory, owner: old.id) == 0)
        #expect(try SQLiteGianStorage(directory: directory).load(scope: scope)?.retentionCleanup == nil)
    }
    @Test func renewedTailRestoresOnlyMatchingVerifiedReadingTranslation() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = PreviewFixtures.instant
        let scope = fictionalScope()
        let old = makeSession(id: "translated-tail", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        func assistant(_ id: String, turn: Int, text: String) -> TranscriptItem {
            TranscriptItem(id: PreviewFixtures.id(id, TranscriptItemID.self),
                turnID: PreviewFixtures.id("translation-turn-\(turn)", TurnID.self), turn: turn,
                timestamp: now, body: .assistant(text: text, delta: false))
        }
        func reading(_ id: String, source: String, sourceText: String, language: String, text: String) -> ReadingTranslation {
            TranslationReducer.verifiedRecord(id: PreviewFixtures.id(id, TranslationRecordID.self),
                sourceID: source, targetLanguage: language, text: text, textLength: text.utf16.count,
                textSHA256: SHA256Hex.digest(Data(text.utf8)), sourceSHA256: SHA256Hex.digest(Data(sourceText.utf8)), paged: false)
        }
        let oldItem = assistant("translation-old", turn: 1, text: "Old result")
        let oldRecord = reading("translation-old-record", source: "turn:1", sourceText: "Old result", language: "zh-CN", text: "Old translation")
        var state = StoredHostState(); state.sessions = [old]
        state.transcripts[old.id] = [oldItem] + (2..<45).map { assistant("translation-old-\($0)", turn: $0, text: "Old \($0)") }
        // Reading records are kept for the reading language, not the sending one.
        var translation = translationState(revision: 1, configRevision: 1, readingLanguage: "zh-CN")
        translation.records = [oldRecord]; state.translations[old.id] = translation
        let storage = try SQLiteGianStorage(directory: directory)
        try storage.save(state, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope); try memory.commit(scope)
        let first = try #require(try memory.retentionWorkSnapshot(scope))
        let refs = first.0.retentionWorkReferences(stored: first.1, evicted: first.4, now: first.5)
        #expect(try memory.retentionStep(scope, generation: first.2, memoryGeneration: first.3,
                                        protected: refs.0, protectedSessions: refs.1, holdDownloads: refs.2) == .more)
        let fresh = assistant("translation-fresh", turn: 100, text: "New result")
        let valid = reading("translation-valid", source: "turn:100", sourceText: "New result", language: "zh-CN", text: "New translation")
        let wrongSource = reading("translation-wrong-source", source: "turn:101", sourceText: "New result", language: "zh-CN", text: "Wrong source")
        let wrongHash = reading("translation-wrong-hash", source: "turn:100", sourceText: "Different", language: "zh-CN", text: "Wrong hash")
        let wrongLanguage = reading("translation-wrong-language", source: "turn:100", sourceText: "New result", language: "fr", text: "Wrong language")
        var tampered = valid
        tampered.id = PreviewFixtures.id("translation-tampered", TranslationRecordID.self)
        tampered.presentableText = "Changed bytes"
        memory.update(scope) {
            $0.transcripts[old.id] = TranscriptLog.merge(existing: $0.transcripts[old.id] ?? [], incoming: [fresh])
            $0.translations[old.id]?.records += [valid, wrongSource, wrongHash, wrongLanguage, tampered]
        }
        var active = old; active.lastActivityAt = now
        memory.noteRetentionActivity(active, scope: scope, at: now)
        memory.noteRetentionItems([fresh], session: old.id, scope: scope)
        try memory.commit(scope)
        let restored = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(restored.transcripts[old.id]?.map(\.id) == [fresh.id])
        #expect(restored.translations[old.id]?.records.map(\.id) == [valid.id])
        #expect(restored.translations[old.id]?.records.first?.presentableText == "New translation")
        let service = DirectoryFixtureService()
        service.transcriptPages = [TranscriptPageResponse(items: [fresh], cursor: nil, hasOlder: false)]
        let store = GianClientStore(service: service, clock: ManualGianClock(instant: now),
                                    storage: try SQLiteGianStorage(directory: directory))
        #expect(store.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: ManualGianClock(instant: now))).isApplied)
        #expect((await store.dispatch(.selectConversation(old.id))).isApplied)
        let after = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(after.translations[old.id]?.records.map(\.id) == [valid.id])
        #expect(after.transcriptCursors[old.id]?.catchUp == nil)
    }
    @Test func verifiedTailKeepsNewestAcrossOlderPagesAndStreaming() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = PreviewFixtures.instant
        let scope = fictionalScope()
        let old = makeSession(id: "ordered-tail", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState(); seed.sessions = [old]
        seed.transcripts[old.id] = (0..<100).map { transcriptItem(id: "order-old-\($0)", turn: $0, text: "Old") }
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope); try memory.commit(scope)
        let latest = (1_000..<1_005).map { transcriptItem(id: "order-new-\($0)", turn: $0, text: "Latest") }
        memory.update(scope) { $0.transcripts[old.id] = TranscriptLog.merge(existing: $0.transcripts[old.id] ?? [], incoming: latest) }
        var active = old; active.lastActivityAt = now
        memory.noteRetentionActivity(active, scope: scope, at: now)
        memory.noteRetentionItems(latest, session: old.id, scope: scope)
        try memory.commit(scope)
        for group in 0..<3 {
            let page = (0..<80).reversed().map { transcriptItem(id: "order-page-\(group)-\($0)", turn: group * 80 + $0, text: "Older") }
            memory.update(scope) { $0.transcripts[old.id] = TranscriptLog.merge(existing: $0.transcripts[old.id] ?? [], incoming: page + [latest[0], latest[0]]) }
            memory.noteRetentionItems(page + [latest[0], latest[0]], session: old.id, scope: scope)
            try memory.commit(scope)
        }
        let streaming = TranscriptItem(id: PreviewFixtures.id("order-stream", TranscriptItemID.self),
            turnID: PreviewFixtures.id("order-stream-turn", TurnID.self), turn: 1_200, timestamp: now,
            body: .assistant(text: "A", delta: false))
        memory.update(scope) { $0.transcripts[old.id] = TranscriptLog.applyingLive(existing: $0.transcripts[old.id] ?? [], item: streaming)! }
        memory.noteRetentionItems([streaming], session: old.id, scope: scope)
        var delta = streaming; delta.body = .assistant(text: "B", delta: true)
        memory.update(scope) { $0.transcripts[old.id] = TranscriptLog.applyingLive(existing: $0.transcripts[old.id] ?? [], item: delta)! }
        memory.noteRetentionItems([delta], session: old.id, scope: scope)
        try memory.commit(scope)
        let loaded = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        let items = try #require(loaded.transcripts[old.id])
        #expect(Set(latest.map(\.id)).isSubset(of: Set(items.map(\.id))))
        #expect(items.filter { $0.id == streaming.id }.count == 1)
        #expect(items.contains { $0.id == streaming.id && $0.body == .assistant(text: "AB", delta: false) })
        #expect(loaded.transcriptCursors[old.id]?.hasOlder == true)
        #expect(loaded.transcriptCursors[old.id]?.catchUp != nil)
    }
    @Test func draftAndNonActivityMetadataDoNotSupersedeRetention() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "nonactivity-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old]
        seed.transcripts[old.id] = [transcriptItem(id: "nonactivity-item", turn: 1, text: "History")]
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        try memory.commit(scope)
        let draft = DraftDocument(id: PreviewFixtures.id("nonactivity-draft", DraftID.self), hostID: scope.host,
                                  target: .conversation(old.id), text: "Typing", attachments: [], updatedAt: now)
        memory.update(scope) {
            $0.drafts = [draft]
            $0.sessions[0].lastActivityAt = now
            $0.sessions[0].activityIsMessageOrExecution = false
        }
        try memory.commit(scope)
        let saved = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(saved.retentionSupersededSessions?.contains(old.id) != true)
        #expect(saved.transcripts[old.id] == nil)
        #expect(saved.drafts == [draft])
        memory.update(scope) {
            $0.sessions[0].lastActivityAt = now.addingTimeInterval(-7 * 24 * 60 * 60 - 1)
            $0.sessions[0].activityIsMessageOrExecution = true
        }
        try memory.commit(scope)
        let stillOld = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(stillOld.retentionSupersededSessions?.contains(old.id) != true)
    }

    @Test func protectedOwnerDoesNotStallOtherHistoryAndSharedBytesSurviveRestart() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let a = makeSession(id: "a-protected", title: "A", taskID: nil, activity: old)
        let b = makeSession(id: "b-eligible", title: "B", taskID: nil, activity: old)
        let c = makeSession(id: "c-eligible", title: "C", taskID: nil, activity: old)
        let shared = PreviewFixtures.id("zz-shared-cache", AttachmentID.self)
        func message(_ raw: String, attachments: [AttachmentID] = []) -> TranscriptItem {
            TranscriptItem(id: PreviewFixtures.id(raw, TranscriptItemID.self),
                turnID: PreviewFixtures.id("owner-test-turn", TurnID.self), turn: 1, timestamp: old,
                body: .user(text: "History", deliveryID: nil, attachmentIDs: attachments, translation: nil))
        }
        var seed = StoredHostState()
        seed.sessions = [a, b, c]
        seed.transcripts[a.id] = (0..<40).map { message(String(format: "a-item-%03d", $0)) } + [message("a-zz-shared", attachments: [shared])]
        seed.transcripts[b.id] = [message("b-item", attachments: [shared])]
        seed.transcripts[c.id] = [message("c-item")]
        for index in 0..<129 { seed.downloads[PreviewFixtures.id(String(format: "filler-%03d", index), AttachmentID.self)] = Data("x".utf8) }
        seed.downloads[shared] = Data("x".utf8)
        let storage = try SQLiteGianStorage(directory: directory)
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        #expect(memory.bundle(for: scope).downloads[shared] == nil)
        try memory.commit(scope)
        let first = try #require(try memory.retentionWorkSnapshot(scope))
        let refs = first.0.retentionWorkReferences(stored: first.1, evicted: first.4, now: first.5)
        #expect(try memory.retentionStep(scope, generation: first.2, memoryGeneration: first.3,
                                        protected: refs.0, protectedSessions: refs.1, holdDownloads: refs.2) == .more)
        await Task.yield()
        let draftID = PreviewFixtures.id("a-pending-draft", DraftID.self)
        let draft = DraftDocument(id: draftID, hostID: scope.host, target: .conversation(a.id), text: "Keep",
                                  attachments: [], updatedAt: now)
        let uncertain = DurableSendIntent(draftID: draftID, stage: .send, sessionID: a.id)
        memory.update(scope) { $0.drafts = [draft]; $0.operations[draftID] = .uncertain(uncertain) }
        try memory.commit(scope)
        let reopenedStorage = try SQLiteGianStorage(directory: directory)
        let reopened = ScopedMemory(storage: reopenedStorage, retentionClock: ManualGianClock(instant: now))
        try reopened.load(scope)
        await Task.yield()
        try drainRetention(reopened, scope: scope)
        #expect(try transcriptRowCount(directory, owner: a.id) > 0)
        #expect(try transcriptRowCount(directory, owner: b.id) == 0)
        #expect(try transcriptRowCount(directory, owner: c.id) == 0)
        #expect(try downloadRowCount(directory, item: shared.rawValue) == 1)
        let paused = try #require(try reopenedStorage.load(scope: scope))
        #expect(paused.transcripts[a.id] == nil)
        #expect(paused.operations[draftID] == .uncertain(uncertain))
        reopened.update(scope) { $0.drafts = []; $0.operations[draftID] = nil }
        try reopened.commit(scope)
        try drainRetention(reopened, scope: scope)
        #expect(try transcriptRowCount(directory, owner: a.id) == 0)
        #expect(try reopenedStorage.load(scope: scope)?.retentionCleanup == nil)
    }
    @Test func renewedActivitySupersedesPartialLargeCleanupWithoutReinsertingHistory() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "renewed-large", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let other = makeSession(id: "z-renewal-other", title: "Other", taskID: nil,
                                activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old, other]
        seed.transcripts[old.id] = (0..<2_500).map { transcriptItem(id: "renewed-item-\($0)", turn: $0, text: "History") }
        seed.transcripts[other.id] = [transcriptItem(id: "renewal-other-item", turn: 1, text: "Other")]
        try storage.save(seed, scope: scope)
        seed.transcripts[old.id]?.append(contentsOf: (2_500..<5_001).map { transcriptItem(id: "renewed-item-\($0)", turn: $0, text: "History") })
        try storage.save(seed, scope: scope)
        let clock = ManualGianClock(instant: now)
        let memory = ScopedMemory(storage: storage, retentionClock: clock)
        try memory.load(scope)
        try memory.commit(scope)
        let first = try #require(try memory.retentionWorkSnapshot(scope))
        let refs = first.0.retentionWorkReferences(stored: first.1, evicted: first.4, now: first.5)
        #expect(try memory.retentionStep(scope, generation: first.2, memoryGeneration: first.3,
                                        protected: refs.0, protectedSessions: refs.1, holdDownloads: refs.2) == .more)
        let beforeActivity = try #require(try memory.retentionWorkSnapshot(scope))
        let beforeRefs = beforeActivity.0.retentionWorkReferences(stored: beforeActivity.1, evicted: beforeActivity.4, now: beforeActivity.5)
        let remainingBeforeActivity = try transcriptRowCount(directory, owner: old.id)
        let draftID = PreviewFixtures.id("renewed-draft", DraftID.self)
        let attachmentID = PreviewFixtures.id("renewed-unsent", AttachmentID.self)
        let bytes = Data("draft".utf8)
        let attachment = DraftAttachment(id: attachmentID, filename: "draft.txt", mime: "text/plain", byteCount: bytes.count,
                                         sha256: SHA256Hex.digest(bytes), state: .localOnly)
        let draft = DraftDocument(id: draftID, hostID: scope.host, target: .conversation(old.id), text: "Unsent",
                                  attachments: [attachment], updatedAt: now)
        let intent = DurableSendIntent(draftID: draftID, stage: .send, sessionID: old.id)
        memory.update(scope) {
            $0.sessions[0].lastActivityAt = now
            $0.sessions[0].activityIsMessageOrExecution = true
            $0.transcripts[old.id]?.append(transcriptItem(id: "renewed-new", turn: 5_001, text: "New activity", at: now))
        }
        var authoritative = old
        authoritative.lastActivityAt = now
        authoritative.activityIsMessageOrExecution = true
        memory.noteRetentionActivity(authoritative, scope: scope, at: now)
        memory.noteRetentionItems([transcriptItem(id: "renewed-new", turn: 5_001, text: "New activity", at: now)],
                                  session: old.id, scope: scope)
        // A stale projection arriving before persistence must not erase the event fence.
        memory.update(scope) { $0.sessions[0] = old }
        #expect(try memory.retentionStep(scope, generation: beforeActivity.2, memoryGeneration: beforeActivity.3,
                                        protected: beforeRefs.0, protectedSessions: beforeRefs.1, holdDownloads: beforeRefs.2) == .stale)
        let uncommitted = try #require(try memory.retentionWorkSnapshot(scope))
        let liveRefs = uncommitted.0.retentionWorkReferences(stored: uncommitted.1, evicted: uncommitted.4, now: uncommitted.5)
        #expect(liveRefs.1.contains(old.id))
        _ = try memory.retentionStep(scope, generation: uncommitted.2, memoryGeneration: uncommitted.3,
                                     protected: liveRefs.0, protectedSessions: liveRefs.1, holdDownloads: liveRefs.2)
        #expect(try transcriptRowCount(directory, owner: old.id) == remainingBeforeActivity)
        memory.update(scope) {
            $0.drafts = [draft]; $0.submittedDrafts[draftID] = draft
            $0.draftBytes[attachmentID] = bytes; $0.operations[draftID] = .uncertain(intent)
        }
        try memory.commit(scope)
        try drainRetention(memory, scope: scope)
        #expect(try transcriptRowCount(directory, owner: other.id) == 0)
        let reopened = try SQLiteGianStorage(directory: directory)
        let hidden = try #require(try reopened.load(scope: scope))
        #expect(hidden.transcripts[old.id]?.map(\.id.rawValue) == ["renewed-new"])
        #expect(hidden.transcriptCursors[old.id]?.hasOlder == true)
        #expect(hidden.transcriptCursors[old.id]?.catchUp != nil)
        #expect(hidden.retentionSupersededSessions?.contains(old.id) == true)
        #expect(hidden.operations[draftID] == .uncertain(intent))
        #expect(hidden.draftBytes[attachmentID] == bytes)
        #expect(try transcriptItemCount(directory, owner: old.id, item: "renewed-new") == 1)
        let restarted = ScopedMemory(storage: reopened, retentionClock: clock)
        try restarted.load(scope)
        restarted.update(scope) {
            $0.catalogRevision = "after-restart"
            if let index = $0.sessions.firstIndex(where: { $0.id == old.id }) {
                $0.sessions[index].lastActivityAt = old.lastActivityAt
            }
        }
        try restarted.commit(scope)
        let saved = try #require(try reopened.load(scope: scope))
        #expect(saved.catalogRevision == "after-restart")
        #expect(saved.transcripts[old.id]?.map(\.id.rawValue) == ["renewed-new"])
        #expect(saved.retentionSupersededSessions?.contains(old.id) == true)
        #expect(saved.operations[draftID] == .uncertain(intent))
        #expect(saved.draftBytes[attachmentID] == bytes)
        #expect(try transcriptItemCount(directory, owner: old.id, item: "renewed-new") == 1)
        let page = [transcriptItem(id: "renewed-host", turn: 5_000, text: "Host page", at: now),
                    transcriptItem(id: "renewed-new", turn: 5_001, text: "New activity", at: now)]
        let service = DirectoryFixtureService()
        service.transcriptPages = [TranscriptPageResponse(items: page, cursor: nil, hasOlder: false)]
        let store = GianClientStore(service: service, clock: clock, storage: reopened)
        #expect(store.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect((await store.dispatch(.selectConversation(old.id))).isApplied)
        let hydrated = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(Set(hydrated.transcripts[old.id]?.map(\.id.rawValue) ?? []) == Set(["renewed-host", "renewed-new"]))
        #expect(hydrated.transcriptCursors[old.id]?.hasOlder == true)
        #expect(hydrated.transcriptCursors[old.id]?.catchUp == nil)
        #expect(hydrated.operations[draftID] == .uncertain(intent))
        #expect(hydrated.draftBytes[attachmentID] == bytes)
    }

    @Test func durableRenewalExpiryWakesWithoutVisibleSessionOrUserWrite() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "expiry-watermark", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old]
        seed.transcripts[old.id] = (0..<40).map { transcriptItem(id: "expiry-\($0)", turn: $0, text: "Old") }
        try storage.save(seed, scope: scope)
        let clock = ManualGianClock(instant: now)
        let memory = ScopedMemory(storage: storage, retentionClock: clock)
        try memory.load(scope)
        try memory.commit(scope)
        var active = old; active.lastActivityAt = now
        memory.noteRetentionActivity(active, scope: scope, at: now)
        memory.update(scope) { $0.sessions = [] }
        try memory.commit(scope)
        let reopened = try SQLiteGianStorage(directory: directory)
        let gate = RetentionYieldGate()
        let store = GianClientStore(service: DirectoryFixtureService(), clock: clock, storage: reopened)
        store.retentionExpirySleep = { _ in await gate.wait() }
        store.retentionRecoveryYield = { await Task.yield() }
        #expect(store.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        await gate.untilWaiting()
        let timer = try #require(store.retentionExpiryTask)
        clock.instant = now.addingTimeInterval(7 * 24 * 60 * 60 + 2)
        gate.resume()
        await timer.value
        if let cleanup = store.retentionRecoveryTasks[scope] { await cleanup.value }
        let result = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(result.retentionCleanup == nil)
        #expect(result.retentionRenewedActivity == nil)
        #expect(try transcriptRowCount(directory, owner: old.id) == 0)
    }

    @Test func retentionExpiryIsCancelledInBackgroundAndRestoredOnForeground() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "expiry-background", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState(); seed.sessions = [old]
        seed.transcripts[old.id] = [transcriptItem(id: "expiry-background-item", turn: 1, text: "Old")]
        try storage.save(seed, scope: scope)
        let clock = ManualGianClock(instant: now)
        let memory = ScopedMemory(storage: storage, retentionClock: clock)
        try memory.load(scope); try memory.commit(scope)
        var active = old; active.lastActivityAt = now
        memory.noteRetentionActivity(active, scope: scope, at: now)
        memory.update(scope) { $0.sessions = [] }; try memory.commit(scope)
        let store = GianClientStore(service: DirectoryFixtureService(), clock: clock,
                                    storage: try SQLiteGianStorage(directory: directory))
        let first = RetentionYieldGate()
        store.retentionExpirySleep = { _ in await first.wait() }
        #expect(store.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        await first.untilWaiting()
        let cancelled = try #require(store.retentionExpiryTask)
        _ = await store.dispatch(.setForeground(.background))
        clock.instant = now.addingTimeInterval(7 * 24 * 60 * 60 + 2)
        first.resume(); await cancelled.value
        #expect(try transcriptRowCount(directory, owner: old.id) == 1)
        store.retentionRecoveryYield = { await Task.yield() }
        _ = await store.dispatch(.setForeground(.foreground))
        if let cleanup = store.retentionRecoveryTasks[scope] { await cleanup.value }
        #expect(try transcriptRowCount(directory, owner: old.id) == 0)
        #expect(store.logout().isApplied)
        #expect(store.retentionExpiryTask == nil)
    }

    @Test func retentionExpiryDoesNotMutateLoggedOutScope() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "expiry-logout", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState(); seed.sessions = [old]
        seed.transcripts[old.id] = [transcriptItem(id: "expiry-logout-item", turn: 1, text: "Old")]
        try storage.save(seed, scope: scope)
        let clock = ManualGianClock(instant: now)
        let memory = ScopedMemory(storage: storage, retentionClock: clock)
        try memory.load(scope); try memory.commit(scope)
        var active = old; active.lastActivityAt = now
        memory.noteRetentionActivity(active, scope: scope, at: now)
        memory.update(scope) { $0.sessions = [] }; try memory.commit(scope)
        let store = GianClientStore(service: DirectoryFixtureService(), clock: clock,
                                    storage: try SQLiteGianStorage(directory: directory))
        let gate = RetentionYieldGate()
        store.retentionExpirySleep = { _ in await gate.wait() }
        #expect(store.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        await gate.untilWaiting()
        let timer = try #require(store.retentionExpiryTask)
        #expect(store.logout().isApplied)
        clock.instant = now.addingTimeInterval(7 * 24 * 60 * 60 + 2)
        gate.resume(); await timer.value
        #expect(try transcriptRowCount(directory, owner: old.id) == 1)
        #expect(store.retentionExpiryTask == nil)
    }
    @Test func cooperativeRetentionYieldsAndNewProtectionPausesWithoutExposingPartialHistory() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let service = DirectoryFixtureService(); service.pages[.tasks] = [directoryPage(.tasks)]
        let now = PreviewFixtures.instant
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let aging = makeSession(id: "yield-old", title: "Old", taskID: nil, activity: now.addingTimeInterval(-24 * 60 * 60))
        store.sessions.append(aging)
        store.memory.update(scope) {
            $0.transcripts[aging.id] = (0..<600).map { transcriptItem(id: "yield-item-\($0)", turn: $0, text: "History") }
        }
        #expect(store.persist())
        clock.instant = now.addingTimeInterval(8 * 24 * 60 * 60)
        let gate = RetentionYieldGate()
        store.retentionRecoveryYield = { await gate.wait() }
        #expect(store.persist())
        await gate.untilWaiting()
        #expect(gate.continuation != nil)
        let stale = try #require(try store.memory.retentionWorkSnapshot(scope))
        let staleRefs = stale.0.retentionWorkReferences(stored: stale.1, evicted: stale.4, now: stale.5)
        store.state.composer.draft.target = .conversation(aging.id)
        store.state.composer.draft.boundSessionID = aging.id
        store.state.composer.draft.text = "Keep this draft"
        let draftID = store.state.composer.draft.id
        let intent = DurableSendIntent(draftID: draftID, stage: .send, sessionID: aging.id)
        store.state.composer.send = .uncertain(intent)
        store.rememberDraft()
        #expect(store.persist())
        #expect(try store.memory.retentionStep(scope, generation: stale.2, memoryGeneration: stale.3,
                                              protected: staleRefs.0, protectedSessions: staleRefs.1, holdDownloads: staleRefs.2) == .stale)
        let paused = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(paused.transcripts[aging.id] == nil)
        #expect(paused.operations[draftID] == .uncertain(intent))
        #expect(paused.drafts.contains { $0.id == draftID && $0.text == "Keep this draft" })
        #expect(store.memory.bundle(for: scope).transcripts[aging.id]?.count == 600)
        store.retentionRecoveryYield = { await Task.yield() }
        let pausedTask = try #require(store.retentionRecoveryTasks[scope])
        gate.resume()
        await pausedTask.value
        #expect(store.retentionRecoveryTasks[scope] == nil)
        if let _ = try store.memory.retentionWorkSnapshot(scope) { Issue.record("Protected cleanup should be paused") }
        store.state.composer.send = .idle
        store.state.composer.draft.text = ""
        store.state.composer.draft.target = .newConversation
        store.state.composer.draft.boundSessionID = nil
        store.sessions.removeAll { $0.id == aging.id }
        store.rememberDraft()
        #expect(store.persist())
        let resumedTask = try #require(store.retentionRecoveryTasks[scope])
        await resumedTask.value
        #expect(store.retentionRecoveryTasks[scope] == nil)
        let cleaned = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(cleaned.transcripts[aging.id] == nil)
        #expect(cleaned.retentionCleanup == nil)
    }

    @Test func logoutCancelsScopedCleanupAndRestartResumesItsBarrier() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let service = DirectoryFixtureService(); service.pages[.tasks] = [directoryPage(.tasks)]
        let now = PreviewFixtures.instant
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let aging = makeSession(id: "logout-old", title: "Old", taskID: nil, activity: now.addingTimeInterval(-24 * 60 * 60))
        store.sessions.append(aging)
        store.memory.update(scope) {
            $0.transcripts[aging.id] = (0..<600).map { transcriptItem(id: "logout-item-\($0)", turn: $0, text: "History") }
        }
        #expect(store.persist())
        clock.instant = now.addingTimeInterval(8 * 24 * 60 * 60)
        let gate = RetentionYieldGate()
        store.retentionRecoveryYield = { await gate.wait() }
        var chunks = 0
        storage.beforeRetentionChunkCommit = { chunks += 1 }
        #expect(store.persist())
        await gate.untilWaiting()
        let task = try #require(store.retentionRecoveryTasks[scope])
        _ = await store.dispatch(.logout)
        gate.resume()
        await task.value
        #expect(chunks == 1)
        let reopened = try SQLiteGianStorage(directory: directory)
        let memory = ScopedMemory(storage: reopened, retentionClock: clock)
        try memory.load(scope)
        #expect(memory.bundle(for: scope).transcripts[aging.id] == nil)
        #expect(memory.bundle(for: scope).retentionCleanup != nil)
        try drainRetention(memory, scope: scope)
        #expect(try reopened.load(scope: scope)?.retentionCleanup == nil)
    }

    @Test func externalProtectionChangeFencesAStaleCleanupAndSave() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "external-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let first = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old]
        seed.transcripts[old.id] = [transcriptItem(id: "external-item", turn: 1, text: "History")]
        try first.save(seed, scope: scope)
        let memory = ScopedMemory(storage: first, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        try memory.commit(scope)
        let stale = try #require(try memory.retentionWorkSnapshot(scope))
        let refs = stale.0.retentionWorkReferences(stored: stale.1, evicted: stale.4, now: stale.5)
        let second = try SQLiteGianStorage(directory: directory)
        var current = try #require(try second.load(scope: scope))
        let draft = DraftDocument(id: PreviewFixtures.id("external-draft", DraftID.self), hostID: scope.host,
                                  target: .conversation(old.id), text: "Keep", attachments: [], updatedAt: now)
        current.drafts = [draft]
        try second.save(current, scope: scope)
        #expect(try memory.retentionStep(scope, generation: stale.2, memoryGeneration: stale.3,
                                        protected: refs.0, protectedSessions: refs.1, holdDownloads: refs.2) == .stale)
        #expect(throws: GianStorageError.concurrentMutation) { try memory.commit(scope) }
        let restored = try #require(try second.load(scope: scope))
        #expect(restored.drafts == [draft])
        #expect(restored.transcripts[old.id] == nil)
        #expect(restored.retentionCleanup != nil)
    }
    private func drainRetention(_ memory: ScopedMemory, scope: ClientScope) throws {
        for _ in 0..<10_000 {
            guard let (snapshot, stored, generation, memoryGeneration, evicted, now) = try memory.retentionWorkSnapshot(scope) else { return }
            let (protected, protectedSessions, holdDownloads) = snapshot.retentionWorkReferences(stored: stored, evicted: evicted, now: now)
            let result = try memory.retentionStep(scope, generation: generation, memoryGeneration: memoryGeneration,
                                                  protected: protected, protectedSessions: protectedSessions, holdDownloads: holdDownloads)
            if result == .complete || result == .paused { return }
        }
        Issue.record("Retention did not finish within its bounded test budget")
    }
    @Test func retentionDeletesUnmaterializedDownloadsWithoutRemovingSharedOrUnsentData() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let otherScopes = [
            fictionalScope(host: PreviewFixtures.id("other-host", HostID.self)),
            fictionalScope(account: AccountID(provider: .controller, id: "other-account")!),
            fictionalScope(server: "https://other.fixture.test"),
        ]
        let now = PreviewFixtures.instant
        let old = makeSession(id: "download-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let recent = makeSession(id: "download-recent", title: "Recent", taskID: nil, activity: now)
        let oldID = PreviewFixtures.id("cache-129", AttachmentID.self)
        let sharedID = PreviewFixtures.id("cache-128", AttachmentID.self)
        let unsentID = PreviewFixtures.id("cache-127", AttachmentID.self)
        let ownerOnlyID = PreviewFixtures.id("cache-130", AttachmentID.self)
        let unknownID = PreviewFixtures.id("cache-131", AttachmentID.self)
        let sharedOwnerOnlyID = PreviewFixtures.id("cache-132", AttachmentID.self)
        let orphanUnsentID = PreviewFixtures.id("cache-134", AttachmentID.self)
        func message(_ raw: String, _ attachments: [AttachmentID]) -> TranscriptItem {
            TranscriptItem(id: PreviewFixtures.id(raw, TranscriptItemID.self),
                turnID: PreviewFixtures.id("download-turn", TurnID.self), turn: 1, timestamp: now,
                body: .user(text: "Fixture", deliveryID: nil, attachmentIDs: attachments, translation: nil))
        }
        let bytes = Data("x".utf8)
        let attachment = DraftAttachment(id: unsentID, filename: "draft.txt", mime: "text/plain", byteCount: bytes.count,
                                         sha256: SHA256Hex.digest(bytes), state: .localOnly)
        var seed = StoredHostState()
        seed.sessions = [old, recent]
        seed.transcripts = [old.id: [message("old-download-message", [oldID, sharedID, orphanUnsentID])],
                            recent.id: [message("recent-download-message", [sharedID])]]
        seed.drafts = [DraftDocument(id: PreviewFixtures.id("download-draft", DraftID.self), hostID: scope.host,
                                     target: .conversation(recent.id), text: "Draft", attachments: [attachment], updatedAt: now)]
        seed.draftBytes[unsentID] = bytes
        seed.draftBytes[orphanUnsentID] = bytes
        seed.downloadOwners = [ownerOnlyID: [old.id], sharedID: [old.id, recent.id], sharedOwnerOnlyID: [old.id, recent.id]]
        for index in 0..<135 {
            seed.downloads[PreviewFixtures.id(String(format: "cache-%03d", index), AttachmentID.self)] = bytes
        }
        let storage = try SQLiteGianStorage(directory: directory)
        try storage.save(seed, scope: scope)
        var other = StoredHostState()
        other.downloads[oldID] = bytes
        for otherScope in otherScopes { try storage.save(other, scope: otherScope) }
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        #expect(memory.bundle(for: scope).downloads[oldID] == nil)
        #expect(memory.bundle(for: scope).downloads[sharedID] == nil)
        #expect(memory.bundle(for: scope).downloads[ownerOnlyID] == nil)
        #expect(memory.bundle(for: scope).downloads[unknownID] == nil)
        #expect(memory.bundle(for: scope).downloads[sharedOwnerOnlyID] == nil)
        try memory.commit(scope)
        storage.beforeRetentionChunkCommit = { throw GianStorageError.unavailable }
        let work = try #require(try memory.retentionWorkSnapshot(scope))
        let references = work.0.retentionWorkReferences(stored: work.1, evicted: work.4, now: work.5)
        #expect(throws: GianStorageError.unavailable) {
            _ = try memory.retentionStep(scope, generation: work.2, memoryGeneration: work.3,
                                         protected: references.0, protectedSessions: references.1, holdDownloads: references.2)
        }
        let reopened = try SQLiteGianStorage(directory: directory)
        let reopenedMemory = ScopedMemory(storage: reopened, retentionClock: ManualGianClock(instant: now))
        try reopenedMemory.load(scope)
        try drainRetention(reopenedMemory, scope: scope)
        let restored = try reopened.load(scope: scope)
        #expect(restored?.retentionCleanup == nil)
        #expect(try downloadRowCount(directory, item: oldID.rawValue) == otherScopes.count)
        #expect(try downloadRowCount(directory, item: sharedID.rawValue) == 1)
        #expect(try downloadRowCount(directory, item: ownerOnlyID.rawValue) == 0)
        #expect(try downloadRowCount(directory, item: unknownID.rawValue) == 1)
        #expect(try downloadRowCount(directory, item: sharedOwnerOnlyID.rawValue) == 1)
        #expect(try downloadRowCount(directory, item: orphanUnsentID.rawValue) == 1)
        #expect(restored?.draftBytes[unsentID] == bytes)
        #expect(restored?.draftBytes[orphanUnsentID] == bytes)
        for otherScope in otherScopes {
            #expect(try reopened.load(scope: otherScope)?.downloads[oldID] == bytes)
        }
    }

    private func downloadRowCount(_ directory: URL, item: String) throws -> Int {
        var database: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &database) == SQLITE_OK)
        let opened = try #require(database)
        defer { sqlite3_close_v2(opened) }
        var query: OpaquePointer?
        try #require(sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM components WHERE kind='download' AND item=?", -1, &query, nil) == SQLITE_OK)
        let statement = try #require(query)
        defer { sqlite3_finalize(statement) }
        try #require(item.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }

    private func transcriptRowCount(_ directory: URL, owner: SessionID) throws -> Int {
        var database: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &database) == SQLITE_OK)
        let opened = try #require(database)
        defer { sqlite3_close_v2(opened) }
        var query: OpaquePointer?
        try #require(sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM components WHERE kind='transcript' AND owner=?", -1, &query, nil) == SQLITE_OK)
        let statement = try #require(query)
        defer { sqlite3_finalize(statement) }
        try #require(owner.rawValue.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }

    private func transcriptItemCount(_ directory: URL, owner: SessionID, item: String) throws -> Int {
        var database: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &database) == SQLITE_OK)
        let opened = try #require(database)
        defer { sqlite3_close_v2(opened) }
        var query: OpaquePointer?
        try #require(sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM components WHERE kind='transcript' AND owner=? AND item=?", -1, &query, nil) == SQLITE_OK)
        let statement = try #require(query)
        defer { sqlite3_finalize(statement) }
        try #require(owner.rawValue.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK)
        try #require(item.withCString { sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }

    private func databaseVersion(_ directory: URL) throws -> Int {
        var database: OpaquePointer?
        try #require(sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &database) == SQLITE_OK)
        let opened = try #require(database)
        defer { sqlite3_close_v2(opened) }
        var query: OpaquePointer?
        try #require(sqlite3_prepare_v2(opened, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK)
        let statement = try #require(query)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }
    @Test func retentionCompletesSingleHistoryLargerThanOneChunk() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "large-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old]
        seed.transcripts[old.id] = (0..<1_100).map { transcriptItem(id: "large-item-\($0)", turn: $0, text: "History") }
        var cursor = StoredTranscriptCursor(cursor: "older", hasOlder: true)
        cursor.catchUp = StoredTranscriptCatchUp(anchorIDs: [PreviewFixtures.id("large-item-1099", TranscriptItemID.self)])
        seed.transcriptCursors[old.id] = cursor
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        var chunks = 0
        storage.beforeRetentionChunkCommit = { chunks += 1 }
        try memory.commit(scope)
        let barrier = try SQLiteGianStorage(directory: directory).load(scope: scope)
        #expect(barrier?.transcripts[old.id] == nil)
        #expect(barrier?.retentionCleanup != nil)
        let first = try #require(try memory.retentionWorkSnapshot(scope))
        let references = first.0.retentionWorkReferences(stored: first.1, evicted: first.4, now: first.5)
        #expect(try memory.retentionStep(scope, generation: first.2, memoryGeneration: first.3,
                                         protected: references.0, protectedSessions: references.1, holdDownloads: references.2) == .more)
        let partial = try SQLiteGianStorage(directory: directory).load(scope: scope)
        #expect(partial?.transcripts[old.id] == nil)
        #expect(partial?.retentionCleanup != nil)
        try drainRetention(memory, scope: scope)
        #expect(chunks >= 3)
        let reopened = try SQLiteGianStorage(directory: directory).load(scope: scope)
        #expect(reopened?.transcripts[old.id] == nil)
        #expect(reopened?.transcriptCursors[old.id] == nil)
        #expect(reopened?.retentionCleanup == nil)
    }

    @Test func interruptedMultiSessionRetentionResumesBeforeReload() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let first = makeSession(id: "first-old", title: "First", taskID: nil,
                                activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let second = makeSession(id: "second-old", title: "Second", taskID: nil,
                                 activity: now.addingTimeInterval(-9 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [first, second]
        seed.transcripts[first.id] = (0..<700).map { transcriptItem(id: "first-\($0)", turn: $0, text: "First") }
        seed.transcripts[second.id] = (0..<700).map { transcriptItem(id: "second-\($0)", turn: $0, text: "Second") }
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        var chunks = 0
        storage.beforeRetentionChunkCommit = {
            chunks += 1
            if chunks == 2 { throw GianStorageError.unavailable }
        }
        try memory.commit(scope)
        let firstWork = try #require(try memory.retentionWorkSnapshot(scope))
        let firstRefs = firstWork.0.retentionWorkReferences(stored: firstWork.1, evicted: firstWork.4, now: firstWork.5)
        _ = try memory.retentionStep(scope, generation: firstWork.2, memoryGeneration: firstWork.3,
                                     protected: firstRefs.0, protectedSessions: firstRefs.1, holdDownloads: firstRefs.2)
        let secondWork = try #require(try memory.retentionWorkSnapshot(scope))
        let secondRefs = secondWork.0.retentionWorkReferences(stored: secondWork.1, evicted: secondWork.4, now: secondWork.5)
        #expect(throws: GianStorageError.unavailable) {
            _ = try memory.retentionStep(scope, generation: secondWork.2, memoryGeneration: secondWork.3,
                                         protected: secondRefs.0, protectedSessions: secondRefs.1, holdDownloads: secondRefs.2)
        }
        #expect(chunks == 2)
        #expect(try databaseVersion(directory) == 3)
        let reopenedStorage = try SQLiteGianStorage(directory: directory)
        let reopenedMemory = ScopedMemory(storage: reopenedStorage, retentionClock: ManualGianClock(instant: now))
        try reopenedMemory.load(scope)
        #expect(reopenedMemory.bundle(for: scope).transcripts[first.id] == nil)
        #expect(reopenedMemory.bundle(for: scope).transcripts[second.id] == nil)
        try drainRetention(reopenedMemory, scope: scope)
        let reopened = try reopenedStorage.load(scope: scope)
        #expect(reopened?.transcripts[first.id] == nil)
        #expect(reopened?.transcripts[second.id] == nil)
        #expect(reopened?.retentionCleanup == nil)
        #expect(try databaseVersion(directory) == 3)
    }

    @Test func restoredScopeAutomaticallySchedulesPendingRetention() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "restart-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old]
        seed.transcripts[old.id] = (0..<600).map { transcriptItem(id: "restart-item-\($0)", turn: $0, text: "History") }
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        try memory.commit(scope)
        let first = try #require(try memory.retentionWorkSnapshot(scope))
        let refs = first.0.retentionWorkReferences(stored: first.1, evicted: first.4, now: first.5)
        #expect(try memory.retentionStep(scope, generation: first.2, memoryGeneration: first.3,
                                        protected: refs.0, protectedSessions: refs.1, holdDownloads: refs.2) == .more)
        let reopened = try SQLiteGianStorage(directory: directory)
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: DirectoryFixtureService(), clock: clock, storage: reopened)
        store.retentionRecoveryYield = { await Task.yield() }
        #expect(store.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect(store.state.conversation?.items.contains(where: { $0.id.rawValue.hasPrefix("restart-item-") }) != true)
        let task = try #require(store.retentionRecoveryTasks[scope])
        await task.value
        let final = try #require(try reopened.load(scope: scope))
        #expect(final.transcripts[old.id] == nil)
        #expect(final.retentionCleanup == nil)
    }

    /// Every streamed chunk moves the in-memory bundle generation, so each
    /// cleanup step comes back stale. The cleanup must back off rather than
    /// recompute its references back to back for as long as the stream runs.
    @Test func retentionCleanupBacksOffWhileStreamingKeepsItStale() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        let now = PreviewFixtures.instant
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let aging = makeSession(id: "streaming-old", title: "Aging", taskID: nil, activity: now.addingTimeInterval(-24 * 60 * 60))
        store.sessions.append(aging)
        store.memory.update(scope) {
            $0.transcripts[aging.id] = (0..<600).map { transcriptItem(id: "streaming-item-\($0)", turn: $0, text: "History") }
        }
        #expect(store.persist())
        clock.instant = now.addingTimeInterval(8 * 24 * 60 * 60)
        var streaming = true
        var chunks = 0
        var yields = 0
        var sleeps = 0
        store.retentionRecoveryYield = { yields += 1; await Task.yield() }
        store.retentionRecoverySleep = { _ in sleeps += 1; streaming = false; await Task.yield() }
        let stream = Task { @MainActor in
            while streaming, chunks < 5_000 {
                chunks += 1
                store.memory.update(scope) { $0.catalogRevision = "chunk-\(chunks)" }
                await Task.yield()
            }
        }
        #expect(store.persist())
        let cleanup = try #require(store.retentionRecoveryTasks[scope])
        await cleanup.value
        streaming = false
        await stream.value
        #expect(sleeps >= 1)
        #expect(chunks < 5_000)
        if let next = store.retentionRecoveryTasks[scope] { await next.value }
        #expect(try SQLiteGianStorage(directory: directory).load(scope: scope)?.transcripts[aging.id] == nil)
    }

    @Test func transientRetentionFailureRetriesWithoutAnotherUserWrite() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SQLiteGianStorage(directory: directory)
        let service = DirectoryFixtureService()
        service.pages[.tasks] = [directoryPage(.tasks)]
        let now = PreviewFixtures.instant
        let clock = ManualGianClock(instant: now)
        let store = GianClientStore(service: service, clock: clock, storage: storage)
        _ = try await signIn(store, clock: clock)
        let scope = try clientScope(store)
        let aging = makeSession(id: "retry-old", title: "Aging", taskID: nil, activity: now.addingTimeInterval(-24 * 60 * 60))
        store.sessions.append(aging)
        store.memory.update(scope) {
            $0.transcripts[aging.id] = (0..<600).map { transcriptItem(id: "retry-item-\($0)", turn: $0, text: "History") }
        }
        #expect(store.persist())
        clock.instant = now.addingTimeInterval(8 * 24 * 60 * 60)
        var attempts = 0
        storage.beforeRetentionChunkCommit = {
            attempts += 1
            if attempts == 1 { throw GianStorageError.unavailable }
        }
        store.retentionRecoverySleep = { _ in await Task.yield() }
        #expect(store.persist())
        let task = try #require(store.retentionRecoveryTasks[scope])
        await task.value
        #expect(store.retentionRecoveryTasks[scope] == nil)
        #expect(store.state.storageError == nil)
        #expect(try SQLiteGianStorage(directory: directory).load(scope: scope)?.transcripts[aging.id] == nil)
        #expect(attempts > 1)
    }

    @Test func newlyUncertainSendRestoresProtectionAfterPriorEviction() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "late-protected", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old]
        seed.transcripts[old.id] = [transcriptItem(id: "late-protected-item", turn: 1, text: "History")]
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        try memory.commit(scope)
        #expect(try storage.load(scope: scope)?.transcripts[old.id] == nil)
        let draftID = PreviewFixtures.id("late-protected-draft", DraftID.self)
        let intent = DurableSendIntent(draftID: draftID, stage: .send, sessionID: old.id)
        memory.update(scope) { $0.operations[draftID] = .uncertain(intent) }
        try memory.commit(scope)
        let restored = try SQLiteGianStorage(directory: directory).load(scope: scope)
        #expect(restored?.transcripts[old.id] == nil)
        #expect(restored?.retentionCleanup != nil)
        #expect(restored?.operations[draftID] == .uncertain(intent))
    }

    @Test func newDraftPausesQueuedDownloadUntilReferenceIsReleased() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "download-pause-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let id = PreviewFixtures.id("download-pause-item", AttachmentID.self)
        let bytes = Data("x".utf8)
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old]
        seed.downloads[id] = bytes
        seed.downloadOwners = [id: [old.id]]
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        try memory.commit(scope)
        let attachment = DraftAttachment(id: id, filename: "draft.txt", mime: "text/plain", byteCount: bytes.count,
                                         sha256: SHA256Hex.digest(bytes), state: .localOnly)
        let draft = DraftDocument(id: PreviewFixtures.id("download-pause-draft", DraftID.self), hostID: scope.host,
                                  target: .conversation(old.id), text: "Keep", attachments: [attachment], updatedAt: now)
        memory.update(scope) { $0.drafts = [draft]; $0.draftBytes[id] = bytes }
        try memory.commit(scope)
        let work = try #require(try memory.retentionWorkSnapshot(scope))
        let references = work.0.retentionWorkReferences(stored: work.1, evicted: work.4, now: work.5)
        #expect(try memory.retentionStep(scope, generation: work.2, memoryGeneration: work.3,
                                        protected: references.0, protectedSessions: references.1, holdDownloads: references.2) == .paused)
        #expect(try storage.load(scope: scope)?.draftBytes[id] == bytes)
        #expect(try downloadRowCount(directory, item: id.rawValue) == 1)
        memory.update(scope) { $0.drafts = []; $0.draftBytes[id] = nil }
        try memory.commit(scope)
        try drainRetention(memory, scope: scope)
        #expect(try downloadRowCount(directory, item: id.rawValue) == 0)
    }

    @Test func unchangedExistingDraftDoesNotPermanentlyPinExpiredTranscript() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let now = PreviewFixtures.instant
        let old = makeSession(id: "existing-draft-old", title: "Old", taskID: nil,
                              activity: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let draft = DraftDocument(id: PreviewFixtures.id("existing-draft", DraftID.self), hostID: scope.host,
                                  target: .conversation(old.id), text: "Unsent", attachments: [], updatedAt: now)
        let storage = try SQLiteGianStorage(directory: directory)
        var seed = StoredHostState()
        seed.sessions = [old]; seed.drafts = [draft]
        seed.transcripts[old.id] = [transcriptItem(id: "existing-draft-item", turn: 1, text: "History")]
        try storage.save(seed, scope: scope)
        let memory = ScopedMemory(storage: storage, retentionClock: ManualGianClock(instant: now))
        try memory.load(scope)
        try memory.commit(scope)
        _ = try #require(try memory.retentionWorkSnapshot(scope))
        try drainRetention(memory, scope: scope)
        let restored = try #require(try SQLiteGianStorage(directory: directory).load(scope: scope))
        #expect(restored.transcripts[old.id] == nil)
        #expect(restored.drafts == [draft])
    }
    @Test func translationRecordOrderSurvivesSQLiteReload() throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = fictionalScope()
        let text = "Translated"
        func record(_ raw: String) -> ReadingTranslation {
            TranslationReducer.verifiedRecord(id: PreviewFixtures.id(raw, TranslationRecordID.self), sourceID: "turn:3",
                targetLanguage: "zh", text: text, textLength: text.utf16.count, textSHA256: SHA256Hex.digest(Data(text.utf8)),
                sourceSHA256: SHA256Hex.digest(Data("Answer".utf8)), paged: false)
        }
        let older = record("zzz-older")
        let newer = record("aaa-newer")
        var state = StoredHostState()
        var translation = translationState(revision: 1, configRevision: 1)
        translation.records = [older, newer]
        state.translations[PreviewFixtures.sessionID] = translation
        try SQLiteGianStorage(directory: directory).save(state, scope: scope)
        let restored = try SQLiteGianStorage(directory: directory).load(scope: scope)
        #expect(restored?.translations[PreviewFixtures.sessionID]?.records.map(\.id) == [older.id, newer.id])
    }
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
