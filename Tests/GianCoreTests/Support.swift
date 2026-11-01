import Foundation
import Testing
@testable import GianCore

func storedLabels(of value: Any) -> Set<String> {
    Set(Mirror(reflecting: value).children.compactMap(\.label))
}

func isUUIDv7(_ raw: String) -> Bool {
    let parts = raw.split(separator: "-")
    guard parts.count == 5 else { return false }
    let variant = parts[3]
    return parts[2].hasPrefix("7")
        && (variant.hasPrefix("8") || variant.hasPrefix("9") || variant.hasPrefix("a") || variant.hasPrefix("b"))
}

func makeSession(
    id: String,
    title: String,
    taskID: TaskID?,
    status: SessionStatus = .done,
    archived: Bool = false,
    authorized: Bool = true,
    attention: AttentionKind? = nil,
    activity: Date? = nil,
    real: Bool = true,
    now: Date = PreviewFixtures.instant
) -> SessionRecord {
    SessionRecord(
        id: PreviewFixtures.id(id, SessionID.self),
        hostID: PreviewFixtures.hostID,
        title: title,
        revision: "rev-1",
        taskID: taskID,
        workspaceID: PreviewFixtures.workspaceID,
        agentID: PreviewFixtures.agentID,
        agentName: "Ada",
        pluginID: "ada.plugin",
        status: status,
        archived: archived,
        authorized: authorized,
        attention: attention,
        lastActivityAt: activity,
        activityIsMessageOrExecution: real,
        updatedAt: now
    )
}

func transcriptItem(id: String, turn: Int, text: String, at: Date = PreviewFixtures.instant) -> TranscriptItem {
    TranscriptItem(
        id: PreviewFixtures.id(id, TranscriptItemID.self),
        turnID: PreviewFixtures.id("turn-\(turn)", TurnID.self),
        turn: turn,
        timestamp: at,
        body: .user(text: text, deliveryID: nil, attachmentIDs: [], translation: nil)
    )
}

func translationState(
    revision: Int,
    configRevision: Int,
    automaticRevision: Int = 0,
    epoch: String = "",
    language: String = "en"
) -> TranslationSessionState {
    TranslationSessionState(
        supported: true,
        enabled: true,
        configured: true,
        sendingLanguage: language,
        readingLanguage: "es",
        revision: revision,
        configRevision: configRevision,
        automaticRevision: automaticRevision,
        automaticEpoch: epoch
    )
}

func directoryTitles(_ projection: DirectoryFilter.Projection) -> (tasks: Set<String>, repos: Set<String>) {
    (
        Set(projection.tasks.flatMap { $0.conversations.map(\.title) }),
        Set(projection.repos.map(\.title))
    )
}

@MainActor
func makeHarness(script: PreviewScript = .legacyContract) -> (GianClientStore, PreviewGianClientService, ManualGianClock) {
    let clock = ManualGianClock(instant: PreviewFixtures.instant)
    let service = PreviewGianClientService(script: script)
    let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
    return (store, service, clock)
}

@MainActor
func authenticate(_ store: GianClientStore, clock: ManualGianClock) async throws {
    let entered = await store.dispatch(.setServerAddress(PreviewFixtures.server))
    try #require(entered.isApplied)
    let started = await store.dispatch(.startGitHubDeviceLogin)
    try #require(started.isApplied)
    clock.instant = clock.instant.addingTimeInterval(5)
    let polled = await store.dispatch(.pollGitHubDeviceLogin)
    try #require(polled.isApplied)
    try #require(store.state.phase == .awaitingHostPairing)
}

@MainActor
func signIn(
    _ store: GianClientStore,
    clock: ManualGianClock,
    qr: String = PreviewFixtures.qr
) async throws -> GianDispatchResult {
    try await authenticate(store, clock: clock)
    let paired = await store.dispatch(.beginHostPairingFromQR(qr))
    try #require(store.state.phase == .ready)
    return paired
}

@MainActor
func clientScope(_ store: GianClientStore) throws -> ClientScope {
    ClientScope(
        server: try #require(store.state.server),
        account: try #require(store.state.account.accountID),
        host: try #require(store.state.currentHostID)
    )
}

