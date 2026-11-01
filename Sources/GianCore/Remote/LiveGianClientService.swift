import Foundation

/// Real Remote service. Construction performs no I/O. No preview or insecure fallback.
@MainActor
public final class LiveGianClientService: GianClientLifecycle {
    public let events: AsyncStream<InboundEnvelope>
    public let diagnostics: AsyncStream<RemoteServiceDiagnostic>
    public private(set) var lastFailure: RemoteClientError?
    let eventContinuation: AsyncStream<InboundEnvelope>.Continuation
    let diagnosticContinuation: AsyncStream<RemoteServiceDiagnostic>.Continuation
    let transport: any RemoteTransport
    let secrets: any RemoteSecretStoring
    let authorizationInvalidations: any AuthorizationInvalidationStoring
    let clock: any GianClock
    let ids: any GianIDGenerating
    var epoch = 0
    var login: RemotePendingLogin?
    var loginAttempts: [RemoteLoginAttemptKey: RemoteLoginAttempt] = [:]
    var invalidAuthorizations: Set<RemoteSecretKey> = []
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
    var invalidServers: Set<ServerAddress> = []
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
    func diagnostic(_ status: RemoteDiagnosticStatus, scope: ClientScope? = nil, login: RemotePendingLogin? = nil) {
        diagnosticContinuation.yield(RemoteServiceDiagnostic(server: scope?.server ?? login?.server,
            account: scope?.account, host: scope?.host, loginID: login?.id, epoch: epoch, status: status))
    }

