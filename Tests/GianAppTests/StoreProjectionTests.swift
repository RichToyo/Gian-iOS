import XCTest
@testable import GianCore
@testable import Gian

/// Deterministic tests for the pure StoreProjection mappers. No store, clock,
/// network or service involved — state values are constructed directly.
final class StoreProjectionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_781_000_000)

    private func id<Kind>(_ raw: String, _ type: ScopedID<Kind>.Type) -> ScopedID<Kind> {
        guard let value = ScopedID<Kind>(rawValue: raw) else {
            XCTFail("invalid test id \(raw)")
            fatalError("invalid test id")
        }
        return value
    }

    private func summary(
        _ rawID: String,
        repo: String?,
        status: SessionStatus = .done,
        attention: AttentionKind? = nil,
        activity: Date
    ) -> ConversationSummary {
        ConversationSummary(
            id: id(rawID, SessionID.self),
            title: "Title \(rawID)",
            agentName: "Ada",
            pluginID: "claude.plugin",
            repositoryName: repo,
            status: status,
            unread: false,
            attention: attention,
            lastActivityAt: activity,
            taskID: nil,
            hostID: id("host-1", HostID.self)
        )
    }

    // MARK: - Status badge

    func testStatusBadgeMapping() {
        XCTAssertEqual(StatusBadge(status: .running, attention: nil), .working)
        XCTAssertEqual(StatusBadge(status: .new, attention: nil), .working)
        XCTAssertEqual(StatusBadge(status: .pending, attention: nil), .waiting)
        XCTAssertEqual(StatusBadge(status: .error, attention: nil), .failed)
        XCTAssertEqual(StatusBadge(status: .done, attention: nil), .idle)
        XCTAssertEqual(StatusBadge(status: .done, attention: .failed), .failed)
        XCTAssertEqual(StatusBadge(status: .done, attention: .interaction), .waiting)
        XCTAssertEqual(StatusBadge(status: .done, attention: .running), .working)
    }

    // MARK: - Directory grouping

    func testReposGroupedByWorkspaceAndSortedByActivity() {
        let infraID = id("workspace-infra", WorkspaceID.self)
        let gianID = id("workspace-gian", WorkspaceID.self)
        let unfiledID = id("workspace-unfiled", WorkspaceID.self)
        var state = GianClientState.signedOut()
        state.directory.repositories = [
            RepositorySection(
                id: infraID,
                title: "infra",
                conversations: [summary("s-old", repo: "infra", activity: now.addingTimeInterval(-7200))]
            ),
            RepositorySection(
                id: gianID,
                title: "gian-dev",
                conversations: [
                    summary("s-mid", repo: "gian-dev", activity: now.addingTimeInterval(-3600)),
                    summary("s-new", repo: "gian-dev", activity: now),
                ]
            ),
            RepositorySection(
                id: unfiledID,
                title: "Unfiled",
                conversations: [summary("s-norepo", repo: nil, activity: now.addingTimeInterval(-100))]
            ),
        ]
        let directory = StoreProjection.directory(state)
        XCTAssertEqual(directory.repos.map(\.repoName), ["gian-dev", "Unfiled", "infra"])
        XCTAssertEqual(directory.repos.map(\.id), [gianID, unfiledID, infraID])
        XCTAssertEqual(directory.repos[0].conversations.map(\.title), ["Title s-new", "Title s-mid"])
    }

    func testReposUnsupportedSurfacesLegacyMessage() {
        var state = GianClientState.signedOut()
        state.directory.reposSupport = .unsupported(.reposDirectory)
        state.directory.legacyLimitations = [
            LegacyLimitation(surface: .reposDirectory, detail: "Repos unavailable on this Host.")
        ]
        let directory = StoreProjection.directory(state)
        XCTAssertEqual(directory.reposAvailability, .unsupported(message: "Repos unavailable on this Host."))
    }

    // MARK: - Transcript rows

    private func item(
        _ rawID: String,
        turn: Int,
        turnID: String,
        seconds: TimeInterval,
        body: TranscriptBody
    ) -> TranscriptItem {
        TranscriptItem(
            id: id(rawID, TranscriptItemID.self),
            turnID: id(turnID, TurnID.self),
            turn: turn,
            timestamp: now.addingTimeInterval(seconds),
            body: body
        )
    }

    func testTranscriptRowsGroupWorkAndPlaceOutcomes() {
        let items = [
            item("i1", turn: 1, turnID: "turn-1", seconds: 0,
                 body: .user(text: "Fix the tests", deliveryID: nil, attachmentIDs: [], translation: nil)),
            item("i2", turn: 1, turnID: "turn-1", seconds: 1,
                 body: .command(status: .error, exitCode: 1)),
            item("i3", turn: 1, turnID: "turn-1", seconds: 2,
                 body: .fileSearch(kind: .grep, matchCount: 3)),
            item("i4", turn: 1, turnID: "turn-1", seconds: 3,
                 body: .turnEnd(outcome: .failed)),
            item("i5", turn: 2, turnID: "turn-2", seconds: 4,
                 body: .assistant(text: "Fixed.", delta: false)),
            item("i6", turn: 2, turnID: "turn-2", seconds: 5,
                 body: .turnEnd(outcome: .worked)),
        ]
        let rows = StoreProjection.transcriptRows(
            items: items, interactions: [], translation: nil,
            agent: .claude, agentName: "Claude", now: now
        )
        // One day marker, then user, work card, failed outcome, assistant.
        XCTAssertEqual(rows.count, 5)
        guard case .timeMarker = rows[0] else { return XCTFail("expected day marker") }
        guard case .user(let user) = rows[1] else { return XCTFail("expected user row") }
        XCTAssertEqual(user.text, "Fix the tests")
        guard case .work(let card) = rows[2] else { return XCTFail("expected work card") }
        XCTAssertEqual(card.phase, .failed) // corrected by the terminal turnEnd
        XCTAssertEqual(card.events.count, 2)
        XCTAssertEqual(card.events[0].outcome, .failed)
        XCTAssertEqual(card.events[0].statusText, "exit 1")
        guard case .turnOutcome(_, let outcome) = rows[3] else { return XCTFail("expected outcome") }
        XCTAssertEqual(outcome, .failed)
        guard case .assistant(let assistant) = rows[4] else { return XCTFail("expected assistant row") }
        XCTAssertEqual(assistant.markdown, "Fixed.")
    }

    func testInteractionPlacedAfterItsTurn() {
        let items = [
            item("i1", turn: 1, turnID: "turn-1", seconds: 0,
                 body: .assistant(text: "May I?", delta: false)),
            item("i2", turn: 2, turnID: "turn-2", seconds: 1,
                 body: .assistant(text: "Later turn", delta: false)),
        ]
        let interaction = InteractionRecord(
            id: id("int-1", InteractionID.self),
            revision: "1",
            sessionID: id("session-1", SessionID.self),
            turnID: id("turn-1", TurnID.self),
            kind: .approval,
            title: "Approval requested",
            detail: "detail",
            risk: .low,
            actions: [],
            phase: .pending
        )
        let rows = StoreProjection.transcriptRows(
            items: items, interactions: [interaction], translation: nil,
            agent: .claude, agentName: "Claude", now: now
        )
        // marker, assistant(turn1), interaction, assistant(turn2)
        XCTAssertEqual(rows.count, 4)
        guard case .interaction(let placed) = rows[2] else {
            return XCTFail("interaction should sit after its turn, got \(rows[2])")
        }
        XCTAssertEqual(placed.id, interaction.id)
    }

    // MARK: - Translation presentation

    private func record(
        sourceID: String,
        integrity: TranslationIntegrityState,
        text: String?
    ) -> ReadingTranslation {
        ReadingTranslation(
            id: id("rec-\(sourceID)", TranslationRecordID.self),
            sourceID: sourceID,
            targetLanguage: "zh",
            presentableText: text,
            textLength: 0,
            textSHA256: "",
            sourceSHA256: "",
            integrity: integrity
        )
    }

    func testReadingPresentationPriority() {
        var translation = TranslationSessionState.unsupported
        translation.supported = true
        translation.configured = true
        translation.records = [record(sourceID: "item-a", integrity: .inlineVerified, text: "Translated text")]
        translation.reading["item-b"] = ReadingRequestState(
            requestID: id("req-1", TranslationRequestID.self), pending: true, uncertain: false
        )
        translation.reading["item-c"] = ReadingRequestState(
            requestID: id("req-2", TranslationRequestID.self), pending: true, uncertain: true
        )
        translation.reading["item-d"] = ReadingRequestState(
            requestID: id("req-3", TranslationRequestID.self),
            pending: false, uncertain: false, error: "boom"
        )
        translation.automatic["item-e"] = AutomaticProgress(pending: true)

        guard case .translated = StoreProjection.readingPresentation(sourceID: "item-a", translation: translation) else {
            return XCTFail("verified record should present as translated")
        }
        XCTAssertEqual(StoreProjection.readingPresentation(sourceID: "item-b", translation: translation), .translating)
        XCTAssertEqual(StoreProjection.readingPresentation(sourceID: "item-c", translation: translation), .uncertain)
        XCTAssertEqual(StoreProjection.readingPresentation(sourceID: "item-d", translation: translation), .failed("boom"))
        XCTAssertEqual(StoreProjection.readingPresentation(sourceID: "item-e", translation: translation), .translating)
        XCTAssertEqual(StoreProjection.readingPresentation(sourceID: "item-z", translation: translation), .none)
    }

    func testNeedsPagingAndIntegrityFailures() {
        var translation = TranslationSessionState.unsupported
        translation.records = [
            record(sourceID: "item-p", integrity: .descriptorPending, text: nil),
            record(sourceID: "item-h", integrity: .hashMismatch, text: "bad"),
        ]
        guard case .needsPaging = StoreProjection.readingPresentation(sourceID: "item-p", translation: translation) else {
            return XCTFail("descriptorPending should require paging")
        }
        XCTAssertEqual(
            StoreProjection.readingPresentation(sourceID: "item-h", translation: translation),
            .failed("Translation failed integrity checks.")
        )
    }

    // MARK: - Session translation capability

    func testSessionTranslationCapability() {
        var state = GianClientState.signedOut()
        let sessionID = id("session-1", SessionID.self)

        // Not negotiated → unsupported even with a record present.
        var translation = TranslationSessionState.unsupported
        translation.supported = true
        translation.configured = true
        state.translations[sessionID] = translation
        XCTAssertEqual(
            StoreProjection.sessionTranslation(state, sessionID: sessionID).capability,
            .unsupported
        )

        state.capabilities = CapabilityProjection(
            grants: [],
            negotiatedFeatures: [.conversationTranslation]
        )
        XCTAssertEqual(
            StoreProjection.sessionTranslation(state, sessionID: sessionID).capability,
            .configured
        )

        translation.configured = false
        state.translations[sessionID] = translation
        XCTAssertEqual(
            StoreProjection.sessionTranslation(state, sessionID: sessionID).capability,
            .unconfigured
        )
    }

    // MARK: - Composer send phase

    func testSendPhasePresentation() {
        let intent = DurableSendIntent(draftID: id("draft-1", DraftID.self), stage: .translation)
        XCTAssertEqual(SendPhasePresentation(.idle), .editable)
        XCTAssertEqual(SendPhasePresentation(.creating(intent)), .creating)
        XCTAssertEqual(SendPhasePresentation(.awaitingTranslation(intent)), .translating)
        XCTAssertEqual(SendPhasePresentation(.sending(intent)), .sending)
        XCTAssertEqual(SendPhasePresentation(.uncertain(intent)), .uncertain)
        XCTAssertEqual(
            SendPhasePresentation(.failed(intent, message: "nope")),
            .failed(message: "nope", isTranslationStage: true)
        )
        let sendIntent = DurableSendIntent(draftID: id("draft-1", DraftID.self), stage: .send)
        XCTAssertEqual(
            SendPhasePresentation(.failed(sendIntent, message: "nope")),
            .failed(message: "nope", isTranslationStage: false)
        )
        XCTAssertEqual(SendPhasePresentation(.succeeded(intent)), .editable)
    }

    // MARK: - Banner

    func testBannerPicksLatestAndShowsCoalescedCount() {
        var state = GianClientState.signedOut()
        let sessionID = id("session-1", SessionID.self)
        state.directory.repos = [summary("session-1", repo: "gian-dev", activity: now)]
        state.banners = [
            BannerItem(
                id: id("b1", BannerID.self), sessionID: sessionID,
                title: "Fix login redirect", summary: "Task completed",
                eventCount: 3, latestAt: now
            ),
            BannerItem(
                id: id("b2", BannerID.self), sessionID: id("session-2", SessionID.self),
                title: "Older", summary: "Older event",
                eventCount: 1, latestAt: now.addingTimeInterval(-60)
            ),
        ]
        let banner = StoreProjection.banner(state)
        XCTAssertEqual(banner?.id, id("b1", BannerID.self))
        XCTAssertEqual(banner?.agent.bundled, .claude)
        XCTAssertEqual(banner?.summary, "Task completed · 3 events")
    }

    // MARK: - Notices

    func testComposerNoticeMessages() {
        XCTAssertNil(ComposerNoticePresentation(.none).message)
        XCTAssertNotNil(ComposerNoticePresentation(.offlineDraftRetained).message)
        XCTAssertNotNil(ComposerNoticePresentation(.keptAfterUncertainOutcome).message)
        XCTAssertNotNil(ComposerNoticePresentation(.translationNeedsChoice).message)
        XCTAssertNotNil(ComposerNoticePresentation(.legacyTaskRequired).message)
    }

    // MARK: - Diagnostics

    func testDiagnosticMapping() {
        XCTAssertEqual(StoreProjection.diagnostic(nil), .none)
        let retrying = RemoteServiceDiagnostic(
            server: nil, account: nil, host: nil, loginID: nil, epoch: 1,
            status: .retryingLogin(
                error: .transport,
                retryAt: now.addingTimeInterval(5),
                expiresAt: now.addingTimeInterval(900)
            )
        )
        guard case .retryingLogin(let message, _, _) = StoreProjection.diagnostic(retrying) else {
            return XCTFail("expected retryingLogin")
        }
        XCTAssertEqual(message, RemoteClientError.transport.safeDescription)

        let closed = RemoteServiceDiagnostic(
            server: nil, account: nil, host: nil, loginID: nil, epoch: 1,
            status: .connectionClosed(.disconnected)
        )
        XCTAssertEqual(
            StoreProjection.diagnostic(closed),
            .connectionClosed(message: RemoteClientError.disconnected.safeDescription)
        )

        let resync = RemoteServiceDiagnostic(
            server: nil, account: nil, host: nil, loginID: nil, epoch: 1,
            status: .resyncRequired(.gapEvicted)
        )
        XCTAssertEqual(StoreProjection.diagnostic(resync), .resyncRequired(reason: "gap_evicted"))

        let cleared = RemoteServiceDiagnostic(
            server: nil, account: nil, host: nil, loginID: nil, epoch: 1,
            status: .cleared
        )
        XCTAssertEqual(StoreProjection.diagnostic(cleared), .none)
    }

    // MARK: - Transcript file presentation

    /// Fictional but parser-valid identifiers: the wire contract requires
    /// lowercase UUID strings for `id` / `session_id`.
    private static let fixtureFileID = "11111111-1111-4111-8111-111111111111"
    private static let fixtureSessionID = "22222222-2222-4222-8222-222222222222"

    /// Builds a descriptor through the real internal wire initializer with
    /// fictional values; expiry is expressed relative to the fixed `now`.
    @MainActor
    private func descriptor(
        _ rawID: String = StoreProjectionTests.fixtureFileID,
        previewable: Bool = true,
        downloadable: Bool = true,
        expiresIn seconds: TimeInterval = 3600
    ) throws -> RemoteFileDescriptor {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAt = formatter.string(from: now.addingTimeInterval(seconds))
        let wire: WireValue = .object([
            "id": .string(rawID),
            "session_id": .string(StoreProjectionTests.fixtureSessionID),
            "name": .string("report.pdf"),
            "mime": .string("application/pdf"),
            "size": .int(1024),
            "revision": .string("rev-1"),
            "previewable": .bool(previewable),
            "downloadable": .bool(downloadable),
            "expires_at": .string(expiresAt),
        ])
        return try RemoteFileDescriptor(
            wire,
            session: id(StoreProjectionTests.fixtureSessionID, SessionID.self)
        )
    }

    @MainActor
    func testAttachmentPresentationMapping() throws {
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(descriptor: nil, state: nil, now: now),
            .unknown
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(descriptor: try descriptor(), state: nil, now: now),
            .readyToDownload(name: "report.pdf", byteCount: 1024, previewable: true)
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(descriptor: try descriptor(), state: .downloading, now: now),
            .downloading(name: "report.pdf")
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(descriptor: try descriptor(), state: .cached, now: now),
            .cached(name: "report.pdf", previewable: true)
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(descriptor: try descriptor(), state: .expired, now: now),
            .expired(name: "report.pdf")
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(descriptor: try descriptor(), state: .unavailable, now: now),
            .unavailable(name: "report.pdf")
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(descriptor: try descriptor(), state: .hashMismatch, now: now),
            .failed(name: "report.pdf", message: "Integrity check failed.")
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(descriptor: try descriptor(), state: .failed("boom"), now: now),
            .failed(name: "report.pdf", message: "boom")
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(
                descriptor: try descriptor(expiresIn: -60),
                state: nil,
                now: now
            ),
            .expired(name: "report.pdf")
        )
        XCTAssertEqual(
            StoreProjection.attachmentPresentation(
                descriptor: try descriptor(downloadable: false),
                state: nil,
                now: now
            ),
            .unavailable(name: "report.pdf")
        )
    }
}
