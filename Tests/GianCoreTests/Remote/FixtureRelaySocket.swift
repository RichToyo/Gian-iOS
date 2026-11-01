import Foundation
import CryptoKit
@testable import GianCore

/// In-process Host/relay fixture: verifies device signatures, derives keys and
/// decrypts actual frames. No URLSession, server, account or Provider is used.
@MainActor
final class FixtureRelaySocket: RemoteWebSocket {
    unowned let fixture: RemoteFixture
    let incoming = RemoteMailbox(limit: 64)
    let hostEphemeral = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([2]))
    var sendKey: SymmetricKey?
    var receiveKey: SymmetricKey?
    var sendSequence = 0
    var receiveSequence = 0
    var commands: [String] = []
    var ledger: [String: WireValue] = [:]
    var loseSendResult = false
    var loseCreateResult = false
    var expiredDownload = false
    var sendDenied = false
    var tamperAcceptNonce = false
    var helloMinor = 3
    var translationRecord: WireValue?
    var upload = Data()
    var uploadID = ""
    var uploadName = ""
    var uploadMIME = ""
    let fileBytes = Data("fixture file".utf8)
    var eventSequence = 0
    var stateRevision = "state-r1"
    var holdCatalogReplies = false
    var heldCatalogCommands: [WireValue] = []
    let catalogHeld = RemoteMailbox(limit: 8)
    var splitSnapshots = false
    var pageItems: [WireValue] = []
    var downloadKinds: [String] = []
    var sendDeliveryState: String?
    var directoryEnabled = false
    var directoryReplies: [WireValue] = []
    var holdDirectoryReplies = false
    var heldDirectoryCommands: [WireValue] = []
    let directoryHeld = RemoteMailbox(limit: 8)
    var commandRequests: [WireValue] = []
    var advertisedFeatures: [WireValue] = []
    var subscriptionInteractions: [WireValue] = []
    var holdSubscriptionReplies = false
    var heldSubscriptionCommands: [WireValue] = []
    let subscriptionHeld = RemoteMailbox(limit: 8)

    init(_ fixture: RemoteFixture) { self.fixture = fixture }
    func receive() async throws -> Data { try await incoming.next().encoded() }
    func close() { incoming.fail(.disconnected) }
    func send(_ data: Data) async throws {
        let wire = try WireValue.decode(data)
        switch try wire.optionalString("type") {
        case "ws.auth":
            try incoming.push(.object(["protocol": .string(RemoteWire.relay), "type": .string("ws.bound"),
                "host_id": .string(fixture.hostID), "device_id": .string(fixture.pairingID), "route_id": .string(fixture.pairingID),
                "connection_id": .string("00000000-0000-7000-8000-000000000091"), "sent_at": .int(fixture.milliseconds)]))
        case "crypto.offer": try accept(wire)
        case nil:
            guard let receiveKey else { throw RemoteClientError.integrity }
            guard try wire.integer("transport_sequence") == receiveSequence else { throw RemoteClientError.integrity }
            let sealed = try RemoteWire.unbase64(wire.string("ciphertext", maximum: RemoteWire.maxFrame))
            let box = try AES.GCM.SealedBox(nonce: RemoteCryptoChannel.nonce(connection: fixture.cryptoID, direction: "device_to_host", sequence: receiveSequence),
                ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            let plain = try AES.GCM.open(box, using: receiveKey, authenticating: aad(direction: "device_to_host", sequence: receiveSequence))
            receiveSequence += 1
            try await handle(WireValue.decode(plain))
        default: throw RemoteClientError.invalidPayload
        }
    }
    func accept(_ offer: WireValue) throws {
        let deviceKey = try RemotePublicKey(wire: offer["device_identity"])
        guard deviceKey == fixture.pairKey else { throw RemoteClientError.integrity }
        var signed: [String: WireValue] = [:]
        for key in ["host_id", "device_id", "crypto_connection_id", "handshake_nonce", "sent_at", "device_identity", "device_ephemeral"] { signed[key] = offer[key] }
        signed["type"] = .string("gian.remote.crypto_offer/1")
        try deviceKey.verify(signature: offer.string("signature"), payload: .object(signed))
        let hostKey = try RemotePublicKey(x963: fixture.hostSigning.publicKey.x963Representation)
        let hostEphemeralKey = try RemotePublicKey(x963: hostEphemeral.publicKey.x963Representation)
        let transcript = WireValue.object(["host_identity": hostKey.wire, "device_identity": deviceKey.wire,
            "host_ephemeral": hostEphemeralKey.wire, "device_ephemeral": offer["device_ephemeral"], "connection_id": .string(fixture.cryptoID)])
        let shared = try hostEphemeral.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: RemotePublicKey(wire: offer["device_ephemeral"]).x963()))
        let salt = Data(SHA256.hash(data: try transcript.encoded()))
        sendKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("gian.remote/1|host_to_device|aes-256-gcm".utf8), outputByteCount: 32)
        receiveKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("gian.remote/1|device_to_host|aes-256-gcm".utf8), outputByteCount: 32)
        var payload: [String: WireValue] = ["type": .string("gian.remote.crypto_accept/1"), "host_id": .string(fixture.hostID),
            "device_id": .string(fixture.pairingID), "crypto_connection_id": .string(fixture.cryptoID), "handshake_nonce": offer["handshake_nonce"],
            "sent_at": .int(fixture.milliseconds), "host_generation": .string(fixture.generation), "host_identity": hostKey.wire,
            "device_identity": deviceKey.wire, "host_ephemeral": hostEphemeralKey.wire, "device_ephemeral": offer["device_ephemeral"]]
        if tamperAcceptNonce { payload["handshake_nonce"] = .string("00000000-0000-7000-8000-000000000099") }
        let signature = try fixture.hostSigning.signature(for: WireValue.object(payload).encoded()).rawRepresentation
        payload.removeValue(forKey: "device_identity")
        payload["signature"] = .string(RemoteWire.base64(signature)); payload["protocol"] = .string(RemoteWire.relay); payload["type"] = .string("crypto.accept")
        try incoming.push(.object(payload))
    }
    func aad(direction: String, sequence: Int) throws -> Data {
        try WireValue.object(["protocol": .string("gian.relay/1"), "inner_protocol": .string("gian.remote/1"),
            "host_generation": .string(fixture.generation), "host_id": .string(fixture.hostID), "device_id": .string(fixture.pairingID),
            "route_id": .string(fixture.pairingID), "connection_id": .string(fixture.cryptoID), "direction": .string(direction), "transport_sequence": .int(sequence)]).encoded()
    }
    func hostFrame(_ message: WireValue) throws -> WireValue {
        guard let sendKey else { throw RemoteClientError.integrity }
        let sequence = sendSequence
        let box = try AES.GCM.seal(message.encoded(), using: sendKey,
            nonce: RemoteCryptoChannel.nonce(connection: fixture.cryptoID, direction: "host_to_device", sequence: sequence),
            authenticating: aad(direction: "host_to_device", sequence: sequence))
        sendSequence += 1
        return .object(["protocol": .string(RemoteWire.relay), "frame_id": .string(fixture.service.newID()),
            "frame_class": .string((try? message.string("type")) == "attachment.chunk" ? "content" : "control"),
            "host_id": .string(fixture.hostID), "device_id": .string(fixture.pairingID), "route_id": .string(fixture.pairingID),
            "connection_id": .string("00000000-0000-7000-8000-000000000090"), "transport_sequence": .int(sequence),
            "transport_ack": .int(max(0, receiveSequence - 1)), "sent_at": .int(fixture.milliseconds), "ciphertext": .string(RemoteWire.base64(box.ciphertext + box.tag))])
    }
    func push(_ message: WireValue) throws { try incoming.push(hostFrame(message)) }
    func handle(_ message: WireValue) async throws {
        switch try message.string("type") {
        case "hello":
            advertisedFeatures = try message.array("capabilities")
            let negotiated = advertisedFeatures.filter { directoryEnabled || $0 != .string(KnownWireFeature.sessionDirectoryV1.rawValue) }
            try push(.object(["type": .string("hello.ok"), "protocol": .string(RemoteBaseline.remoteProtocol), "host_version": .string("fixture/1"),
                "host_generation": .string(fixture.generation), "connection_id": .string(fixture.cryptoID), "negotiated_major_version": .int(1),
                "negotiated_minor_version": .int(helloMinor), "negotiated_capabilities": .array(negotiated), "server_time": .int(fixture.milliseconds)]))
        case "command.request":
            let method = try message.string("method")
            let id = try message.string("command_id")
            commands.append(method)
            commandRequests.append(message)
            var result: WireValue
            switch method {
            case "state.refresh":
                if splitSnapshots {
                    let full = snapshot
                    let bytes = try full.encoded()
                    try push(.object(["type": .string("command.result"), "command_id": .string(id), "attempt_id": message["attempt_id"], "ok": .bool(true),
                        "data": .object(["type": .string("state.snapshot.pending"), "snapshot_id": full["snapshot_id"]])]))
                    try push(.object(["type": .string("state.snapshot.part"), "snapshot_id": full["snapshot_id"], "host_generation": .string(fixture.generation),
                        "revision": full["revision"], "event_sequence": full["event_sequence"], "part_index": .int(0), "part_total": .int(1),
                        "payload_size": .int(bytes.count), "payload_sha256": .string(RemoteWire.hash(bytes)), "bytes": .string(RemoteWire.base64(bytes))]))
                    return
                }
                result = snapshot
            case "catalog.read":
                if holdCatalogReplies {
                    heldCatalogCommands.append(message)
                    try catalogHeld.push(.null)
                    return
                }
                result = catalog
            case "command.status":
                let target = try message["params"].string("command_id")
                result = ledger[target] ?? .object(["command_id": .string(target), "state": .string("not_seen")])
            case "directory.list":
                if holdDirectoryReplies {
                    heldDirectoryCommands.append(message); try directoryHeld.push(.null); return
                }
                guard !directoryReplies.isEmpty else { throw RemoteClientError.invalidPayload }
                result = directoryReplies.removeFirst()
            case "session.subscribe":
                if holdSubscriptionReplies {
                    heldSubscriptionCommands.append(message); try subscriptionHeld.push(.null); return
                }
                var data: [String: WireValue] = ["session": session, "cursor": .string("fixture-cursor")]
                if directoryEnabled { data["interactions"] = .array(subscriptionInteractions) }
                result = .object(data)
            case "session.page": result = .object(["session_id": .string(fixture.sessionID), "has_more": .bool(false), "items": .array(pageItems)])
            case "session.create":
                guard case .object(var created) = session else { throw RemoteClientError.invalidPayload }
                created["task_id"] = message["params"]["task_id"]
                result = .object(created)
                ledger[id] = .object(["command_id": .string(id), "state": .string("succeeded"), "result": result])
                if loseCreateResult { close(); return }
            case "session.send":
                var data: [String: WireValue] = ["session": session, "delivery_id": .string("00000000-0000-7000-8000-000000000030")]
                if let sendDeliveryState { data["delivery_state"] = .string(sendDeliveryState) }
                result = .object(data)
                ledger[id] = .object(["command_id": .string(id), "state": .string("succeeded"), "result": result])
                try push(.object(["type": .string("command.accepted"), "command_id": .string(id), "attempt_id": message["attempt_id"]]))
                if loseSendResult { close(); return }
            case "translation.request_status": result = translationRecord.map { .object(["state": .string("succeeded"), "record": $0]) } ?? .object(["state": .string("unknown")])
            case "translation.request":
                result = .object(["request_id": message["params"]["request_id"], "status": .string("accepted")])
                let text = "Translated fixture"
                let record = WireValue.object(["id": .string("00000000-0000-7000-8000-000000000031"), "session_id": .string(fixture.sessionID),
                    "purpose": .string("send"), "target_language": .string("en"), "text": .string(text), "text_length": .int(text.utf16.count),
                    "text_sha256": .string(RemoteWire.hash(Data(text.utf8))), "source_sha256": .string(RemoteWire.hash(Data("fixture".utf8)))])
                translationRecord = record
                try push(.object(["type": .string("event"), "host_generation": .string(fixture.generation), "event_sequence": .int(eventSequence),
                    "event": .object(["kind": .string("translation.updated"), "session_id": .string(fixture.sessionID), "upsert": record, "request_id": message["params"]["request_id"]])]))
            case "translation.cancel": result = .object(["ok": .bool(true)])
            case "file.preview":
                result = .object(["transfer_id": .string(fixture.service.newID()), "preview_max_bytes": .int(1024 * 1024),
                    "file": .object(["id": message["params"]["handle_id"], "session_id": .string(fixture.sessionID), "name": .string("fixture.txt"),
                        "mime": .string("text/plain"), "size": .int(fileBytes.count), "revision": .string("file-r1"), "previewable": .bool(true),
                        "downloadable": .bool(true), "expires_at": .string("2030-01-01T00:00:00Z")])])
            case "translation.result_text":
                try push(.object(["type": .string("command.result"), "command_id": .string(id), "attempt_id": message["attempt_id"], "ok": .bool(false),
                    "error": .object(["code": .string("FILE_REFERENCE_EXPIRED"), "message": .string("expired fixture")])]))
                return
            default: throw RemoteClientError.unsupported
            }
            try push(.object(["type": .string("command.result"), "command_id": .string(id), "attempt_id": message["attempt_id"], "ok": .bool(true), "data": result]))
        case "attachment.begin":
            upload = Data(); uploadID = try message.identifier("upload_id"); uploadName = try message.string("name"); uploadMIME = try message.string("mime")
            try ack(message, offset: 0)
        case "attachment.chunk": upload.append(try RemoteWire.unbase64(message.string("bytes", maximum: RemoteWire.maxFrame))); try ack(message, offset: upload.count)
        case "attachment.complete":
            try push(.object(["type": .string("attachment.result"), "transfer_id": message["transfer_id"], "upload_id": .string(uploadID),
                "attachment_id": .string("00000000-0000-7000-8000-000000000032"), "name": .string(uploadName), "mime": .string(uploadMIME),
                "size": .int(upload.count), "sha256": .string(RemoteWire.hash(upload)), "expires_at": .string("2030-01-01T00:00:00Z")]))
        case "download.request":
            downloadKinds.append(try message.string("kind"))
            if expiredDownload { try push(.object(["type": .string("transfer.error"), "transfer_id": message["transfer_id"], "code": .string("FILE_REFERENCE_EXPIRED"), "message": .string("expired")])); return }
            let hash = RemoteWire.hash(fileBytes)
            try push(.object(["type": .string("download.metadata"), "transfer_id": message["transfer_id"], "name": .string("fixture.txt"),
                "mime": .string("text/plain"), "size": .int(fileBytes.count), "sha256": .string(hash), "disposition": .string("attachment"), "preview": .bool(true)]))
            try push(.object(["type": .string("attachment.chunk"), "transfer_id": message["transfer_id"], "transfer_sequence": .int(0), "offset": .int(0), "bytes": .string(RemoteWire.base64(fileBytes))]))
            try push(.object(["type": .string("download.complete"), "transfer_id": message["transfer_id"], "size": .int(fileBytes.count), "sha256": .string(hash)]))
        case "transfer.ack", "transfer.cancel": break
        default: throw RemoteClientError.invalidPayload
        }
    }
    func ack(_ message: WireValue, offset: Int) throws {
        try push(.object(["type": .string("transfer.ack"), "transfer_id": message["transfer_id"], "contiguous_offset": .int(offset), "window_chunks": .int(4)]))
    }
    func releaseCatalog(at index: Int = 0) throws {
        let command = heldCatalogCommands.remove(at: index)
        try push(.object(["type": .string("command.result"), "command_id": command["command_id"], "attempt_id": command["attempt_id"],
            "ok": .bool(true), "data": catalog]))
    }
    func releaseDirectory(_ result: WireValue, at index: Int = 0) throws {
        let command = heldDirectoryCommands.remove(at: index)
        try push(.object(["type": .string("command.result"), "command_id": command["command_id"], "attempt_id": command["attempt_id"],
            "ok": .bool(true), "data": result]))
    }
    func releaseSubscription(at index: Int = 0) throws {
        let command = heldSubscriptionCommands.remove(at: index)
        let result = WireValue.object(["session": session, "cursor": .string("fixture-cursor"), "interactions": .array(subscriptionInteractions)])
        try push(.object(["type": .string("command.result"), "command_id": command["command_id"], "attempt_id": command["attempt_id"],
            "ok": .bool(true), "data": result]))
    }
    var session: WireValue { .object(["id": .string(fixture.sessionID), "revision": .string("session-r1"), "name": .string("Fixture conversation"),
        "task_id": .string(fixture.taskID), "workspace_id": .string(fixture.workspaceID), "agent": .object(["id": .string(fixture.agentID), "name": .string("Fixture Agent"), "proxy": .string("fixture")]),
        "status": .string("done"), "queue": .object(["revision": .string("queue-r1"), "entries": .array([])]), "updated_at": .string("2026-09-01T00:00:00Z")]) }
    var snapshot: WireValue {
        var capabilities: [String: WireValue] = [:]
        for capability in BusinessCapability.allCases { capabilities[capability.rawValue] = .object(["state": .string(capability == .sessionSend && sendDenied ? "denied" : "supported")]) }
        return .object(["type": .string("state.snapshot"), "snapshot_id": .string("00000000-0000-7000-8000-000000000033"),
            "host_generation": .string(fixture.generation), "revision": .string(stateRevision), "event_sequence": .int(eventSequence),
            "host": .object(["id": .string(fixture.hostID), "name": .string("Fixture Host"), "online": .bool(true), "version": .string("fixture/1")]),
            "workspaces": .array([.object(["id": .string(fixture.workspaceID), "name": .string("Fixture Repo")])]),
            "tasks": .array([.object(["id": .string(fixture.taskID), "name": .string("Fixture Task"), "updated_at": .string("2026-09-01T00:00:00Z"), "session_ids": .strings([fixture.sessionID])])]),
            "sessions": .array([session]), "interactions": .array([]), "capabilities": .object(capabilities), "attention": .array([]), "catalog_revision": .string("catalog-r1")])
    }
    var catalog: WireValue { .object(["catalog_revision": .string("catalog-r1"), "workspaces": .array([.object(["id": .string(fixture.workspaceID), "name": .string("Fixture Repo")])]),
        "agents": .array([.object(["id": .string(fixture.agentID), "name": .string("Fixture Agent"), "proxy": .string("fixture"), "readiness": .string("ready")])]),
        "tasks": .array([.object(["id": .string(fixture.taskID), "name": .string("Fixture Task")])])]) }
}
