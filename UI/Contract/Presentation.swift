import Foundation
import GianCore

/// Presentation-only view inputs projected from the delivered GianCore
/// contract. These structs carry no behavior and no store access; they exist
/// so views stay simple value renderers. All identity fields are the typed
/// contract IDs, so dispatch needs no re-parsing.

// MARK: - Agents

/// Agent logo selection from the Host-supplied plugin identity. Unknown
/// plugins render a neutral symbol — never a wrong logo.
/// An Agent's logo: the Host's own (`proxy.logo`, looked up by plugin ID)
/// when it has one, else a bundled copy for well-known Agents, else the
/// Agent name's initial (see `AgentAvatar`).
struct AgentLogo: Equatable, Sendable {
    enum Bundled: Equatable, Sendable {
        case claude, codex, deepseek, grok, kimi, zcode

        var assetName: String {
            switch self {
            case .claude: "agent-claude"
            case .codex: "agent-codex"
            case .deepseek: "agent-deepseek"
            case .grok: "agent-grok"
            case .kimi: "agent-kimi"
            case .zcode: "agent-zcode"
            }
        }
    }

    var pluginID: String
    var bundled: Bundled?

    init(pluginID: String, agentName: String) {
        self.pluginID = pluginID
        let token = (pluginID + " " + agentName).lowercased()
        if token.contains("claude") || token.contains("cc-proxy") { bundled = .claude }
        else if token.contains("codex") { bundled = .codex }
        else if token.contains("deepseek") || token.contains("dsh") { bundled = .deepseek }
        else if token.contains("grok") { bundled = .grok }
        else if token.contains("kimi") { bundled = .kimi }
        else if token.contains("zcode") { bundled = .zcode }
        else { bundled = nil }
    }

    private init(pluginID: String, bundled: Bundled?) {
        self.pluginID = pluginID
        self.bundled = bundled
    }

    var assetName: String? { bundled?.assetName }

    // Shorthands for previews and fixtures.
    static let claude = AgentLogo(pluginID: "claude", bundled: .claude)
    static let codex = AgentLogo(pluginID: "codex", bundled: .codex)
    static let deepseek = AgentLogo(pluginID: "dsh", bundled: .deepseek)
    static let grok = AgentLogo(pluginID: "grok", bundled: .grok)
    static let kimi = AgentLogo(pluginID: "kimi", bundled: .kimi)
    static let zcode = AgentLogo(pluginID: "zcode", bundled: .zcode)
    static let other = AgentLogo(pluginID: "", bundled: nil)
}

// MARK: - Directory

/// Row badge derived from the contract session status plus attention.
enum StatusBadge: Equatable, Sendable {
    case working
    case waiting
    case failed
    case idle

    init(status: SessionStatus, attention: AttentionKind?) {
        if let attention {
            switch attention {
            case .running: self = .working; return
            case .interaction: self = .waiting; return
            case .failed: self = .failed; return
            case .completed: break
            }
        }
        switch status {
        case .running: self = .working
        case .pending: self = .waiting
        case .error: self = .failed
        case .new, .done: self = .idle
        }
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }
}

struct HostItem: Identifiable, Equatable, Sendable {
    let id: HostID
    var name: String
    var isReachable: Bool
    var isCurrent: Bool
}

/// One row in Tasks/Repos/search, projected from `ConversationSummary`.
struct ConversationRowItem: Identifiable, Equatable, Sendable {
    let id: SessionID
    var title: String
    var agent: AgentLogo
    var agentName: String
    var repoName: String?
    var badge: StatusBadge
    var lastActivity: Date?
    /// The Host's read state; a finished conversation shows its status icon
    /// only while unread.
    var unread = false
}

struct TaskGroupItem: Identifiable, Equatable, Sendable {
    let id: TaskID
    var title: String
    var conversations: [ConversationRowItem]
}

struct RepoGroupItem: Identifiable, Equatable, Sendable {
    let id: WorkspaceID
    var repoName: String
    var conversations: [ConversationRowItem]
}

/// Honest surface availability from the contract projection.
enum SurfaceAvailability: Equatable, Sendable {
    case ready
    case unsupported(message: String)
}

struct DirectoryPresentation: Equatable, Sendable {
    var view: DirectoryView
    var tasks: [TaskGroupItem]
    var repos: [RepoGroupItem]
    var reposAvailability: SurfaceAvailability
    var searchQuery: String
    var searchResults: [ConversationRowItem]
    var searchAvailability: SurfaceAvailability
    var tasksPage: DirectoryPageStatus
    var reposPage: DirectoryPageStatus
    var searchPage: DirectoryPageStatus
    var timeFilter: DirectoryTimeFilter = .last7Days
    var temporarySearchResult: ConversationRowItem? = nil
    var temporarySearchGeneration: Int = 0
    var temporaryCreatedResults: [ConversationRowItem] = []
}

