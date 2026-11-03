import Foundation

public enum SessionStatus: String, Sendable, Equatable {
    case new, running, pending, error, done
}

public enum TaskStatus: String, Sendable, Equatable {
    case open, completed, other
}

public enum AttentionKind: String, Sendable, Equatable {
    case running, interaction, completed, failed
}

public enum DirectoryAuthority: String, Sendable, Equatable {
    /// Gian-Dev 0c0f2f5c: `isRemoteSessionVisible` is open Doing tasks only,
    /// and `createSession` rejects a missing or non-open Task.
    case legacyOpenDoingTasksOnly
    /// Negotiated, independently paginated Host membership, not an exhaustive snapshot.
    case negotiatedDirectoryV1
    /// Retained compatibility for explicitly injected services.
    case fullAuthorizedDirectory
}

public enum LegacySurface: String, Sendable, Equatable {
    case reposDirectory
    case olderSearch
    case tasklessFirstSend
}

public struct LegacyLimitation: Sendable, Equatable, Identifiable {
    public var surface: LegacySurface
    public var detail: String
    public var id: String { surface.rawValue }

    public init(surface: LegacySurface, detail: String) {
        self.surface = surface
        self.detail = detail
    }
}

public enum SurfaceSupport: Sendable, Equatable {
    case supported
    case unsupported(LegacySurface)
}

public struct HostSummary: Sendable, Equatable, Identifiable {
    public var id: HostID
    public var name: String
    public var online: Bool
    public var version: String

    public init(id: HostID, name: String, online: Bool, version: String) {
        self.id = id
        self.name = name
        self.online = online
        self.version = version
    }
}

public struct WorkspaceRecord: Sendable, Equatable, Identifiable {
    public var id: WorkspaceID
    public var name: String

    public init(id: WorkspaceID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AgentRecord: Sendable, Equatable, Identifiable {
    public var id: AgentID
    public var name: String
    public var pluginID: String
    public var models: [AgentModelRecord]?
    public var defaultModel: String?

    public init(id: AgentID, name: String, pluginID: String) {
        self.id = id
        self.name = name
        self.pluginID = pluginID
        self.models = nil
        self.defaultModel = nil
    }
}

/// One selectable value of an Agent option, as the Host labels it.
public struct AgentOptionChoice: Codable, Sendable, Equatable, Hashable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// Conversation options an Agent exposes through `catalog.agent`. Empty
/// choices mean the Agent does not offer that option (e.g. Fast outside
/// Codex, or anything on Agents configured natively).
public struct AgentConversationOptions: Codable, Sendable, Equatable {
    public var catalogRevision: String?
    public var thinking: [AgentOptionChoice]
    public var approval: [AgentOptionChoice]
    public var approvalDefault: String?
    public var supportsFast: Bool
    /// Models Fast is limited to; nil means every model.
    public var fastModels: Set<String>?

    public init(
        catalogRevision: String? = nil,
        thinking: [AgentOptionChoice] = [],
        approval: [AgentOptionChoice] = [],
        approvalDefault: String? = nil,
        supportsFast: Bool = false,
        fastModels: Set<String>? = nil
    ) {
        self.catalogRevision = catalogRevision
        self.thinking = thinking
        self.approval = approval
        self.approvalDefault = approvalDefault
        self.supportsFast = supportsFast
        self.fastModels = fastModels
    }

    public func fastAvailable(forModel model: String?) -> Bool {
        guard supportsFast else { return false }
        guard let fastModels else { return true }
        return model.map(fastModels.contains) ?? false
    }
}

public struct AgentModelRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var isDefault: Bool
    public var supportedThinking: [String]

    public init(id: String, label: String, isDefault: Bool, supportedThinking: [String]) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.supportedThinking = supportedThinking
    }
}

public struct TaskRecord: Sendable, Equatable, Identifiable {
    public var id: TaskID
    public var title: String
    public var status: TaskStatus
    public var updatedAt: Date

