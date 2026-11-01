import Foundation

/// No authorization or credentials are stored here. A scope is an exact namespace,
/// not evidence that the caller is allowed to display it.
@MainActor
public protocol GianStorage: AnyObject, AuthorizationInvalidationStoring {
    func load(scope: ClientScope) throws -> StoredHostState?
    /// Atomically replaces retained state, unsent bytes and the download cache.
    func save(_ state: StoredHostState, scope: ClientScope) throws
    func clearDownloadCache(scope: ClientScope) throws
}

public enum GianStorageError: Error, Equatable, Sendable {
    case unsafeLocation
    case unavailable
    case unsupportedSchema
    case corruptData
    case scopeMismatch
    case invalidAttachment
}

/// Retained data is distinct from `downloads`, which may be evicted at any time.
/// In-flight operations are written as uncertain before their first side effect.
public struct StoredHostState: Codable, Equatable, Sendable {
    public var activeDraftID: DraftID?
    public var drafts: [DraftDocument] = []
    public var transcripts: [SessionID: [TranscriptItem]] = [:]
    public var transcriptCursors: [SessionID: StoredTranscriptCursor] = [:]
    public var sessions: [SessionRecord] = []
    public var tasks: [TaskRecord] = []
    public var workspaces: [WorkspaceRecord] = []
    public var agents: [AgentRecord] = []
    public var interactions: [InteractionRecord] = []
    public var cursor: SyncCursor?
    public var needsSnapshot = false
    public var translations: [SessionID: TranslationSessionState] = [:]
    public var readingIntents: [SessionID: [String: StoredReadingIntent]] = [:]
    public var catalogRevision = ""
    public var capabilities = CapabilityProjection.empty
    public var authority = DirectoryAuthority.legacyOpenDoingTasksOnly
    public var operations: [DraftID: SendPhase] = [:]
    /// Frozen send content, distinct from a draft subsequently edited by the user.
    public var submittedDrafts: [DraftID: DraftDocument] = [:]
    public var selections: [DraftID: ComposerSelection] = [:]
    public var pendingStop: SendPhase = .idle
    public var interactionCommands: [InteractionID: CommandID] = [:]
    public var autoTranslationCommands: [SessionID: CommandID] = [:]
    public var downloads: [AttachmentID: Data] = [:]
    public var draftBytes: [AttachmentID: Data] = [:]
    public var host: HostSummary?
    public var searchHits: [SessionRecord] = []
    public var directoryViews: [DirectoryCollection: StoredDirectoryView]?

    public init() {}

    mutating func cacheDownload(_ bytes: Data, id: AttachmentID) {
        downloads[id] = bytes
        var count = downloads.values.reduce(0) { $0 + $1.count }
        for candidate in downloads.keys.sorted(by: { $0.rawValue < $1.rawValue }) where candidate != id {
            if count <= 32 * 1024 * 1024 { break }
            count -= downloads.removeValue(forKey: candidate)?.count ?? 0
        }
    }

    func validate(scope: ClientScope, previous: StoredHostState? = nil) throws {
        for view in (directoryViews ?? [:]).values {
            let entries = view.entries + (view.pendingEntries ?? [])
            guard view.entries.count <= 4096, (view.pendingEntries?.count ?? 0) <= 4096,
                  view.visitedCursors.count <= 4096, (view.query?.count ?? 0) <= 256,
                  entries.allSatisfy({ $0.session.hostID == scope.host }),
                  (view.cursor?.utf8.count ?? 0) <= 4096 else { throw GianStorageError.corruptData }
        }
        if let cursor, cursor.eventSequence < -1 { throw GianStorageError.corruptData }
        guard transcripts.values.reduce(0, { $0 + $1.count }) <= 50_000,
              drafts.count <= 4_096, submittedDrafts.count <= 4_096, sessions.count <= 4_096, tasks.count <= 4_096,
              interactions.count <= 4_096, agents.count <= 4_096, workspaces.count <= 4_096,
              searchHits.count <= 4_096,
              transcriptCursors.values.allSatisfy({ ($0.catchUp?.anchorIDs.count ?? 0) <= 256 }) else {
            throw GianStorageError.unavailable
        }
        guard host == nil || host?.id == scope.host,
              (sessions + searchHits).allSatisfy({ $0.hostID == scope.host }),
              (drafts + Array(submittedDrafts.values)).allSatisfy({ $0.hostID == scope.host }),
              operations.allSatisfy({ $0.key == $0.value.intent?.draftID })
        else { throw GianStorageError.scopeMismatch }
        for phase in operations.values {
            guard let intent = phase.intent else { continue }
            guard intent.createRequest.map({ $0.commandID == intent.creationID }) ?? true,
                  intent.sendRequest.map({ $0.commandID == intent.sendID && $0.sessionID == intent.sessionID }) ?? true,
                  intent.creationID == nil || intent.sendID == nil || intent.creationID != intent.sendID,
                  (intent.sendRequest?.text.utf8.count ?? 0) <= 2 * 1024 * 1024,
                  (intent.sendRequest?.attachmentIDs.count ?? 0) <= 32 else { throw GianStorageError.corruptData }
        }
        let previousAttachments = previous.map { ($0.drafts + Array($0.submittedDrafts.values)).flatMap(\.attachments) } ?? []
        let oldMetadata = previousAttachments.reduce(into: [AttachmentID: DraftAttachment]()) { $0[$1.id] = $1 }
        for draft in drafts + Array(submittedDrafts.values) {
            for attachment in draft.attachments {
                guard AttachmentRules.safeFilename(attachment.filename),
                      AttachmentRules.accepts(byteCount: attachment.byteCount) else {
                    throw GianStorageError.invalidAttachment
                }
                if let bytes = draftBytes[attachment.id] {
                    guard bytes.count == attachment.byteCount else { throw GianStorageError.invalidAttachment }
                    let unchanged = previous?.draftBytes[attachment.id] == bytes && oldMetadata[attachment.id]?.sha256 == attachment.sha256
                    guard unchanged || SHA256Hex.digest(bytes) == attachment.sha256.lowercased() else {
                        throw GianStorageError.invalidAttachment
                    }
                }
            }
        }
        guard draftBytes.values.allSatisfy({ AttachmentRules.accepts(byteCount: $0.count) }),
              downloads.values.allSatisfy({ AttachmentRules.accepts(byteCount: $0.count) }) else {
            throw GianStorageError.invalidAttachment
        }
        guard (drafts + Array(submittedDrafts.values)).allSatisfy({ $0.text.utf8.count <= 2 * 1024 * 1024 }),
              readingIntents.values.allSatisfy({ $0.values.allSatisfy({ $0.sourceText.utf8.count <= 2 * 1024 * 1024 }) }) else {
            throw GianStorageError.unavailable
        }
    }

