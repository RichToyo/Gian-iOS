import Foundation

/// Injected backend. A failed call must not be replaced with the preview service.
@MainActor
public protocol GianClientServicing: AnyObject {
    /// Verifies the Server's identity (pinning it on first use) and admits
    /// this app as a controller there with a single-use enrollment token.
    /// Once admitted, reconnecting needs no token. No account sign-in.
    func connectServer(server: ServerAddress, enrollmentToken: String?) async -> ServerConnectResponse
    /// Claims a Host pairing as the admitted controller; the Host confirms it.
    func claimHost(server: ServerAddress, account: AccountID, invitation: HostPairingInvitation) async -> HostPairingResponse
    func refreshHostPairing(server: ServerAddress, account: AccountID, pairingID: PairingID) async -> HostPairingResponse
    func refreshDirectory(scope: ClientScope) async -> DirectoryRefreshResponse
    func listDirectory(scope: ClientScope, request: DirectoryPageRequest) async -> DirectoryPageResponse
    func createSession(scope: ClientScope, request: SessionCreateRequest) async -> CommandDispatchResponse
    func sendMessage(scope: ClientScope, request: SessionSendRequest) async -> CommandDispatchResponse
    func stopSession(scope: ClientScope, request: SessionStopRequest) async -> CommandDispatchResponse
    func mutateQueue(scope: ClientScope, request: QueueMutationRequest) async -> CommandDispatchResponse
    func queryCommand(scope: ClientScope, commandID: CommandID) async -> CommandStatusResponse
    func respondToInteraction(scope: ClientScope, request: InteractionRespondRequest) async -> CommandDispatchResponse
    func setAutoTranslation(scope: ClientScope, request: TranslationAutoRequest) async -> TranslationCommandResponse
    func requestTranslation(scope: ClientScope, request: TranslationRequest) async -> TranslationCommandResponse
    func cancelTranslation(scope: ClientScope, request: TranslationCancelRequest) async -> TranslationCommandResponse
    func pageTranslationText(scope: ClientScope, request: TranslationTextPageRequest) async -> TranslationTextPageResponse
    func translationRequestStatus(scope: ClientScope, request: TranslationStatusRequest) async -> TranslationCommandResponse
    func uploadAttachment(scope: ClientScope, request: AttachmentUploadRequest) async -> AttachmentTransferResponse
    func downloadAttachment(scope: ClientScope, request: AttachmentDownloadRequest) async -> AttachmentTransferResponse
    func pageTranscript(scope: ClientScope, sessionID: SessionID, cursor: String?) async -> TranscriptPageResponse
    func searchSessions(scope: ClientScope, query: String) async -> SearchResponse
    func updateSession(scope: ClientScope, request: SessionUpdateRequest) async -> SessionUpdateResponse
    func agentOptions(scope: ClientScope, request: AgentOptionsRequest) async -> AgentOptionsResponse
    func agentLogo(scope: ClientScope, pluginID: String, variant: AgentLogoVariant) async -> AgentLogoResponse
}

extension GianClientServicing {
    /// Existing services remain explicitly unsupported, never a fabricated page.
    public func listDirectory(scope: ClientScope, request: DirectoryPageRequest) async -> DirectoryPageResponse { .unsupported }
    public func updateSession(scope: ClientScope, request: SessionUpdateRequest) async -> SessionUpdateResponse { .unsupported }
    public func agentOptions(scope: ClientScope, request: AgentOptionsRequest) async -> AgentOptionsResponse { .unavailable }
    public func agentLogo(scope: ClientScope, pluginID: String, variant: AgentLogoVariant) async -> AgentLogoResponse { .unsupported }
    public func mutateQueue(scope: ClientScope, request: QueueMutationRequest) async -> CommandDispatchResponse {
        .failed(request.commandID, message: "Queue changes are not supported by this Host.")
    }
}

public enum QueueMutation: Sendable, Equatable {
    case update(id: String, text: String)
    case remove(id: String)
    case clear
    case sendNow
}

public struct QueueMutationRequest: Sendable, Equatable {
    public var commandID: CommandID
    public var sessionID: SessionID
    public var revision: String
    public var mutation: QueueMutation

