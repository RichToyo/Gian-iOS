import Foundation

/// Pinned inspected Gian-Dev remote baseline. This client does not invent wire methods.
public enum RemoteBaseline {
    public static let inspectedCommit = "0c0f2f5c92bc70f78269b105e4e0b98cf99770d0"
    public static let authProtocol = "gian.remote.auth/1"
    public static let remoteProtocol = "gian.remote/1"
    /// Remote 1.5: `POST /api/v1/server-identity` signs this payload type.
    public static let serverIdentityProofType = "gian.remote.server_identity/1"
    public static let serverIdentityProofLifetime: TimeInterval = 120
    public static let majorVersion = 1
    public static let minimumMinorVersion = 1
    public static let maximumMinorVersion = 3
}

public enum GianCore {
    /// Bump only when a public signature changes. UI binds this revision.
    public static let contractRevision = "0.1.0-contract.3"
}

public enum RemoteLimits {
    public static let maxAttachmentBytes = 20 * 1024 * 1024
    /// Exactly seven 24-hour periods. The recent-activity boundary is inclusive.
    public static let recentActivity: TimeInterval = 7 * 24 * 60 * 60
    /// Host `text_length` counts JavaScript UTF-16 code units, not Swift graphemes.
    public static let translationInlineUTF16 = 16_000
}

public enum KnownWireFeature: String, Sendable, Equatable, CaseIterable {
    case snapshotParts = "wire.snapshot_parts"
    case contentResume = "wire.content_resume"
    case transcriptPage = "wire.transcript_page"
    case executionV1 = "wire.execution_v1"
    case hostLocale = "wire.host_locale"
    case conversationTranslation = "wire.conversation_translation"
    case sessionDirectoryV1 = "wire.session_directory_v1"
}

public enum BusinessCapability: String, Sendable, Equatable, CaseIterable {
    case catalogRead = "catalog.read"
    case stateRefresh = "state.refresh"
    case taskRead = "task.read"
    case sessionRead = "session.read"
    case sessionCreate = "session.create"
    case sessionUpdate = "session.update"
    case sessionSend = "session.send"
    case sessionStop = "session.stop"
    case queueRead = "queue.read"
    case queueAdd = "queue.add"
    case queueUpdate = "queue.update"
    case queueRemove = "queue.remove"
    case queueClear = "queue.clear"
    case queueSendNow = "queue.send_now"
    case turnSteer = "turn.steer"
    case interactionRead = "interaction.read"
    case interactionRespond = "interaction.respond"
    case attachmentUpload = "attachment.upload"
    case attachmentRead = "attachment.read"
    case fileRead = "file.read"
    case fileDownload = "file.download"
}

public enum CapabilityState: String, Sendable, Equatable {
    case supported
    case unsupported
    case offline
    case denied
    case versionMismatch = "version_mismatch"
}

public struct CapabilityGrant: Sendable, Equatable {
    public var capability: BusinessCapability
    public var state: CapabilityState

    public init(capability: BusinessCapability, state: CapabilityState) {
        self.capability = capability
        self.state = state
    }
}

