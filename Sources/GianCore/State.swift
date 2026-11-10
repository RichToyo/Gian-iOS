import Foundation

public enum ClientPhase: Sendable, Equatable {
    case signedOut
    /// A Server address is set; its identity is being verified (or failed).
    case serverEntered
    case awaitingHostPairing
    case ready
}

public enum AccountStatus: String, Sendable, Equatable {
    /// No Server yet.
    case signedOut
    /// Verifying the Server's identity.
    case pending
    case signedIn
    /// The Server couldn't be reached or answered unexpectedly.
    case error
    /// The Server's identity differs from the one pinned on first use.
    case serverIdentityChanged
}

/// This app's standing on the current Server: its controller identity there
/// once the Server's identity is verified and pinned. No person's account.
public struct AccountAuthorization: Sendable, Equatable {
    public var status: AccountStatus
    public var accountID: AccountID?
    public var installationID: InstallationID?
    /// Why connecting to the Server failed, for setup to show.
    public var failure: String?

    public init(
        status: AccountStatus,
        accountID: AccountID? = nil,
        installationID: InstallationID? = nil,
        failure: String? = nil
    ) {
        self.status = status
        self.accountID = accountID
        self.installationID = installationID
        self.failure = failure
    }

    public static let signedOut = AccountAuthorization(status: .signedOut)
}

/// How the last pairing attempt ended.
public enum HostPairingOutcome: Sendable, Equatable {
    /// Confirmed; the Host is now current (it may have been paired before).
    case paired(HostID)
    /// Not a pairing link or QR code for this server.
    case invalidCode
    case rejected
    case expired
    case failed(String)
}

/// An Agent's own logo as the Host provides it, per appearance.
public struct AgentLogoImages: Sendable, Equatable {
    public var light: Data?
    public var dark: Data?

    public init(light: Data? = nil, dark: Data? = nil) {
        self.light = light
        self.dark = dark
    }

    public subscript(variant: AgentLogoVariant) -> Data? {
        get { variant == .light ? light : dark }
        set { if variant == .light { light = newValue } else { dark = newValue } }
    }
}

public struct PendingHostPairing: Sendable, Equatable {
    public var pairingID: PairingID
    public var hostID: HostID

    public init(pairingID: PairingID, hostID: HostID) {
        self.pairingID = pairingID
        self.hostID = hostID
    }
}

public enum ConnectionProjection: Sendable, Equatable {
    case signedOut
    case offline
    case online
    case hostOffline
    case resyncing
    /// A working connection dropped and the service is reconnecting on its
    /// own. Not offline unless that attempt fails too.
    case reconnecting
    case deviceRevoked
    case versionMismatch(hostVersion: String)
}

public enum LocalConnectivity: Sendable, Equatable {
    case available, unavailable
}

public enum ForegroundPresence: Sendable, Equatable {
    case foreground, background
}

public enum DirectoryView: String, Sendable, Equatable {
    case tasks, repos
}

public enum AppDestination: Sendable, Equatable {
    case home
    case newChat
    case conversation(SessionID)
}

public struct NavigationState: Sendable, Equatable {
    public var destination: AppDestination
    public var directoryView: DirectoryView
    public var settingsOpen: Bool

    public init(destination: AppDestination, directoryView: DirectoryView, settingsOpen: Bool) {
        self.destination = destination
        self.directoryView = directoryView
        self.settingsOpen = settingsOpen
    }

    public static let home = NavigationState(destination: .home, directoryView: .tasks, settingsOpen: false)
}

public struct DirectoryProjection: Sendable, Equatable {
    public var authority: DirectoryAuthority
    public var tasks: [TaskSection]
    public var repos: [ConversationSummary]
    public var reposSupport: SurfaceSupport
    public var searchSupport: SurfaceSupport
    public var searchQuery: String
    public var searchResults: [ConversationSummary]
    public var evaluatedAt: Date?
    public var legacyLimitations: [LegacyLimitation]
    public var repositories: [RepositorySection]
    public var tasksPage: DirectoryPageStatus
    public var reposPage: DirectoryPageStatus
    public var searchPage: DirectoryPageStatus
    public var tasksTimeFilter: DirectoryTimeFilter = .last7Days
    public var reposTimeFilter: DirectoryTimeFilter = .last7Days
    public var temporarySearchResult: ConversationSummary?
    public var temporarySearchGeneration: Int = 0
    public var temporaryCreatedResults: [ConversationSummary] = []

