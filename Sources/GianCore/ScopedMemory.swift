import Foundation

@MainActor
final class ScopedMemory {
    typealias Bundle = StoredHostState
    private let storage: any GianStorage
    private var bundles: [ClientScope: Bundle] = [:]
    private var dirty: Set<ClientScope> = []

    init(storage: any GianStorage) { self.storage = storage }

    var usesSQLite: Bool { storage is SQLiteGianStorage }

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

    func update(_ scope: ClientScope, _ body: (inout Bundle) -> Void) {
        var bundle = bundles[scope] ?? Bundle()
        body(&bundle)
        bundles[scope] = bundle
        dirty.insert(scope)
    }

    func commit(_ scope: ClientScope) throws {
        try storage.save(bundle(for: scope), scope: scope)
        dirty.remove(scope)
    }

    func flushDirty() throws {
        for scope in Array(dirty) { try commit(scope) }
    }

    func discardCommitted() {
        bundles = bundles.filter { dirty.contains($0.key) }
    }

    func clearDownloads(_ scope: ClientScope) throws {
        try storage.clearDownloadCache(scope: scope)
        bundles[scope]?.downloads = [:]
        dirty.insert(scope)
    }
}
