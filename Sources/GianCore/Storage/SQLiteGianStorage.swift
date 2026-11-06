import CSQLite
import Foundation

enum RetentionStepResult: Equatable { case complete, more, paused, stale }

/// Platform SQLite, FULL-synchronous WAL transactions. No network, Keychain or
/// implicit user-data location is accessed by the initializer.
@MainActor
public final class SQLiteGianStorage: GianStorage {
    private let connection: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var committed: [ClientScope: StoredHostState] = [:]
    private var componentSizes: [ClientScope: [ComponentKey: Int]] = [:]
    private var headerSizes: [ClientScope: Int] = [:]
    private var headerHashes: [ClientScope: String] = [:]
    private var retainedHeaders: [ClientScope: StoredHostState] = [:]
    private var recentScopes: [ClientScope] = []
    private var retentionGeneration: [ClientScope: Int] = [:]
    private static let maximumTransactionBytes = 32 * 1024 * 1024
    private static let maximumChangedRows = 4_096
    private static let maximumLoadedRows = 50_000
    private static let maximumRetentionJobs = 250_000
    internal private(set) var lastCommitChangedRowCount = 0
    internal private(set) var lastCommitBytes = 0
    internal var beforeSaveCommit: (() throws -> Void)?
    internal var beforeRetentionChunkCommit: (() throws -> Void)?
    internal private(set) var retentionRecoveryScopes: Set<ClientScope> = []
    internal private(set) var retentionConflicts: Set<ClientScope> = []
    internal var beforeAuthorizationInvalidationCommit: (() throws -> Void)?
    internal var retainedByteLimit = 128 * 1024 * 1024

