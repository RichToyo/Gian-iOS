import CSQLite
import Foundation

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
    private var recentScopes: [ClientScope] = []
    private static let maximumTransactionBytes = 32 * 1024 * 1024
    private static let maximumChangedRows = 4_096
    private static let maximumLoadedRows = 50_000
    internal private(set) var lastCommitChangedRowCount = 0
    internal private(set) var lastCommitBytes = 0
    internal var beforeSaveCommit: (() throws -> Void)?
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
        guard (0...2).contains(version) else { throw GianStorageError.unsupportedSchema }
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
        if version == 2, tables != Set(["retained", "components", "authorization_invalidations"]) {
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
            try execute("PRAGMA user_version = 2")
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
                guard SHA256Hex.digest(payload) == text(statement, at: 1) else { throw GianStorageError.corruptData }
                do { return try decoder.decode(StoredHostState.self, from: payload) }
                catch { throw GianStorageError.corruptData }
            }
            guard var state else { return nil }
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
                    let bytes = try blob(statement, at: 3, maximum: Self.maximumTransactionBytes)
                    totalBytes += bytes.count
                    guard totalBytes <= retainedByteLimit else { throw GianStorageError.unavailable }
                    guard SHA256Hex.digest(bytes) == text(statement, at: 4) else { throw GianStorageError.corruptData }
                    sizes[key] = bytes.count
                    try apply(bytes, key: key, to: &state)
                }
            }
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
                    let bytes = try blob(statement, at: 1, maximum: RemoteLimits.maxAttachmentBytes)
                    if SHA256Hex.digest(bytes) == text(statement, at: 2) {
                        state.downloads[id] = bytes
                        count += size
                    }
                }
            }
            state.transcripts = state.transcripts.mapValues { TranscriptLog.merge(existing: [], incoming: $0) }
            for session in state.translations.keys {
                state.translations[session]?.records.sort { $0.id.rawValue < $1.id.rawValue }
            }
            try state.validate(scope: scope)
            return state.recovered()
        }
        if let loaded {
            committed[scope] = loaded
            componentSizes[scope] = sizes
            headerSizes[scope] = headerBytes
            rememberScope(scope)
        }
        return loaded
    }

    public func save(_ state: StoredHostState, scope: ClientScope) throws {
        let prior: StoredHostState
        if let saved = committed[scope] { prior = saved }
        else { prior = try load(scope: scope) ?? StoredHostState() }
        try state.validate(scope: scope, previous: prior)
        let retained = header(state)
        let headerChanged = retained != header(prior) || committed[scope] == nil
        let payload = headerChanged ? try encoder.encode(retained) : Data()
        let changes = try changedComponents(state, prior: prior)
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
        committed[scope] = state
        componentSizes[scope] = nextSizes
        if headerChanged { headerSizes[scope] = payload.count }
        rememberScope(scope)
        lastCommitChangedRowCount = changes.count + (headerChanged ? 1 : 0)
        lastCommitBytes = bytes
    }

    private func header(_ state: StoredHostState) -> StoredHostState {
        var result = state
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

    private func changedComponents(_ state: StoredHostState, prior: StoredHostState) throws -> [ComponentKey: Data?] {
        var changes: [ComponentKey: Data?] = [:]
        func diff<K: Hashable & CustomStringConvertible, V: Encodable & Equatable>(
            _ next: [K: V], _ old: [K: V], kind: String, owner: String = ""
        ) throws {
            for (id, value) in next where old[id] != value {
                guard changes.count < Self.maximumChangedRows else { throw GianStorageError.unavailable }
                let data = try encoder.encode(value)
                guard data.count <= Self.maximumTransactionBytes else { throw GianStorageError.unavailable }
                changes[ComponentKey(kind: kind, owner: owner, item: id.description)] = .some(data)
            }
            for id in old.keys where next[id] == nil {
                changes[ComponentKey(kind: kind, owner: owner, item: id.description)] = .some(nil)
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
            let next = (state.transcripts[session] ?? []).reduce(into: [TranscriptItemID: TranscriptItem]()) { $0[$1.id] = $1 }
            let old = (prior.transcripts[session] ?? []).reduce(into: [TranscriptItemID: TranscriptItem]()) { $0[$1.id] = $1 }
            try diff(next, old, kind: "transcript", owner: session.rawValue)
        }
        var nextTranslations = state.translations
        var oldTranslations = prior.translations
        for session in Set(state.translations.keys).union(prior.translations.keys) {
            if state.translations[session]?.records != prior.translations[session]?.records {
                let next = (state.translations[session]?.records ?? []).reduce(into: [TranslationRecordID: ReadingTranslation]()) { $0[$1.id] = $1 }
                let old = (prior.translations[session]?.records ?? []).reduce(into: [TranslationRecordID: ReadingTranslation]()) { $0[$1.id] = $1 }
                try diff(next, old, kind: "translationRecord", owner: session.rawValue)
            }
            nextTranslations[session]?.records = []
            oldTranslations[session]?.records = []
        }
        try diff(nextTranslations, oldTranslations, kind: "translation")
        for session in Set(state.readingIntents.keys).union(prior.readingIntents.keys) {
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
