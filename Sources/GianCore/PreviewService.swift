import Foundation

public enum PreviewFixtures {
    public static let instant = Date(timeIntervalSince1970: 1_781_000_000)
    public static let server = "https://remote.example.test"
    public static let qr = "https://remote.example.test/pair#nonce=abcdefghijklmnop"
    public static let account = AccountID(provider: .controller, id: "install-1")!
    public static let otherAccount = AccountID(provider: .controller, id: "install-2")!
    public static let hostID = id("host-harbor", HostID.self)
    public static let deviceID = id("device-phone", DeviceID.self)
    public static let generationID = id("generation-1", HostGenerationID.self)
    public static let sessionID = id("session-mooring", SessionID.self)
    public static let taskID = id("task-paint", TaskID.self)
    public static let agentID = id("agent-ada", AgentID.self)
    public static let workspaceID = id("ws-harbor", WorkspaceID.self)
    public static let actionID = id("action-allow", ActionID.self)
    public static let interactionID = id("interaction-1", InteractionID.self)

    static func id<Kind>(_ raw: String, _: ScopedID<Kind>.Type) -> ScopedID<Kind> {
        guard let value = ScopedID<Kind>(rawValue: raw) else {
            preconditionFailure("invalid fixture id \(raw)")
        }
        return value
    }
}

public enum PreviewCommandBehavior: Sendable, Equatable {
    case succeed
    case lostAckNotSeen
    case lostAckStillUnknown
    case fail
    case createSucceedsSendUnknown
}

public enum PreviewRefreshBehavior: Sendable, Equatable {
    case snapshot, fail
}

public enum PreviewPairingConfirmation: Sendable, Equatable {
    case immediate, onRefresh
}

/// How the scripted Server answers its identity check.
public enum PreviewServerIdentity: Sendable, Equatable {
    case verified, changed, unreachable
}

public struct PreviewScript: Sendable, Equatable {
    public var account: AccountIdentity
    public var serverIdentity: PreviewServerIdentity
    public var confirmation: PreviewPairingConfirmation
    public var directory: DirectorySnapshotPayload
    public var commandBehavior: PreviewCommandBehavior
    public var refreshBehavior: PreviewRefreshBehavior
    public var transcript: [TranscriptItem]
    public var searchSessions: [SessionRecord]
    public var uploadSHA256Override: String?
    public var downloadExpired: Bool
    public var translatedText: String
    public var translationUnknown: Bool
    public var translationPageText: String

    public init(
        account: AccountIdentity,
        serverIdentity: PreviewServerIdentity = .verified,
        confirmation: PreviewPairingConfirmation,
        directory: DirectorySnapshotPayload,
        commandBehavior: PreviewCommandBehavior,
        refreshBehavior: PreviewRefreshBehavior,
        transcript: [TranscriptItem],
        searchSessions: [SessionRecord],
        uploadSHA256Override: String? = nil,
        downloadExpired: Bool = false,
        translatedText: String = "Hola",
        translationUnknown: Bool = false,
        translationPageText: String = "hello"
    ) {
        self.account = account
        self.serverIdentity = serverIdentity
        self.confirmation = confirmation
        self.directory = directory
        self.commandBehavior = commandBehavior
        self.refreshBehavior = refreshBehavior
        self.transcript = transcript
        self.searchSessions = searchSessions
        self.uploadSHA256Override = uploadSHA256Override
        self.downloadExpired = downloadExpired
        self.translatedText = translatedText
        self.translationUnknown = translationUnknown
        self.translationPageText = translationPageText
    }

    public static let legacyContract = PreviewScript(
        account: AccountIdentity(
            account: PreviewFixtures.account,
            installationID: PreviewFixtures.id("install-1", InstallationID.self)
        ),
        confirmation: .immediate,
        directory: PreviewDirectory.make(authority: .legacyOpenDoingTasksOnly, extras: false),
        commandBehavior: .succeed,
        refreshBehavior: .snapshot,
        transcript: PreviewDirectory.transcript,
        searchSessions: []
    )

