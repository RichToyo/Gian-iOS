import Foundation
import Security

extension LiveGianClientService {
    /// Remote 1.5 needs no account: the Server proves its identity (pinned on
    /// first use), then this app's installation key is admitted as a native
    /// controller once with a single-use enrollment token. Hosts are paired as
    /// that controller and confirmed on the Host.
    public func connectServer(server: ServerAddress, enrollmentToken: String?) async -> ServerConnectResponse {
        disconnectNow()
        let captured = epoch
        do {
            let identity = try identity(server: server)
            let fingerprint = try await verifyServerIdentity(server: server, epoch: captured)
            guard let installation = InstallationID(rawValue: try RemoteWire.id(identity.installation)) else {
                throw RemoteClientError.integrity
            }
            let account = AccountID(installation: installation)
            if try loadVault(server: server, account: account)?.admitted != true {
                guard let enrollmentToken, !enrollmentToken.isEmpty else { return .failed(ControllerEnrollment.tokenRequired) }
                try await admitController(server: server, identity: identity, fingerprint: fingerprint,
                                          enrollmentToken: enrollmentToken, epoch: captured)
            }
            try establishController(server: server, account: account, identity: identity, fingerprint: fingerprint, epoch: captured)
            lastFailure = nil
            return .connected(AccountIdentity(account: account, installationID: installation))
        } catch RemoteClientError.serverIdentityChanged {
            return .identityChanged
        } catch {
            let safe = note(error)
            return .failed(ControllerEnrollment.message(for: safe) ?? safe.safeDescription)
        }
    }

    /// `POST /api/v1/controller-enrollments/claim`: the enrollment token (from
    /// the Server's enrollment page or admin CLI) admits this installation key
    /// as a native controller. An installation admitted earlier proves itself
    /// with a controller sign-in instead.
    private func admitController(server: ServerAddress, identity: RemoteSigningIdentity, fingerprint: String,
                                 enrollmentToken: String, epoch captured: Int) async throws {
        guard enrollmentToken.utf8.count <= 4096 else { throw RemoteClientError.invalidPayload }
        do {
            let result = try await http(server: server, path: "/api/v1/controller-enrollments/claim", body: .object([
                "protocol": .string(RemoteBaseline.authProtocol), "enrollment_token": .string(enrollmentToken),
                "browser_installation_id": .string(identity.installation),
                "device_public_key": try identity.publicKey.wire, "platform": .string("iOS"),
            ]))
            try checkEpoch(captured); try validateProtocol(result)
            try result.closed(["protocol", "browser_installation_id", "server_identity"])
            let claimed = result["server_identity"]
            try claimed.closed(["algorithm", "public_key", "fingerprint"])
            guard try result.identifier("browser_installation_id") == identity.installation,
                  try claimed.string("fingerprint") == fingerprint,
                  RemoteWire.hash(try RemotePublicKey(wire: claimed["public_key"]).wire.encoded()) == fingerprint else {
                throw RemoteClientError.integrity
            }
        } catch RemoteClientError.server(code: "CONTROLLER_ALREADY_ADMITTED", retryAfter: _) {
            // Admitted before (e.g. the vault was lost): signing in proves it.
            controllerLeases.removeValue(forKey: server)
            _ = try await controllerAccessToken(server: server, identity: identity, epoch: captured)
        }
    }

