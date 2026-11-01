import Foundation
import CryptoKit

@MainActor
final class RemoteRelay {
    private let socket: any RemoteWebSocket
    private let clock: any GianClock
    private let ids: any GianIDGenerating
    private var crypto: RemoteCryptoChannel?
    private var socketID = ""
    private var receiveTask: Task<Void, Never>?
    private var sendTail: Task<Void, any Error>?
    private var queuedSends = 0
    private var nextSendAt = ContinuousClock.now
    private(set) var features: [KnownWireFeature] = []
    private(set) var generation = ""
    private(set) var isOpen = false
    var onMessage: ((WireValue) throws -> Void)?
    var onClose: ((RemoteClientError) -> Void)?

    init(socket: any RemoteWebSocket, clock: any GianClock, ids: any GianIDGenerating) {
        self.socket = socket; self.clock = clock; self.ids = ids
    }
    private func rawSend(_ wire: WireValue) async throws { try await socket.send(wire.encoded()) }
    private func rawReceive() async throws -> WireValue { try await WireValue.decode(socket.receive()) }

    func connect(ticket: String, host: String, device: String, connection: String,
                 hostKey: RemotePublicKey, identity: RemoteSigningIdentity) async throws {
        try await withTaskCancellationHandler {
            try await handshake(ticket: ticket, host: host, device: device, connection: connection, hostKey: hostKey, identity: identity)
        } onCancel: {
            Task { @MainActor [weak self] in self?.close(.cancelled) }
        }
    }