// MARK: - Transcript rows

struct UserRow: Equatable, Identifiable, Sendable {
    let id: TranscriptItemID
    var text: String
    var attachmentIDs: [AttachmentID]
    var sentTranslation: SentTranslation?
}

/// Reading-translation presentation for one assistant item, derived from the
/// session's translation records, in-flight reading requests and automatic
/// progress.
enum ReadingTranslationPresentation: Equatable, Sendable {
    case none
    case translating
    /// Settled but the ack was uncertain; never re-requested implicitly.
    case uncertain
    case failed(String)
    case unavailable(String)
    /// Verified text ready to show.
    case translated(ReadingTranslation)
    /// Descriptor verified but full text must be paged before display.
    case needsPaging(ReadingTranslation)
}

struct AssistantRow: Equatable, Identifiable, Sendable {
    let id: TranscriptItemID
    var agent: AgentLogo
    var agentName: String
    var markdown: String
    var reading: ReadingTranslationPresentation
    var translationSourceID: String? = nil
    var translationExpandedByDefault: Bool = true
    var canCancelTranslation: Bool = false
    var isFinalResult: Bool = true
}

struct WorkEventItem: Equatable, Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        case command, fileChange, fileRead, fileSearch, webSearch, tool, subagent, warning
    }

    enum Outcome: Sendable {
        case running, done, failed, unknown
    }

    let id: TranscriptItemID
    var kind: Kind
    var title: String
    var outcome: Outcome
    var statusText: String
}

struct WorkCard: Equatable, Identifiable, Sendable {
    enum Phase: Sendable {
        case working, worked, failed, stopped, unknown
    }

    let id: TurnID
    var phase: Phase
    var events: [WorkEventItem]
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    /// The turn number, set once a turn's work is consolidated into one card.
    var turn: Int? = nil
}

enum TranscriptRow: Equatable, Identifiable, Sendable {
    case timeMarker(id: String, label: String)
    case user(UserRow)
    case assistant(AssistantRow)
    case work(WorkCard)
    case interaction(InteractionRecord)
    case turnOutcome(id: TranscriptItemID, outcome: TurnOutcome)
    case severeError(id: TranscriptItemID)
    case notice(id: TranscriptItemID, severity: NoticeSeverity, code: String)

    var id: String {
        switch self {
        case .timeMarker(let id, _): "marker-\(id)"
        case .user(let row): row.id.rawValue
        case .assistant(let row): row.id.rawValue
        // Stable for the whole turn, so the card keeps its expansion and
        // scroll anchor while events arrive or a page reorders them.
        case .work(let card): card.turn.map { "work-turn-\($0)" } ?? "work-\(card.id.rawValue)"
        case .interaction(let record): "interaction-\(record.id.rawValue)"
        case .turnOutcome(let id, _): "outcome-\(id.rawValue)"
        case .severeError(let id): "error-\(id.rawValue)"
        case .notice(let id, _, _): "notice-\(id.rawValue)"
        }
    }
}

// MARK: - Composer

/// Presentation of the durable send pipeline for the composer accessory area.
enum SendPhasePresentation: Equatable, Sendable {
    case editable
    /// The draft is shown in the transcript as a pending message; the
    /// composer stays empty until it is sent or taken back.
    case held
    case creating
    case translating
    case sending
    case failed(message: String, isTranslationStage: Bool)
    case uncertain

    init(_ phase: SendPhase) {
        switch phase {
        case .idle, .succeeded: self = .editable
        case .creating: self = .creating
        case .awaitingTranslation: self = .translating
        case .sending: self = .sending
        case .uncertain: self = .uncertain
        case .failed(let intent, let message):
            self = .failed(message: message, isTranslationStage: intent.stage == .translation)
        }
    }
}

enum ComposerNoticePresentation: Equatable, Sendable {
    case none
    case offlineDraftRetained
    case keptAfterUncertainOutcome
    case translationNeedsChoice
    case legacyTaskRequired

    init(_ notice: ComposerNotice) {
        switch notice {
        case .none: self = .none
        case .offlineDraftRetained: self = .offlineDraftRetained
        case .keptAfterUncertainOutcome: self = .keptAfterUncertainOutcome
        case .translationNeedsChoice: self = .translationNeedsChoice
        case .legacyTaskRequired: self = .legacyTaskRequired
        }
    }

