import Foundation

struct StoredRetentionPurge: Codable, Equatable, Hashable, Sendable {
    var kind: String
    var owner: String
}

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
    case concurrentMutation
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
    /// Tasks-view conversation order, first seen first (see `ConversationOrder`).
    var conversationOrder: [SessionID]?
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
    /// Command IDs are persisted before queue mutations; a restart queries them instead of resending.
    public var pendingQueueCommands: [SessionID: CommandID]?
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
    public var tasksTimeFilter: DirectoryTimeFilter?
    public var reposTimeFilter: DirectoryTimeFilter?
    var pendingSessionAccessIDs: [SessionID]?
    var deniedSessionAccessIDs: [SessionID]?
    var sessionAccessOverflow: Bool?
    public var translationRecordOrder: [SessionID: [TranslationRecordID]]?
    public var downloadOwners: [AttachmentID: [SessionID]]?
    var retentionCleanup: [StoredRetentionPurge]?
    var retentionProtectedDownloads: [AttachmentID]?
    var retentionPausedSessions: [SessionID]?
    var retentionRevision: Int?
    var retentionOwnerAttachments: [SessionID: [AttachmentID]]?
    var retentionActivityBaseline: [SessionID: Date]?
    var retentionRenewedActivity: [SessionID: Date]?
    var retentionSupersededSessions: [SessionID]?
    var retentionTailItemIDs: [SessionID: [TranscriptItemID]]?
    var retentionTailReadingIDs: [SessionID: [TranslationRecordID]]?
    var retentionHydratedSessions: [SessionID]?
    // Input to save only; never part of the retained header.
    var retentionRecentActivity: [SessionID: Date]?
    var retentionReferenceNow: Date?
    var retentionVerifiedItems: [SessionID: [TranscriptItemID]]?
    var retentionHydratedEvidence: [SessionID]?

    public init() {}

    /// Produce a disk snapshot without discarding the live in-memory view.
    /// Unknown activity and recovery-related sessions are retained conservatively.
    var historySessionIDs: Set<SessionID> {
        let directorySessions = (directoryViews ?? [:]).values.flatMap { view in
            (view.entries + (view.pendingEntries ?? [])).map(\.session.id)
        }
        return Set(sessions.map(\.id) + searchHits.map(\.id) + directorySessions)
            .union(transcripts.keys).union(transcriptCursors.keys)
    }

    func recentHistoryIDs(now: Date) -> Set<SessionID> {
        Set(recentHistoryActivity(now: now).keys)
    }

    func recentHistoryActivity(now: Date) -> [SessionID: Date] {
        let cutoff = now.addingTimeInterval(-DirectoryTimeFilter.last7Days.duration)
        let entries = (directoryViews ?? [:]).values.flatMap { $0.entries + ($0.pendingEntries ?? []) }
        let unavailable = Set(sessions.filter { !$0.authorized || $0.archived }.map(\.id))
        var result = (sessions + searchHits + entries.map(\.session)).reduce(into: [SessionID: Date]()) { result, session in
            guard !unavailable.contains(session.id), session.authorized, !session.archived, session.activityIsMessageOrExecution,
                  let at = session.lastActivityAt, at.timeIntervalSince1970.isFinite, at >= cutoff else { return }
            result[session.id] = max(result[session.id] ?? at, at)
        }
        for (id, at) in retentionRecentActivity ?? [:] where !unavailable.contains(id) && at.timeIntervalSince1970.isFinite && at >= cutoff {
            result[id] = max(result[id] ?? at, at)
        }
        return result
    }

    func retentionProtectedSessionIDs() -> Set<SessionID> {
        var protected = Set<SessionID>()
        for phase in Array(operations.values) + [pendingStop] {
            switch phase {
            case .creating, .awaitingTranslation, .sending, .uncertain:
                if let id = phase.intent?.sessionID { protected.insert(id) }
            case .idle, .failed, .succeeded:
                break
            }
        }
        protected.formUnion(interactions.filter {
            $0.phase == .pending || $0.phase == .responding || $0.phase == .uncertain || interactionCommands[$0.id] != nil
        }.map(\.sessionID))
        protected.formUnion(autoTranslationCommands.keys)
        protected.formUnion((pendingQueueCommands ?? [:]).keys)
        for (id, intents) in readingIntents where !intents.isEmpty {
            guard let translation = translations[id] else { protected.insert(id); continue }
            if intents.keys.contains(where: { translation.reading[$0].map { $0.pending || $0.uncertain } == true }) {
                protected.insert(id)
            }
        }
        for (id, translation) in translations where translation.reading.values.contains(where: { $0.pending || $0.uncertain }) || translation.automatic.values.contains(where: \.pending) {
            protected.insert(id)
        }
        return protected
    }

    func retentionPauseSessionIDs() -> Set<SessionID> {
        var result = retentionProtectedSessionIDs()
        for draft in drafts + Array(submittedDrafts.values) where !draft.isEmpty || draft.id == activeDraftID {
            if case .conversation(let id) = draft.target { result.insert(id) }
            if let id = draft.boundSessionID { result.insert(id) }
        }
        return result
    }

    func changedRetentionDraftOwners(since previous: StoredHostState) -> Set<SessionID> {
        let oldDrafts = previous.drafts.reduce(into: [DraftID: DraftDocument]()) { $0[$1.id] = $1 }
        var result: Set<SessionID> = []
        func note(_ draft: DraftDocument) {
            if case .conversation(let id) = draft.target { result.insert(id) }
            if let id = draft.boundSessionID { result.insert(id) }
        }
        for draft in drafts where !draft.isEmpty && oldDrafts[draft.id] != draft { note(draft) }
        for (id, draft) in submittedDrafts where !draft.isEmpty && previous.submittedDrafts[id] != draft { note(draft) }
        if activeDraftID != previous.activeDraftID, let activeDraftID,
           let draft = drafts.first(where: { $0.id == activeDraftID }) { note(draft) }
        return result
    }

    var hasAmbiguousRetentionReferences: Bool {
        operations.contains { id, phase in
            switch phase {
            case .creating, .awaitingTranslation, .sending, .uncertain:
                return submittedDrafts[id] == nil && phase.intent?.sendRequest == nil
            case .idle, .failed, .succeeded:
                return false
            }
        }
    }

    func retentionDownloadReferences() -> Set<AttachmentID> {
        var result = Set(downloads.keys).union(draftBytes.keys).union((downloadOwners ?? [:]).keys)
            .union(retentionProtectedDownloads ?? [])
        for items in transcripts.values {
            for item in items {
                if case .user(_, _, let ids, _) = item.body { result.formUnion(ids) }
            }
        }
        for draft in drafts + Array(submittedDrafts.values) {
            for attachment in draft.attachments {
                result.insert(attachment.id)
                if let id = attachment.remoteID { result.insert(id) }
            }
        }
        for phase in Array(operations.values) + [pendingStop] {
            if let ids = phase.intent?.sendRequest?.attachmentIDs { result.formUnion(ids) }
        }
        return result
    }

    func retentionWorkReferences(stored: StoredHostState, evicted: Set<SessionID> = [], now: Date? = nil) -> (Set<AttachmentID>, Set<SessionID>, Bool) {
        var snapshot = self
        var protected = retentionProtectedSessionIDs().union(stored.retentionProtectedSessionIDs())
            .union(stored.retentionPausedSessions ?? [])
            .union(stored.retentionSupersededSessions ?? [])
            .union(changedRetentionDraftOwners(since: stored))
        if let now { protected.formUnion(recentlyActiveRetentionOwners(stored: stored, now: now)) }
        var removing = evicted.subtracting(protected)
        for id in removing { snapshot.transcripts[id] = nil }
        for job in stored.retentionCleanup ?? [] where job.kind == "transcript" {
            if let id = SessionID(rawValue: job.owner), !protected.contains(id) {
                snapshot.transcripts[id] = nil
                removing.insert(id)
            }
        }
        snapshot.downloads = stored.downloads
        snapshot.retentionProtectedDownloads = stored.retentionProtectedDownloads
        var owners = stored.downloadOwners ?? [:]
        for (id, sessions) in snapshot.downloadOwners ?? [:] {
            let retained = sessions.filter { !removing.contains($0) }
            guard !retained.isEmpty else { continue }
            var combined = owners[id] ?? []
            for session in retained where !combined.contains(session) { combined.append(session) }
            owners[id] = combined
        }
        snapshot.downloadOwners = owners
        var references = snapshot.retentionDownloadReferences().union(stored.retentionDownloadReferences())
        for id in protected { references.formUnion(stored.retentionOwnerAttachments?[id] ?? []) }
        let missingOwnership = protected.contains { id in
            stored.retentionOwnerAttachments?[id] == nil && snapshot.transcripts[id] == nil
        }
        return (references, protected, hasAmbiguousRetentionReferences || stored.hasAmbiguousRetentionReferences || missingOwnership)
    }

    func recentlyActiveRetentionOwners(stored: StoredHostState, now: Date) -> Set<SessionID> {
        let queued = Set((stored.retentionCleanup ?? []).compactMap { $0.kind == "download" ? nil : SessionID(rawValue: $0.owner) })
        return Set(recentHistoryActivity(now: now).compactMap { id, at in
            guard queued.contains(id), stored.retentionActivityBaseline?[id].map({ at > $0 }) ?? true else { return nil }
            return id
        })
    }

    func retainingRecentHistory(now: Date, previouslyEvicted: Set<SessionID> = []) -> StoredHostState {
        let protected = retentionProtectedSessionIDs()
        var protectedMetadata = Set<SessionID>()
        for draft in drafts + Array(submittedDrafts.values) where !draft.isEmpty || draft.id == activeDraftID {
            if case .conversation(let id) = draft.target { protectedMetadata.insert(id) }
            if let id = draft.boundSessionID { protectedMetadata.insert(id) }
        }
        protectedMetadata.formUnion(protected)

        let cutoff = now.addingTimeInterval(-DirectoryTimeFilter.last7Days.duration)
        let directorySessions = (directoryViews ?? [:]).values.flatMap { view in
            (view.entries + (view.pendingEntries ?? [])).map(\.session)
        }
        let records = Dictionary(grouping: sessions + searchHits + directorySessions, by: \.id)
        let candidates = records.compactMap { id, versions -> SessionID? in
            guard !protected.contains(id), versions.allSatisfy({ session in
                session.activityIsMessageOrExecution && session.lastActivityAt.map { $0 < cutoff } == true
            }) else { return nil }
            return id
        }.sorted { $0.rawValue < $1.rawValue }
        var evicted = previouslyEvicted.union(candidates)
        evicted.subtract(recentHistoryIDs(now: now))
        evicted.subtract(protected)
        guard !evicted.isEmpty else { return self }
        var next = self
        let evictedAttachments = Set(transcripts.filter { evicted.contains($0.key) }.values.flatMap { items in
            items.flatMap { item -> [AttachmentID] in
                if case .user(_, _, let ids, _) = item.body { return ids }
                return []
            }
        })
        var retainedAttachments = Set(transcripts.filter { !evicted.contains($0.key) }.values.flatMap { items in
            items.flatMap { item -> [AttachmentID] in
                if case .user(_, _, let ids, _) = item.body { return ids }
                return []
            }
        }).union((drafts + Array(submittedDrafts.values)).flatMap { $0.attachments.map(\.id) })
        retainedAttachments.formUnion((drafts + Array(submittedDrafts.values)).flatMap { $0.attachments.compactMap(\.remoteID) })
        retainedAttachments.formUnion(draftBytes.keys)
        for phase in Array(operations.values) + [pendingStop] {
            if let ids = phase.intent?.sendRequest?.attachmentIDs { retainedAttachments.formUnion(ids) }
        }
        for (id, owners) in downloadOwners ?? [:] where owners.contains(where: { !evicted.contains($0) }) {
            retainedAttachments.insert(id)
        }
        next.downloads = downloads.filter { !evictedAttachments.contains($0.key) || retainedAttachments.contains($0.key) }
        for (id, owners) in downloadOwners ?? [:] where !owners.isEmpty {
            let retainedOwners = owners.filter { !evicted.contains($0) }
            if retainedOwners.isEmpty && !retainedAttachments.contains(id) {
                next.downloadOwners?[id] = nil
                next.downloads[id] = nil
            } else if !retainedOwners.isEmpty {
                next.downloadOwners?[id] = retainedOwners
            }
        }
        next.sessions.removeAll { evicted.contains($0.id) && !protectedMetadata.contains($0.id) }
        next.searchHits.removeAll { evicted.contains($0.id) && !protectedMetadata.contains($0.id) }
        next.transcripts = transcripts.filter { !evicted.contains($0.key) }
        next.transcriptCursors = transcriptCursors.filter { !evicted.contains($0.key) || protected.contains($0.key) }
        next.translations = translations.filter { !evicted.contains($0.key) || protected.contains($0.key) }
        next.readingIntents = readingIntents.filter { !evicted.contains($0.key) || protected.contains($0.key) }
        next.interactions.removeAll { evicted.contains($0.sessionID) && !protected.contains($0.sessionID) }
        for view in (next.directoryViews ?? [:]).keys {
            next.directoryViews?[view]?.entries.removeAll { evicted.contains($0.session.id) }
            next.directoryViews?[view]?.pendingEntries?.removeAll { evicted.contains($0.session.id) }
        }
        return next
    }

    mutating func cacheDownload(_ bytes: Data, id: AttachmentID, session: SessionID? = nil) {
        downloads[id] = bytes
        if let session { noteDownloadOwner(id, session: session) }
        var count = downloads.values.reduce(0) { $0 + $1.count }
        for candidate in downloads.keys.sorted(by: { $0.rawValue < $1.rawValue }) where candidate != id {
            if count <= 32 * 1024 * 1024 { break }
            count -= downloads.removeValue(forKey: candidate)?.count ?? 0
        }
    }

    mutating func noteDownloadOwner(_ id: AttachmentID, session: SessionID) {
        if downloadOwners == nil { downloadOwners = [:] }
        var owners = downloadOwners?[id] ?? []
        if !owners.contains(session) { owners.append(session) }
        downloadOwners?[id] = owners
    }

    mutating func releaseConfirmedDraftBytes(_ submitted: DraftDocument, currentDrafts: [DraftDocument]) {
        var protected = Set<AttachmentID>()
        let remaining = currentDrafts + submittedDrafts.values.filter { $0.id != submitted.id }
        for draft in remaining {
            for attachment in draft.attachments {
                protected.insert(attachment.id)
                if let remote = attachment.remoteID { protected.insert(remote) }
            }
        }
        for (id, phase) in operations where id != submitted.id {
            switch phase {
            case .creating, .awaitingTranslation, .sending, .uncertain, .failed:
                if submittedDrafts[id] == nil && phase.intent?.sendRequest == nil { return }
                if let ids = phase.intent?.sendRequest?.attachmentIDs { protected.formUnion(ids) }
            case .idle, .succeeded: break
            }
        }
        for attachment in submitted.attachments {
            guard !protected.contains(attachment.id),
                  attachment.remoteID.map({ !protected.contains($0) }) ?? true else { continue }
            draftBytes[attachment.id] = nil
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
              (pendingSessionAccessIDs?.count ?? 0) <= 4_096,
              Set(pendingSessionAccessIDs ?? []).count == (pendingSessionAccessIDs?.count ?? 0),
              (deniedSessionAccessIDs?.count ?? 0) <= 4_096,
              Set(deniedSessionAccessIDs ?? []).count == (deniedSessionAccessIDs?.count ?? 0),
              interactions.count <= 4_096, agents.count <= 4_096, workspaces.count <= 4_096,
              searchHits.count <= 4_096,
              transcriptCursors.values.allSatisfy({ ($0.catchUp?.anchorIDs.count ?? 0) <= 256 }) else {
            throw GianStorageError.unavailable
        }
        if let downloadOwners {
            guard downloadOwners.count <= 131_072,
                  downloadOwners.values.reduce(0, { $0 + $1.count }) <= 200_000,
                  downloadOwners.values.allSatisfy({ !$0.isEmpty && Set($0).count == $0.count }) else {
                throw GianStorageError.unavailable
            }
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
    public func clearDownloadCache(scope: ClientScope) throws {
        states[scope]?.downloads.removeAll()
        states[scope]?.downloadOwners = nil
    }
}