    public init(commandID: CommandID, sessionID: SessionID, revision: String, mutation: QueueMutation) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.revision = revision
        self.mutation = mutation
    }
}

/// One conversation setting change. The Host accepts these mid-run and
/// applies them from the next turn; nil resets to the Agent default.
public enum SessionSettingChange: Sendable, Equatable {
    case model(String?)
    case thinking(String?)
    case fast(Bool)
    case approvalMode(String?)
}

public struct SessionUpdateRequest: Sendable, Equatable {
    public var commandID: CommandID
    public var sessionID: SessionID
    /// The Host rejects a stale revision (`PRECONDITION_FAILED`).
    public var sessionRevision: String
    public var change: SessionSettingChange

    public init(commandID: CommandID, sessionID: SessionID, sessionRevision: String, change: SessionSettingChange) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.sessionRevision = sessionRevision
        self.change = change
    }
}

public enum SessionUpdateResponse: Sendable, Equatable {
    /// The Host's record after the change, carrying the new revision.
    case updated(SessionRecord)
    /// Definitively not applied (stale revision, value not offered, …).
    case rejected(message: String)
    /// The reply was lost; refresh before trusting either value.
    case unknownOutcome
    case unsupported
}

public struct AgentOptionsRequest: Sendable, Equatable {
    public var agentID: AgentID
    public var catalogRevision: String?

    public init(agentID: AgentID, catalogRevision: String?) {
        self.agentID = agentID
        self.catalogRevision = catalogRevision
    }
}

public enum AgentOptionsResponse: Sendable, Equatable {
    case options(AgentConversationOptions)
    case unavailable
    case failed(String)
}

/// The Agent's own logo comes in a variant per appearance.
public enum AgentLogoVariant: String, Sendable, Equatable, Hashable, CaseIterable {
    case light, dark
}

public enum AgentLogoResponse: Sendable, Equatable {
    /// PNG or WebP bytes, checked against the Host's digest.
    case logo(Data)
    /// The Host has no logo for this Agent.
    case notFound
    /// The Host predates `proxy.logo`.
    case unsupported
    case failed(String)
}

/// How the Host invited this device: its QR code (a pairing link carrying a
/// grant nonce) or its one-time code.
public enum HostPairingInvitation: Sendable, Equatable {
    case grantNonce(String)
    /// Canonical `XXXX-XXXX` (Crockford base32).
    case code(String)
}

/// This app's controller identity on one Server.
public struct AccountIdentity: Sendable, Equatable {
    public var account: AccountID
    public var installationID: InstallationID

    public init(account: AccountID, installationID: InstallationID) {
        self.account = account
        self.installationID = installationID
    }
}

public enum ServerConnectResponse: Sendable, Equatable {
    /// The Server proved its identity; Host pairing can start.
    case connected(AccountIdentity)
    /// The Server's identity differs from the one pinned on first use.
    case identityChanged
    case failed(String)
}

public enum HostPairingResponse: Sendable, Equatable {
    case confirmed(HostSummary, deviceID: DeviceID)
    case pendingConfirmation(PairingID, HostID)
    case rejected
    case expired
    case failed(String)
}

public struct DirectorySnapshotPayload: Sendable, Equatable {
    public var authority: DirectoryAuthority
    public var host: HostSummary
    public var tasks: [TaskRecord]
    public var sessions: [SessionRecord]
    public var interactions: [InteractionRecord]
    public var workspaces: [WorkspaceRecord]
    public var agents: [AgentRecord]
    public var capabilities: [CapabilityGrant]
    public var negotiatedFeatures: [KnownWireFeature]
    public var cursor: SyncCursor
    public var catalogRevision: String
    public var translations: [SessionID: TranslationSessionState]

    public init(
        authority: DirectoryAuthority,
        host: HostSummary,
        tasks: [TaskRecord],
        sessions: [SessionRecord],
        interactions: [InteractionRecord],
        workspaces: [WorkspaceRecord],
        agents: [AgentRecord],
        capabilities: [CapabilityGrant],
        negotiatedFeatures: [KnownWireFeature],
        cursor: SyncCursor,
        catalogRevision: String,
        translations: [SessionID: TranslationSessionState] = [:]
    ) {
        self.authority = authority
        self.host = host
        self.tasks = tasks
        self.sessions = sessions
        self.interactions = interactions
        self.workspaces = workspaces
        self.agents = agents
        self.capabilities = capabilities
        self.negotiatedFeatures = negotiatedFeatures
        self.cursor = cursor
        self.catalogRevision = catalogRevision
        self.translations = translations
    }
}