    /// A controller access token for pairing claims: `controller-challenge`
    /// then `controller-login`, signed by the installation key. Reused until
    /// shortly before it expires.
    func controllerAccessToken(server: ServerAddress, identity: RemoteSigningIdentity, epoch captured: Int) async throws -> String {
        if let lease = controllerLeases[server], lease.installation == identity.installation,
           lease.expiresAt > clock.now().addingTimeInterval(30) { return lease.token }
        let challenge = try await http(server: server, path: "/api/v1/sessions/controller-challenge", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": .string(identity.installation),
        ]))
        try checkEpoch(captured); try validateProtocol(challenge)
        try challenge.closed(["protocol", "challenge_id", "challenge", "expires_at"])
        let challengeID = try challenge.identifier("challenge_id")
        let login = try await http(server: server, path: "/api/v1/sessions/controller-login", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": .string(identity.installation),
            "challenge_id": .string(challengeID), "signature": .string(try identity.sign(Data(challengeID.utf8))),
        ]))
        try checkEpoch(captured); try validateProtocol(login)
        try login.closed(["protocol", "controller_access_token", "expires_at", "browser_installation_id"])
        guard try login.identifier("browser_installation_id") == identity.installation else { throw RemoteClientError.integrity }
        let token = try login.string("controller_access_token")
        let expires = Date(timeIntervalSince1970: Double(try login.integer("expires_at")) / 1000)
        guard !token.isEmpty, expires > clock.now(), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RemoteClientError.expired }
        controllerLeases[server] = RemoteControllerLease(installation: identity.installation, token: token, expiresAt: expires)
        return token
    }

    /// Forgets a Server's pinned identity and this app's controller identity
    /// there, so the next connection trusts the Server afresh (for a Server
    /// that was reinstalled). Its paired Hosts must be paired again.
    public func forgetServer(_ server: ServerAddress) async throws {
        disconnectNow()
        controllerLeases.removeValue(forKey: server)
        if let pointerData = try secrets.read(activeKey(server)),
           let pointer = try? JSONDecoder().decode(RemoteActiveController.self, from: pointerData),
           let account = AccountID(provider: .controller, id: pointer.account) {
            try secrets.remove(vaultKey(server: server, account: account, installation: pointer.installation))
            try secrets.remove(RemoteSecretKey(server: server, account: account, installation: pointer.installation, purpose: "pending-pairing-key"))
        }
        try secrets.remove(activeKey(server))
        try secrets.remove(installationKey(server))
        try secrets.remove(pinKey(server))
    }

    /// `POST /api/v1/server-identity`: the Server signs a fresh nonce with its
    /// identity key. The first fingerprint seen is pinned; a different one is
    /// refused. Like remote-web, this rides on TLS rather than replacing it.
    func verifyServerIdentity(server: ServerAddress, epoch captured: Int) async throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RemoteClientError.integrity }
        let nonce = RemoteWire.base64(Data(bytes))
        let response = try await http(server: server, path: "/api/v1/server-identity", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "nonce": .string(nonce),
        ]))
        try checkEpoch(captured); try validateProtocol(response)
        try response.closed(["protocol", "server_identity", "expires_at", "signature"])
        let identity = response["server_identity"]
        try identity.closed(["algorithm", "public_key", "fingerprint"])
        guard try identity.string("algorithm") == "P-256" else { throw RemoteClientError.integrity }
        let key = try RemotePublicKey(wire: identity["public_key"])
        let fingerprint = RemoteWire.hash(try key.wire.encoded())
        guard try identity.string("fingerprint") == fingerprint else { throw RemoteClientError.integrity }
        let expiresAt = try response.integer("expires_at")
        // The nonce binds freshness; the expiry check only tolerates clock skew.
        let skew: TimeInterval = 60
        let expires = Date(timeIntervalSince1970: Double(expiresAt) / 1000)
        guard expires > clock.now().addingTimeInterval(-skew),
              expires <= clock.now().addingTimeInterval(RemoteBaseline.serverIdentityProofLifetime + skew) else { throw RemoteClientError.expired }
        try key.verify(signature: try response.string("signature", maximum: 256), payload: .object([
            "type": .string(RemoteBaseline.serverIdentityProofType), "nonce": .string(nonce),
            "fingerprint": .string(fingerprint), "expires_at": .int(expiresAt),
        ]))
        if let pin = try secrets.read(pinKey(server)) {
            guard pin == Data(fingerprint.utf8) else { throw RemoteClientError.serverIdentityChanged }
        } else {
            try secrets.write(Data(fingerprint.utf8), for: pinKey(server))
        }
        return fingerprint
    }

    /// Creates this app's controller vault for a Server on first use (or after
    /// sign-out), otherwise records the fresh Server verification.
    private func establishController(server: ServerAddress, account: AccountID, identity: RemoteSigningIdentity,
                                     fingerprint: String, epoch captured: Int) throws {
        let now = clock.now()
        if var vault = try loadVault(server: server, account: account) {
            guard vault.fingerprint == fingerprint else { throw RemoteClientError.integrity }
            vault.lastVerifiedAt = now
            vault.admitted = true
            try saveVault(vault, server: server, account: account, epoch: captured)
            return
        }
        let vault = RemoteControllerVault(server: server.absoluteString, account: account.id, identity: identity,
            fingerprint: fingerprint, keyFingerprint: RemoteWire.hash(try identity.publicKey.wire.encoded()),
            createdAt: now, lastVerifiedAt: now, hosts: [:], translationAttempts: [:], commandAttempts: [:], admitted: true)
        try saveVault(vault, server: server, account: account, epoch: captured)
        try secrets.write(JSONEncoder().encode(RemoteActiveController(account: account.id, installation: identity.installation)),
                          for: activeKey(server))
        try secrets.remove(tombstoneKey(server: server, account: account))
        invalidAccounts.remove(DataScope(server: server, account: account))
    }

    public func claimHost(server: ServerAddress, account: AccountID, invitation: HostPairingInvitation) async -> HostPairingResponse {
        let captured = epoch
        do {
            let invite: (String, String)
            switch invitation {
            case .grantNonce(let nonce):
                guard !nonce.isEmpty, nonce.utf8.count <= 16_384 else { throw RemoteClientError.invalidPayload }
                invite = ("grant_nonce", nonce)
            case .code(let code):
                guard let canonical = PairingCode.canonical(code) else { throw RemoteClientError.invalidPayload }
                invite = ("code", canonical)
            }
            // The Server proves its pinned identity before a claim.
            _ = try await verifyServerIdentity(server: server, epoch: captured)
            var vault = try requireVault(server: server, account: account)
            guard vault.admitted == true else { throw RemoteClientError.notAuthorized }
            let controllerToken = try await controllerAccessToken(server: server, identity: vault.identity, epoch: captured)
            let identity = RemoteSigningIdentity(installation: vault.identity.installation)
            let pendingKey = RemoteSecretKey(server: server, account: account, installation: identity.installation, purpose: "pending-pairing-key")
            try secrets.write(JSONEncoder().encode(identity), for: pendingKey)
            let result = try await http(server: server, path: "/api/v1/pairings/claim", body: .object([
                "protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": .string(identity.installation),
                "device_public_key": try identity.publicKey.wire, "platform": .string("iOS"),
                "user_agent": .string("Gian iOS/0.1.0"), "controller_admission": .int(1), invite.0: .string(invite.1),
            ]), bearer: controllerToken)
            try checkEpoch(captured); try validateProtocol(result)
            try result.closed(["protocol", "pairing_id", "host_id", "status", "crypto_connection_id"])
            guard try result.string("status") == "pending_confirmation" else { throw RemoteClientError.invalidPayload }
            let host: HostID = try result.scoped("host_id")
            let pairing: PairingID = try result.scoped("pairing_id")
            vault = try requireVault(server: server, account: account)
            guard vault.hosts[host.rawValue] != nil || vault.hosts.count < 20 else { throw RemoteClientError.capabilityDenied }
            let previous = vault.hosts[host.rawValue]
            vault.hosts[host.rawValue] = RemoteHostCredential(id: host.rawValue, identity: identity, pairingID: pairing.rawValue,
                deviceID: nil, cryptoConnection: try result.identifier("crypto_connection_id"), hostKey: previous?.hostKey,
                name: previous?.name ?? "Gian Host", version: previous?.version ?? "", lastVerifiedAt: nil, claimedAt: clock.now())
            try saveVault(vault, server: server, account: account, epoch: captured)
            try secrets.remove(tombstoneKey(server: server, account: account, host: host))
            invalidHosts.remove(ClientScope(server: server, account: account, host: host))
            try secrets.remove(pendingKey)
            return .pendingConfirmation(pairing, host)
        } catch {
            let safe = note(error)
            switch safe {
            case .server(code: "CONTROLLER_NOT_ADMITTED", retryAfter: _), .deviceRevoked:
                controllerLeases.removeValue(forKey: server)
                return .failed("This device isn't admitted on the server anymore. Sign out and connect with a new enrollment token.")
            case .notAuthorized:
                return .failed("That code isn't valid anymore. Make a new one on the Host.")
            default:
                return .failed(safe.safeDescription)
            }
        }
    }

    public func refreshHostPairing(server: ServerAddress, account: AccountID, pairingID: PairingID) async -> HostPairingResponse {
        let captured = epoch
        do {
            let vault = try requireVault(server: server, account: account)
            guard let host = vault.hosts.values.first(where: { $0.pairingID == pairingID.rawValue }),
                  let id = HostID(rawValue: host.id) else { throw RemoteClientError.notAuthorized }
            let scope = ClientScope(server: server, account: account, host: id)
            let auth = try await authenticateDevice(scope: scope, epoch: captured)
            guard let device = DeviceID(rawValue: auth.deviceID) else { throw RemoteClientError.invalidPayload }
            return .confirmed(HostSummary(id: id, name: host.name, online: false, version: host.version), deviceID: device)
        } catch RemoteClientError.server(code: "DEVICE_NOT_PAIRED", retryAfter: _) {
            guard let vault = try? requireVault(server: server, account: account),
                  let host = vault.hosts.values.first(where: { $0.pairingID == pairingID.rawValue }), let id = HostID(rawValue: host.id) else { return .expired }
            // This is a local confirmation deadline, not a fabricated grant expiry.
            // No native pairing-status endpoint distinguishes rejection from expiration.
            if clock.now().timeIntervalSince(host.claimedAt) >= 300 {
                lastFailure = .timeout
                return .failed("The Host has not confirmed this device.")
            }
            return .pendingConfirmation(pairingID, id)
        } catch { return .failed(note(error).safeDescription) }
    }

    func authenticateDevice(scope: ClientScope, epoch captured: Int) async throws -> RemoteDeviceLease {
        do { return try await performDeviceAuthentication(scope: scope, epoch: captured) }
        catch {
            if captured == epoch, let failure = error as? RemoteClientError, failure == .deviceRevoked || failure == .integrity {
                try invalidateHost(scope)
            }
            throw error
        }
    }

    private func performDeviceAuthentication(scope: ClientScope, epoch captured: Int) async throws -> RemoteDeviceLease {
        guard try !hostIsInvalid(scope) else { throw RemoteClientError.notAuthorized }
        var vault = try requireVault(server: scope.server, account: scope.account)
        guard var host = vault.hosts[scope.host.rawValue] else { throw RemoteClientError.notAuthorized }
        let challenge = try await http(server: scope.server, path: "/api/v1/sessions/device-challenge", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": .string(host.identity.installation), "host_id": .string(host.id),
        ]))
        try checkEpoch(captured); try validateProtocol(challenge)
        try challenge.closed(["protocol", "challenge_id", "challenge", "expires_at"])
        let challengeID = try challenge.identifier("challenge_id")
        guard !(try challenge.string("challenge")).isEmpty else { throw RemoteClientError.invalidPayload }
        guard Double(try challenge.integer("expires_at")) / 1000 > clock.now().timeIntervalSince1970 else { throw RemoteClientError.expired }
        let response = try await http(server: scope.server, path: "/api/v1/sessions/device-login", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": .string(host.identity.installation),
            "host_id": .string(host.id), "challenge_id": .string(challengeID), "signature": .string(try host.identity.sign(Data(challengeID.utf8))),
        ]))
        try checkEpoch(captured); try validateProtocol(response)
        try response.closed(["protocol", "access_token", "expires_at", "device_id", "host_id", "crypto_connection_id", "host_public_key"])
        let device = try response.identifier("device_id")
        let key = try RemotePublicKey(wire: response["host_public_key"])
        if let previous = host.hostKey, previous != key { try invalidateHost(scope); throw RemoteClientError.integrity }
        guard try response.identifier("host_id") == host.id, device == host.pairingID,
              host.deviceID == nil || host.deviceID == device, host.hostKey == nil || host.hostKey == key else { throw RemoteClientError.integrity }
        host.deviceID = device; host.hostKey = key; host.cryptoConnection = try response.identifier("crypto_connection_id")
        let expires = Date(timeIntervalSince1970: Double(try response.integer("expires_at")) / 1000)
        let token = try response.string("access_token")
        guard !token.isEmpty, expires > clock.now(), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RemoteClientError.expired }
        // Availability of a grant was validated, but online restoration still requires the signed handshake.
        vault = try requireVault(server: scope.server, account: scope.account)
        guard vault.hosts[host.id]?.identity.privateKey == host.identity.privateKey, try !hostIsInvalid(scope) else { throw RemoteClientError.cancelled }
        vault.hosts[host.id] = host
        try saveVault(vault, server: scope.server, account: scope.account, epoch: captured)
        let lease = RemoteDeviceLease(host: host, token: token, expiresAt: expires, deviceID: device)
        deviceLeases[scope] = lease
        return lease
    }
}

struct RemoteControllerLease {
    let installation: String
    let token: String
    let expiresAt: Date
}

/// Wording for controller enrollment outcomes (the Server's codes are not
/// shown as is).
enum ControllerEnrollment {
    static let tokenRequired = "Enter the enrollment token from the server's enrollment page."

    static func message(for error: RemoteClientError) -> String? {
        switch error {
        case .server(code: "ENROLLMENT_CONSUMED", retryAfter: _):
            "That enrollment token was already used. Generate a new one."
        case .server(code: "ENROLLMENT_EXPIRED", retryAfter: _):
            "That enrollment token expired. Tokens last 5 minutes; generate a new one."
        case .notAuthorized:
            "That enrollment token isn't valid for this server."
        case .deviceRevoked:
            "This device was removed from the server. Sign out and connect with a new enrollment token."
        default: nil
        }
    }
}

struct RemoteDeviceLease {
    let host: RemoteHostCredential
    let token: String
    let expiresAt: Date
    let deviceID: String
}
