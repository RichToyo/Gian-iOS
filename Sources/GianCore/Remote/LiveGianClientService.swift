import Foundation

/// Real Remote service. Construction performs no I/O. No preview or insecure fallback.
@MainActor
public final class LiveGianClientService: GianClientLifecycle {
    public let events: AsyncStream<InboundEnvelope>
    public let diagnostics: AsyncStream<RemoteServiceDiagnostic>
    // Set by the extensions in Remote/*.swift, so the setter is module-internal.
    public internal(set) var lastFailure: RemoteClientError?
    let eventContinuation: AsyncStream<InboundEnvelope>.Continuation
    let diagnosticContinuation: AsyncStream<RemoteServiceDiagnostic>.Continuation
    let transport: any RemoteTransport
    let secrets: any RemoteSecretStoring
    let authorizationInvalidations: any AuthorizationInvalidationStoring
    let clock: any GianClock
    let ids: any GianIDGenerating
    var epoch = 0
    var relay: RemoteRelay?
    var relayScope: ClientScope?
    var connecting: Task<Void, any Error>?
    var reconnect: Task<Void, Never>?
    var reconnectAttempt = 0
    var intentionalDisconnect = false
    var overflowed = false
    var commandWaiters: [String: RemoteCommandWaiter] = [:]
    var mailboxes: [String: RemoteMailbox] = [:]
    var snapshot: WireValue?
    var stagedSnapshot: WireValue?
    var snapshotParts: RemoteSnapshotAssembly?
    var snapshotTimeout: Task<Void, Never>?
    var catalog: WireValue?
    var directoryReadGeneration = 0
    var directoryInvalidationGeneration = 0
    var directoryMembershipGeneration = 0
    var directoryPageReads: [DirectoryCollection: Int] = [:]
    var pendingReadSnapshots: Set<String> = []
    var cursor: SyncCursor?
    var subscribedSession: SessionID?
    var subscriptionReadGeneration = 0
    var desiredSession: SessionID?
    var latestTranscriptTurns: [SessionID: Int] = [:]
    var issuedCommands: [String: String] = [:]
    var transfers: [String: RemoteTransfer] = [:]
    var deviceLeases: [ClientScope: RemoteDeviceLease] = [:]
    var invalidAccounts: Set<DataScope> = []
    var invalidHosts: Set<ClientScope> = []
    var fileDescriptors: [AttachmentID: RemoteFileDescriptor] = [:]
    var inflightTransferBytes = 0