public enum DirectoryRefreshResponse: Sendable, Equatable {
    case snapshot(DirectorySnapshotPayload)
    case failed(String)
    case unknownOutcome
}

public struct CommandSuccess: Sendable, Equatable {
    public var commandID: CommandID
    public var session: SessionRecord?
    public var deliveryID: String?
    public var queue: SessionQueue?

    public init(commandID: CommandID, session: SessionRecord? = nil, deliveryID: String? = nil, queue: SessionQueue? = nil) {
        self.commandID = commandID
        self.session = session
        self.deliveryID = deliveryID
        self.queue = queue
    }
}

public enum CommandDispatchResponse: Sendable, Equatable {
    case succeeded(CommandSuccess)
    case failed(CommandID, message: String)
    case unknownOutcome(CommandID)
}

public enum CommandStatusResponse: Sendable, Equatable {
    case notSeen(CommandID)
    case accepted(CommandID)
    case succeeded(CommandSuccess)
    case failed(CommandID, message: String)
    case unknownOutcome(CommandID)
    case expired(CommandID)

    public var commandID: CommandID {
        switch self {
        case .notSeen(let id), .accepted(let id), .failed(let id, _), .unknownOutcome(let id), .expired(let id):
            return id
        case .succeeded(let success):
            return success.commandID
        }
    }
}

public struct SessionCreateRequest: Codable, Sendable, Equatable {
    public var commandID: CommandID
    public var catalogRevision: String
    public var workspaceID: WorkspaceID
    public var agentID: AgentID
    public var taskID: TaskID?
    public var model: String?
    public var thinking: String?
    /// `fast`, or nil for the standard tier (only Agents offering Fast).
    public var serviceTier: String?

    public init(
        commandID: CommandID,
        catalogRevision: String,
        workspaceID: WorkspaceID,
        agentID: AgentID,
        taskID: TaskID?,
        model: String?,
        thinking: String? = nil,
        serviceTier: String? = nil
    ) {
        self.commandID = commandID
        self.catalogRevision = catalogRevision
        self.workspaceID = workspaceID
        self.agentID = agentID
        self.taskID = taskID
        self.model = model
        self.thinking = thinking
        self.serviceTier = serviceTier
    }
}

public enum TranslationDispatch: Codable, Sendable, Equatable {
    case receipt(TranslationRecordID)
    case original
}

public enum SendBusyPolicy: String, Codable, Sendable, Equatable {
    case queue, fail
}

public struct SessionSendRequest: Codable, Sendable, Equatable {
    public var commandID: CommandID
    public var sessionID: SessionID
    public var text: String
    public var attachmentIDs: [AttachmentID]
    public var busy: SendBusyPolicy?
    public var translation: TranslationDispatch?

    public init(
        commandID: CommandID,
        sessionID: SessionID,
        text: String,
        attachmentIDs: [AttachmentID],
        busy: SendBusyPolicy?,
        translation: TranslationDispatch?
    ) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.busy = busy
        self.translation = translation
    }
}

public struct SessionStopRequest: Sendable, Equatable {
    public var commandID: CommandID
    public var sessionID: SessionID
    public var sessionRevision: String

    public init(commandID: CommandID, sessionID: SessionID, sessionRevision: String) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.sessionRevision = sessionRevision
    }
}

public struct InteractionRespondRequest: Sendable, Equatable {
    public var commandID: CommandID
    public var interactionID: InteractionID
    public var revision: String
    public var actionID: ActionID
    public var values: [String: InteractionValue]

    public init(
        commandID: CommandID,
        interactionID: InteractionID,
        revision: String,
        actionID: ActionID,
        values: [String: InteractionValue]
    ) {
        self.commandID = commandID
        self.interactionID = interactionID
        self.revision = revision
        self.actionID = actionID
        self.values = values
    }
}

public struct TranslationAutoRequest: Sendable, Equatable {
    public var commandID: CommandID
    public var sessionID: SessionID
    public var enabled: Bool
    public var expectedEnabled: Bool?
    public var expectedRevision: Int?