    public init(
        authority: DirectoryAuthority,
        tasks: [TaskSection],
        repos: [ConversationSummary],
        reposSupport: SurfaceSupport,
        searchSupport: SurfaceSupport,
        searchQuery: String,
        searchResults: [ConversationSummary],
        evaluatedAt: Date?,
        legacyLimitations: [LegacyLimitation],
        repositories: [RepositorySection] = [],
        tasksPage: DirectoryPageStatus = DirectoryPageStatus(),
        reposPage: DirectoryPageStatus = DirectoryPageStatus(),
        searchPage: DirectoryPageStatus = DirectoryPageStatus()
    ) {
        self.authority = authority
        self.tasks = tasks
        self.repos = repos
        self.reposSupport = reposSupport
        self.searchSupport = searchSupport
        self.searchQuery = searchQuery
        self.searchResults = searchResults
        self.evaluatedAt = evaluatedAt
        self.legacyLimitations = legacyLimitations
        self.repositories = repositories
        self.tasksPage = tasksPage; self.reposPage = reposPage; self.searchPage = searchPage
    }

    public static let empty = DirectoryProjection(
        authority: .legacyOpenDoingTasksOnly,
        tasks: [],
        repos: [],
        reposSupport: .unsupported(.reposDirectory),
        searchSupport: .unsupported(.olderSearch),
        searchQuery: "",
        searchResults: [],
        evaluatedAt: nil,
        legacyLimitations: LegacyCopy.limitations
    )
}

public enum TranscriptSyncState: Sendable, Equatable {
    case idle, syncing, failed
}

public enum QueueCommandState: Sendable, Equatable {
    case pending(CommandID)
    case uncertain(CommandID)
    case failed(String)
}

public struct ConversationProjection: Sendable, Equatable {
    public var session: SessionRecord
    public var items: [TranscriptItem]
    public var cursor: String?
    public var hasOlder: Bool
    public var hydratedFromCache: Bool
    public var transcriptSync: TranscriptSyncState

    public init(
        session: SessionRecord,
        items: [TranscriptItem],
        cursor: String?,
        hasOlder: Bool,
        hydratedFromCache: Bool,
        transcriptSync: TranscriptSyncState = .idle
    ) {
        self.session = session
        self.items = items
        self.cursor = cursor
        self.hasOlder = hasOlder
        self.hydratedFromCache = hydratedFromCache
        self.transcriptSync = transcriptSync
    }
}

public struct ComposerSelection: Sendable, Equatable {
    public var agentID: AgentID?
    public var model: String?
    public var workspaceID: WorkspaceID?
    public var taskID: TaskID?
    /// New-chat conversation options. Thinking and Fast travel with
    /// `session.create`; approval is applied right after creation. Optional so
    /// selections persisted before these existed still decode.
    public var thinking: String? = nil
    public var fast: Bool? = nil
    public var approvalMode: String? = nil

    public init(agentID: AgentID? = nil, model: String? = nil, workspaceID: WorkspaceID? = nil, taskID: TaskID? = nil) {
        self.agentID = agentID
        self.model = model
        self.workspaceID = workspaceID
        self.taskID = taskID
    }
}

public enum ComposerNotice: Sendable, Equatable {
    case none
    case offlineDraftRetained
    case keptAfterUncertainOutcome
    case translationNeedsChoice
    case legacyTaskRequired
}

public struct ComposerProjection: Sendable, Equatable {
    public var selection: ComposerSelection
    public var draft: DraftDocument
    public var send: SendPhase
    public var notice: ComposerNotice

    public init(selection: ComposerSelection, draft: DraftDocument, send: SendPhase, notice: ComposerNotice) {
        self.selection = selection
        self.draft = draft
        self.send = send
        self.notice = notice
    }
}

public struct CapabilityProjection: Sendable, Equatable {
    public var grants: [CapabilityGrant]
    public var negotiatedFeatures: [KnownWireFeature]

    public init(grants: [CapabilityGrant], negotiatedFeatures: [KnownWireFeature]) {
        self.grants = grants
        self.negotiatedFeatures = negotiatedFeatures
    }

    public static let empty = CapabilityProjection(grants: [], negotiatedFeatures: [])

    public func state(of capability: BusinessCapability) -> CapabilityState {
        grants.first { $0.capability == capability }?.state ?? .unsupported
    }

    public var translationNegotiated: Bool {
        negotiatedFeatures.contains(.conversationTranslation)
    }

    public var directoryNegotiated: Bool {
        negotiatedFeatures.contains(.sessionDirectoryV1)
    }
}

public struct SyncProjection: Sendable, Equatable {
    public var cursor: SyncCursor?
    public var needsSnapshot: Bool
    public var reason: SnapshotRequiredReason?

    public init(cursor: SyncCursor? = nil, needsSnapshot: Bool = false, reason: SnapshotRequiredReason? = nil) {
        self.cursor = cursor
        self.needsSnapshot = needsSnapshot
        self.reason = reason
    }
}

