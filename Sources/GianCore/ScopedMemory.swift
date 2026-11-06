import Foundation

@MainActor
final class ScopedMemory {
    typealias Bundle = StoredHostState
    private let storage: any GianStorage
    private let retentionClock: (any GianClock)?
    private var bundles: [ClientScope: Bundle] = [:]
    private var dirty: Set<ClientScope> = []
    private var committedEvictions: [ClientScope: Set<SessionID>] = [:]
    private var bundleGeneration: [ClientScope: Int] = [:]
    private var retentionActivityEvidence: [ClientScope: [SessionID: Date]] = [:]
    private var retentionVerifiedItems: [ClientScope: [SessionID: [TranscriptItemID]]] = [:]
    private var retentionHydratedEvidence: [ClientScope: Set<SessionID>] = [:]

    init(storage: any GianStorage, retentionClock: (any GianClock)? = nil) {
        self.storage = storage
        self.retentionClock = retentionClock
    }

    var usesSQLite: Bool { storage is SQLiteGianStorage }

    func needsRetentionRecovery(_ scope: ClientScope) -> Bool {
        (storage as? SQLiteGianStorage)?.retentionRecoveryScopes.contains(scope) == true
    }

    func retentionNextExpiry(_ scope: ClientScope) -> Date? {
        (storage as? SQLiteGianStorage)?.retentionNextExpiry(scope)
    }

    func retentionWorkSnapshot(_ scope: ClientScope) throws -> (StoredHostState, StoredHostState, Int, Int, Set<SessionID>, Date?)? {
        if bundles[scope] == nil { try load(scope) }
        guard let (stored, generation) = try (storage as? SQLiteGianStorage)?.retentionWorkSnapshot(scope) else { return nil }
        var snapshot = bundle(for: scope)
        snapshot.retentionRecentActivity = retentionActivityEvidence[scope]
        return (snapshot, stored, generation, bundleGeneration[scope] ?? 0, committedEvictions[scope] ?? [], retentionClock?.now())
    }

    func retentionStep(_ scope: ClientScope, generation: Int, memoryGeneration: Int,
                       protected: Set<AttachmentID>, protectedSessions: Set<SessionID>, holdDownloads: Bool = false) throws -> RetentionStepResult {
        guard bundleGeneration[scope, default: 0] == memoryGeneration else { return .stale }
        guard let sqlite = storage as? SQLiteGianStorage else { return .complete }
        if let now = retentionClock?.now(), let (stored, currentGeneration) = try sqlite.retentionWorkSnapshot(scope),
           currentGeneration == generation,
           !retentionSnapshot(scope).recentlyActiveRetentionOwners(stored: stored, now: now).isSubset(of: protectedSessions) {
            return .stale
        }
        return try sqlite.retentionStep(scope, generation: generation, protected: protected,
                                        protectedSessions: protectedSessions, holdDownloads: holdDownloads)
    }

    func invalidateAuthorization(scope: DataScope, at date: Date) throws {
        try storage.invalidateAuthorization(scope: scope, at: date)
    }

    func authorizationInvalidatedAt(scope: DataScope) throws -> Date? {
        try storage.authorizationInvalidatedAt(scope: scope)
    }

    func load(_ scope: ClientScope) throws {
        guard bundles[scope] != nil || dirty.count < 2 else { throw GianStorageError.unavailable }
        if bundles[scope] == nil { bundles[scope] = try storage.load(scope: scope) ?? Bundle() }
    }

    func bundle(for scope: ClientScope) -> Bundle { bundles[scope] ?? Bundle() }

    private func retentionSnapshot(_ scope: ClientScope) -> Bundle {
        var snapshot = bundle(for: scope)
        var activity = (storage as? SQLiteGianStorage)?.retentionRenewalWatermarks(scope) ?? [:]
        for (id, at) in retentionActivityEvidence[scope] ?? [:] {
            activity[id] = max(activity[id] ?? at, at)
        }
        snapshot.retentionRecentActivity = activity
        snapshot.retentionVerifiedItems = retentionVerifiedItems[scope]
        snapshot.retentionHydratedEvidence = retentionHydratedEvidence[scope].map { Array($0) }
        return snapshot
    }

    func retentionTailIDs(_ scope: ClientScope, session: SessionID) -> Set<TranscriptItemID>? {
        guard (storage as? SQLiteGianStorage)?.retentionPendingSessionIDs(scope).contains(session) == true else { return nil }
        return Set(bundle(for: scope).retentionTailItemIDs?[session] ?? [])
            .union(retentionVerifiedItems[scope]?[session] ?? [])
    }

    func noteRetentionItems(_ items: [TranscriptItem], session: SessionID, scope: ClientScope, hydrated: Bool = false) {
        guard var verified = retentionTailIDs(scope, session: session) else { return }
        verified.formUnion(items.map(\.id))
        let candidates = (bundle(for: scope).transcripts[session] ?? []).filter { verified.contains($0.id) }
        let ordered = TranscriptLog.merge(existing: [], incoming: candidates)
        retentionVerifiedItems[scope, default: [:]][session] = Array(ordered.suffix(64).map(\.id))
        if hydrated { retentionHydratedEvidence[scope, default: []].insert(session) }
        bundleGeneration[scope, default: 0] += 1
    }

