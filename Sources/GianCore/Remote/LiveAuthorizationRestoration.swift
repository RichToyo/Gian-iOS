import Foundation

extension LiveGianClientService {
    public func loadCachedAuthorization(server: ServerAddress, account: AccountID) throws -> AuthorizedSessionRestoration? {
        try restoration(server: server, account: account, onlineHost: nil)
    }

    public func revalidateAuthorization(scope: ClientScope) async throws -> AuthorizedSessionRestoration {
        // Even an existing open socket is not an evergreen grant verification.
        disconnectNow()
        try await connect(scope: scope)
        guard let evidence = try restoration(server: scope.server, account: scope.account, onlineHost: scope.host),
              evidence.hosts.contains(where: { $0.host.id == scope.host && $0.validation == .online }) else {
            throw RemoteClientError.notAuthorized
        }
        return evidence
    }

    private func restoration(server: ServerAddress, account: AccountID, onlineHost: HostID?) throws -> AuthorizedSessionRestoration? {
        guard let vault = try loadVault(server: server, account: account) else { return nil }
        guard let pin = try secrets.read(pinKey(server)), let identityData = try secrets.read(installationKey(server)) else { return nil }
        let identity = try JSONDecoder().decode(RemoteSigningIdentity.self, from: identityData)
        guard pin == Data(vault.fingerprint.utf8), identity.installation == vault.identity.installation,
              try identity.publicKey == vault.identity.publicKey,
              let installation = InstallationID(rawValue: identity.installation),
              vault.lastVerifiedAt <= clock.now() else { throw RemoteClientError.integrity }
        // Sign a local challenge to prove the stored private key is actually usable.
        let proof = WireValue.object(["type": .string("gian.ios.local_key_check/1"), "installation_id": .string(identity.installation)])
        try identity.publicKey.verify(signature: identity.sign(proof), payload: proof)
        var hosts: [AuthorizedHostRestoration] = []
        for host in vault.hosts.values.sorted(by: { $0.id < $1.id }) {
            guard let device = host.deviceID, let key = host.hostKey, let verified = host.lastVerifiedAt,
                  host.cryptoConnection != nil else { continue }
            guard let hostID = HostID(rawValue: try RemoteWire.id(host.id)),
                  let deviceID = DeviceID(rawValue: try RemoteWire.id(device)), device == host.pairingID,
                  host.identity.installation == identity.installation, verified <= clock.now() else { throw RemoteClientError.integrity }
            if try hostIsInvalid(ClientScope(server: server, account: account, host: hostID)) { continue }
            let hostProof = WireValue.object(["type": .string("gian.ios.local_grant_key_check/1"), "host_id": .string(host.id), "device_id": .string(device)])
            try host.identity.publicKey.verify(signature: host.identity.sign(hostProof), payload: hostProof)
            let online = onlineHost == hostID && relayScope == ClientScope(server: server, account: account, host: hostID) && relay?.isOpen == true
            hosts.append(AuthorizedHostRestoration(host: HostSummary(id: hostID, name: host.name, online: false, version: host.version),
                deviceID: deviceID, hostKeyFingerprint: RemoteWire.hash(try key.wire.encoded()),
                deviceKeyFingerprint: RemoteWire.hash(try host.identity.publicKey.wire.encoded()), lastVerifiedAt: verified,
                validation: online ? .online : .cached))
        }
        return AuthorizedSessionRestoration(server: server, serverIdentityFingerprint: vault.fingerprint,
            identity: AccountIdentity(account: account, installationID: installation),
            accountKeyFingerprint: vault.keyFingerprint, accountLastVerifiedAt: vault.lastVerifiedAt, hosts: hosts)
    }
}