    private func handshake(ticket: String, host: String, device: String, connection: String,
                           hostKey: RemotePublicKey, identity: RemoteSigningIdentity) async throws {
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)); self?.close(.timeout) } catch {}
        }
        defer { watchdog.cancel() }
        do {
            try Task.checkCancellation()
            try await rawSend(.object(["protocol": .string(RemoteWire.relay), "type": .string("ws.auth"), "ticket": .string(ticket)]))
            let bound = try await rawReceive()
            try bound.closed(["protocol", "type", "host_id", "device_id", "route_id", "connection_id", "sent_at"])
            guard try bound.string("protocol") == RemoteWire.relay, try bound.string("type") == "ws.bound",
                  try bound.identifier("host_id") == host, try bound.identifier("device_id") == device,
                  try bound.identifier("route_id") == device else { throw RemoteClientError.integrity }
            socketID = try bound.identifier("connection_id")
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let deviceEphemeral = try RemotePublicKey(x963: ephemeral.publicKey.x963Representation)
            let deviceIdentity = try identity.publicKey
            let nonce = ids.next(at: clock.now())
            let sentAt = Int(clock.now().timeIntervalSince1970 * 1000)
            var fields: [String: WireValue] = [
                "type": .string("gian.remote.crypto_offer/1"), "host_id": .string(host), "device_id": .string(device),
                "crypto_connection_id": .string(connection), "handshake_nonce": .string(nonce), "sent_at": .int(sentAt),
                "device_identity": deviceIdentity.wire, "device_ephemeral": deviceEphemeral.wire,
            ]
            let signature = try identity.sign(.object(fields))
            fields["type"] = .string("crypto.offer"); fields["protocol"] = .string(RemoteWire.relay)
            fields["signature"] = .string(signature)
            try await rawSend(.object(fields))
            var accept = try await rawReceive()
            // Presence is advisory and is not an alternative to a signed handshake.
            for _ in 0..<8 where (try? accept.string("type")) == "host.online" { accept = try await rawReceive() }
            try accept.closed(["protocol", "type", "host_id", "device_id", "crypto_connection_id", "handshake_nonce",
                "host_generation", "host_identity", "host_ephemeral", "device_ephemeral", "signature", "sent_at"])
            let acceptTime = try accept.integer("sent_at")
            guard try accept.string("protocol") == RemoteWire.relay, try accept.string("type") == "crypto.accept",
                  try accept.identifier("host_id") == host, try accept.identifier("device_id") == device,
                  try accept.identifier("crypto_connection_id") == connection, try accept.identifier("handshake_nonce") == nonce,
                  try RemotePublicKey(wire: accept["host_identity"]) == hostKey,
                  try RemotePublicKey(wire: accept["device_ephemeral"]) == deviceEphemeral,
                  abs(acceptTime - Int(clock.now().timeIntervalSince1970 * 1000)) <= 300_000,
                  acceptTime + 300_000 >= sentAt else { throw RemoteClientError.integrity }
            generation = try accept.identifier("host_generation")
            let remoteEphemeral = try RemotePublicKey(wire: accept["host_ephemeral"])
            let payload = WireValue.object([
                "type": .string("gian.remote.crypto_accept/1"), "host_id": .string(host), "device_id": .string(device),
                "crypto_connection_id": .string(connection), "handshake_nonce": .string(nonce), "sent_at": .int(acceptTime),
                "host_generation": .string(generation), "host_identity": hostKey.wire, "device_identity": deviceIdentity.wire,
                "host_ephemeral": remoteEphemeral.wire, "device_ephemeral": deviceEphemeral.wire,
            ])
            try hostKey.verify(signature: accept.string("signature"), payload: payload)
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: remoteEphemeral.x963()))
            crypto = try RemoteCryptoChannel(host: host, device: device, connection: connection, generation: generation,
                shared: shared, transcript: .object([
                    "host_identity": hostKey.wire, "device_identity": deviceIdentity.wire,
                    "host_ephemeral": remoteEphemeral.wire, "device_ephemeral": deviceEphemeral.wire,
                    "connection_id": .string(connection),
                ]))
            try await send(.object([
                "type": .string("hello"), "protocol": .string(RemoteBaseline.remoteProtocol), "client_version": .string("gian-ios/0.1.0"),
                "major_version": .int(1), "min_minor_version": .int(1), "max_minor_version": .int(3),
                "capabilities": .strings(RemoteWire.supportedFeatures.map(\.rawValue)), "device_id": .string(device),
            ]), duringHandshake: true)
            var deferred: [WireValue] = []
            var deferredBytes = 0
            while true {
                let message = try decodeFrame(await rawReceive())
                if try message.string("type") == "hello.ok" {
                    try message.closed(["type", "protocol", "host_version", "host_generation", "connection_id",
                        "negotiated_major_version", "negotiated_minor_version", "negotiated_capabilities", "server_time"])
                    guard try message.string("protocol") == RemoteBaseline.remoteProtocol,
                          try message.identifier("connection_id") == connection,
                          try message.identifier("host_generation") == generation,
                          try message.integer("negotiated_major_version") == 1,
                          (1...3).contains(try message.integer("negotiated_minor_version")) else { throw RemoteClientError.versionMismatch }
                    let values = try message.array("negotiated_capabilities", maximum: 32)
                    features = try values.map { value in
                        guard case .string(let s) = value, let feature = KnownWireFeature(rawValue: s),
                              RemoteWire.supportedFeatures.contains(feature) else { throw RemoteClientError.versionMismatch }
                        return feature
                    }
                    guard Set(features.map(\.rawValue)).count == features.count else { throw RemoteClientError.invalidPayload }
                    break
                }
                deferredBytes += try message.encoded().count
                guard deferred.count < 64, deferredBytes <= RemoteWire.maxSnapshot else { throw RemoteClientError.bufferLimit }
                deferred.append(message)
            }
            try Task.checkCancellation()
            isOpen = true
            for message in deferred { try onMessage?(message) }
            receiveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled, self.isOpen {
                        let frame = try await self.rawReceive()
                        if !frame["type"].isNull {
                            guard try frame.string("protocol") == RemoteWire.relay,
                                  try frame.identifier("host_id") == self.crypto?.host else { throw RemoteClientError.integrity }
                            if !frame["device_id"].isNull, try frame.identifier("device_id") != self.crypto?.device { throw RemoteClientError.integrity }
                            let kind = try frame.string("type")
                            if kind == "device.revoked" { throw RemoteClientError.deviceRevoked }
                            if kind == "host.offline" { throw RemoteClientError.disconnected }
                            if kind == "host.online" { continue }
                            throw RemoteClientError.invalidPayload
                        }
                        try self.onMessage?(self.decodeFrame(frame))
                    }
                } catch { self.close((error as? RemoteClientError) ?? .disconnected) }
            }
        } catch {
            close(error is CancellationError ? .cancelled : (error as? RemoteClientError) ?? .transport)
            throw error
        }
    }

    private func decodeFrame(_ frame: WireValue) throws -> WireValue {
        try frame.closed(["protocol", "frame_id", "frame_class", "route_id", "host_id", "device_id", "connection_id",
            "transport_sequence", "transport_ack", "sent_at", "ciphertext"])
        guard try frame.string("protocol") == RemoteWire.relay, let crypto else { throw RemoteClientError.invalidPayload }
        _ = try frame.identifier("frame_id"); _ = try frame.identifier("connection_id")
        _ = try frame.integer("sent_at"); _ = try frame.integer("transport_ack")
        // Inbound wire connection_id is the Host's socket ID, not our ID or AEAD ID.
        let message = try crypto.open(frame)
        let isContent = try message.string("type") == "attachment.chunk"
        guard try frame.string("frame_class") == (isContent ? "content" : "control") else { throw RemoteClientError.integrity }
        return message
    }

    func send(_ message: WireValue, content: Bool = false, duringHandshake: Bool = false) async throws {
        guard (isOpen || duringHandshake), queuedSends < 64 else { throw RemoteClientError.disconnected }
        queuedSends += 1
        defer { queuedSends -= 1 }
        let previous = sendTail
        let work = Task { @MainActor [weak self] in
            if let previous { try await previous.value }
            guard let self, let crypto = self.crypto, !crypto.closed else { throw RemoteClientError.disconnected }
            try Task.checkCancellation()
            // 25 frames/s, below 9 MiB/s ciphertext: under Server burst and byte limits.
            let now = ContinuousClock.now
            if self.nextSendAt > now { try await Task.sleep(until: self.nextSendAt, clock: .continuous) }
            self.nextSendAt = ContinuousClock.now.advanced(by: .milliseconds(40))
            let sealed = try crypto.seal(message.encoded())
            try await self.rawSend(.object([
                "protocol": .string(RemoteWire.relay), "frame_id": .string(self.ids.next(at: self.clock.now())),
                "frame_class": .string(content ? "content" : "control"), "route_id": .string(crypto.device),
                "host_id": .string(crypto.host), "device_id": .string(crypto.device), "connection_id": .string(self.socketID),
                "transport_ack": .int(max(0, crypto.inbound - 1)), "transport_sequence": .int(sealed.sequence),
                "sent_at": .int(Int(self.clock.now().timeIntervalSince1970 * 1000)), "ciphertext": .string(sealed.ciphertext),
            ]))
        }
        sendTail = work
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)); self?.close(.timeout) } catch {}
        }
        defer { watchdog.cancel() }
        do { try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
        catch {
            // A sealed-but-unsent frame consumes a nonce. Never continue this sequence after send failure.
            close(error is CancellationError ? .cancelled : .disconnected)
            throw error
        }
    }
    func close(_ error: RemoteClientError = .cancelled) {
        let notify = isOpen || crypto != nil
        isOpen = false; crypto?.close(); crypto = nil
        receiveTask?.cancel(); receiveTask = nil; sendTail?.cancel(); sendTail = nil
        socket.close()
        if notify { onClose?(error) }
    }
}