    func noteRetentionActivity(_ session: SessionRecord, scope: ClientScope, at: Date) {
        let previous = retentionActivityEvidence[scope]?[session.id]
        guard previous.map({ $0 >= at }) != true else { return }
        retentionActivityEvidence[scope, default: [:]][session.id] = at
        update(scope) { bundle in
            if let index = bundle.sessions.firstIndex(where: { $0.id == session.id }) {
                if bundle.sessions[index].lastActivityAt.map({ $0 < at }) != false || !bundle.sessions[index].activityIsMessageOrExecution {
                    bundle.sessions[index].lastActivityAt = at
                    bundle.sessions[index].activityIsMessageOrExecution = true
                }
            } else { bundle.sessions.append(session) }
        }
    }

    func clearRetentionActivity(scope: ClientScope, session: SessionID? = nil) {
        if let session {
            retentionActivityEvidence[scope]?.removeValue(forKey: session)
            retentionVerifiedItems[scope]?.removeValue(forKey: session)
            retentionHydratedEvidence[scope]?.remove(session)
        } else {
            retentionActivityEvidence.removeValue(forKey: scope)
            retentionVerifiedItems.removeValue(forKey: scope)
            retentionHydratedEvidence.removeValue(forKey: scope)
        }
        bundleGeneration[scope, default: 0] += 1
    }

    func update(_ scope: ClientScope, _ body: (inout Bundle) -> Void) {
        var bundle = bundles[scope] ?? Bundle()
        body(&bundle)
        bundles[scope] = bundle
        bundleGeneration[scope, default: 0] += 1
        dirty.insert(scope)
    }

    func commit(_ scope: ClientScope) throws {
        let bundle = retentionSnapshot(scope)
        let now = retentionClock?.now()
        var retained = now.map {
            bundle.retainingRecentHistory(now: $0, previouslyEvicted: committedEvictions[scope] ?? [])
        } ?? bundle
        if storage is SQLiteGianStorage {
            retained.retentionRecentActivity = now.map { bundle.recentHistoryActivity(now: $0) }
            retained.retentionReferenceNow = now
        }
        let paused = bundle.retentionPauseSessionIDs()
        let hasExpiredPausedOwner = now.map { instant in
            bundle.sessions.contains { session in
                paused.contains(session.id) && session.activityIsMessageOrExecution
                    && session.lastActivityAt.map { $0 < instant.addingTimeInterval(-DirectoryTimeFilter.last7Days.duration) } == true
            }
        } ?? false
        if !paused.isEmpty && (hasExpiredPausedOwner || needsRetentionRecovery(scope)) {
            for (id, owners) in bundle.downloadOwners ?? [:] {
                let protectedOwners = owners.filter { paused.contains($0) }
                for owner in protectedOwners { retained.noteDownloadOwner(id, session: owner) }
            }
        }
        try storage.save(retained, scope: scope)
        if let sqlite = storage as? SQLiteGianStorage {
            bundles[scope]?.retentionTailItemIDs = sqlite.retentionTailItemIDs(scope)
            bundles[scope]?.retentionHydratedSessions = sqlite.retentionHydratedSessions(scope)
        }
        retentionVerifiedItems[scope] = nil
        retentionHydratedEvidence[scope] = nil
        let previous = committedEvictions[scope] ?? []
        let stillEvicted = now.map {
            previous.subtracting(bundle.recentHistoryIDs(now: $0)).subtracting(bundle.retentionProtectedSessionIDs())
        } ?? []
        let pending = (storage as? SQLiteGianStorage)?.retentionPendingSessionIDs(scope) ?? []
        // Keep the tombstone while queued even when activity or a command pauses it.
        // The retention projection separately lets protected/recent data win.
        let heldEvictions = pending
        let removedTranscripts = Set(bundle.transcripts.keys).subtracting(retained.transcripts.keys)
        committedEvictions[scope] = stillEvicted.union(heldEvictions).union(removedTranscripts)
            .union(bundle.historySessionIDs.subtracting(retained.historySessionIDs))
        dirty.remove(scope)
    }

    func flushDirty() throws {
        for scope in Array(dirty) { try commit(scope) }
    }

    func discardCommitted() {
        bundles = bundles.filter { dirty.contains($0.key) }
        retentionActivityEvidence = retentionActivityEvidence.filter { dirty.contains($0.key) }
        retentionVerifiedItems = retentionVerifiedItems.filter { dirty.contains($0.key) }
        retentionHydratedEvidence = retentionHydratedEvidence.filter { dirty.contains($0.key) }
    }

    func clearDownloads(_ scope: ClientScope) throws {
        try storage.clearDownloadCache(scope: scope)
        bundles[scope]?.downloads = [:]
        bundles[scope]?.downloadOwners = nil
        bundleGeneration[scope, default: 0] += 1
        dirty.insert(scope)
    }
}