    public static let fullDirectory = PreviewScript(
        account: legacyContract.account,
        confirmation: .immediate,
        directory: PreviewDirectory.make(authority: .fullAuthorizedDirectory, extras: true),
        commandBehavior: .succeed,
        refreshBehavior: .snapshot,
        transcript: PreviewDirectory.transcript,
        searchSessions: PreviewDirectory.olderSearchHits()
    )
}

enum PreviewDirectory {
    /// Fictional Agent with a model catalog, so the composer's ⋯ shows real
    /// choices in previews.
    static var ada: AgentRecord {
        var agent = AgentRecord(id: PreviewFixtures.agentID, name: "Ada", pluginID: "ada.plugin")
        let thinking = ["low", "medium", "high"]
        agent.models = [
            AgentModelRecord(id: "ada-large", label: "Ada Large", isDefault: true, supportedThinking: thinking),
            AgentModelRecord(id: "ada-swift", label: "Ada Swift", isDefault: false, supportedThinking: thinking),
        ]
        agent.defaultModel = "ada-large"
        return agent
    }

    static let adaOptions = AgentConversationOptions(
        thinking: [
            AgentOptionChoice(value: "low", label: "Light"),
            AgentOptionChoice(value: "medium", label: "Medium"),
            AgentOptionChoice(value: "high", label: "High"),
        ],
        approval: [
            AgentOptionChoice(value: "ask", label: "Ask for approval"),
            AgentOptionChoice(value: "auto", label: "Approve for me"),
            AgentOptionChoice(value: "full-access", label: "Full access"),
        ],
        approvalDefault: "ask",
        supportsFast: true,
        fastModels: ["ada-swift"]
    )

    static func make(authority: DirectoryAuthority, extras: Bool) -> DirectorySnapshotPayload {
        let now = PreviewFixtures.instant
        var sessions = [mooring(now)]
        var tasks = [openTask(now)]
        if extras {
            sessions.append(contentsOf: extraSessions(now))
            tasks.append(TaskRecord(id: PreviewFixtures.id("task-done", TaskID.self), title: "Done pier", status: .completed, updatedAt: now))
        }
        return DirectorySnapshotPayload(
            authority: authority,
            host: HostSummary(id: PreviewFixtures.hostID, name: "Harbor", online: true, version: "0.6.9"),
            tasks: tasks,
            sessions: sessions,
            interactions: [interaction],
            workspaces: [WorkspaceRecord(id: PreviewFixtures.workspaceID, name: "Harbor Repo")],
            agents: [PreviewDirectory.ada],
            capabilities: BusinessCapability.allCases.map { CapabilityGrant(capability: $0, state: .supported) },
            negotiatedFeatures: KnownWireFeature.allCases.filter { $0 != .sessionDirectoryV1 },
            cursor: SyncCursor(hostGeneration: PreviewFixtures.generationID, eventSequence: 4, revision: "rev-4"),
            catalogRevision: "catalog-1"
        )
    }

    static func olderSearchHits() -> [SessionRecord] {
        [session(id: "session-old-log", title: "Old log", taskID: PreviewFixtures.taskID, status: .done, archived: false, activity: PreviewFixtures.instant.addingTimeInterval(-30 * 24 * 60 * 60), real: true, now: PreviewFixtures.instant)]
    }

    static var transcript: [TranscriptItem] {
        [
            TranscriptItem(
                id: PreviewFixtures.id("item-1", TranscriptItemID.self),
                turnID: PreviewFixtures.id("turn-1", TurnID.self),
                turn: 1,
                timestamp: PreviewFixtures.instant,
                body: .user(text: "Check the mooring line", deliveryID: nil, attachmentIDs: [], translation: nil)
            ),
        ]
    }

