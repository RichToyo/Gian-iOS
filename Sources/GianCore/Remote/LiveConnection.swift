import Foundation

extension LiveGianClientService {
    public func connect(scope: ClientScope) async throws {
        if relayScope == scope, relay?.isOpen == true, !overflowed { _ = try requireConnection(scope); return }
        if relayScope == scope, let connecting { try await connecting.value; return }
        disconnectNow()
        intentionalDisconnect = false; overflowed = false; relayScope = scope
        let captured = epoch
        let task = Task { @MainActor [weak self] in
            guard let self else { throw RemoteClientError.cancelled }
            try await self.openConnection(scope: scope, epoch: captured)
        }
        connecting = task
        defer { if captured == epoch { connecting = nil } }
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { if captured == epoch { disconnectNow(); diagnostic(.connectionClosed(note(error)), scope: scope) }; throw error }
    }

    func openConnection(scope: ClientScope, epoch captured: Int) async throws {
        // Like remote-web: the Server proves its pinned identity before each connection.
        _ = try await verifyServerIdentity(server: scope.server, epoch: captured)
        let lease = try await authenticateDevice(scope: scope, epoch: captured)
        let ticket = try await http(server: scope.server, path: "/api/v1/ws-tickets", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "host_id": .string(scope.host.rawValue),
        ]), bearer: lease.token)
        try checkEpoch(captured); try validateProtocol(ticket)
        try ticket.closed(["protocol", "ticket", "expires_at"])
        guard Double(try ticket.integer("expires_at")) / 1000 > clock.now().timeIntervalSince1970,
              let hostKey = lease.host.hostKey, let connection = lease.host.cryptoConnection else { throw RemoteClientError.expired }
        var url = URLComponents(url: try RemoteWire.origin(scope.server), resolvingAgainstBaseURL: false)!
        url.scheme = "wss"; url.path = "/ws"
        var request = URLRequest(url: url.url!)
        request.setValue(scope.server.absoluteString, forHTTPHeaderField: "Origin")
        let socket = try await transport.openWebSocket(request)
        do { try checkEpoch(captured) } catch { socket.close(); throw error }
        let remote = RemoteRelay(socket: socket, clock: clock, ids: ids)
        relay = remote
        remote.onMessage = { [weak self, weak remote] message in
            guard let self, self.epoch == captured, self.relay === remote, self.relayScope == scope else { return }
            try self.receive(message, scope: scope)
        }
        remote.onClose = { [weak self, weak remote] error in
            guard let self, self.epoch == captured, self.relay === remote else { return }
            self.connectionClosed(error, scope: scope, epoch: captured)
        }
        try await remote.connect(ticket: ticket.string("ticket"), host: scope.host.rawValue, device: lease.deviceID,
            connection: connection, hostKey: hostKey, identity: lease.host.identity)
        try checkEpoch(captured)
        var vault = try requireVault(server: scope.server, account: scope.account)
        guard var host = vault.hosts[scope.host.rawValue] else { throw RemoteClientError.notAuthorized }
        host.lastVerifiedAt = clock.now(); vault.hosts[host.id] = host
        try saveVault(vault, server: scope.server, account: scope.account, epoch: captured)
        lastFailure = nil
        diagnostic(.cleared, scope: scope)
        // A fresh crypto session never establishes directory/capability readiness on its own.
        emit(.snapshotRequired(.cryptoResumed), scope: scope)
    }

    public func disconnect() async { disconnectNow() }

    func disconnectNow() {
        intentionalDisconnect = true
        epoch += 1
        reconnectAttempt = 0
        reconnect?.cancel(); reconnect = nil
        connecting?.cancel(); connecting = nil
        relay?.onClose = nil; relay?.onMessage = nil
        relay?.close(); relay = nil; relayScope = nil
        for waiter in commandWaiters.values { waiter.mailbox.fail(.disconnected) }
        for mailbox in mailboxes.values { mailbox.fail(.disconnected) }
        for transfer in transfers.values { transfer.mailbox.fail(.disconnected) }
        commandWaiters.removeAll(); mailboxes.removeAll(); transfers.removeAll()
        snapshotTimeout?.cancel(); snapshotTimeout = nil
        snapshotParts = nil; snapshot = nil; capabilities = nil; stagedSnapshot = nil; catalog = nil; cursor = nil
        pendingReadSnapshots.removeAll()
        subscribedSession = nil; desiredSession = nil; latestTranscriptTurns.removeAll()
        fileDescriptors.removeAll()
    }

    func connectionClosed(_ error: RemoteClientError, scope: ClientScope, epoch captured: Int) {
        guard captured == epoch else { return }
        epoch += 1
        let nextEpoch = epoch
        connecting?.cancel(); connecting = nil
        relay?.onClose = nil; relay?.onMessage = nil
        relay?.close(error); relay = nil
        for waiter in commandWaiters.values { waiter.mailbox.fail(error) }
        for mailbox in mailboxes.values { mailbox.fail(error) }
        for transfer in transfers.values { transfer.mailbox.fail(error) }
        commandWaiters.removeAll(); mailboxes.removeAll(); transfers.removeAll()
        snapshotTimeout?.cancel(); snapshotTimeout = nil
        snapshotParts = nil; snapshot = nil; capabilities = nil; stagedSnapshot = nil; catalog = nil
        pendingReadSnapshots.removeAll()
        subscribedSession = nil; fileDescriptors.removeAll()
        lastFailure = error
        diagnostic(.connectionClosed(error), scope: scope)
        emit(.snapshotRequired(.cryptoResumed), scope: scope)
        if error == .notAuthorized {
            do { try invalidateAccount(server: scope.server, account: scope.account) } catch { _ = note(error) }
            return
        }
        if error == .deviceRevoked {
            // A server revocation notice makes cached grant evidence unusable immediately.
            do {
                try invalidateHost(scope)
                var vault = try requireVault(server: scope.server, account: scope.account)
                vault.hosts.removeValue(forKey: scope.host.rawValue)
                try saveVault(vault, server: scope.server, account: scope.account, epoch: nextEpoch)
            } catch { _ = note(error) }
            return
        }
        guard !intentionalDisconnect, !overflowed, error != .cancelled, error != .integrity,
              error != .versionMismatch, error != .invalidPayload,
              reconnect == nil, reconnectAttempt < 5 else { return }
        reconnectAttempt += 1
        let delay = 1 << reconnectAttempt
        reconnect = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self, self.epoch == nextEpoch, !self.intentionalDisconnect else { return }
                self.reconnect = nil
                try await self.openConnection(scope: scope, epoch: nextEpoch)
                guard case .snapshot(let payload) = await self.refreshDirectory(scope: scope) else { throw RemoteClientError.disconnected }
                if let session = self.desiredSession, self.relay?.features.contains(.sessionDirectoryV1) == true || payload.sessions.contains(where: { $0.id == session }) {
                    try await self.catchUpTranscript(scope: scope, session: session, epoch: nextEpoch)
                }
                self.reconnectAttempt = 0
            } catch {
                guard let self, self.epoch == nextEpoch, !self.intentionalDisconnect else { return }
                self.reconnect = nil
                self.connectionClosed((error as? RemoteClientError) ?? .transport, scope: scope, epoch: nextEpoch)
            }
        }
    }

    /// Signing out is local: this app forgets its controller identity and Host
    /// keys for the Server (the pinned Server identity stays). Hosts keep the
    /// pairing until it is removed there.
    public func logout(server: ServerAddress, account: AccountID) async throws {
        disconnectNow()
        controllerLeases.removeValue(forKey: server)
        let loaded = Result { try loadVaultForCleanup(server: server, account: account) }
        try invalidateAccount(server: server, account: account)
        try secrets.remove(activeKey(server))
        try secrets.remove(installationKey(server))
        guard let vault = try loaded.get() else { return }
        try secrets.remove(vaultKey(server: server, account: account, installation: vault.identity.installation))
        try secrets.remove(RemoteSecretKey(server: server, account: account, installation: vault.identity.installation, purpose: "pending-pairing-key"))
    }

    public func revoke(scope: ClientScope) async throws {
        disconnectNow()
        let loaded = Result { try requireVault(server: scope.server, account: scope.account) }
        let lease = deviceLeases.removeValue(forKey: scope)
        try invalidateHost(scope)
        var vault = try loaded.get()
        guard let host = vault.hosts.removeValue(forKey: scope.host.rawValue) else { throw RemoteClientError.notAuthorized }
        try saveVault(vault, server: scope.server, account: scope.account, epoch: epoch)
        guard let lease, lease.expiresAt > clock.now(), let device = host.deviceID else { throw RemoteClientError.disconnected }
        let signedAt = Int(clock.now().timeIntervalSince1970 * 1000)
        let signature = try host.identity.sign(.object(["action": .string("self_revoke"), "host_id": .string(host.id),
            "device_id": .string(device), "signed_at": .int(signedAt)]))
        let response = try await http(server: scope.server, path: "/api/v1/hosts/\(host.id)/pairing", method: "DELETE", body: .object([
            "protocol": .string(RemoteBaseline.authProtocol), "host_id": .string(host.id), "signed_at": .int(signedAt), "signature": .string(signature),
        ]), bearer: lease.token)
        try validateProtocol(response)
        guard try response.identifier("host_id") == host.id, try response.string("status") == "revoked" else {
            // tombstoned/pending_host is NOT confirmation that the Host applied revocation.
            throw RemoteClientError.server(code: "UNKNOWN_OUTCOME", retryAfter: nil)
        }
    }
}