@MainActor
func dataScope(_ store: GianClientStore) throws -> ClientScope {
    try clientScope(store)
}

@MainActor
func prepareComposer(_ store: GianClientStore, text: String = "Check the line", task: Bool = true) async {
    _ = await store.dispatch(.openNewChat)
    _ = await store.dispatch(.selectAgent(PreviewFixtures.agentID))
    _ = await store.dispatch(.selectWorkspace(PreviewFixtures.workspaceID))
    if task {
        _ = await store.dispatch(.selectTask(PreviewFixtures.taskID))
    }
    _ = await store.dispatch(.editDraftText(text))
}

@MainActor
final class RejectingService: GianClientServicing {
    func startGitHubDeviceLogin(server: ServerAddress) async -> GitHubLoginStartResponse {
        _ = server
        return .failed("unreachable")
    }

    func pollGitHubDeviceLogin(server: ServerAddress, loginID: LoginID) async -> GitHubLoginPollResponse {
        _ = (server, loginID)
        return .denied
    }

    func claimHostQR(server: ServerAddress, account: AccountID, qr: HostPairingQR) async -> HostPairingResponse {
        _ = (server, account, qr)
        return .failed("unreachable")
    }

    func refreshHostPairing(server: ServerAddress, account: AccountID, pairingID: PairingID) async -> HostPairingResponse {
        _ = (server, account, pairingID)
        return .failed("unreachable")
    }

    func refreshDirectory(scope: ClientScope) async -> DirectoryRefreshResponse {
        _ = scope
        return .failed("unreachable")
    }

    func createSession(scope: ClientScope, request: SessionCreateRequest) async -> CommandDispatchResponse {
        _ = scope
        return .failed(request.commandID, message: "unreachable")
    }

    func sendMessage(scope: ClientScope, request: SessionSendRequest) async -> CommandDispatchResponse {
        _ = scope
        return .failed(request.commandID, message: "unreachable")
    }

    func stopSession(scope: ClientScope, request: SessionStopRequest) async -> CommandDispatchResponse {
        _ = scope
        return .failed(request.commandID, message: "unreachable")
    }

    func queryCommand(scope: ClientScope, commandID: CommandID) async -> CommandStatusResponse {
        _ = scope
        return .notSeen(commandID)
    }

    func respondToInteraction(scope: ClientScope, request: InteractionRespondRequest) async -> CommandDispatchResponse {
        _ = scope
        return .failed(request.commandID, message: "unreachable")
    }

    func setAutoTranslation(scope: ClientScope, request: TranslationAutoRequest) async -> TranslationCommandResponse {
        _ = (scope, request)
        return .failed("unreachable")
    }

    func requestTranslation(scope: ClientScope, request: TranslationRequest) async -> TranslationCommandResponse {
        _ = (scope, request)
        return .failed("unreachable")
    }

    func cancelTranslation(scope: ClientScope, request: TranslationCancelRequest) async -> TranslationCommandResponse {
        _ = (scope, request)
        return .failed("unreachable")
    }

    func pageTranslationText(scope: ClientScope, request: TranslationTextPageRequest) async -> TranslationTextPageResponse {
        _ = (scope, request)
        return .failed("unreachable")
    }

    func translationRequestStatus(scope: ClientScope, request: TranslationStatusRequest) async -> TranslationCommandResponse {
        _ = (scope, request)
        return .failed("unreachable")
    }

    func uploadAttachment(scope: ClientScope, request: AttachmentUploadRequest) async -> AttachmentTransferResponse {
        _ = (scope, request)
        return .failed("unreachable")
    }

    func downloadAttachment(scope: ClientScope, request: AttachmentDownloadRequest) async -> AttachmentTransferResponse {
        _ = (scope, request)
        return .unavailable("unreachable")
    }

    func pageTranscript(scope: ClientScope, sessionID: SessionID, cursor: String?) async -> TranscriptPageResponse {
        _ = (scope, sessionID, cursor)
        return TranscriptPageResponse(items: [], cursor: nil, hasOlder: false, failed: true)
    }

    func searchSessions(scope: ClientScope, query: String) async -> SearchResponse {
        _ = (scope, query)
        return SearchResponse(supported: false, sessions: [])
    }
}