    public init(id: TaskID, title: String, status: TaskStatus, updatedAt: Date) {
        self.id = id
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct SessionRecord: Sendable, Equatable, Identifiable {
    public var id: SessionID
    public var hostID: HostID
    public var title: String
    public var revision: String
    public var taskID: TaskID?
    public var workspaceID: WorkspaceID
    public var agentID: AgentID
    public var agentName: String
    public var pluginID: String
    public var status: SessionStatus
    public var archived: Bool
    public var authorized: Bool
    public var unread: Bool
    public var attention: AttentionKind?
    /// Message or execution time. Viewing must leave `activityIsMessageOrExecution` false.
    public var lastActivityAt: Date?
    public var activityIsMessageOrExecution: Bool
    public var updatedAt: Date
    public var completedAt: String?
    /// Settings the Host reports for the conversation; nil means the Agent's
    /// default. `session.update` changes them and they apply from the next turn.
    public var model: String?
    public var thinking: String?
    /// `fast`, or nil for the standard tier.
    public var serviceTier: String?
    public var approvalMode: String?

    public init(
        id: SessionID,
        hostID: HostID,
        title: String,
        revision: String,
        taskID: TaskID?,
        workspaceID: WorkspaceID,
        agentID: AgentID,
        agentName: String,
        pluginID: String,
        status: SessionStatus,
        archived: Bool = false,
        authorized: Bool = true,
        unread: Bool = false,
        attention: AttentionKind? = nil,
        lastActivityAt: Date? = nil,
        activityIsMessageOrExecution: Bool = false,
        updatedAt: Date
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.revision = revision
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.agentID = agentID
        self.agentName = agentName
        self.pluginID = pluginID
        self.status = status
        self.archived = archived
        self.authorized = authorized
        self.unread = unread
        self.attention = attention
        self.lastActivityAt = lastActivityAt
        self.activityIsMessageOrExecution = activityIsMessageOrExecution
        self.updatedAt = updatedAt
        self.completedAt = nil
    }
}

public struct ConversationSummary: Sendable, Equatable, Identifiable {
    public var id: SessionID
    public var title: String
    public var agentName: String
    public var pluginID: String
    public var repositoryName: String?
    public var status: SessionStatus
    public var unread: Bool
    public var attention: AttentionKind?
    public var lastActivityAt: Date?
    public var taskID: TaskID?
    public var hostID: HostID

    public init(
        id: SessionID,
        title: String,
        agentName: String,
        pluginID: String,
        repositoryName: String?,
        status: SessionStatus,
        unread: Bool,
        attention: AttentionKind?,
        lastActivityAt: Date?,
        taskID: TaskID?,
        hostID: HostID
    ) {
        self.id = id
        self.title = title
        self.agentName = agentName
        self.pluginID = pluginID
        self.repositoryName = repositoryName
        self.status = status
        self.unread = unread
        self.attention = attention
        self.lastActivityAt = lastActivityAt
        self.taskID = taskID
        self.hostID = hostID
    }
}

public struct TaskSection: Sendable, Equatable, Identifiable {
    public var id: TaskID
    public var title: String
    public var conversations: [ConversationSummary]

    public init(id: TaskID, title: String, conversations: [ConversationSummary]) {
        self.id = id
        self.title = title
        self.conversations = conversations
    }
}

public enum AttachmentBodyState: Sendable, Equatable {
    case localOnly
    case uploading
    case uploaded
    case downloading
    case cached
    case expired
    case unavailable
    case hashMismatch
    case failed(String)
}

public struct DraftAttachment: Sendable, Equatable, Identifiable {
    public var id: AttachmentID
    public var filename: String
    public var mime: String
    public var byteCount: Int
    public var sha256: String
    public var state: AttachmentBodyState
    public var remoteID: AttachmentID?

    public init(
        id: AttachmentID,
        filename: String,
        mime: String,
        byteCount: Int,
        sha256: String,
        state: AttachmentBodyState,
        remoteID: AttachmentID? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mime = mime
        self.byteCount = byteCount
        self.sha256 = sha256
        self.state = state
        self.remoteID = remoteID
    }
}

public enum DraftTarget: Hashable, Sendable, Equatable {
    case newConversation
    case conversation(SessionID)
}

public struct DraftDocument: Sendable, Equatable, Identifiable {
    /// Local optimistic-edit identity, independent of clock precision.
    public var localRevision: Int = 0
    public var id: DraftID
    public var hostID: HostID?
    public var target: DraftTarget
    public var text: String
    public var attachments: [DraftAttachment]
    public var updatedAt: Date
    public var boundSessionID: SessionID?
    public var boundCreationID: CommandID?

    public init(
        id: DraftID,
        hostID: HostID?,
        target: DraftTarget,
        text: String,
        attachments: [DraftAttachment],
        updatedAt: Date,
        boundSessionID: SessionID? = nil,
        boundCreationID: CommandID? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.target = target
        self.text = text
        self.attachments = attachments
        self.updatedAt = updatedAt
        self.boundSessionID = boundSessionID
        self.boundCreationID = boundCreationID
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

public struct AttachmentDraftInput: Sendable, Equatable {
    public var filename: String
    public var mime: String
    public var bytes: Data

    public init(filename: String, mime: String, bytes: Data) {
        self.filename = filename
        self.mime = mime
        self.bytes = bytes
    }
}

public enum TranslationIntegrityState: String, Sendable, Equatable {
    case inlineVerified
    case descriptorPending
    case pagedVerified
    case hashMismatch
    case lengthMismatch
}

public struct ReadingTranslation: Sendable, Equatable, Identifiable {
    public var id: TranslationRecordID
    public var sourceID: String?
    public var targetLanguage: String
    /// Present only after the UTF-16 length and UTF-8 SHA-256 both match.
    public var presentableText: String?
    public var textLength: Int
    public var textSHA256: String
    public var sourceSHA256: String
    public var integrity: TranslationIntegrityState

    public init(
        id: TranslationRecordID,
        sourceID: String?,
        targetLanguage: String,
        presentableText: String?,
        textLength: Int,
        textSHA256: String,
        sourceSHA256: String,
        integrity: TranslationIntegrityState
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetLanguage = targetLanguage
        self.presentableText = presentableText
        self.textLength = textLength
        self.textSHA256 = textSHA256
        self.sourceSHA256 = sourceSHA256
        self.integrity = integrity
    }
}

public struct SentTranslation: Sendable, Equatable {
    public var id: TranslationRecordID
    public var presentableText: String?
    public var textLength: Int
    public var textSHA256: String
    public var targetLanguage: String
    public var integrity: TranslationIntegrityState

    public init(
        id: TranslationRecordID,
        presentableText: String?,
        textLength: Int,
        textSHA256: String,
        targetLanguage: String,
        integrity: TranslationIntegrityState
    ) {
        self.id = id
        self.presentableText = presentableText
        self.textLength = textLength
        self.textSHA256 = textSHA256
        self.targetLanguage = targetLanguage
        self.integrity = integrity
    }
}

public struct AutomaticProgress: Sendable, Equatable {
    public var pending: Bool
    public var error: String?

    public init(pending: Bool, error: String? = nil) {
        self.pending = pending
        self.error = error
    }
}

public struct ReadingRequestState: Sendable, Equatable {
    public var requestID: TranslationRequestID
    public var pending: Bool
    public var uncertain: Bool
    public var error: String?

    public init(requestID: TranslationRequestID, pending: Bool, uncertain: Bool, error: String? = nil) {
        self.requestID = requestID
        self.pending = pending
        self.uncertain = uncertain
        self.error = error
    }
}

public struct TranslationSessionState: Sendable, Equatable {
    public var supported: Bool
    public var enabled: Bool
    public var configured: Bool
    public var sendingLanguage: String
    public var readingLanguage: String
    public var revision: Int
    public var configRevision: Int
    public var automaticRevision: Int
    public var automaticEpoch: String
    public var automatic: [String: AutomaticProgress]
    public var records: [ReadingTranslation]
    public var reading: [String: ReadingRequestState]
    public var notice: String

    public init(
        supported: Bool,
        enabled: Bool,
        configured: Bool,
        sendingLanguage: String,
        readingLanguage: String,
        revision: Int,
        configRevision: Int,
        automaticRevision: Int,
        automaticEpoch: String,
        automatic: [String: AutomaticProgress] = [:],
        records: [ReadingTranslation] = [],
        reading: [String: ReadingRequestState] = [:],
        notice: String = ""
    ) {
        self.supported = supported
        self.enabled = enabled
        self.configured = configured
        self.sendingLanguage = sendingLanguage
        self.readingLanguage = readingLanguage
        self.revision = revision
        self.configRevision = configRevision
        self.automaticRevision = automaticRevision
        self.automaticEpoch = automaticEpoch
        self.automatic = automatic
        self.records = records
        self.reading = reading
        self.notice = notice
    }

    public static let unsupported = TranslationSessionState(
        supported: false,
        enabled: false,
        configured: false,
        sendingLanguage: "",
        readingLanguage: "",
        revision: 0,
        configRevision: 0,
        automaticRevision: 0,
        automaticEpoch: ""
    )
}

public enum ToolStatus: String, Sendable, Equatable {
    case pending, running, success, error
}

public enum AgentRunStatus: String, Sendable, Equatable {
    case running, done, error
}

public enum FileSearchKind: String, Sendable, Equatable {
    case glob, grep
}

public enum NoticeSeverity: String, Sendable, Equatable {
    case info, warning, error
}

public enum CircuitTrigger: String, Sendable, Equatable {
    case consecutive, total
}

public enum TurnOutcome: String, Sendable, Equatable {
    case worked, failed, stopped
}

public enum TranscriptBody: Sendable, Equatable {
    case user(text: String, deliveryID: String?, attachmentIDs: [AttachmentID], translation: SentTranslation?)
    case assistant(text: String, delta: Bool)
    case command(status: ToolStatus, exitCode: Int?)
    case fileChange(fileCount: Int)
    case fileRead
    case fileSearch(kind: FileSearchKind, matchCount: Int?)
    case webSearch(resultCount: Int?)
    case tool(name: String, status: ToolStatus)
    case agent(status: AgentRunStatus, agentType: String?, model: String?, background: Bool)
    case notice(severity: NoticeSeverity, code: String)
    case classifierDenied(consecutive: Int, total: Int)
    case circuitBreaker(trigger: CircuitTrigger, consecutive: Int, total: Int)
    case turnEnd(outcome: TurnOutcome)
    case error
}

public struct TranscriptItem: Sendable, Equatable, Identifiable {
    public var id: TranscriptItemID
    public var turnID: TurnID
    public var turn: Int
    public var timestamp: Date
    public var body: TranscriptBody

    public init(id: TranscriptItemID, turnID: TurnID, turn: Int, timestamp: Date, body: TranscriptBody) {
        self.id = id
        self.turnID = turnID
        self.turn = turn
        self.timestamp = timestamp
        self.body = body
    }
}

public enum InteractionKind: String, Sendable, Equatable {
    case approval, question, exitPlanMode = "exit_plan_mode", nativeChoice = "native_choice"
}

public enum InteractionRisk: String, Sendable, Equatable {
    case low, medium, high
}

public enum ActionTone: String, Sendable, Equatable {
    case `default`, danger
}

public enum InteractionPhase: String, Sendable, Equatable {
    case pending, responding, uncertain, resolvedHere, resolvedElsewhere, expired, failed
}

public struct InteractionAction: Sendable, Equatable, Identifiable {
    public var id: ActionID
    public var label: String
    public var tone: ActionTone

    public init(id: ActionID, label: String, tone: ActionTone) {
        self.id = id
        self.label = label
        self.tone = tone
    }
}

public enum InteractionInputType: String, Sendable, Equatable {
    case text, multilineText = "multiline_text", singleSelect = "single_select"
    case multiSelect = "multi_select", boolean
}

public struct InteractionInput: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var type: InteractionInputType
    public var options: [InteractionInputOption]?

    public init(id: String, label: String, type: InteractionInputType) {
        self.id = id
        self.label = label
        self.type = type
        self.options = nil
    }

    public init(id: String, label: String, type: InteractionInputType, options: [InteractionInputOption]) {
        self.id = id
        self.label = label
        self.type = type
        self.options = options
    }
}

public struct InteractionInputOption: Codable, Sendable, Equatable, Identifiable {
    public var value: String
    public var label: String
    public var description: String?
    public var id: String { value }

    public init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }
}

public struct InteractionRecord: Sendable, Equatable, Identifiable {
    public var id: InteractionID
    public var revision: String
    public var sessionID: SessionID
    public var turnID: TurnID
    public var kind: InteractionKind
    public var title: String
    public var detail: String
    public var risk: InteractionRisk
    public var actions: [InteractionAction]
    public var inputs: [InteractionInput]
    public var phase: InteractionPhase

    public init(
        id: InteractionID,
        revision: String,
        sessionID: SessionID,
        turnID: TurnID,
        kind: InteractionKind,
        title: String,
        detail: String,
        risk: InteractionRisk,
        actions: [InteractionAction],
        inputs: [InteractionInput] = [],
        phase: InteractionPhase = .pending
    ) {
        self.id = id
        self.revision = revision
        self.sessionID = sessionID
        self.turnID = turnID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.risk = risk
        self.actions = actions
        self.inputs = inputs
        self.phase = phase
    }
}

public enum InteractionValue: Sendable, Equatable {
    case text(String)
    case boolean(Bool)
    case list([String])
}

public enum OperationStage: String, Sendable, Equatable {
    case create, translation, send
}

public struct DurableSendIntent: Sendable, Equatable {
    public var draftID: DraftID
    public var stage: OperationStage
    public var creationID: CommandID?
    public var sendID: CommandID?
    public var translationRequestID: TranslationRequestID?
    public var sessionID: SessionID?
    public var translationReceiptID: TranslationRecordID?
    public var explicitOriginal: Bool
    public var createDispatched: Bool
    public var translationDispatched: Bool
    public var sendDispatched: Bool
    public var userRequestedSend: Bool
    public var createRequest: SessionCreateRequest?
    public var sendRequest: SessionSendRequest?

    public init(
        draftID: DraftID,
        stage: OperationStage,
        creationID: CommandID? = nil,
        sendID: CommandID? = nil,
        translationRequestID: TranslationRequestID? = nil,
        sessionID: SessionID? = nil,
        translationReceiptID: TranslationRecordID? = nil,
        explicitOriginal: Bool = false,
        createDispatched: Bool = false,
        translationDispatched: Bool = false,
        sendDispatched: Bool = false,
        userRequestedSend: Bool = true
    ) {
        self.draftID = draftID
        self.stage = stage
        self.creationID = creationID
        self.sendID = sendID
        self.translationRequestID = translationRequestID
        self.sessionID = sessionID
        self.translationReceiptID = translationReceiptID
        self.explicitOriginal = explicitOriginal
        self.createDispatched = createDispatched
        self.translationDispatched = translationDispatched
        self.sendDispatched = sendDispatched
        self.userRequestedSend = userRequestedSend
        self.createRequest = nil
        self.sendRequest = nil
    }
}

public enum SendPhase: Sendable, Equatable {
    case idle
    case creating(DurableSendIntent)
    case awaitingTranslation(DurableSendIntent)
    case sending(DurableSendIntent)
    case uncertain(DurableSendIntent)
    case failed(DurableSendIntent, message: String)
    case succeeded(DurableSendIntent)

    public var intent: DurableSendIntent? {
        switch self {
        case .idle: return nil
        case .creating(let intent), .awaitingTranslation(let intent), .sending(let intent),
             .uncertain(let intent), .failed(let intent, _), .succeeded(let intent):
            return intent
        }
    }

    public var isInFlight: Bool {
        switch self {
        case .creating, .awaitingTranslation, .sending: return true
        case .idle, .uncertain, .failed, .succeeded: return false
        }
    }
}

public struct BannerItem: Sendable, Equatable, Identifiable {
    public var id: BannerID
    public var sessionID: SessionID
    public var title: String
    public var summary: String
    public var eventCount: Int
    public var latestAt: Date

    public init(id: BannerID, sessionID: SessionID, title: String, summary: String, eventCount: Int, latestAt: Date) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.summary = summary
        self.eventCount = eventCount
        self.latestAt = latestAt
    }
}

public struct SyncCursor: Sendable, Equatable {
    public var hostGeneration: HostGenerationID
    /// Last applied canonical sequence, or -1 before the first canonical event.
    /// Remote projects a snapshot's raw next-sequence counter by subtracting one.
    /// Transcript and translation live frames do not occupy this sequence.
    public var eventSequence: Int
    public var revision: String