    var message: String? {
        switch self {
        case .none: nil
        case .offlineDraftRetained: "Offline — the draft was kept on this device."
        case .keptAfterUncertainOutcome: "The outcome is uncertain. The draft was kept; nothing was resent."
        case .translationNeedsChoice: "Translation needs attention: retry it or send the original text."
        case .legacyTaskRequired: "This Host requires an open task for a new conversation. Choose a task first."
        }
    }
}

// MARK: - Translation session

enum TranslationCapabilityPresentation: Equatable, Sendable {
    case configured
    case unconfigured
    case unsupported
}

struct SessionTranslationPresentation: Equatable, Sendable {
    var capability: TranslationCapabilityPresentation
    var isAutomatic: Bool
    var sendingLanguage: String
    var readingLanguage: String
    var notice: String
}

// MARK: - Connectivity

enum ConnectivityPresentation: Equatable, Sendable {
    case hidden
    case offlineHistory
    case reconnecting
    case hostOffline
    case resyncing
    case deviceRevoked
    case versionMismatch(String)

    init(_ connection: ConnectionProjection) {
        switch connection {
        case .signedOut, .online: self = .hidden
        case .offline: self = .offlineHistory
        case .hostOffline: self = .hostOffline
        case .resyncing: self = .resyncing
        case .reconnecting: self = .reconnecting
        case .deviceRevoked: self = .deviceRevoked
        case .versionMismatch(let version): self = .versionMismatch(version)
        }
    }
}

struct BannerPresentation: Equatable, Identifiable, Sendable {
    let id: BannerID
    var sessionID: SessionID
    var agent: AgentLogo
    var title: String
    var kind: BannerEvent
    var summary: String
}

// MARK: - Diagnostics (sanitized, never raw error text)

enum DiagnosticPresentation: Equatable, Sendable {
    case none
    case connectionClosed(message: String)
    case resyncRequired(reason: String)
}

struct ConversationStatusPresentation: Equatable, Sendable {
    let label: String
    let symbol: String
    let details: [String]
    let retryConnection: Bool
    let retryMessages: Bool
    let isError: Bool
    /// Work in progress (reconnecting, syncing): the symbol spins.
    var isActivity = false

    static func make(connectivity: ConnectivityPresentation, diagnostic: DiagnosticPresentation,
                     transcriptSync: TranscriptSyncState) -> Self? {
        var details: [String] = []
        var primary: (label: String, symbol: String, error: Bool, activity: Bool)?
        var retryConnection = false
        var retryMessages = false
        func add(_ label: String, _ symbol: String, _ detail: String, error: Bool = false, activity: Bool = false) {
            if primary == nil { primary = (label, symbol, error, activity) }
            details.append(detail)
        }
        switch connectivity {
        case .offlineHistory:
            add("Offline", "wifi.slash", "Offline. Showing saved history.")
            retryConnection = true
        case .hostOffline:
            add("Host offline", "laptopcomputer.slash", "The Host is offline.")
            retryConnection = true
        case .deviceRevoked: add("Access revoked", "hand.raised.fill", "This device's access was revoked. Pair the Host again.", error: true)
        case .versionMismatch(let version): add("Incompatible", "exclamationmark.triangle", "Host version \(version) is not supported by this app.", error: true)
        case .hidden, .reconnecting, .resyncing: break
        }
        if transcriptSync == .failed {
            add("Sync failed", "exclamationmark.triangle", "Messages could not be synchronized.", error: true)
            retryMessages = true
        }
        if case .connectionClosed(let message) = diagnostic {
            add("Connection lost", "wifi.exclamationmark", message, error: true)
            // Failed integrity, payload or version checks aren't retried on
            // their own, and an automatic retry can be 32 s away. Only pairing
            // again helps a revoked device.
            if connectivity != .deviceRevoked { retryConnection = true }
        }
        switch connectivity {
        case .reconnecting: add("Reconnecting", "arrow.triangle.2.circlepath", "Reconnecting to the Host.", activity: true)
        case .resyncing: add("Syncing", "arrow.triangle.2.circlepath", "Catching up with the Host.", activity: true)
        default: break
        }
        if case .resyncRequired = diagnostic {
            add("Sync required", "arrow.triangle.2.circlepath", "Synchronization is required.", error: true)
            retryConnection = true
        }
        if transcriptSync == .syncing { add("Syncing", "arrow.triangle.2.circlepath", "Synchronizing messages.", activity: true) }
        guard let primary else { return nil }
        return Self(label: primary.label, symbol: primary.symbol, details: details, retryConnection: retryConnection,
                    retryMessages: retryMessages, isError: primary.error, isActivity: primary.activity)
    }
}