public struct GianClientState: Sendable, Equatable {
    public var queueCommands: [SessionID: QueueCommandState] = [:]
    /// Static, non-sensitive diagnostic. No database path or payload is exposed.
    public var storageError: String? = nil
    public var phase: ClientPhase
    public var server: ServerAddress?
    public var account: AccountAuthorization
    public var hosts: [HostSummary]
    public var currentHostID: HostID?
    public var pendingPairing: PendingHostPairing?
    /// The last pairing attempt's outcome, cleared by the next attempt.
    public var pairingOutcome: HostPairingOutcome? = nil
    public var connection: ConnectionProjection
    public var localConnectivity: LocalConnectivity
    public var foreground: ForegroundPresence
    public var navigation: NavigationState
    public var directory: DirectoryProjection
    public var workspaces: [WorkspaceRecord]
    public var agents: [AgentRecord]
    public var catalogRevision: String
    public var conversation: ConversationProjection?
    public var drafts: [DraftDocument]
    public var composer: ComposerProjection
    public var interactions: [InteractionRecord]
    public var translations: [SessionID: TranslationSessionState]
    public var banners: [BannerItem]
    public var capabilities: CapabilityProjection
    public var sync: SyncProjection
    public var pendingStop: SendPhase
    /// `catalog.agent` options per Agent, for the composer's ⋯ menu.
    public var agentOptions: [AgentID: AgentConversationOptions] = [:]
    /// A conversation-setting change in flight, and the last failure to show.
    public var settingsUpdatePending: Bool = false
    public var settingsNotice: String? = nil
    /// Agent logos fetched from the Host, keyed by plugin ID.
    public var agentLogos: [String: AgentLogoImages] = [:]
    /// Every open Task on the Host, for New chat. Home's task sections can
    /// omit tasks without conversations (a negotiated directory lists only
    /// tasks it has rows for), and a fresh Host has none yet.
    public var openTasks: [TaskRecord] = []

    public init(
        phase: ClientPhase,
        server: ServerAddress?,
        account: AccountAuthorization,
        hosts: [HostSummary],
        currentHostID: HostID?,
        pendingPairing: PendingHostPairing?,
        connection: ConnectionProjection,
        localConnectivity: LocalConnectivity,
        foreground: ForegroundPresence,
        navigation: NavigationState,
        directory: DirectoryProjection,
        workspaces: [WorkspaceRecord],
        agents: [AgentRecord],
        catalogRevision: String,
        conversation: ConversationProjection?,
        drafts: [DraftDocument],
        composer: ComposerProjection,
        interactions: [InteractionRecord],
        translations: [SessionID: TranslationSessionState],
        banners: [BannerItem],
        capabilities: CapabilityProjection,
        sync: SyncProjection,
        pendingStop: SendPhase
    ) {
        self.phase = phase
        self.server = server
        self.account = account
        self.hosts = hosts
        self.currentHostID = currentHostID
        self.pendingPairing = pendingPairing
        self.connection = connection
        self.localConnectivity = localConnectivity
        self.foreground = foreground
        self.navigation = navigation
        self.directory = directory
        self.workspaces = workspaces
        self.agents = agents
        self.catalogRevision = catalogRevision
        self.conversation = conversation
        self.drafts = drafts
        self.composer = composer
        self.interactions = interactions
        self.translations = translations
        self.banners = banners
        self.capabilities = capabilities
        self.sync = sync
        self.pendingStop = pendingStop
    }

    public static func signedOut() -> GianClientState {
        GianClientState(
            phase: .signedOut,
            server: nil,
            account: .signedOut,
            hosts: [],
            currentHostID: nil,
            pendingPairing: nil,
            connection: .signedOut,
            localConnectivity: .available,
            foreground: .foreground,
            navigation: .home,
            directory: .empty,
            workspaces: [],
            agents: [],
            catalogRevision: "",
            conversation: nil,
            drafts: [],
            composer: ComposerProjection(
                selection: ComposerSelection(),
                draft: DraftDocument.placeholder(now: Date(timeIntervalSince1970: 0)),
                send: .idle,
                notice: .none
            ),
            interactions: [],
            translations: [:],
            banners: [],
            capabilities: .empty,
            sync: SyncProjection(),
            pendingStop: .idle
        )
    }
}

extension CapabilityProjection: Codable {}
extension ComposerSelection: Codable {}

extension DraftDocument {
    static func placeholder(now: Date) -> DraftDocument {
        DraftDocument(
            id: DraftID(rawValue: "unsigned-draft") ?? DraftID(trusted: "unsigned-draft"),
            hostID: nil,
            target: .newConversation,
            text: "",
            attachments: [],
            updatedAt: now
        )
    }
}

enum LegacyCopy {
    static let repos = "This Host only exposes sessions in open Doing tasks (projection.isRemoteSessionVisible at 0c0f2f5c). Repos is unavailable until a broader directory contract exists."
    static let search = "Older authorized search is unavailable. The inspected Host does not expose non-Doing sessions, and this client will not invent them."
    static let taskless = "First send requires an open Doing Task. command-adapter.createSession rejects a missing or non-open Task."

    static var limitations: [LegacyLimitation] {
        [
            LegacyLimitation(surface: .reposDirectory, detail: repos),
            LegacyLimitation(surface: .olderSearch, detail: search),
            LegacyLimitation(surface: .tasklessFirstSend, detail: taskless),
        ]
    }
}