    private static func openTask(_ now: Date) -> TaskRecord {
        TaskRecord(id: PreviewFixtures.taskID, title: "Paint the harbor", status: .open, updatedAt: now)
    }

    private static func mooring(_ now: Date) -> SessionRecord {
        session(id: "session-mooring", title: "Mooring notes", taskID: PreviewFixtures.taskID, status: .done, archived: false, activity: now.addingTimeInterval(-3600), real: true, now: now)
    }

    private static func extraSessions(_ now: Date) -> [SessionRecord] {
        [
            session(id: "session-old-quiet", title: "Old quiet", taskID: PreviewFixtures.taskID, status: .done, archived: false, activity: now.addingTimeInterval(-8 * 24 * 60 * 60), real: true, now: now),
            session(id: "session-night", title: "Night watch", taskID: PreviewFixtures.taskID, status: .running, archived: false, activity: now.addingTimeInterval(-30 * 24 * 60 * 60), real: true, now: now),
            session(id: "session-viewed", title: "Only viewed", taskID: PreviewFixtures.taskID, status: .done, archived: false, activity: now.addingTimeInterval(-60), real: false, now: now),
            session(id: "session-archived", title: "Archived log", taskID: PreviewFixtures.taskID, status: .done, archived: true, activity: now.addingTimeInterval(-60), real: true, now: now),
            session(id: "session-loose", title: "Unassigned", taskID: nil, status: .done, archived: false, activity: now.addingTimeInterval(-60), real: true, now: now),
        ]
    }

    private static func session(
        id: String,
        title: String,
        taskID: TaskID?,
        status: SessionStatus,
        archived: Bool,
        activity: Date,
        real: Bool,
        now: Date
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
            lastActivityAt: activity,
            activityIsMessageOrExecution: real,
            updatedAt: now
        )
    }

    private static var interaction: InteractionRecord {
        InteractionRecord(
            id: PreviewFixtures.interactionID,
            revision: "1",
            sessionID: PreviewFixtures.sessionID,
            turnID: PreviewFixtures.id("turn-1", TurnID.self),
            kind: .approval,
            title: "Allow the sample tool",
            detail: "Fictional approval",
            risk: .low,
            actions: [InteractionAction(id: PreviewFixtures.actionID, label: "Allow", tone: .default)]
        )
    }
}

/// Explicit fictional backend. Construct this only for previews and tests.
@MainActor
public final class PreviewGianClientService: GianClientServicing {
    public var script: PreviewScript
    private(set) var createCount = 0
    private(set) var sendCount = 0
    private(set) var searchCount = 0
    private(set) var translationRequestCount = 0
    private(set) var respondCount = 0
    private(set) var uploadCount = 0
    private var createIDs: Set<CommandID> = []
    private var sendIDs: Set<CommandID> = []
    private var created: [CommandID: SessionRecord] = [:]
    private var updated: [SessionID: SessionRecord] = [:]
    private var serial = 0
    private var claimed = false

    public init(script: PreviewScript) {
        self.script = script
    }

    public func connectServer(server: ServerAddress) async -> ServerConnectResponse {
        _ = server
        switch script.serverIdentity {
        case .verified: return .connected(script.account)
        case .changed: return .identityChanged
        case .unreachable: return .failed("The remote service is temporarily unavailable.")
        }
    }

    public func claimHostQR(server: ServerAddress, account: AccountID, qr: HostPairingQR) async -> HostPairingResponse {
        _ = (server, account, qr)
        if script.confirmation == .onRefresh && !claimed {
            claimed = true
            return .pendingConfirmation(PreviewFixtures.id("pairing-1", PairingID.self), script.directory.host.id)
        }
        return confirmedHost()
    }

    public func refreshHostPairing(server: ServerAddress, account: AccountID, pairingID: PairingID) async -> HostPairingResponse {
        _ = (server, account, pairingID)
        return confirmedHost()
    }