/// What the chat title's status is made of. The title shows these once they
/// have settled, so a quick sync or reconnect never flickers in it.
struct ConversationStatusInputs: Equatable, Sendable {
    var session: SessionID?
    var connectivity: ConnectivityPresentation
    var diagnostic: DiagnosticPresentation
    var transcriptSync: TranscriptSyncState

    /// Nothing to show.
    static let quiet = Self(session: nil, connectivity: .hidden, diagnostic: .none, transcriptSync: .idle)

    /// A status shows, changes or clears once it has lasted this long.
    static let settle: Duration = .milliseconds(300)

    var status: ConversationStatusPresentation? {
        .make(connectivity: connectivity, diagnostic: diagnostic, transcriptSync: transcriptSync)
    }

    /// What the title shows at once when `latest` arrives while it shows
    /// `shown`, and whether `latest` follows once it has settled. New details
    /// of the status shown apply at once. Another chat starts from nothing
    /// shown for its messages, not from the previous chat's.
    static func next(shown: Self, latest: Self) -> (now: Self, settling: Bool) {
        var now = shown
        if now.session != latest.session { now.session = latest.session; now.transcriptSync = .idle }
        if now.status?.label == latest.status?.label { return (latest, false) }
        return (now, true)
    }
}

// MARK: - Transcript files

/// Cache-aware presentation of one transcript attachment, from the Core
/// descriptor plus the bounded download cache state.
enum AttachmentFilePresentation: Equatable, Sendable {
    /// No descriptor — render an honest "unavailable" note, not a fake file.
    case unknown
    case readyToDownload(name: String, byteCount: Int, previewable: Bool)
    case downloading(name: String)
    /// Verified bytes are in the bounded in-process cache; preview allowed.
    case cached(name: String, previewable: Bool)
    case expired(name: String)
    case unavailable(name: String)
    case failed(name: String, message: String)

    var displayName: String {
        switch self {
        case .unknown: "Attachment"
        case .readyToDownload(let name, _, _),
             .downloading(let name),
             .cached(let name, _),
             .expired(let name),
             .unavailable(let name),
             .failed(let name, _):
            name
        }
    }
}

// MARK: - Active conversation

struct ActiveConversationPresentation: Equatable, Sendable {
    var id: SessionID
    var title: String
    var hostName: String
    var rows: [TranscriptRow]
    var hasOlderPages: Bool
    var connectivity: ConnectivityPresentation
    var translation: SessionTranslationPresentation?
    var isTurnActive: Bool
    var transcriptSync: TranscriptSyncState = .idle
    var queue: SessionQueue? = nil
    var queueCommand: QueueCommandState? = nil
    var canUpdateQueue = false
    var canRemoveQueue = false
    var canClearQueue = false
    var canSendQueueNow = false
    /// The user's message on its way, shown after the transcript.
    var pendingSend: PendingSendRow? = nil
    /// The composer stays empty while its draft is on its way.
    var holdsDraft = false
}

/// The user's message while it is on its way (the desktop's "echo"): dimmed
/// at the end of the transcript until the Host has it, with the translation's
/// status and choices beneath. The composer is empty meanwhile.
struct PendingSendRow: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case translating
        /// `showsStatus` for a send that went through translation; a plain
        /// send is only dimmed.
        case sending(showsStatus: Bool)
        case failed(String)
    }

    let text: String
    let attachmentCount: Int
    let phase: Phase
}

/// The options a conversation can change while it runs, for the composer's ⋯
/// menu. Empty choice lists hide that item (the Agent doesn't offer it).
struct ConversationSettingsPresentation: Equatable, Sendable {
    enum Fast: Equatable, Sendable {
        /// The Agent has no Fast option.
        case unavailable
        /// Fast exists but not for the current model.
        case unsupportedModel
        case available(isOn: Bool)
    }

    /// The conversation's Agent: its logo marks the Model row.
    var agent: AgentLogo = .other
    var agentName: String = "Agent"
    var models: [AgentOptionChoice] = []
    var model: String?
    var thinking: [AgentOptionChoice] = []
    var currentThinking: String?
    var fast: Fast = .unavailable
    var approval: [AgentOptionChoice] = []
    var currentApproval: String?
    /// False while a change is in flight or mutations are gated.
    var isEnabled: Bool = true
    var notice: String?

    /// Fast is shown only when the current model offers it.
    var showsFast: Bool {
        if case .available = fast { return true }
        return false
    }

    var isEmpty: Bool {
        models.isEmpty && thinking.isEmpty && !showsFast && approval.isEmpty
    }
}