    func recovered() -> StoredHostState {
        var next = self
        for view in (next.directoryViews ?? [:]).keys { next.directoryViews?[view]?.invalidate() }
        for (id, phase) in operations where phase.isInFlight {
            if let intent = phase.intent { next.operations[id] = .uncertain(intent) }
        }
        if pendingStop.isInFlight, let intent = pendingStop.intent { next.pendingStop = .uncertain(intent) }
        for index in next.interactions.indices where next.interactions[index].phase == .responding {
            next.interactions[index].phase = .uncertain
        }
        for id in next.translations.keys {
            guard var translation = next.translations[id] else { continue }
            for source in translation.reading.keys where translation.reading[source]?.pending == true {
                translation.reading[source]?.uncertain = true
            }
            next.translations[id] = translation
        }
        for index in next.drafts.indices {
            for attachment in next.drafts[index].attachments.indices {
                switch next.drafts[index].attachments[attachment].state {
                case .uploading: next.drafts[index].attachments[attachment].state = .localOnly
                case .downloading: next.drafts[index].attachments[attachment].state = .uploaded
                case .cached:
                    if downloads[next.drafts[index].attachments[attachment].id] == nil {
                        next.drafts[index].attachments[attachment].state = .uploaded
                    }
                default: break
                }
            }
        }
        return next
    }
}

public struct StoredTranscriptCursor: Codable, Equatable, Sendable {
    public var cursor: String?
    public var hasOlder: Bool
    public var hostGeneration: HostGenerationID?
    public var catchUp: StoredTranscriptCatchUp?

    public init(cursor: String?, hasOlder: Bool) {
        self.cursor = cursor
        self.hasOlder = hasOlder
        self.hostGeneration = nil
        self.catchUp = nil
    }
}

public struct StoredTranscriptCatchUp: Codable, Equatable, Sendable {
    public let anchorIDs: [TranscriptItemID]
    public init(anchorIDs: [TranscriptItemID]) { self.anchorIDs = anchorIDs }
}

public struct StoredReadingIntent: Codable, Equatable, Sendable {
    public var requestID: TranslationRequestID
    public var sourceText: String

    public init(requestID: TranslationRequestID, sourceText: String) {
        self.requestID = requestID
        self.sourceText = sourceText
    }
}

/// Explicitly opt in for tests and previews. Never used as an error fallback.
@MainActor
public final class InMemoryGianStorage: GianStorage {
    private var invalidations: [DataScope: Date] = [:]

    public func invalidateAuthorization(scope: DataScope, at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw GianStorageError.corruptData }
        invalidations[scope] = max(invalidations[scope] ?? date, date)
    }

    public func authorizationInvalidatedAt(scope: DataScope) throws -> Date? {
        invalidations[scope]
    }
    private var states: [ClientScope: StoredHostState] = [:]
    public init() {}

    public func load(scope: ClientScope) throws -> StoredHostState? { states[scope]?.recovered() }
    public func save(_ state: StoredHostState, scope: ClientScope) throws {
        try state.validate(scope: scope)
        states[scope] = state
    }
    public func clearDownloadCache(scope: ClientScope) throws { states[scope]?.downloads.removeAll() }
}