    func http(server: ServerAddress, path: String, method: String = "POST", body: WireValue? = nil,
              accountToken: String? = nil, bearer: String? = nil) async throws -> WireValue {
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
        for credential in [accountToken, bearer].compactMap({ $0 }) {
            guard !credential.isEmpty, credential.utf8.count <= 16_384,
                  credential.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RemoteClientError.integrity }
        }
        if let accountToken { request.setValue(accountToken, forHTTPHeaderField: "x-gian-account-token") }
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
    func validateProtocol(_ wire: WireValue, account: Bool = false) throws {
        guard try wire.string("protocol") == (account ? RemoteBaseline.accountProtocol : RemoteBaseline.authProtocol) else {
            throw RemoteClientError.versionMismatch
        }
    }
    func installationKey(_ server: ServerAddress) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "identity")
    }
    func activeKey(_ server: ServerAddress) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "active-account")
    }
    func vaultKey(server: ServerAddress, account: AccountID, installation: String, authorizationID: String? = nil) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: account, installation: installation,
            purpose: authorizationID.map { "account-and-grants:\($0)" } ?? "account-and-grants")
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
    func identity(server: ServerAddress) throws -> RemoteSigningIdentity {
        _ = try RemoteWire.origin(server)
        guard !invalidServers.contains(server),
              try secrets.read(RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "server-identity-mismatch")) == nil else {
            throw RemoteClientError.integrity
        }
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
    func loadVault(server: ServerAddress, account: AccountID, authorization: RemoteActiveAccount? = nil) throws -> RemoteAccountVault? {
        try readVaultRecord(server: server, account: account, authorization: authorization, enforcingInvalidation: true)
    }

    /// Cleanup only: Core has already persisted the logout barrier before
    /// hiding data. The old token is usable solely for its explicit logout.
    func loadVaultForLogout(server: ServerAddress, account: AccountID) throws -> RemoteAccountVault? {
        try readVaultRecord(server: server, account: account, authorization: nil, enforcingInvalidation: false)
    }

    private func readVaultRecord(server: ServerAddress, account: AccountID, authorization: RemoteActiveAccount?,
                                 enforcingInvalidation: Bool) throws -> RemoteAccountVault? {
        _ = try RemoteWire.origin(server)
        guard !invalidServers.contains(server),
              try secrets.read(RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "server-identity-mismatch")) == nil else { return nil }
        guard !invalidAccounts.contains(DataScope(server: server, account: account)),
              try secrets.read(tombstoneKey(server: server, account: account)) == nil else { return nil }
        let pointer: RemoteActiveAccount
        if let authorization { pointer = authorization }
        else {
            guard let pointerData = try secrets.read(activeKey(server)) else { return nil }
            guard pointerData.count <= 1024 else { throw RemoteClientError.bufferLimit }
            pointer = try JSONDecoder().decode(RemoteActiveAccount.self, from: pointerData)
        }
        guard pointer.account == account.id else { return nil }
        _ = try RemoteWire.id(pointer.installation)
        if let authorizationID = pointer.authorizationID {
            _ = try RemoteWire.id(authorizationID)
            let binding = RemoteLoginAuthorization(account: account, installation: pointer.installation, authorizationID: authorizationID, previous: nil)
            let marker = cancellationKey(server: server, authorization: binding)
            guard !invalidAuthorizations.contains(marker), try secrets.read(marker) == nil else { return nil }
        }
        guard let data = try secrets.read(vaultKey(server: server, account: account, installation: pointer.installation, authorizationID: pointer.authorizationID)) else {
            throw RemoteClientError.integrity
        }
        guard data.count <= 512 * 1024 else { throw RemoteClientError.bufferLimit }
        let vault = try JSONDecoder().decode(RemoteAccountVault.self, from: data)
        if enforcingInvalidation {
            guard try authorizationPostdatesInvalidation(vault, server: server, account: account) else { return nil }
        }
        guard vault.server == server.absoluteString, vault.account == account.id,
              vault.authorizationID == pointer.authorizationID,
              vault.identity.installation == pointer.installation, !vault.token.isEmpty, vault.token.count <= 256,
              !vault.login.isEmpty, vault.fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              vault.hosts.count <= 20 else { throw RemoteClientError.integrity }
        let publicKey = try vault.identity.publicKey
        _ = try RemoteWire.unbase64(vault.token, maximum: 256)
        guard RemoteWire.hash(try publicKey.wire.encoded()) == vault.keyFingerprint else { throw RemoteClientError.integrity }
        guard let identityData = try secrets.read(installationKey(server)) else { return nil }
        guard identityData.count <= 2048 else { throw RemoteClientError.bufferLimit }
        let bootstrap = try JSONDecoder().decode(RemoteSigningIdentity.self, from: identityData)
        let pinKey = RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "server-fingerprint")
        guard let pin = try secrets.read(pinKey), pin == Data(vault.fingerprint.utf8),
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
        return vault.expiresAt > clock.now() ? vault : nil
    }
    func requireVault(server: ServerAddress, account: AccountID) throws -> RemoteAccountVault {
        guard let vault = try loadVault(server: server, account: account) else { throw RemoteClientError.notAuthorized }
        return vault
    }
    func saveVault(_ vault: RemoteAccountVault, server: ServerAddress, account: AccountID, epoch expected: Int) throws {
        try checkEpoch(expected)
        guard try authorizationPostdatesInvalidation(vault, server: server, account: account) else { throw RemoteClientError.notAuthorized }
        if let authorizationID = vault.authorizationID {
            let binding = RemoteLoginAuthorization(account: account, installation: vault.identity.installation, authorizationID: authorizationID, previous: nil)
            let marker = cancellationKey(server: server, authorization: binding)
            guard !invalidAuthorizations.contains(marker), try secrets.read(marker) == nil else { throw RemoteClientError.cancelled }
        }
        try secrets.write(JSONEncoder().encode(vault), for: vaultKey(server: server, account: account,
            installation: vault.identity.installation, authorizationID: vault.authorizationID))
    }
}

struct RemoteActiveAccount: Codable, Equatable {
    let account: String
    let installation: String
    var authorizationID: String? = nil
}
struct RemoteAccountVault: Codable {
    var server: String
    var account: String
    var login: String
    var identity: RemoteSigningIdentity
    var token: String
    var expiresAt: Date
    var fingerprint: String
    var keyFingerprint: String
    var lastVerifiedAt: Date
    var hosts: [String: RemoteHostCredential]
    var translationAttempts: [String: String]
    var commandAttempts: [String: String]
    var authorizationID: String? = nil
    var authorizationCreatedAt: Date? = nil
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
struct RemotePendingLogin {
    let attempt: RemoteLoginAttempt
    let server: ServerAddress
    let id: LoginID
    let identity: RemoteSigningIdentity
    let signature: String
    let fingerprint: String
    let expiresAt: Date
    var interval: Int
    var nextPoll: Date
}