    public func refreshDirectory(scope: ClientScope) async -> DirectoryRefreshResponse {
        _ = scope
        switch script.refreshBehavior {
        case .snapshot: return .snapshot(script.directory)
        case .fail: return .failed("directory unavailable")
        }
    }

    public func createSession(scope: ClientScope, request: SessionCreateRequest) async -> CommandDispatchResponse {
        _ = scope
        createCount += 1
        createIDs.insert(request.commandID)
        switch script.commandBehavior {
        case .succeed, .createSucceedsSendUnknown:
            let session = createdSession(request)
            return .succeeded(CommandSuccess(commandID: request.commandID, session: session))
        case .fail:
            return .failed(request.commandID, message: "create failed")
        case .lostAckNotSeen, .lostAckStillUnknown:
            return .unknownOutcome(request.commandID)
        }
    }

    public func sendMessage(scope: ClientScope, request: SessionSendRequest) async -> CommandDispatchResponse {
        _ = scope
        sendCount += 1
        sendIDs.insert(request.commandID)
        switch script.commandBehavior {
        case .succeed:
            return .succeeded(CommandSuccess(commandID: request.commandID, deliveryID: "delivery-1"))
        case .createSucceedsSendUnknown, .lostAckStillUnknown, .lostAckNotSeen:
            return .unknownOutcome(request.commandID)
        case .fail:
            return .failed(request.commandID, message: "send failed")
        }
    }

    public func stopSession(scope: ClientScope, request: SessionStopRequest) async -> CommandDispatchResponse {
        _ = scope
        return .succeeded(CommandSuccess(commandID: request.commandID))
    }

    public func queryCommand(scope: ClientScope, commandID: CommandID) async -> CommandStatusResponse {
        _ = scope
        switch script.commandBehavior {
        case .succeed:
            return .succeeded(CommandSuccess(commandID: commandID, session: created[commandID]))
        case .lostAckNotSeen:
            return .notSeen(commandID)
        case .lostAckStillUnknown:
            return .unknownOutcome(commandID)
        case .fail:
            return .failed(commandID, message: "failed")
        case .createSucceedsSendUnknown:
            if sendIDs.contains(commandID) { return .unknownOutcome(commandID) }
            return .succeeded(CommandSuccess(commandID: commandID, session: created[commandID]))
        }
    }

    public func respondToInteraction(scope: ClientScope, request: InteractionRespondRequest) async -> CommandDispatchResponse {
        _ = scope
        respondCount += 1
        return .succeeded(CommandSuccess(commandID: request.commandID))
    }

    public func setAutoTranslation(scope: ClientScope, request: TranslationAutoRequest) async -> TranslationCommandResponse {
        _ = scope
        var state = TranslationSessionState.unsupported
        state.supported = true
        state.enabled = request.enabled
        state.configured = true
        state.sendingLanguage = "en"
        state.readingLanguage = "es"
        state.revision = (request.expectedRevision ?? 0) + 1
        state.configRevision = 1
        return .state(state)
    }

    public func requestTranslation(scope: ClientScope, request: TranslationRequest) async -> TranslationCommandResponse {
        _ = scope
        translationRequestCount += 1
        if script.translationUnknown { return .unknown(request.requestID) }
        let text = script.translatedText
        let record = TranslationReducer.verifiedRecord(
            id: PreviewFixtures.id("translation-receipt", TranslationRecordID.self),
            sourceID: request.sourceID,
            targetLanguage: "es",
            text: text,
            textLength: text.utf16.count,
            textSHA256: SHA256Hex.digest(Data(text.utf8)),
            sourceSHA256: SHA256Hex.digest(Data(request.text.utf8)),
            paged: false
        )
        return .settled(request.requestID, record: record, error: nil)
    }

    public func cancelTranslation(scope: ClientScope, request: TranslationCancelRequest) async -> TranslationCommandResponse {
        _ = scope
        return .cancelled(request.requestID)
    }

