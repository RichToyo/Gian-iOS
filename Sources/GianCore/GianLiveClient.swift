import Foundation

/// App-owned live composition. Supply SQLite explicitly and retain this object
/// across View recreation. Construction does not start networking or read keys.
@MainActor
public final class GianLiveClient {
    public let store: GianClientStore
    public let coordinator: GianClientCoordinator

    public init(storage: SQLiteGianStorage,
                clock: any GianClock = SystemGianClock(),
                ids: any GianIDGenerating = UUIDv7IDGenerator()) throws {
        let service = LiveGianClientService(transport: URLSessionRemoteTransport(), secrets: KeychainRemoteSecretStore(),
            authorizationInvalidations: storage, clock: clock, ids: ids)
        store = GianClientStore(service: service, clock: clock, ids: ids, storage: storage)
        coordinator = try GianClientCoordinator(store: store, service: service)
    }

    public func start() { coordinator.start() }

    public func stop() async { await coordinator.stop() }

    @discardableResult
    public func restoreCachedAuthorization(server: ServerAddress, account: AccountID, selectedHost: HostID? = nil) async -> GianDispatchResult {
        await coordinator.restoreCachedAuthorization(server: server, account: account, selectedHost: selectedHost)
    }
}