    public init(directory: URL) throws {
        let directory = try Self.prepareDirectory(directory)
        let file = directory.appendingPathComponent("history.sqlite3")
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: file.path + suffix)
            try Self.rejectLink(url)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.referenceCount] as? Int ?? 1) == 1 else { throw GianStorageError.unsafeLocation }
            }
        }
        connection = try SQLiteConnection(file: file)
        let version = try statement("PRAGMA user_version") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw GianStorageError.unavailable }
            return sqlite3_column_int(statement, 0)
        }
        guard (0...3).contains(version) else { throw GianStorageError.unsupportedSchema }
        let tables = try statement("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") { statement in
            var names: Set<String> = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw GianStorageError.unavailable }
                names.insert(text(statement, at: 0))
                guard names.count <= 3 else { throw GianStorageError.unsupportedSchema }
            }
            return names
        }
        if version == 0, !tables.isEmpty { throw GianStorageError.unsupportedSchema }
        if version == 1, tables != Set(["retained", "components"]) { throw GianStorageError.corruptData }
        if version >= 2, tables != Set(["retained", "components", "authorization_invalidations"]) {
            throw GianStorageError.corruptData
        }
        try execute("PRAGMA foreign_keys = ON")
        if version == 0 { try execute("PRAGMA auto_vacuum = INCREMENTAL") }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        let journal = try statement("PRAGMA journal_mode") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw GianStorageError.unavailable }
            return text(statement, at: 0)
        }
        guard journal.lowercased() == "wal" else { throw GianStorageError.unavailable }
        try transaction {
            try execute("""
                CREATE TABLE IF NOT EXISTS retained (
                    server TEXT NOT NULL, account TEXT NOT NULL, host TEXT NOT NULL,
                    payload BLOB NOT NULL, sha256 TEXT NOT NULL,
                    PRIMARY KEY (server, account, host)
                ) WITHOUT ROWID
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS components (
                    server TEXT NOT NULL, account TEXT NOT NULL, host TEXT NOT NULL,
                    kind TEXT NOT NULL, owner TEXT NOT NULL, item TEXT NOT NULL,
                    body BLOB NOT NULL, sha256 TEXT NOT NULL,
                    PRIMARY KEY (server, account, host, kind, owner, item)
                ) WITHOUT ROWID
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS authorization_invalidations (
                    server TEXT NOT NULL, account TEXT NOT NULL,
                    invalidated_at REAL NOT NULL,
                    PRIMARY KEY (server, account)
                ) WITHOUT ROWID
                """)
            if version < 2 { try execute("PRAGMA user_version = 2") }
        }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                #endif
            }
        }
    }

    /// Explicit application composition only. Tests must use a temporary directory.
    /// Complete file protection is inherited by SQLite's WAL and shared-memory files.
    public static func applicationSupport(applicationIdentifier: String) throws -> SQLiteGianStorage {
        guard !applicationIdentifier.isEmpty,
              applicationIdentifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
              }), applicationIdentifier != ".", applicationIdentifier != ".." else {
            throw GianStorageError.unsafeLocation
        }
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        return try SQLiteGianStorage(directory: root.appendingPathComponent(applicationIdentifier, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true))
    }

    public func invalidateAuthorization(scope: DataScope, at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw GianStorageError.corruptData }
        try transaction {
            try statement("""
                INSERT INTO authorization_invalidations(server, account, invalidated_at) VALUES (?, ?, ?)
                ON CONFLICT(server, account) DO UPDATE
                SET invalidated_at = MAX(invalidated_at, excluded.invalidated_at)
                """) { statement in
                try bind(scope, to: statement)
                guard sqlite3_bind_double(statement, 3, date.timeIntervalSince1970) == SQLITE_OK else {
                    throw GianStorageError.unavailable
                }
                try stepDone(statement)
            }
            try beforeAuthorizationInvalidationCommit?()
        }
    }

    public func authorizationInvalidatedAt(scope: DataScope) throws -> Date? {
        try statement("SELECT invalidated_at FROM authorization_invalidations WHERE server=? AND account=?") { statement in
            try bind(scope, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw GianStorageError.unavailable }
            let type = sqlite3_column_type(statement, 0)
            let timestamp = sqlite3_column_double(statement, 0)
            guard (type == SQLITE_FLOAT || type == SQLITE_INTEGER), timestamp.isFinite else {
                throw GianStorageError.corruptData
            }
            return Date(timeIntervalSince1970: timestamp)
        }
    }

    public func load(scope: ClientScope) throws -> StoredHostState? {
        var sizes: [ComponentKey: Int] = [:]
        var headerBytes = 0
        var loadedHeader: StoredHostState?
        var loadedHash: String?
        let loaded: StoredHostState? = try transaction {
            let state: StoredHostState? = try statement(
                "SELECT payload, sha256 FROM retained WHERE server=? AND account=? AND host=?"
            ) { statement in
                try bind(scope, to: statement)
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW else { throw GianStorageError.unavailable }
                let payload = try blob(statement, at: 0, maximum: Self.maximumTransactionBytes)
                headerBytes = payload.count
                guard headerBytes <= retainedByteLimit else { throw GianStorageError.unavailable }
                let digest = text(statement, at: 1)
                guard SHA256Hex.digest(payload) == digest else { throw GianStorageError.corruptData }
                do {
                    let header = try decoder.decode(StoredHostState.self, from: payload)
                    loadedHeader = header; loadedHash = digest
                    return header
                }
                catch { throw GianStorageError.corruptData }
            }
            guard var state else { return nil }
            let jobs = state.retentionCleanup ?? []
            guard jobs.count <= Self.maximumRetentionJobs, Set(jobs).count == jobs.count,
                  jobs.allSatisfy({ job in
                      if job.kind == "download" { return AttachmentID(rawValue: job.owner) != nil }
                      return ["transcript", "translationRecord", "readingIntent"].contains(job.kind) && SessionID(rawValue: job.owner) != nil
                  }), (state.retentionRevision ?? 0) >= 0, state.retentionRevision != Int.max,
                  (state.retentionPausedSessions?.count ?? 0) <= 4_096,
                  (state.retentionSupersededSessions?.count ?? 0) <= 4_096,
                  (state.retentionTailItemIDs?.count ?? 0) <= 4_096,
                  (state.retentionTailItemIDs ?? [:]).values.allSatisfy({ $0.count <= 64 && Set($0).count == $0.count }),
                  (state.retentionTailReadingIDs?.count ?? 0) <= 4_096,
                  (state.retentionTailReadingIDs ?? [:]).values.allSatisfy({ $0.count <= 64 && Set($0).count == $0.count }),
                  (state.retentionHydratedSessions?.count ?? 0) <= 4_096,
                  (state.retentionOwnerAttachments?.count ?? 0) <= 4_096,
                  (state.retentionActivityBaseline?.count ?? 0) <= 4_096,
                  (state.retentionRenewedActivity?.count ?? 0) <= 4_096,
                  (state.retentionActivityBaseline ?? [:]).values.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                  (state.retentionRenewedActivity ?? [:]).values.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                  (state.retentionProtectedDownloads?.count ?? 0) <= 131_072 else { throw GianStorageError.corruptData }
            let pending = Set(jobs)
            let paused = Set(state.retentionPausedSessions ?? [])
            let hasHiddenTranscripts = jobs.contains { $0.kind == "transcript" }
            try statement("SELECT kind, owner, item, body, sha256 FROM components WHERE server=? AND account=? AND host=? AND kind!='download' LIMIT 50001") { statement in
                try bind(scope, to: statement)
                var count = 0
                var totalBytes = headerBytes
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw GianStorageError.unavailable }
                    count += 1
                    guard count <= Self.maximumLoadedRows else { throw GianStorageError.unavailable }
                    let key = ComponentKey(kind: text(statement, at: 0), owner: text(statement, at: 1), item: text(statement, at: 2))
                    let size = Int(sqlite3_column_bytes(statement, 3))
                    guard size >= 0, size <= Self.maximumTransactionBytes else { throw GianStorageError.unavailable }
                    totalBytes += size
                    guard totalBytes <= retainedByteLimit else { throw GianStorageError.unavailable }
                    sizes[key] = size
                    let protectedIntent = key.kind == "readingIntent" && SessionID(rawValue: key.owner).map { paused.contains($0) } == true
                    let verifiedTail = key.kind == "transcript" && SessionID(rawValue: key.owner).map { session in
                        state.retentionSupersededSessions?.contains(session) == true &&
                            state.retentionTailItemIDs?[session]?.contains(where: { $0.rawValue == key.item }) == true
                    } == true
                    let verifiedReading = key.kind == "translationRecord" && SessionID(rawValue: key.owner).map { session in
                        state.retentionSupersededSessions?.contains(session) == true &&
                            state.retentionTailReadingIDs?[session]?.contains(where: { $0.rawValue == key.item }) == true
                    } == true
                    if pending.contains(StoredRetentionPurge(kind: key.kind, owner: key.owner)) && !protectedIntent && !verifiedTail && !verifiedReading { continue }
                    let bytes = try blob(statement, at: 3, maximum: Self.maximumTransactionBytes)
                    guard SHA256Hex.digest(bytes) == text(statement, at: 4) else { throw GianStorageError.corruptData }
                    try apply(bytes, key: key, to: &state)
                }
            }
            let retainedRefs = state.retentionDownloadReferences()
            try statement("SELECT item, body, sha256 FROM components WHERE server=? AND account=? AND host=? AND kind='download' ORDER BY item LIMIT 128") { statement in
                try bind(scope, to: statement)
                var count = 0
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw GianStorageError.unavailable }
                    let size = Int(sqlite3_column_bytes(statement, 1))
                    guard let id = AttachmentID(rawValue: text(statement, at: 0)),
                          AttachmentRules.accepts(byteCount: size), count + size <= 32 * 1024 * 1024 else { continue }
                    if (hasHiddenTranscripts || pending.contains(StoredRetentionPurge(kind: "download", owner: id.rawValue))) && !retainedRefs.contains(id) { continue }
                    let bytes = try blob(statement, at: 1, maximum: RemoteLimits.maxAttachmentBytes)
                    if SHA256Hex.digest(bytes) == text(statement, at: 2) {
                        state.downloads[id] = bytes
                        count += size
                    }
                }
            }
            state.transcripts = state.transcripts.mapValues { TranscriptLog.merge(existing: [], incoming: $0) }
            for job in jobs where job.kind == "translationRecord" {
                guard let id = SessionID(rawValue: job.owner), var translation = state.translations[id] else { continue }
                let allowed = Set(state.retentionTailReadingIDs?[id] ?? [])
                translation.records = validTailReadings(translation.records.filter { allowed.contains($0.id) },
                    transcript: state.transcripts[id] ?? [], language: translation.readingLanguage)
                state.translations[id] = translation
            }
            for job in jobs where job.kind == "transcript" {
                guard let id = SessionID(rawValue: job.owner), state.retentionSupersededSessions?.contains(id) == true,
                      state.retentionTailItemIDs?[id]?.isEmpty == false else { continue }
                var cursor = state.transcriptCursors[id] ?? StoredTranscriptCursor(cursor: nil, hasOlder: true)
                cursor.cursor = nil; cursor.hasOlder = true
                if state.retentionHydratedSessions?.contains(id) != true && cursor.catchUp == nil {
                    cursor.catchUp = StoredTranscriptCatchUp(anchorIDs: state.retentionTailItemIDs?[id] ?? [])
                }
                state.transcriptCursors[id] = cursor
            }
            for session in state.translations.keys {
                let order = state.translationRecordOrder?[session] ?? []
                let ranks = order.enumerated().reduce(into: [TranslationRecordID: Int]()) { result, pair in
                    if result[pair.element] == nil { result[pair.element] = pair.offset }
                }
                state.translations[session]?.records.sort {
                    let lhs = ranks[$0.id] ?? Int.max
                    let rhs = ranks[$1.id] ?? Int.max
                    return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs < rhs
                }
            }
            try state.validate(scope: scope)
            return state.recovered()
        }
        if let loaded {
            committed[scope] = loaded
            componentSizes[scope] = sizes
            headerSizes[scope] = headerBytes
            headerHashes[scope] = loadedHash
            retainedHeaders[scope] = loadedHeader
            rememberScope(scope)
            retentionGeneration[scope, default: 0] += 1
            if !(loaded.retentionCleanup ?? []).isEmpty { retentionRecoveryScopes.insert(scope) }
        } else {
            committed[scope] = nil; componentSizes[scope] = nil; headerSizes[scope] = nil
            headerHashes[scope] = nil; retainedHeaders[scope] = nil
            retentionGeneration[scope, default: 0] += 1
            retentionRecoveryScopes.remove(scope)
        }
        return loaded
    }

    public func save(_ state: StoredHostState, scope: ClientScope) throws {
        guard !retentionConflicts.contains(scope) else { throw GianStorageError.concurrentMutation }
        let prior: StoredHostState
        if let saved = committed[scope] { prior = saved }
        else { prior = try load(scope: scope) ?? StoredHostState() }
        try state.validate(scope: scope, previous: prior)
        let currentPause = state.retentionPauseSessionIDs()
        let queuedOwners = Set((prior.retentionCleanup ?? []).compactMap { job in
            job.kind == "download" ? nil : SessionID(rawValue: job.owner)
        })
        var baselines = prior.retentionActivityBaseline ?? [:]
        var renewed = prior.retentionRenewedActivity ?? [:]
        if let now = state.retentionReferenceNow {
            let cutoff = now.addingTimeInterval(-DirectoryTimeFilter.last7Days.duration)
            renewed = renewed.filter { $0.value >= cutoff }
        }
        for (id, at) in state.retentionRecentActivity ?? [:] where queuedOwners.contains(id) {
            guard at.timeIntervalSince1970.isFinite, baselines[id].map({ at > $0 }) ?? true else { continue }
            renewed[id] = max(renewed[id] ?? at, at)
        }
        let superseded = Set(renewed.keys).intersection(queuedOwners)
        let paused = state.retentionProtectedSessionIDs()
            .union(Set(prior.retentionPausedSessions ?? []).intersection(currentPause))
            .union(state.changedRetentionDraftOwners(since: prior).intersection(queuedOwners))
        guard paused.union(superseded).count <= 4_096, prior.retentionRevision != Int.max else { throw GianStorageError.unavailable }
        var pending = Set(prior.retentionCleanup ?? [])
        // New recovery identities must remain durable even if old intents were queued.
        pending = pending.filter { job in
            guard job.kind == "readingIntent", let id = SessionID(rawValue: job.owner) else { return true }
            return !paused.contains(id) && !superseded.contains(id)
        }
        var effective = state
        var tailIDs = prior.retentionTailItemIDs ?? [:]
        var tailReadingIDs = prior.retentionTailReadingIDs ?? [:]
        var hydrated = Set(prior.retentionHydratedSessions ?? [])
        for job in pending where job.kind == "transcript" || job.kind == "translationRecord" {
            guard let id = SessionID(rawValue: job.owner) else { throw GianStorageError.corruptData }
            if job.kind == "transcript" {
                if superseded.contains(id) {
                    let allowed = Set(tailIDs[id] ?? []).union(state.retentionVerifiedItems?[id] ?? [])
                    let candidates = (state.transcripts[id] ?? prior.transcripts[id] ?? []).filter { allowed.contains($0.id) }
                    let ordered = TranscriptLog.merge(existing: [], incoming: candidates)
                    let tail = try boundedRetentionTail(ordered)
                    effective.transcripts[id] = tail
                    tailIDs[id] = tail.map(\.id)
                    var cursor = state.transcriptCursors[id] ?? StoredTranscriptCursor(cursor: nil, hasOlder: true)
                    cursor.cursor = nil; cursor.hasOlder = true
                    if state.retentionHydratedEvidence?.contains(id) == true {
                        hydrated.insert(id); cursor.catchUp = nil
                    } else if !hydrated.contains(id), cursor.catchUp == nil {
                        cursor.catchUp = StoredTranscriptCatchUp(anchorIDs: tail.map(\.id))
                    }
                    effective.transcriptCursors[id] = cursor
                } else {
                    effective.transcripts[id] = nil
                    effective.transcriptCursors[id] = nil
                }
            } else {
                effective.translations[id]?.records = []
            }
        }
        for job in pending where job.kind == "translationRecord" {
            guard let id = SessionID(rawValue: job.owner), superseded.contains(id),
                  var translation = state.translations[id] else { continue }
            let matching = validTailReadings(translation.records, transcript: effective.transcripts[id] ?? [], language: translation.readingLanguage)
            translation.records = try boundedRetentionTail(matching)
            tailReadingIDs[id] = translation.records.map(\.id)
            effective.translations[id] = translation
        }
        pending.formUnion(retentionPurges(effective, prior: prior))
        let purges = pending.sorted { ($0.kind, $0.owner) < ($1.kind, $1.owner) }
        var ownerAttachments = prior.retentionOwnerAttachments ?? [:]
        for job in purges where job.kind == "transcript" {
            guard let id = SessionID(rawValue: job.owner) else { throw GianStorageError.corruptData }
            if ownerAttachments[id] == nil || superseded.contains(id) {
                let items = superseded.contains(id) ? (state.transcripts[id] ?? prior.transcripts[id]) : prior.transcripts[id]
                guard let items else { continue }
                var refs = Set(ownerAttachments[id] ?? [])
                for item in items {
                    if case .user(_, _, let ids, _) = item.body { refs.formUnion(ids) }
                }
                for (attachment, owners) in prior.downloadOwners ?? [:] where owners.contains(id) { refs.insert(attachment) }
                ownerAttachments[id] = refs.sorted { $0.rawValue < $1.rawValue }
            }
            if baselines[id] == nil {
                let records = prior.sessions + prior.searchHits + (prior.directoryViews ?? [:]).values.flatMap { ($0.entries + ($0.pendingEntries ?? [])).map(\.session) }
                baselines[id] = records.filter { $0.id == id && $0.activityIsMessageOrExecution }.compactMap(\.lastActivityAt).max()
            }
        }
        if purges.isEmpty { ownerAttachments.removeAll(); baselines.removeAll(); renewed.removeAll(); tailIDs.removeAll(); tailReadingIDs.removeAll(); hydrated.removeAll() }
        guard purges.count <= Self.maximumRetentionJobs else { throw GianStorageError.unavailable }
        guard purges.isEmpty || effective.downloads.count <= 131_072 else { throw GianStorageError.unavailable }
        var retained = header(effective)
        retained.retentionCleanup = purges.isEmpty ? nil : purges
        retained.retentionPausedSessions = purges.isEmpty ? nil : paused.sorted { $0.rawValue < $1.rawValue }
        retained.retentionProtectedDownloads = purges.isEmpty ? nil : effective.downloads.keys.sorted { $0.rawValue < $1.rawValue }
        retained.retentionOwnerAttachments = ownerAttachments.isEmpty ? nil : ownerAttachments
        retained.retentionActivityBaseline = baselines.isEmpty ? nil : baselines
        retained.retentionRenewedActivity = renewed.isEmpty ? nil : renewed
        retained.retentionSupersededSessions = purges.isEmpty || superseded.isEmpty ? nil : superseded.sorted { $0.rawValue < $1.rawValue }
        retained.retentionTailItemIDs = tailIDs.isEmpty ? nil : tailIDs
        retained.retentionTailReadingIDs = tailReadingIDs.isEmpty ? nil : tailReadingIDs
        retained.retentionHydratedSessions = hydrated.isEmpty ? nil : hydrated.sorted { $0.rawValue < $1.rawValue }
        retained.retentionRevision = prior.retentionRevision != nil || !purges.isEmpty ? (prior.retentionRevision ?? 0) + 1 : nil
        var priorHeader = header(prior)
        priorHeader.retentionCleanup = prior.retentionCleanup
        priorHeader.retentionPausedSessions = prior.retentionPausedSessions
        priorHeader.retentionProtectedDownloads = prior.retentionProtectedDownloads
        priorHeader.retentionOwnerAttachments = prior.retentionOwnerAttachments
        priorHeader.retentionActivityBaseline = prior.retentionActivityBaseline
        priorHeader.retentionRenewedActivity = prior.retentionRenewedActivity
        priorHeader.retentionSupersededSessions = prior.retentionSupersededSessions
        priorHeader.retentionTailItemIDs = prior.retentionTailItemIDs
        priorHeader.retentionTailReadingIDs = prior.retentionTailReadingIDs
        priorHeader.retentionHydratedSessions = prior.retentionHydratedSessions
        priorHeader.retentionRevision = prior.retentionRevision
        let headerChanged = retained != priorHeader || committed[scope] == nil
        let payload = headerChanged ? try encoder.encode(retained) : Data()
        let changes = try changedComponents(effective, prior: prior, purges: Set(purges), superseded: superseded)
        let bytes = changes.values.reduce(payload.count) { $0 + ($1?.count ?? 0) }
        var nextSizes = componentSizes[scope] ?? [:]
        var retainedBytes = (headerChanged ? payload.count : headerSizes[scope] ?? 0) + nextSizes.values.reduce(0, +)
        for (key, data) in changes where key.kind != "download" {
            retainedBytes -= nextSizes[key] ?? 0
            retainedBytes += data?.count ?? 0
            nextSizes[key] = data?.count
        }
        guard changes.count <= Self.maximumChangedRows, bytes <= Self.maximumTransactionBytes else {
            throw GianStorageError.unavailable
        }
        guard retainedBytes <= retainedByteLimit, nextSizes.count <= Self.maximumLoadedRows else { throw GianStorageError.unavailable }
        try transaction {
            try assertRetentionFence(scope)
            // Older clients cannot preserve cleanup queues or ownership metadata.
            if !purges.isEmpty || !(effective.downloadOwners ?? [:]).isEmpty { try execute("PRAGMA user_version = 3") }
            if headerChanged {
                try statement("INSERT OR REPLACE INTO retained VALUES (?, ?, ?, ?, ?)") { statement in
                    try bind(scope, to: statement)
                    try bind(payload, to: statement, at: 4)
                    try bind(SHA256Hex.digest(payload), to: statement, at: 5)
                    try stepDone(statement)
                }
            }
            for (key, bytes) in changes {
                if let bytes {
                    try statement("INSERT OR REPLACE INTO components VALUES (?, ?, ?, ?, ?, ?, ?, ?)") { statement in
                        try bind(scope, to: statement)
                        try bind(key.kind, to: statement, at: 4)
                        try bind(key.owner, to: statement, at: 5)
                        try bind(key.item, to: statement, at: 6)
                        try bind(bytes, to: statement, at: 7)
                        try bind(SHA256Hex.digest(bytes), to: statement, at: 8)
                        try stepDone(statement)
                    }
                } else {
                    try statement("DELETE FROM components WHERE server=? AND account=? AND host=? AND kind=? AND owner=? AND item=?") { statement in
                        try bind(scope, to: statement)
                        try bind(key.kind, to: statement, at: 4)
                        try bind(key.owner, to: statement, at: 5)
                        try bind(key.item, to: statement, at: 6)
                        try stepDone(statement)
                    }
                }
            }
            try beforeSaveCommit?()
        }
        effective.retentionCleanup = retained.retentionCleanup
        effective.retentionPausedSessions = retained.retentionPausedSessions
        effective.retentionProtectedDownloads = retained.retentionProtectedDownloads
        effective.retentionOwnerAttachments = retained.retentionOwnerAttachments
        effective.retentionActivityBaseline = retained.retentionActivityBaseline
        effective.retentionRenewedActivity = retained.retentionRenewedActivity
        effective.retentionSupersededSessions = retained.retentionSupersededSessions
        effective.retentionTailItemIDs = retained.retentionTailItemIDs
        effective.retentionTailReadingIDs = retained.retentionTailReadingIDs
        effective.retentionHydratedSessions = retained.retentionHydratedSessions
        effective.retentionRecentActivity = nil
        effective.retentionReferenceNow = nil
        effective.retentionVerifiedItems = nil
        effective.retentionHydratedEvidence = nil
        effective.retentionRevision = retained.retentionRevision
        committed[scope] = effective
        componentSizes[scope] = nextSizes
        if headerChanged {
            headerSizes[scope] = payload.count
            headerHashes[scope] = SHA256Hex.digest(payload)
            retainedHeaders[scope] = retained
        }
        retentionGeneration[scope, default: 0] += 1
        if purges.isEmpty { retentionRecoveryScopes.remove(scope) } else { retentionRecoveryScopes.insert(scope) }
        rememberScope(scope)
        lastCommitChangedRowCount = changes.count + (headerChanged ? 1 : 0)
        lastCommitBytes = bytes
    }

    private func header(_ state: StoredHostState) -> StoredHostState {
        var result = state
        result.retentionCleanup = nil
        result.retentionProtectedDownloads = nil
        result.retentionPausedSessions = nil
        result.retentionRevision = nil
        result.retentionOwnerAttachments = nil
        result.retentionActivityBaseline = nil
        result.retentionRenewedActivity = nil
        result.retentionSupersededSessions = nil
        result.retentionTailItemIDs = nil
        result.retentionTailReadingIDs = nil
        result.retentionHydratedSessions = nil
        result.retentionRecentActivity = nil
        result.retentionReferenceNow = nil
        result.retentionVerifiedItems = nil
        result.retentionHydratedEvidence = nil
        result.translationRecordOrder = state.translations.mapValues { $0.records.map(\.id) }
        result.transcripts = [:]
        result.drafts = []
        result.submittedDrafts = [:]
        result.translations = [:]
        result.readingIntents = [:]
        result.operations = [:]
        result.selections = [:]
        result.downloads = [:]
        result.draftBytes = [:]
        return result
    }

    private struct ComponentKey: Hashable {
        let kind: String
        let owner: String
        let item: String
    }

    private func boundedRetentionTail<T: Encodable>(_ values: [T]) throws -> [T] {
        var result: [T] = []
        var bytes = 0
        for value in values.reversed().prefix(64) {
            let size = try encoder.encode(value).count
            guard size <= Self.maximumTransactionBytes / 2 else { throw GianStorageError.unavailable }
            if !result.isEmpty && bytes + size > 8 * 1024 * 1024 { break }
            result.append(value); bytes += size
        }
        return Array(result.reversed())
    }

    private func validTailReadings(_ records: [ReadingTranslation], transcript: [TranscriptItem], language: String) -> [ReadingTranslation] {
        guard !language.isEmpty else { return [] }
        let ordered = TranscriptLog.merge(existing: [], incoming: transcript)
        var finalAssistant: [TurnID: TranscriptItemID] = [:]
        for item in ordered {
            if case .assistant(let text, _) = item.body, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalAssistant[item.turnID] = item.id
            }
        }
        var sources: [String: Set<String>] = [:]
        for item in ordered {
            guard case .assistant(let text, _) = item.body else { continue }
            let hash = SHA256Hex.digest(Data(text.utf8))
            sources[item.id.rawValue, default: []].insert(hash)
            if finalAssistant[item.turnID] == item.id { sources["turn:\(item.turn)", default: []].insert(hash) }
        }
        return records.compactMap { record in
            guard let source = record.sourceID,
                  sources[source]?.contains(record.sourceSHA256.lowercased()) == true,
                  record.targetLanguage.caseInsensitiveCompare(language) == .orderedSame,
                  record.integrity != .hashMismatch, record.integrity != .lengthMismatch,
                  record.integrity == .descriptorPending || record.presentableText != nil else { return nil }
            let checked = TranslationReducer.verifiedRecord(id: record.id, sourceID: source,
                targetLanguage: record.targetLanguage, text: record.presentableText, textLength: record.textLength,
                textSHA256: record.textSHA256, sourceSHA256: record.sourceSHA256, paged: record.integrity == .pagedVerified)
            guard checked.integrity != .hashMismatch, checked.integrity != .lengthMismatch else { return nil }
            return checked
        }
    }

    private func assertRetentionFence(_ scope: ClientScope) throws {
        let current: String? = try statement("SELECT sha256 FROM retained WHERE server=? AND account=? AND host=?") { statement in
            try bind(scope, to: statement)
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw GianStorageError.unavailable }
            return text(statement, at: 0)
        }
        guard current == headerHashes[scope] else {
            retentionConflicts.insert(scope)
            throw GianStorageError.concurrentMutation
        }
    }

    private func retentionPurges(_ state: StoredHostState, prior: StoredHostState) -> [StoredRetentionPurge] {
        var jobs: Set<StoredRetentionPurge> = []
        for session in prior.transcripts.keys where state.transcripts[session] == nil {
            jobs.insert(StoredRetentionPurge(kind: "transcript", owner: session.rawValue))
        }
        for (session, translation) in prior.translations where state.translations[session] == nil && !translation.records.isEmpty {
            jobs.insert(StoredRetentionPurge(kind: "translationRecord", owner: session.rawValue))
        }
        for session in prior.readingIntents.keys where state.readingIntents[session] == nil {
            jobs.insert(StoredRetentionPurge(kind: "readingIntent", owner: session.rawValue))
        }
        for id in (prior.downloadOwners ?? [:]).keys
        where state.downloadOwners?[id] == nil && state.downloads[id] == nil {
            jobs.insert(StoredRetentionPurge(kind: "download", owner: id.rawValue))
        }
        return jobs.sorted { ($0.kind, $0.owner) < ($1.kind, $1.owner) }
    }

    func retentionWorkSnapshot(_ scope: ClientScope) throws -> (StoredHostState, Int)? {
        guard !retentionConflicts.contains(scope) else { throw GianStorageError.concurrentMutation }
        if committed[scope] == nil { _ = try load(scope: scope) }
        guard let state = committed[scope], let jobs = state.retentionCleanup, !jobs.isEmpty else { return nil }
        let paused = Set(state.retentionPausedSessions ?? []).union(state.retentionSupersededSessions ?? [])
        guard jobs.contains(where: { job in
            guard job.kind != "download", let id = SessionID(rawValue: job.owner) else { return true }
            return !paused.contains(id)
        }) else { return nil }
        return (state, retentionGeneration[scope] ?? 0)
    }

    func retentionPendingSessionIDs(_ scope: ClientScope) -> Set<SessionID> {
        Set((committed[scope]?.retentionCleanup ?? []).compactMap { job in
            job.kind == "download" ? nil : SessionID(rawValue: job.owner)
        })
    }

    func retentionTailItemIDs(_ scope: ClientScope) -> [SessionID: [TranscriptItemID]]? {
        committed[scope]?.retentionTailItemIDs
    }

    func retentionHydratedSessions(_ scope: ClientScope) -> [SessionID]? {
        committed[scope]?.retentionHydratedSessions
    }

    func retentionRenewalWatermarks(_ scope: ClientScope) -> [SessionID: Date] {
        committed[scope]?.retentionRenewedActivity ?? [:]
    }

    func retentionNextExpiry(_ scope: ClientScope) -> Date? {
        guard let state = committed[scope] else { return nil }
        let pending = retentionPendingSessionIDs(scope)
        return (state.retentionRenewedActivity ?? [:]).compactMap { id, at in
            pending.contains(id) ? at.addingTimeInterval(DirectoryTimeFilter.last7Days.duration) : nil
        }.min()
    }

    func retentionStep(_ scope: ClientScope, generation: Int, protected: Set<AttachmentID>,
                       protectedSessions: Set<SessionID>, holdDownloads: Bool) throws -> RetentionStepResult {
        guard retentionGeneration[scope] == generation else { return .stale }
        var removed: [ComponentKey] = []
        var updatedJobs: [StoredRetentionPurge] = []
        var updatedHeaderBytes = 0
        var updatedRevision: Int?
        var updatedHeader: StoredHostState?
        var updatedHash: String?
        let result: RetentionStepResult = try transaction {
                do { try assertRetentionFence(scope) }
                catch GianStorageError.concurrentMutation { return .stale }
                guard var header = retainedHeaders[scope], let jobs = header.retentionCleanup, !jobs.isEmpty else { return .complete }
                guard header.retentionRevision == committed[scope]?.retentionRevision else { return .stale }
                retentionRecoveryScopes.insert(scope)
                try header.validate(scope: scope)
                guard jobs.count <= Self.maximumRetentionJobs else { throw GianStorageError.corruptData }
                if let protected = header.retentionProtectedDownloads {
                    guard protected.count <= 131_072, Set(protected).count == protected.count else { throw GianStorageError.corruptData }
                }
                let paused = Set(header.retentionPausedSessions ?? []).union(header.retentionSupersededSessions ?? []).union(protectedSessions)
                guard let index = jobs.firstIndex(where: { job in
                    if job.kind == "download" {
                        return !holdDownloads && (AttachmentID(rawValue: job.owner).map { !protected.contains($0) } ?? true)
                    }
                    return SessionID(rawValue: job.owner).map { !paused.contains($0) } == true
                }) else { return .paused }
                let job = jobs[index]
                    guard ["transcript", "translationRecord", "readingIntent", "download"].contains(job.kind) else {
                        throw GianStorageError.corruptData
                    }
                var exhausted = false
                var completedCount = 1
                    if job.kind == "download" {
                        completedCount = 0
                        for candidate in jobs[index...].prefix(512) {
                            guard candidate.kind == "download" else { break }
                            guard let id = AttachmentID(rawValue: candidate.owner) else { throw GianStorageError.corruptData }
                            if protected.contains(id) { break }
                            try statement("DELETE FROM components WHERE server=? AND account=? AND host=? AND kind='download' AND owner='' AND item=?") { statement in
                                try bind(scope, to: statement)
                                try bind(id.rawValue, to: statement, at: 4)
                                try stepDone(statement)
                            }
                            completedCount += 1
                        }
                        exhausted = true
                    } else if job.kind == "transcript" {
                        guard SessionID(rawValue: job.owner) != nil else { throw GianStorageError.corruptData }
                        let batch = try purgeTranscriptChunk(scope, owner: job.owner, limit: 15,
                                                              protected: protected, deferDownloads: holdDownloads)
                        removed += batch.deletedItems.map { ComponentKey(kind: job.kind, owner: job.owner, item: $0) }
                        for id in batch.deferredDownloads {
                            let deferred = StoredRetentionPurge(kind: "download", owner: id.rawValue)
                            if !jobs.contains(deferred) && !updatedJobs.contains(deferred) { updatedJobs.append(deferred) }
                        }
                        exhausted = batch.exhausted
                    } else {
                        guard SessionID(rawValue: job.owner) != nil else { throw GianStorageError.corruptData }
                        var items: [String] = []
                        try statement("SELECT item FROM components WHERE server=? AND account=? AND host=? AND kind=? AND owner=? ORDER BY item LIMIT 512") { statement in
                            try bind(scope, to: statement)
                            try bind(job.kind, to: statement, at: 4)
                            try bind(job.owner, to: statement, at: 5)
                            while true {
                                let code = sqlite3_step(statement)
                                if code == SQLITE_DONE { break }
                                guard code == SQLITE_ROW else { throw GianStorageError.unavailable }
                                items.append(text(statement, at: 0))
                            }
                        }
                        for item in items {
                            try statement("DELETE FROM components WHERE server=? AND account=? AND host=? AND kind=? AND owner=? AND item=?") { statement in
                                try bind(scope, to: statement)
                                try bind(job.kind, to: statement, at: 4)
                                try bind(job.owner, to: statement, at: 5)
                                try bind(item, to: statement, at: 6)
                                try stepDone(statement)
                            }
                            removed.append(ComponentKey(kind: job.kind, owner: job.owner, item: item))
                        }
                        exhausted = items.count < 512
                    }
                var nextJobs = jobs
                if exhausted { nextJobs.removeSubrange(index..<(index + completedCount)) }
                nextJobs.append(contentsOf: updatedJobs)
                nextJobs.sort { ($0.kind, $0.owner) < ($1.kind, $1.owner) }
                guard nextJobs.count <= Self.maximumRetentionJobs else { throw GianStorageError.unavailable }
                header.retentionCleanup = nextJobs.isEmpty ? nil : nextJobs
                if nextJobs.isEmpty {
                    header.retentionProtectedDownloads = nil; header.retentionPausedSessions = nil
                    header.retentionOwnerAttachments = nil; header.retentionActivityBaseline = nil
                    header.retentionRenewedActivity = nil; header.retentionSupersededSessions = nil
                    header.retentionTailItemIDs = nil; header.retentionHydratedSessions = nil
                    header.retentionTailReadingIDs = nil
                }
                guard header.retentionRevision != Int.max else { throw GianStorageError.corruptData }
                header.retentionRevision = (header.retentionRevision ?? 0) + 1
                let payload = try encoder.encode(header)
                guard payload.count <= Self.maximumTransactionBytes else { throw GianStorageError.unavailable }
                let digest = SHA256Hex.digest(payload)
                try statement("INSERT OR REPLACE INTO retained VALUES (?, ?, ?, ?, ?)") { statement in
                    try bind(scope, to: statement)
                    try bind(payload, to: statement, at: 4)
                    try bind(digest, to: statement, at: 5)
                    try stepDone(statement)
                }
                try beforeRetentionChunkCommit?()
                updatedJobs = nextJobs
                updatedHeaderBytes = payload.count
                updatedRevision = header.retentionRevision
                updatedHeader = header
                updatedHash = digest
                return nextJobs.isEmpty ? .complete : .more
        }
        if result == .complete || result == .more {
            for key in removed { componentSizes[scope]?[key] = nil }
            committed[scope]?.retentionCleanup = updatedJobs.isEmpty ? nil : updatedJobs
            if let updatedRevision { committed[scope]?.retentionRevision = updatedRevision }
            retainedHeaders[scope] = updatedHeader
            headerHashes[scope] = updatedHash
            if result == .complete {
                committed[scope]?.retentionPausedSessions = nil
                committed[scope]?.retentionProtectedDownloads = nil
                committed[scope]?.retentionOwnerAttachments = nil
                committed[scope]?.retentionActivityBaseline = nil
                committed[scope]?.retentionRenewedActivity = nil
                committed[scope]?.retentionSupersededSessions = nil
                committed[scope]?.retentionTailItemIDs = nil
                committed[scope]?.retentionTailReadingIDs = nil
                committed[scope]?.retentionHydratedSessions = nil
                retentionRecoveryScopes.remove(scope)
            }
            if updatedHeaderBytes > 0 { headerSizes[scope] = updatedHeaderBytes }
        } else if result == .stale {
            retentionConflicts.insert(scope)
            committed[scope] = nil; componentSizes[scope] = nil; headerSizes[scope] = nil
            retainedHeaders[scope] = nil; headerHashes[scope] = nil
            retentionGeneration[scope, default: 0] += 1
        }
        return result
    }

    private func purgeTranscriptChunk(_ scope: ClientScope, owner: String, limit: Int,
                                      protected: Set<AttachmentID>, deferDownloads: Bool) throws -> (cost: Int, exhausted: Bool, deletedItems: [String], deferredDownloads: [AttachmentID]) {
        var rows: [(String, [AttachmentID])] = []
        var bytesRead = 0
        var reachedBudget = false
        try statement("""
            SELECT item, body, sha256 FROM components
            WHERE server=? AND account=? AND host=? AND kind='transcript' AND owner=? ORDER BY item LIMIT ?
            """) { statement in
            try bind(scope, to: statement)
            try bind(owner, to: statement, at: 4)
            guard sqlite3_bind_int(statement, 5, Int32(limit)) == SQLITE_OK else { throw GianStorageError.unavailable }
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw GianStorageError.unavailable }
                let key = text(statement, at: 0)
                let size = Int(sqlite3_column_bytes(statement, 1))
                guard size >= 0, size <= Self.maximumTransactionBytes else { throw GianStorageError.corruptData }
                if !rows.isEmpty && bytesRead + size > 8 * 1024 * 1024 { reachedBudget = true; break }
                let body = try blob(statement, at: 1, maximum: Self.maximumTransactionBytes)
                bytesRead += body.count
                guard SHA256Hex.digest(body) == text(statement, at: 2) else { throw GianStorageError.corruptData }
                let item: TranscriptItem
                do { item = try decoder.decode(TranscriptItem.self, from: body) }
                catch { throw GianStorageError.corruptData }
                guard item.id.rawValue == key else { throw GianStorageError.corruptData }
                var attachments: [AttachmentID] = []
                if case .user(_, _, let ids, _) = item.body {
                    guard ids.count <= 32 else { throw GianStorageError.corruptData }
                    let candidates = deferDownloads ? Set(ids) : Set(ids).subtracting(protected)
                    attachments = candidates.sorted { $0.rawValue < $1.rawValue }
                }
                rows.append((key, attachments))
            }
        }
        var cost = 0
        var deferred: Set<AttachmentID> = []
        for (key, attachments) in rows {
            try statement("DELETE FROM components WHERE server=? AND account=? AND host=? AND kind='transcript' AND owner=? AND item=?") { statement in
                try bind(scope, to: statement)
                try bind(owner, to: statement, at: 4)
                try bind(key, to: statement, at: 5)
                try stepDone(statement)
            }
            cost += 1
            for id in attachments {
                if deferDownloads { deferred.insert(id) }
                else {
                    try statement("DELETE FROM components WHERE server=? AND account=? AND host=? AND kind='download' AND owner='' AND item=?") { statement in
                        try bind(scope, to: statement)
                        try bind(id.rawValue, to: statement, at: 4)
                        try stepDone(statement)
                    }
                }
                cost += 1
            }
        }
        return (cost, rows.count < limit && !reachedBudget, rows.map { $0.0 }, Array(deferred).sorted { $0.rawValue < $1.rawValue })
    }

    private func changedComponents(_ state: StoredHostState, prior: StoredHostState,
                                   purges: Set<StoredRetentionPurge>, superseded: Set<SessionID>) throws -> [ComponentKey: Data?] {
        var changes: [ComponentKey: Data?] = [:]
        func diff<K: Hashable & CustomStringConvertible, V: Encodable & Equatable>(
            _ next: [K: V], _ old: [K: V], kind: String, owner: String = "", allowDeletes: Bool = true
        ) throws {
            for (id, value) in next where old[id] != value {
                guard changes.count < Self.maximumChangedRows else { throw GianStorageError.unavailable }
                let data = try encoder.encode(value)
                guard data.count <= Self.maximumTransactionBytes else { throw GianStorageError.unavailable }
                changes[ComponentKey(kind: kind, owner: owner, item: id.description)] = .some(data)
            }
            if allowDeletes {
                for id in old.keys where next[id] == nil {
                    changes[ComponentKey(kind: kind, owner: owner, item: id.description)] = .some(nil)
                }
            }
        }
        func drafts(_ values: [DraftDocument]) -> [DraftID: DraftDocument] {
            values.reduce(into: [:]) { $0[$1.id] = $1 }
        }
        try diff(drafts(state.drafts), drafts(prior.drafts), kind: "draft")
        try diff(state.submittedDrafts, prior.submittedDrafts, kind: "submitted")
        try diff(state.operations, prior.operations, kind: "operation")
        try diff(state.selections, prior.selections, kind: "selection")
        for session in Set(state.transcripts.keys).union(prior.transcripts.keys) {
            if state.transcripts[session] == prior.transcripts[session] { continue }
            let isPurging = purges.contains(StoredRetentionPurge(kind: "transcript", owner: session.rawValue))
            if isPurging && !superseded.contains(session) { continue }
            let next = (state.transcripts[session] ?? []).reduce(into: [TranscriptItemID: TranscriptItem]()) { $0[$1.id] = $1 }
            let old = (prior.transcripts[session] ?? []).reduce(into: [TranscriptItemID: TranscriptItem]()) { $0[$1.id] = $1 }
            try diff(next, old, kind: "transcript", owner: session.rawValue, allowDeletes: !isPurging)
        }
        var nextTranslations = state.translations
        var oldTranslations = prior.translations
        for session in Set(state.translations.keys).union(prior.translations.keys) {
            let isPurging = purges.contains(StoredRetentionPurge(kind: "translationRecord", owner: session.rawValue))
            if state.translations[session]?.records != prior.translations[session]?.records,
               !isPurging || superseded.contains(session) {
                let next = (state.translations[session]?.records ?? []).reduce(into: [TranslationRecordID: ReadingTranslation]()) { $0[$1.id] = $1 }
                let old = (prior.translations[session]?.records ?? []).reduce(into: [TranslationRecordID: ReadingTranslation]()) { $0[$1.id] = $1 }
                try diff(next, old, kind: "translationRecord", owner: session.rawValue, allowDeletes: !isPurging)
            }
            nextTranslations[session]?.records = []
            oldTranslations[session]?.records = []
        }
        try diff(nextTranslations, oldTranslations, kind: "translation")
        for session in Set(state.readingIntents.keys).union(prior.readingIntents.keys) {
            if purges.contains(StoredRetentionPurge(kind: "readingIntent", owner: session.rawValue)) { continue }
            try diff(state.readingIntents[session] ?? [:], prior.readingIntents[session] ?? [:],
                     kind: "readingIntent", owner: session.rawValue)
        }
        for (kind, next, old) in [("unsent", state.draftBytes, prior.draftBytes), ("download", state.downloads, prior.downloads)] {
            for (id, data) in next where old[id] != data {
                changes[ComponentKey(kind: kind, owner: "", item: id.rawValue)] = .some(data)
            }
            for id in old.keys where next[id] == nil {
                changes[ComponentKey(kind: kind, owner: "", item: id.rawValue)] = .some(nil)
            }
        }
        return changes
    }

    private func apply(_ bytes: Data, key: ComponentKey, to state: inout StoredHostState) throws {
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            do { return try decoder.decode(type, from: bytes) }
            catch { throw GianStorageError.corruptData }
        }
        func id<K>(_ raw: String, _ type: ScopedID<K>.Type) throws -> ScopedID<K> {
            guard let id = ScopedID<K>(rawValue: raw) else { throw GianStorageError.corruptData }
            return id
        }
        switch key.kind {
        case "draft": state.drafts.append(try decode(DraftDocument.self))
        case "submitted": state.submittedDrafts[try id(key.item, DraftID.self)] = try decode(DraftDocument.self)
        case "operation": state.operations[try id(key.item, DraftID.self)] = try decode(SendPhase.self)
        case "selection": state.selections[try id(key.item, DraftID.self)] = try decode(ComposerSelection.self)
        case "transcript":
            let session = try id(key.owner, SessionID.self)
            state.transcripts[session, default: []].append(try decode(TranscriptItem.self))
        case "translation":
            let session = try id(key.item, SessionID.self)
            let records = state.translations[session]?.records ?? []
            state.translations[session] = try decode(TranslationSessionState.self)
            state.translations[session]?.records = records
        case "translationRecord":
            let session = try id(key.owner, SessionID.self)
            if state.translations[session] == nil { state.translations[session] = .unsupported }
            state.translations[session]?.records.append(try decode(ReadingTranslation.self))
        case "readingIntent":
            let session = try id(key.owner, SessionID.self)
            state.readingIntents[session, default: [:]][key.item] = try decode(StoredReadingIntent.self)
        case "unsent": state.draftBytes[try id(key.item, AttachmentID.self)] = bytes
        case "download": state.downloads[try id(key.item, AttachmentID.self)] = bytes
        default: throw GianStorageError.corruptData
        }
    }

    public func clearDownloadCache(scope: ClientScope) throws {
        try transaction { try deleteDownloads(scope) }
        committed[scope]?.downloads = [:]
        retentionGeneration[scope, default: 0] += 1
        try? execute("PRAGMA incremental_vacuum(128)")
    }

    private func rememberScope(_ scope: ClientScope) {
        recentScopes.removeAll { $0 == scope }
        recentScopes.append(scope)
        while recentScopes.count > 2 {
            let evicted = recentScopes.removeFirst()
            committed[evicted] = nil
            componentSizes[evicted] = nil
            headerSizes[evicted] = nil
            headerHashes[evicted] = nil
            retainedHeaders[evicted] = nil
        }
    }

    private func deleteDownloads(_ scope: ClientScope) throws {
        try statement("DELETE FROM components WHERE server=? AND account=? AND host=? AND kind='download'") { statement in
            try bind(scope, to: statement)
            try stepDone(statement)
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection.handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw GianStorageError.unavailable
        }
    }

    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw GianStorageError.unavailable }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ scope: ClientScope, to statement: OpaquePointer) throws {
        guard ServerAddress(parsing: scope.server.absoluteString) == scope.server,
              AccountID(provider: scope.account.provider, id: scope.account.id) == scope.account,
              HostID(rawValue: scope.host.rawValue) != nil else { throw GianStorageError.scopeMismatch }
        try bind(scope.server.absoluteString, to: statement, at: 1)
        try bind(scope.account.provider.rawValue + ":" + scope.account.id, to: statement, at: 2)
        try bind(scope.host.rawValue, to: statement, at: 3)
    }

    private func bind(_ scope: DataScope, to statement: OpaquePointer) throws {
        guard ServerAddress(parsing: scope.server.absoluteString) == scope.server,
              AccountID(provider: scope.account.provider, id: scope.account.id) == scope.account else {
            throw GianStorageError.scopeMismatch
        }
        try bind(scope.server.absoluteString, to: statement, at: 1)
        try bind(scope.account.provider.rawValue + ":" + scope.account.id, to: statement, at: 2)
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK else { throw GianStorageError.unavailable }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        guard value.count <= Int(Int32.max) else { throw GianStorageError.unavailable }
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw GianStorageError.unavailable }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw GianStorageError.unavailable }
    }

    private func text(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }

    private func blob(_ statement: OpaquePointer, at index: Int32, maximum: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, count <= maximum, let bytes = sqlite3_column_blob(statement, index) else { throw GianStorageError.corruptData }
        return Data(bytes: bytes, count: count)
    }

    private static func rejectLink(_ url: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw GianStorageError.unsafeLocation
        }
    }

    private static func prepareDirectory(_ input: URL) throws -> URL {
        guard input.isFileURL else { throw GianStorageError.unsafeLocation }
        let url = input.standardizedFileURL
        try rejectLink(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw GianStorageError.unsafeLocation }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resolved.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: resolved.path)
        #endif
        var protected = resolved
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        return resolved
    }
}

/// The wrapper owns the C resource; all operations are confined to GianStorage's
/// main actor. Sendability only permits safe release from a nonisolated deinit.
private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(file: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &handle,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw GianStorageError.unavailable
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 1_000)
    }
    deinit { sqlite3_close_v2(handle) }
}
