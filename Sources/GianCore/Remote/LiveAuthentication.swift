import Foundation

extension LiveGianClientService {
    public func startGitHubDeviceLogin(server: ServerAddress) async -> GitHubLoginStartResponse {
        disconnectNow()
        login = nil
        let captured = epoch
        do {
            guard loginAttempts.count < 64 else { throw RemoteClientError.bufferLimit }
            let identity = try identity(server: server)
            let peer = WireValue.object(["role": .string("controller"), "installation_id": .string(identity.installation),
                                         "public_key": try identity.publicKey.wire])
            let response = try await http(server: server, path: "/api/v1/account/start",
                body: .object(["protocol": .string(RemoteBaseline.accountProtocol), "peer": peer]))
            try checkEpoch(captured)
            try validateProtocol(response, account: true)
            try response.closed(["protocol", "login_id", "challenge", "user_code", "verification_uri", "expires_at", "interval_seconds"])
            let challenge = response["challenge"]
            try challenge.closed(["type", "challenge_id", "nonce", "server_identity_fingerprint", "peer", "expires_at"])
            guard try challenge.string("type") == "gian.remote.account_challenge/1", challenge["peer"] == peer,
                  try response.string("verification_uri") == RemoteBaseline.githubDeviceVerificationURI else { throw RemoteClientError.integrity }
            _ = try challenge.identifier("challenge_id")
            _ = try RemoteWire.unbase64(challenge.string("nonce", maximum: 256))
            let expires = Date(timeIntervalSince1970: Double(try response.integer("expires_at")) / 1000)
            let challengeExpires = Date(timeIntervalSince1970: Double(try challenge.integer("expires_at")) / 1000)
            guard expires > clock.now(), expires <= challengeExpires else { throw RemoteClientError.expired }
            let fingerprint = try challenge.string("server_identity_fingerprint")
            guard fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw RemoteClientError.invalidPayload }
            let pinKey = RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "server-fingerprint")
            if let pin = try secrets.read(pinKey) {
                guard pin == Data(fingerprint.utf8) else {
                    invalidServers.insert(server)
                    try secrets.write(Data([1]), for: RemoteSecretKey(server: server, account: nil, installation: "server-bootstrap", purpose: "server-identity-mismatch"))
                    throw RemoteClientError.integrity
                }
            } else { try secrets.write(Data(fingerprint.utf8), for: pinKey) }
            let id: LoginID = try response.scoped("login_id")
            let interval = try response.integer("interval_seconds", range: 5...60)
            let userCode = try response.string("user_code", maximum: 64)
            guard !userCode.isEmpty else { throw RemoteClientError.invalidPayload }
            let attemptKey = RemoteLoginAttemptKey(server: server, loginID: id)
            guard loginAttempts[attemptKey] == nil else { throw RemoteClientError.integrity }
            let attempt = RemoteLoginAttempt(server: server, loginID: id, installation: identity.installation, authorizationID: newID())
            loginAttempts[attemptKey] = attempt
            login = RemotePendingLogin(attempt: attempt, server: server, id: id, identity: identity, signature: try identity.sign(challenge),
                fingerprint: fingerprint, expiresAt: expires, interval: interval, nextPoll: clock.now().addingTimeInterval(Double(interval)))
            lastFailure = nil
            return .started(GitHubDeviceLoginChallenge(loginID: id, userCode: userCode,
                verificationURI: URL(string: RemoteBaseline.githubDeviceVerificationURI)!, expiresAt: expires, intervalSeconds: interval))
        } catch { return .failed(note(error).safeDescription) }
    }

    public func pollGitHubDeviceLogin(server: ServerAddress, loginID: LoginID) async -> GitHubLoginPollResponse {
        guard var pending = login, pending.server == server, pending.id == loginID else { return .expired }
        guard pending.expiresAt > clock.now() else { login = nil; return .expired }
        guard pending.nextPoll <= clock.now() else { return .pending(intervalSeconds: pending.interval) }
        let captured = epoch
        pending.nextPoll = clock.now().addingTimeInterval(Double(pending.interval)); login = pending
        do {
            let response = try await http(server: server, path: "/api/v1/account/poll", body: .object([
                "protocol": .string(RemoteBaseline.accountProtocol), "login_id": .string(loginID.rawValue), "signature": .string(pending.signature),
            ]))
            try checkLoginAttempt(pending.attempt, epoch: captured)
            guard login?.id == loginID, pending.expiresAt > clock.now() else { return .expired }
            try validateProtocol(response, account: true)
            switch try response.string("status") {
            case "pending":
                try response.closed(["protocol", "status", "interval_seconds"])
                pending.interval = try response.integer("interval_seconds", range: 5...60)
                pending.nextPoll = clock.now().addingTimeInterval(Double(pending.interval)); login = pending
                lastFailure = nil; diagnostic(.cleared, login: pending)
                return .pending(intervalSeconds: pending.interval)
            case "denied": try response.closed(["protocol", "status"]); login = nil; return .denied
            case "expired": try response.closed(["protocol", "status"]); login = nil; return .expired
            case "authorized":
                try response.closed(["protocol", "status", "account", "account_token", "installation_id", "role", "expires_at"])
                let identity = try accountIdentity(response, expectedInstallation: pending.identity.installation)
                let token = try response.string("account_token", maximum: 256)
                guard !token.isEmpty else { throw RemoteClientError.notAuthorized }
                _ = try RemoteWire.unbase64(token, maximum: 256)
                let expires = Date(timeIntervalSince1970: Double(try response.integer("expires_at")) / 1000)
                guard expires > clock.now() else { throw RemoteClientError.expired }
                let previous = try loadVault(server: server, account: identity.account)
                // One instant for both: the invalidation barrier requires
                // authorizationCreatedAt <= lastVerifiedAt, and two reads of a
                // real clock put creation a few microseconds later.
                let verifiedAt = clock.now()
                let vault = RemoteAccountVault(server: server.absoluteString, account: identity.account.id, login: identity.login,
                    identity: pending.identity, token: token, expiresAt: expires, fingerprint: pending.fingerprint,
                    keyFingerprint: RemoteWire.hash(try pending.identity.publicKey.wire.encoded()), lastVerifiedAt: verifiedAt,
                    hosts: previous?.identity.installation == identity.installationID.rawValue ? previous?.hosts ?? [:] : [:],
                    translationAttempts: previous?.translationAttempts ?? [:], commandAttempts: previous?.commandAttempts ?? [:],
                    authorizationID: pending.attempt.authorizationID, authorizationCreatedAt: verifiedAt)
                try persistLogin(vault, account: identity.account, attempt: pending.attempt, epoch: captured)
                login = nil; lastFailure = nil; diagnostic(.cleared, login: pending)
                return .authorized(identity)
            default: throw RemoteClientError.invalidPayload
            }
        } catch {
            let safe = note(error)
            if case .cancelled = pending.attempt.phase { return .expired }
            guard captured == epoch, login?.id == loginID else { return .expired }
            if safe == .notAuthorized { login = nil; return .denied }
            if safe == .expired { login = nil; return .expired }
            // The shared enum has no failed/transient case. Preserve pending and expose lastFailure.
            // In particular cancellation, HTTP 503 and TLS failures are never authorization success.
            let retryAfter: Int
            if case .server(_, let retry) = safe { retryAfter = retry ?? 5 } else { retryAfter = 5 }
            pending.interval = min(60, max(retryAfter, pending.interval * 2))
            pending.nextPoll = clock.now().addingTimeInterval(Double(pending.interval)); login = pending
            diagnostic(.retryingLogin(error: safe, retryAt: min(pending.nextPoll, pending.expiresAt), expiresAt: pending.expiresAt), login: pending)
            return .pending(intervalSeconds: pending.interval)
        }
    }

    func accountIdentity(_ response: WireValue, expectedInstallation: String) throws -> AccountIdentity {
        guard try response.string("role") == "controller", try response.identifier("installation_id") == expectedInstallation,
              try response["account"].string("provider") == "github",
              let account = AccountID(provider: .github, id: try response["account"].string("id")),
              let installation = InstallationID(rawValue: expectedInstallation) else { throw RemoteClientError.integrity }
        try response["account"].closed(["provider", "id", "login"])
        return AccountIdentity(account: account, login: try response["account"].string("login", maximum: 256), installationID: installation)
    }

    func verifyAccount(server: ServerAddress, account: AccountID, epoch captured: Int) async throws -> RemoteAccountVault {
        do { return try await performAccountVerification(server: server, account: account, epoch: captured) }
        catch {
            if captured == epoch, let failure = error as? RemoteClientError, failure == .notAuthorized || failure == .integrity {
                try invalidateAccount(server: server, account: account)
            }
            throw error
        }
    }

    private func performAccountVerification(server: ServerAddress, account: AccountID, epoch captured: Int) async throws -> RemoteAccountVault {
        var vault = try requireVault(server: server, account: account)
        let result = try await http(server: server, path: "/api/v1/account/me", method: "GET", bearer: vault.token)
        try checkEpoch(captured)
        try validateProtocol(result, account: true)
        try result.closed(["protocol", "installation_id", "role", "account", "expires_at"])
        let identity = try accountIdentity(result, expectedInstallation: vault.identity.installation)
        guard identity.account == account else { throw RemoteClientError.integrity }
        let expires = Date(timeIntervalSince1970: Double(try result.integer("expires_at")) / 1000)
        guard expires > clock.now() else { throw RemoteClientError.expired }
        vault = try requireVault(server: server, account: account)
        if vault.authorizationCreatedAt == nil { vault.authorizationCreatedAt = vault.lastVerifiedAt }
        vault.lastVerifiedAt = clock.now(); vault.expiresAt = min(vault.expiresAt, expires); vault.login = identity.login
        try saveVault(vault, server: server, account: account, epoch: captured)
        return vault
    }

    public func claimHostQR(server: ServerAddress, account: AccountID, qr: HostPairingQR) async -> HostPairingResponse {
        let captured = epoch
        do {
            guard !qr.grantNonce.isEmpty, qr.grantNonce.utf8.count <= 16_384 else { throw RemoteClientError.invalidPayload }
            var vault = try await verifyAccount(server: server, account: account, epoch: captured)
            let identity = RemoteSigningIdentity(installation: vault.identity.installation)
            let pendingKey = RemoteSecretKey(server: server, account: account, installation: identity.installation, purpose: "pending-pairing-key")
            try secrets.write(JSONEncoder().encode(identity), for: pendingKey)
            let result = try await http(server: server, path: "/api/v1/pairings/claim", body: .object([
                "protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": .string(identity.installation),
                "device_public_key": try identity.publicKey.wire, "platform": .string("iOS"),
                "user_agent": .string("Gian iOS/0.1.0"), "grant_nonce": .string(qr.grantNonce),
            ]), accountToken: vault.token)
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
        } catch { return .failed(note(error).safeDescription) }
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
        var vault = try await verifyAccount(server: scope.server, account: scope.account, epoch: captured)
        guard var host = vault.hosts[scope.host.rawValue] else { throw RemoteClientError.notAuthorized }
        let challenge = try await http(server: scope.server, path: "/api/v1/sessions/device-challenge", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": .string(host.identity.installation), "host_id": .string(host.id),
        ]), accountToken: vault.token)
        try checkEpoch(captured); try validateProtocol(challenge)
        try challenge.closed(["protocol", "challenge_id", "challenge", "expires_at"])
        let challengeID = try challenge.identifier("challenge_id")
        guard !(try challenge.string("challenge")).isEmpty else { throw RemoteClientError.invalidPayload }
        guard Double(try challenge.integer("expires_at")) / 1000 > clock.now().timeIntervalSince1970 else { throw RemoteClientError.expired }
        let response = try await http(server: scope.server, path: "/api/v1/sessions/device-login", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": .string(host.identity.installation),
            "host_id": .string(host.id), "challenge_id": .string(challengeID), "signature": .string(try host.identity.sign(Data(challengeID.utf8))),
        ]), accountToken: vault.token)
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

struct RemoteDeviceLease {
    let host: RemoteHostCredential
    let token: String
    let expiresAt: Date
    let deviceID: String
}