    public func pageTranslationText(scope: ClientScope, request: TranslationTextPageRequest) async -> TranslationTextPageResponse {
        _ = (scope, request)
        return .page(text: script.translationPageText, nextOffset: nil)
    }

    public func translationRequestStatus(scope: ClientScope, request: TranslationStatusRequest) async -> TranslationCommandResponse {
        _ = scope
        if script.translationUnknown { return .unknown(request.requestID) }
        return .failed("not seen")
    }

    public func uploadAttachment(scope: ClientScope, request: AttachmentUploadRequest) async -> AttachmentTransferResponse {
        _ = scope
        uploadCount += 1
        let sha = script.uploadSHA256Override ?? request.sha256
        return .uploaded(remoteID: PreviewFixtures.id("remote-file", AttachmentID.self), sha256: sha)
    }

    public func downloadAttachment(scope: ClientScope, request: AttachmentDownloadRequest) async -> AttachmentTransferResponse {
        _ = scope
        if script.downloadExpired { return .expired }
        let bytes = Data("hello".utf8)
        return .downloaded(sha256: request.sha256, bytes: bytes)
    }

    public func pageTranscript(scope: ClientScope, sessionID: SessionID, cursor: String?) async -> TranscriptPageResponse {
        _ = (scope, sessionID, cursor)
        return TranscriptPageResponse(items: script.transcript, cursor: nil, hasOlder: false)
    }

    public func searchSessions(scope: ClientScope, query: String) async -> SearchResponse {
        _ = (scope, query)
        searchCount += 1
        return SearchResponse(supported: true, sessions: script.searchSessions)
    }

    private func confirmedHost() -> HostPairingResponse {
        .confirmed(
            script.directory.host,
            deviceID: PreviewFixtures.deviceID
        )
    }

    public func agentOptions(scope: ClientScope, request: AgentOptionsRequest) async -> AgentOptionsResponse {
        _ = scope
        return request.agentID == PreviewFixtures.agentID ? .options(PreviewDirectory.adaOptions) : .unavailable
    }

    /// Applies the change to the scripted record and bumps its revision, like
    /// the Host's `session.update` result.
    public func updateSession(scope: ClientScope, request: SessionUpdateRequest) async -> SessionUpdateResponse {
        _ = scope
        guard var record = updated[request.sessionID]
                ?? script.directory.sessions.first(where: { $0.id == request.sessionID })
                ?? created.values.first(where: { $0.id == request.sessionID }) else {
            return .rejected(message: "Unknown conversation")
        }
        guard record.revision == request.sessionRevision else { return .rejected(message: "Revision mismatch") }
        switch request.change {
        case .model(let model):
            record.model = model
            record.thinking = nil
        case .thinking(let thinking): record.thinking = thinking
        case .fast(let enabled): record.serviceTier = enabled ? "fast" : nil
        case .approvalMode(let mode): record.approvalMode = mode
        }
        serial += 1
        record.revision = "rev-update-\(serial)"
        updated[request.sessionID] = record
        return .updated(record)
    }

    private func createdSession(_ request: SessionCreateRequest) -> SessionRecord {
        if let existing = created[request.commandID] { return existing }
        serial += 1
        var record = SessionRecord(
            id: PreviewFixtures.id("session-created-\(serial)", SessionID.self),
            hostID: script.directory.host.id,
            title: "New conversation",
            revision: "rev-new",
            taskID: request.taskID,
            workspaceID: request.workspaceID,
            agentID: request.agentID,
            agentName: "Ada",
            pluginID: "ada.plugin",
            status: .new,
            lastActivityAt: PreviewFixtures.instant,
            activityIsMessageOrExecution: true,
            updatedAt: PreviewFixtures.instant
        )
        record.model = request.model
        record.thinking = request.thinking
        record.serviceTier = request.serviceTier
        created[request.commandID] = record
        return record
    }
}