    public init(hostGeneration: HostGenerationID, eventSequence: Int, revision: String) {
        self.hostGeneration = hostGeneration
        self.eventSequence = eventSequence
        self.revision = revision
    }
}

public enum SnapshotRequiredReason: String, Sendable, Equatable {
    case cryptoResumed = "crypto_resumed"
    case generationChanged = "generation_changed"
    case gapEvicted = "gap_evicted"
    case revisionMismatch = "revision_mismatch"
    case serverRestart = "server_restart"
}

// Local storage serialization only; these are not Remote wire payloads.
extension SessionStatus: Codable {}
extension TaskStatus: Codable {}
extension AttentionKind: Codable {}
extension DirectoryAuthority: Codable {}
extension HostSummary: Codable {}
extension WorkspaceRecord: Codable {}
extension AgentRecord: Codable {}
extension TaskRecord: Codable {}
extension SessionRecord: Codable {}
extension AttachmentBodyState: Codable {}
extension DraftAttachment: Codable {}
extension DraftTarget: Codable {}
extension DraftDocument: Codable {}
extension TranslationIntegrityState: Codable {}
extension ReadingTranslation: Codable {}
extension SentTranslation: Codable {}
extension AutomaticProgress: Codable {}
extension ReadingRequestState: Codable {}
extension TranslationSessionState: Codable {}
extension ToolStatus: Codable {}
extension AgentRunStatus: Codable {}
extension FileSearchKind: Codable {}
extension NoticeSeverity: Codable {}
extension CircuitTrigger: Codable {}
extension TurnOutcome: Codable {}
extension TranscriptBody: Codable {}
extension TranscriptItem: Codable {}
extension InteractionKind: Codable {}
extension InteractionRisk: Codable {}
extension ActionTone: Codable {}
extension InteractionPhase: Codable {}
extension InteractionAction: Codable {}
extension InteractionInputType: Codable {}
extension InteractionInput: Codable {}
extension InteractionRecord: Codable {}
extension OperationStage: Codable {}
extension DurableSendIntent: Codable {}
extension SendPhase: Codable {}
extension SyncCursor: Codable {}