    public convenience init(authorizationInvalidations: any AuthorizationInvalidationStoring) {
        self.init(transport: URLSessionRemoteTransport(), secrets: KeychainRemoteSecretStore(), authorizationInvalidations: authorizationInvalidations)
    }
    public init(transport: any RemoteTransport, secrets: any RemoteSecretStoring,
                authorizationInvalidations: any AuthorizationInvalidationStoring,
                clock: any GianClock = SystemGianClock(), ids: any GianIDGenerating = UUIDv7IDGenerator()) {
        self.transport = transport; self.secrets = secrets; self.clock = clock; self.ids = ids
        self.authorizationInvalidations = authorizationInvalidations
        let stream = AsyncStream<InboundEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(512))
        events = stream.stream; eventContinuation = stream.continuation
        let diagnosticStream = AsyncStream<RemoteServiceDiagnostic>.makeStream(bufferingPolicy: .bufferingNewest(32))
        diagnostics = diagnosticStream.stream; diagnosticContinuation = diagnosticStream.continuation
    }

    func note(_ error: any Error) -> RemoteClientError {
        let safe = error is CancellationError ? RemoteClientError.cancelled : (error as? RemoteClientError) ?? .transport
        lastFailure = safe
        return safe
    }
    func checkEpoch(_ captured: Int) throws {
        try Task.checkCancellation()
        guard captured == epoch else { throw RemoteClientError.cancelled }
    }
    func newID() -> String { ids.next(at: clock.now()) }
    func emit(_ event: InboundEvent, scope: ClientScope) {
        guard relayScope == scope else { return }
        if case .dropped = eventContinuation.yield(InboundEnvelope(scope: scope, event: event, serviceEpoch: eventEpoch)) {
            // Losing an ordered event cannot silently leave the client mutation-ready.
            lastFailure = .bufferLimit
            overflowed = true
            disconnectNow()
            eventContinuation.yield(InboundEnvelope(scope: scope, event: .snapshotRequired(.gapEvicted), serviceEpoch: eventEpoch))
            diagnostic(.resyncRequired(.gapEvicted), scope: scope)
        }
    }
    func diagnostic(_ status: RemoteDiagnosticStatus, scope: ClientScope? = nil) {
        diagnosticContinuation.yield(RemoteServiceDiagnostic(server: scope?.server,
            account: scope?.account, host: scope?.host, epoch: epoch, status: status))
    }

    func http(server: ServerAddress, path: String, method: String = "POST", body: WireValue? = nil,
              bearer: String? = nil) async throws -> WireValue {
        let origin = try RemoteWire.origin(server)
        guard path.hasPrefix("/api/v1/"), !path.contains("?"), !path.contains("..") else { throw RemoteClientError.invalidServer }
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { throw RemoteClientError.invalidServer }
        components.path = path
        guard let url = components.url else { throw RemoteClientError.invalidServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body { request.httpBody = try body.encoded(); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer {
            guard !bearer.isEmpty, bearer.utf8.count <= 16_384,
                  bearer.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RemoteClientError.integrity }
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        try Task.checkCancellation()
        let response = try await transport.request(request, maximumResponseBytes: 64 * 1024)
        try Task.checkCancellation()
        if response.status == 429 || response.status >= 500 {
            throw RemoteClientError.server(code: response.status == 429 ? "RATE_LIMITED" : "HOST_OFFLINE",
                retryAfter: min(60, max(5, response.retryAfterSeconds ?? 5)))
        }
        let value = try WireValue.decode(response.body, maximum: 64 * 1024)
        guard (200..<300).contains(response.status) else {
            throw RemoteWire.error(value["error"], retryAfter: response.retryAfterSeconds)
        }
        return value
    }
    func validateProtocol(_ wire: WireValue) throws {
        guard try wire.string("protocol") == RemoteBaseline.authProtocol else { throw RemoteClientError.versionMismatch }
    }
    func installationKey(_ server: ServerAddress) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "identity")
    }
    func activeKey(_ server: ServerAddress) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "active-controller")
    }
    func pinKey(_ server: ServerAddress) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "server-fingerprint")
    }
    func vaultKey(server: ServerAddress, account: AccountID, installation: String) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: account, installation: installation, purpose: "controller-and-grants")
    }
    func tombstoneKey(server: ServerAddress, account: AccountID, host: HostID? = nil) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: account, installation: "local-revocation", purpose: host.map { "host:\($0.rawValue)" } ?? "account")
    }
    func hostIsInvalid(_ scope: ClientScope) throws -> Bool {
        if invalidHosts.contains(scope) { return true }
        return try secrets.read(tombstoneKey(server: scope.server, account: scope.account, host: scope.host)) != nil
    }
    func invalidateAccount(server: ServerAddress, account: AccountID) throws {
        invalidAccounts.insert(DataScope(server: server, account: account))
        for scope in deviceLeases.keys.filter({ $0.server == server && $0.account == account }) { deviceLeases.removeValue(forKey: scope) }
        try persistAccountInvalidation(server: server, account: account)
    }
    func invalidateHost(_ scope: ClientScope) throws {
        invalidHosts.insert(scope)
        deviceLeases.removeValue(forKey: scope)
        do { try secrets.write(Data([1]), for: tombstoneKey(server: scope.server, account: scope.account, host: scope.host)) }
        catch {
            // If the scoped secure marker fails, invalidate the account cache
            // rather than let this revoked Host reappear after a restart.
            invalidAccounts.insert(scope.data)
            try authorizationInvalidations.invalidateAuthorization(scope: scope.data, at: clock.now())
            throw error
        }
    }
    /// This app's installation key for a Server: its controller identity there.
    func identity(server: ServerAddress) throws -> RemoteSigningIdentity {
        _ = try RemoteWire.origin(server)
        let key = installationKey(server)
        if let data = try secrets.read(key) {
            guard data.count <= 2048 else { throw RemoteClientError.bufferLimit }
            let identity = try JSONDecoder().decode(RemoteSigningIdentity.self, from: data)
            _ = try RemoteWire.id(identity.installation); _ = try identity.publicKey
            return identity
        }
        let identity = RemoteSigningIdentity(installation: newID())
        try secrets.write(JSONEncoder().encode(identity), for: key)
        return identity
    }
    func loadVault(server: ServerAddress, account: AccountID) throws -> RemoteControllerVault? {
        try readVaultRecord(server: server, account: account, enforcingInvalidation: true)
    }

    /// Cleanup only: Core has already persisted the sign-out barrier.
    func loadVaultForCleanup(server: ServerAddress, account: AccountID) throws -> RemoteControllerVault? {
        try readVaultRecord(server: server, account: account, enforcingInvalidation: false)
    }

    private func readVaultRecord(server: ServerAddress, account: AccountID, enforcingInvalidation: Bool) throws -> RemoteControllerVault? {
        _ = try RemoteWire.origin(server)
        guard !invalidAccounts.contains(DataScope(server: server, account: account)),
              try secrets.read(tombstoneKey(server: server, account: account)) == nil else { return nil }
        guard let pointerData = try secrets.read(activeKey(server)) else { return nil }
        guard pointerData.count <= 1024 else { throw RemoteClientError.bufferLimit }
        let pointer = try JSONDecoder().decode(RemoteActiveController.self, from: pointerData)
        guard pointer.account == account.id else { return nil }
        _ = try RemoteWire.id(pointer.installation)
        guard let data = try secrets.read(vaultKey(server: server, account: account, installation: pointer.installation)) else {
            throw RemoteClientError.integrity
        }
        guard data.count <= 512 * 1024 else { throw RemoteClientError.bufferLimit }
        let vault = try JSONDecoder().decode(RemoteControllerVault.self, from: data)
        if enforcingInvalidation {
            guard try authorizationPostdatesInvalidation(vault, server: server, account: account) else { return nil }
        }
        guard vault.server == server.absoluteString, vault.account == account.id,
              vault.identity.installation == pointer.installation,
              vault.fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              vault.hosts.count <= 20 else { throw RemoteClientError.integrity }
        let publicKey = try vault.identity.publicKey
        guard RemoteWire.hash(try publicKey.wire.encoded()) == vault.keyFingerprint else { throw RemoteClientError.integrity }
        guard let identityData = try secrets.read(installationKey(server)) else { return nil }
        guard identityData.count <= 2048 else { throw RemoteClientError.bufferLimit }
        let bootstrap = try JSONDecoder().decode(RemoteSigningIdentity.self, from: identityData)
        guard let pin = try secrets.read(pinKey(server)), pin == Data(vault.fingerprint.utf8),
              bootstrap.installation == vault.identity.installation, try bootstrap.publicKey == publicKey,
              vault.translationAttempts.count <= 2048, vault.commandAttempts.count <= 2048 else { throw RemoteClientError.integrity }
        for (hostID, host) in vault.hosts {
            guard try RemoteWire.id(hostID) == host.id,
                  host.identity.installation == pointer.installation else { throw RemoteClientError.integrity }
            _ = try host.identity.publicKey
            if let deviceID = host.deviceID { _ = try RemoteWire.id(deviceID) }
            if let connection = host.cryptoConnection { _ = try RemoteWire.id(connection) }
            if let key = host.hostKey { _ = try RemotePublicKey(wire: key.wire) }
        }
        return vault
    }
    func requireVault(server: ServerAddress, account: AccountID) throws -> RemoteControllerVault {
        guard let vault = try loadVault(server: server, account: account) else { throw RemoteClientError.notAuthorized }
        return vault
    }
    func saveVault(_ vault: RemoteControllerVault, server: ServerAddress, account: AccountID, epoch expected: Int) throws {
        try checkEpoch(expected)
        guard try authorizationPostdatesInvalidation(vault, server: server, account: account) else { throw RemoteClientError.notAuthorized }
        try secrets.write(JSONEncoder().encode(vault), for: vaultKey(server: server, account: account, installation: vault.identity.installation))
    }
}

/// Which controller identity is active for a Server.
struct RemoteActiveController: Codable, Equatable {
    let account: String
    let installation: String
}
/// This app's controller identity on one Server: the pinned Server identity
/// and, per paired Host, the device key and grant. Keychain only.
struct RemoteControllerVault: Codable {
    var server: String
    var account: String
    var identity: RemoteSigningIdentity
    /// The Server identity fingerprint pinned on first use.
    var fingerprint: String
    var keyFingerprint: String
    /// When this controller identity was set up here (the sign-out barrier's proof time).
    var createdAt: Date
    /// When this app last verified the Server's identity proof.
    var lastVerifiedAt: Date
    var hosts: [String: RemoteHostCredential]
    var translationAttempts: [String: String]
    var commandAttempts: [String: String]
}
struct RemoteHostCredential: Codable {
    var id: String
    var identity: RemoteSigningIdentity
    var pairingID: String
    var deviceID: String?
    var cryptoConnection: String?
    var hostKey: RemotePublicKey?
    var name: String
    var version: String
    var lastVerifiedAt: Date?
    var claimedAt: Date
}