    public init(
        commandID: CommandID,
        sessionID: SessionID,
        enabled: Bool,
        expectedEnabled: Bool?,
        expectedRevision: Int?
    ) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.enabled = enabled
        self.expectedEnabled = expectedEnabled
        self.expectedRevision = expectedRevision
    }
}

public enum TranslationPurpose: String, Sendable, Equatable {
    case send, read
}

public struct TranslationRequest: Sendable, Equatable {
    public var requestID: TranslationRequestID
    public var sessionID: SessionID
    public var purpose: TranslationPurpose
    public var text: String
    public var sourceID: String?

    public init(
        requestID: TranslationRequestID,
        sessionID: SessionID,
        purpose: TranslationPurpose,
        text: String,
        sourceID: String?
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.purpose = purpose
        self.text = text
        self.sourceID = sourceID
    }
}

public struct TranslationCancelRequest: Sendable, Equatable {
    public var sessionID: SessionID
    public var requestID: TranslationRequestID

    public init(sessionID: SessionID, requestID: TranslationRequestID) {
        self.sessionID = sessionID
        self.requestID = requestID
    }
}

public struct TranslationTextPageRequest: Sendable, Equatable {
    public var sessionID: SessionID
    public var recordID: TranslationRecordID
    public var offset: Int?

    public init(sessionID: SessionID, recordID: TranslationRecordID, offset: Int?) {
        self.sessionID = sessionID
        self.recordID = recordID
        self.offset = offset
    }
}

public struct TranslationStatusRequest: Sendable, Equatable {
    public var sessionID: SessionID
    public var requestID: TranslationRequestID

    public init(sessionID: SessionID, requestID: TranslationRequestID) {
        self.sessionID = sessionID
        self.requestID = requestID
    }
}

public enum TranslationCommandResponse: Sendable, Equatable {
    case state(TranslationSessionState)
    case settled(TranslationRequestID, record: ReadingTranslation?, error: String?)
    case cancelled(TranslationRequestID)
    case unknown(TranslationRequestID)
    case failed(String)
    case unavailable
}

public enum TranslationTextPageResponse: Sendable, Equatable {
    case page(text: String, nextOffset: Int?)
    case notFound
    case failed(String)
    case unknown
}

public struct AttachmentUploadRequest: Sendable, Equatable {
    public var localID: AttachmentID
    public var sessionID: SessionID?
    public var filename: String
    public var mime: String
    public var sha256: String
    public var bytes: Data

    public init(
        localID: AttachmentID,
        sessionID: SessionID?,
        filename: String,
        mime: String,
        sha256: String,
        bytes: Data
    ) {
        self.localID = localID
        self.sessionID = sessionID
        self.filename = filename
        self.mime = mime
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public struct AttachmentDownloadRequest: Sendable, Equatable {
    public var attachmentID: AttachmentID
    public var sha256: String

    public init(attachmentID: AttachmentID, sha256: String) {
        self.attachmentID = attachmentID
        self.sha256 = sha256
    }
}

public enum AttachmentTransferResponse: Sendable, Equatable {
    case uploaded(remoteID: AttachmentID, sha256: String)
    case downloaded(sha256: String, bytes: Data)
    case expired
    case unavailable(String)
    case failed(String)
}

public struct TranscriptPageResponse: Sendable, Equatable {
    public var items: [TranscriptItem]
    public var cursor: String?
    public var hasOlder: Bool
    public var failed: Bool
    /// A failed read that something newer overtook: the chat changed, or
    /// another read of it started, while it was in flight. Reading again is
    /// expected to work; it says nothing about the chat or the connection.
    public var superseded: Bool

    public init(items: [TranscriptItem], cursor: String?, hasOlder: Bool, failed: Bool = false, superseded: Bool = false) {
        self.items = items
        self.cursor = cursor
        self.hasOlder = hasOlder
        self.failed = failed || superseded
        self.superseded = superseded
    }
}

public struct SearchResponse: Sendable, Equatable {
    public var supported: Bool
    public var sessions: [SessionRecord]

    public init(supported: Bool, sessions: [SessionRecord]) {
        self.supported = supported
        self.sessions = sessions
    }
}