/// Opaque scoped identity. Empty values and characters outside the id alphabet are rejected.
public struct ScopedID<Kind>: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isAcceptable(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    init(trusted rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    static func isAcceptable(_ rawValue: String) -> Bool {
        guard (1...128).contains(rawValue.count) else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
    }
}

public enum AccountKind {}
public enum InstallationKind {}
public enum HostKind {}
public enum DeviceKind {}
public enum HostGenerationKind {}
public enum SessionKind {}
public enum TaskKind {}
public enum WorkspaceKind {}
public enum AgentKind {}
public enum TurnKind {}
public enum TranscriptItemKind {}
public enum CommandKind {}
public enum DraftKind {}
public enum SubmissionKind {}
public enum TranslationRequestKind {}
public enum TranslationRecordKind {}
public enum AttachmentKind {}
public enum InteractionKindID {}
public enum ActionKind {}
public enum BannerKind {}
public enum PairingKind {}

public typealias InstallationID = ScopedID<InstallationKind>
public typealias HostID = ScopedID<HostKind>
public typealias DeviceID = ScopedID<DeviceKind>
public typealias HostGenerationID = ScopedID<HostGenerationKind>
public typealias SessionID = ScopedID<SessionKind>
public typealias TaskID = ScopedID<TaskKind>
public typealias WorkspaceID = ScopedID<WorkspaceKind>
public typealias AgentID = ScopedID<AgentKind>
public typealias TurnID = ScopedID<TurnKind>
public typealias TranscriptItemID = ScopedID<TranscriptItemKind>
public typealias CommandID = ScopedID<CommandKind>
public typealias DraftID = ScopedID<DraftKind>
public typealias SubmissionID = ScopedID<SubmissionKind>
public typealias TranslationRequestID = ScopedID<TranslationRequestKind>
public typealias TranslationRecordID = ScopedID<TranslationRecordKind>
public typealias AttachmentID = ScopedID<AttachmentKind>
public typealias InteractionID = ScopedID<InteractionKindID>
public typealias ActionID = ScopedID<ActionKind>
public typealias BannerID = ScopedID<BannerKind>
public typealias PairingID = ScopedID<PairingKind>

/// What scopes this app's data on a Remote Server. Remote 1.5 needs no
/// person's account (no GitHub sign-in): the scope is this app's own
/// controller identity on that Server, the device-key installation it pairs
/// Hosts with.
public enum AccountProvider: String, Sendable, Equatable {
    case controller
}

public struct AccountID: Hashable, Sendable {
    public var provider: AccountProvider
    public var id: String

    public init?(provider: AccountProvider, id: String) {
        guard ScopedID<AccountKind>.isAcceptable(id) else { return nil }
        self.provider = provider
        self.id = id
    }

    /// The controller identity for an installation on one Server.
    public init(installation: InstallationID) {
        provider = .controller
        id = installation.rawValue
    }
}

public struct ServerAddress: Hashable, Sendable {
    public let origin: URL

    public var absoluteString: String { origin.absoluteString }

    /// HTTPS origin only. Userinfo, paths, queries, and fragments are rejected.
    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        guard components.path.isEmpty || components.path == "/" else { return nil }
        guard components.query == nil, components.fragment == nil else { return nil }
        var originComponents = URLComponents()
        originComponents.scheme = "https"
        originComponents.host = host
        originComponents.port = components.port
        guard let origin = originComponents.url else { return nil }
        self.origin = origin
    }

    public init(validated origin: URL) {
        self.origin = origin
    }
}

public struct DataScope: Hashable, Sendable {
    public var server: ServerAddress
    public var account: AccountID

    public init(server: ServerAddress, account: AccountID) {
        self.server = server
        self.account = account
    }
}

public struct ClientScope: Hashable, Sendable {
    public var server: ServerAddress
    public var account: AccountID
    public var host: HostID

    public init(server: ServerAddress, account: AccountID, host: HostID) {
        self.server = server
        self.account = account
        self.host = host
    }

    public var data: DataScope { DataScope(server: server, account: account) }
}

public enum RejectionCode: String, Sendable, Equatable, Error {
    case invalidServerAddress
    /// The Server presented a different identity than the one pinned.
    case serverIdentityChanged
    case notAuthorized
    case pairingQRInvalid
    case pairingServerMismatch
    case noCurrentHost
    case offlineDraftRetained
    case operationInFlight
    case uncertainOutcome
    case capabilityDenied
    case capabilityUnsupported
    case legacyTasklessCreateUnsupported
    case legacyReposUnsupported
    case legacySearchUnsupported
    case missingTask
    case missingAgent
    case missingWorkspace
    case missingCatalog
    case emptyDraft
    case unknownActionID
    case unknownInputID
    case interactionNotPending
    case translationUnavailable
    case translationNotConfigured
    case attachmentRejected
    case scopeMismatch
    case notFound
    case staleOperation
    case mutationsDisabled
}

public struct GianDispatchResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case applied
        case rejected(RejectionCode)
    }

    public var status: Status

    public init(status: Status) {
        self.status = status
    }

    public var isApplied: Bool {
        if case .applied = status { return true }
        return false
    }

    public static let applied = GianDispatchResult(status: .applied)

    public static func rejected(_ code: RejectionCode) -> GianDispatchResult {
        GianDispatchResult(status: .rejected(code))
    }
}

extension KnownWireFeature: Codable {}
extension BusinessCapability: Codable {}
extension CapabilityState: Codable {}
extension CapabilityGrant: Codable {}
extension AccountProvider: Codable {}
extension DataScope: Codable {}
extension ClientScope: Codable {}

extension ScopedID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid scoped identity.")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension AccountID: Codable {
    private enum CodingKeys: String, CodingKey { case provider, id }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(provider: try container.decode(AccountProvider.self, forKey: .provider),
                               id: try container.decode(String.self, forKey: .id)) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid account identity.")
        }
        self = value
    }
}

extension ServerAddress: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(parsing: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid server origin.")
        }
        self = value
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(absoluteString)
    }
}
