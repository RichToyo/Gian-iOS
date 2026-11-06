import Foundation
import Testing
@testable import GianCore

@MainActor
struct TranslationRecoveryTests {
    @Test func canonicalReadingReusesHostRecordAndDoesNotDuplicatePendingWork() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        store.state.conversation?.items = [TranscriptItem(id: PreviewFixtures.id("canonical-item", TranscriptItemID.self),
            turnID: PreviewFixtures.id("canonical-turn", TurnID.self), turn: 3, timestamp: PreviewFixtures.instant,
            body: .assistant(text: "Final answer", delta: false))]
        var translation = translationState(revision: 1, configRevision: 1)
        translation.readingLanguage = "zh"
        translation.automatic["turn:3"] = AutomaticProgress(pending: true)
        store.state.translations[PreviewFixtures.sessionID] = translation
        #expect(await store.dispatch(.requestReadingTranslation(sourceID: "turn:3", text: "Final answer")) == .rejected(.operationInFlight))
        #expect(service.base.translationRequestCount == 0)
        translation.automatic = [:]
        store.state.translations[PreviewFixtures.sessionID] = translation
        #expect(await store.dispatch(.requestReadingTranslation(sourceID: "turn:3", text: "Earlier fragment")) == .rejected(.staleOperation))
        #expect(service.base.translationRequestCount == 0)
        let text = "Translated answer"
        let record = TranslationReducer.verifiedRecord(id: PreviewFixtures.id("canonical-read", TranslationRecordID.self),
            sourceID: "turn:3", targetLanguage: "zh", text: nil, textLength: text.utf16.count,
            textSHA256: SHA256Hex.digest(Data(text.utf8)), sourceSHA256: SHA256Hex.digest(Data("Final answer".utf8)), paged: false)
        translation.records = [record]
        store.state.translations[PreviewFixtures.sessionID] = translation
        #expect((await store.dispatch(.requestReadingTranslation(sourceID: "turn:3", text: "Final answer"))).isApplied)
        service.translationPages = [.page(text: text, nextOffset: nil)]
        #expect((await store.dispatch(.retryTranslationText(record.id))).isApplied)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.records.first?.presentableText == text)
        #expect(service.base.translationRequestCount == 0)
    }

    @Test func canonicalUnknownOutcomeNeverStartsASecondPaidRequest() async throws {
        let service = ControlledService()
        service.base.script.translationUnknown = true
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        store.state.conversation?.items = [TranscriptItem(id: PreviewFixtures.id("canonical-item", TranscriptItemID.self),
            turnID: PreviewFixtures.id("canonical-turn", TurnID.self), turn: 3, timestamp: PreviewFixtures.instant,
            body: .assistant(text: "Final answer", delta: false))]
        store.state.translations[PreviewFixtures.sessionID] = translationState(revision: 1, configRevision: 1)
        _ = await store.dispatch(.requestReadingTranslation(sourceID: "turn:3", text: "Final answer"))
        #expect(service.translationRequest?.sourceID == "turn:3")
        #expect(await store.dispatch(.requestReadingTranslation(sourceID: "turn:3", text: "Final answer")) == .rejected(.uncertainOutcome))
        #expect(service.base.translationRequestCount == 1)
        let requestID = try #require(store.state.translations[PreviewFixtures.sessionID]?.reading["turn:3"]?.requestID)
        let result = "Recovered translation"
        let record = TranslationReducer.verifiedRecord(id: PreviewFixtures.id("canonical-recovered", TranslationRecordID.self),
            sourceID: "turn:3", targetLanguage: "es", text: result, textLength: result.utf16.count,
            textSHA256: SHA256Hex.digest(Data(result.utf8)), sourceSHA256: SHA256Hex.digest(Data("Final answer".utf8)), paged: false)
        service.translationStatus = .settled(requestID, record: record, error: nil)
        #expect((await store.dispatch(.recoverReadingTranslation(sourceID: "turn:3"))).isApplied)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.records.first?.presentableText == result)
        #expect(service.base.translationRequestCount == 1)
    }

    @Test func unknownPaidSendRecoversDescriptorAndPagesTextWithoutAnotherModelCall() async throws {
        let service = ControlledService()
        service.base.script.translationUnknown = true
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let storage = InMemoryGianStorage()
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        store.state.translations[PreviewFixtures.sessionID] = translationState(revision: 1, configRevision: 1)
        _ = await store.dispatch(.editDraftText("Original input"))
        _ = await store.dispatch(.send)
        let intent = try #require(store.state.composer.send.intent)
        let requestID = try #require(intent.translationRequestID)
        #expect(service.base.translationRequestCount == 1)
        #expect(service.base.sendCount == 0)
        let text = "Translated answer"
        let recordID = PreviewFixtures.id("descriptor-result", TranslationRecordID.self)
        let descriptor = TranslationReducer.verifiedRecord(id: recordID, sourceID: nil, targetLanguage: "en",
            text: nil, textLength: text.utf16.count, textSHA256: SHA256Hex.digest(Data(text.utf8)),
            sourceSHA256: SHA256Hex.digest(Data("Original input".utf8)), paged: false)
        service.translationStatus = .settled(requestID, record: descriptor, error: nil)
        _ = await store.dispatch(.recoverUncertainOperation)
        #expect(store.state.composer.send.intent?.translationReceiptID == recordID)
        #expect(await store.dispatch(.retryTranslationSend) == .rejected(.translationUnavailable))
        #expect(service.base.translationRequestCount == 1)
        service.translationPages = [.page(text: "Translated ", nextOffset: 11), .page(text: "answer", nextOffset: nil)]
        _ = await store.dispatch(.retryTranslationText(recordID))
        #expect(store.state.translations[PreviewFixtures.sessionID]?.records.first(where: { $0.id == recordID })?.presentableText == text)
        _ = await store.dispatch(.retryTranslationSend)
        #expect(service.base.translationRequestCount == 1)
        #expect(service.base.sendCount == 1)
        #expect(service.sendRequest?.translation == .receipt(recordID))
        let saved = try #require(try storage.load(scope: fictionalScope()))
        #expect(saved.translations[PreviewFixtures.sessionID]?.records.first(where: { $0.id == recordID })?.integrity == .pagedVerified)
    }

    @Test func uncertainReadingRequestRetainsOriginalAndOnlyQueriesStatus() async throws {
        let service = ControlledService()
        service.base.script.translationUnknown = true
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let storage = InMemoryGianStorage()
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: storage)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        store.state.translations[PreviewFixtures.sessionID] = translationState(revision: 1, configRevision: 1)
        _ = await store.dispatch(.requestReadingTranslation(sourceID: "source-id", text: "Original source"))
        let requestID = try #require(store.state.translations[PreviewFixtures.sessionID]?.reading["source-id"]?.requestID)
        let saved = try #require(try storage.load(scope: fictionalScope()))
        #expect(saved.readingIntents[PreviewFixtures.sessionID]?["source-id"]?.sourceText == "Original source")
        #expect(saved.translations[PreviewFixtures.sessionID]?.reading["source-id"]?.uncertain == true)
        #expect(saved.translations[PreviewFixtures.sessionID]?.reading["source-id"]?.sourceSHA256 == SHA256Hex.digest(Data("Original source".utf8)))
        #expect(saved.translations[PreviewFixtures.sessionID]?.reading["source-id"]?.targetLanguage == "es")
        #expect(await store.dispatch(.requestReadingTranslation(sourceID: "source-id", text: "Original source")) == .rejected(.uncertainOutcome))
        let translated = "Verified reading"
        let record = TranslationReducer.verifiedRecord(id: PreviewFixtures.id("reading-record", TranslationRecordID.self),
            sourceID: "source-id", targetLanguage: "en", text: translated, textLength: translated.utf16.count,
            textSHA256: SHA256Hex.digest(Data(translated.utf8)), sourceSHA256: SHA256Hex.digest(Data("Original source".utf8)), paged: false)
        service.translationStatus = .settled(requestID, record: record, error: nil)
        _ = await store.dispatch(.recoverUncertainOperation)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.reading["source-id"] == nil)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.records.first?.presentableText == translated)
        #expect(service.base.translationRequestCount == 1)
    }

    @Test func malformedPagingDoesNotPresentPartialTranslation() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        let recordID = PreviewFixtures.id("bad-page-result", TranslationRecordID.self)
        let text = "Complete translation"
        let descriptor = TranslationReducer.verifiedRecord(id: recordID, sourceID: "source", targetLanguage: "en",
            text: nil, textLength: text.utf16.count, textSHA256: SHA256Hex.digest(Data(text.utf8)),
            sourceSHA256: SHA256Hex.digest(Data("source".utf8)), paged: false)
        var state = translationState(revision: 1, configRevision: 1)
        state.records = [descriptor]
        store.state.translations[PreviewFixtures.sessionID] = state
        service.translationPages = [.page(text: "prefix", nextOffset: 0)]
        #expect(await store.dispatch(.retryTranslationText(recordID)) == .rejected(.translationUnavailable))
        #expect(store.state.translations[PreviewFixtures.sessionID]?.records.first?.presentableText == nil)
        #expect(service.base.translationRequestCount == 0)
    }

    @Test func newHostGenerationEstablishesFreshTranslationBaselineWithoutPaidRetry() async throws {
        let (store, service, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        var previous = translationState(revision: 9, configRevision: 7, automaticRevision: 12, epoch: "old-runtime")
        previous.reading["source"] = ReadingRequestState(requestID: PreviewFixtures.id("old-reading", TranslationRequestID.self), pending: true, uncertain: false)
        store.state.translations[PreviewFixtures.sessionID] = previous
        var incoming = translationState(revision: 1, configRevision: 1, automaticRevision: 0, epoch: "new-runtime")
        incoming.enabled = false
        service.script.directory.cursor = SyncCursor(hostGeneration: PreviewFixtures.id("restarted-generation", HostGenerationID.self),
            eventSequence: 0, revision: "restart")
        service.script.directory.translations[PreviewFixtures.sessionID] = incoming
        _ = await store.dispatch(.refreshDirectory)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.revision == 1)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.enabled == false)
        #expect(store.state.translations[PreviewFixtures.sessionID]?.automaticEpoch == "new-runtime")
        #expect(store.state.translations[PreviewFixtures.sessionID]?.reading["source"]?.uncertain == true)
        #expect(service.translationRequestCount == 0)
    }
}
