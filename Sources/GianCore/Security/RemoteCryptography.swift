import Foundation
import CryptoKit

struct RemotePublicKey: Codable, Sendable, Equatable {
    let kty: String
    let crv: String
    let x: String
    let y: String

    init(x963: Data) throws {
        guard x963.count == 65, x963.first == 4 else { throw RemoteClientError.integrity }
        kty = "EC"; crv = "P-256"
        x = RemoteWire.base64(x963.subdata(in: 1..<33))
        y = RemoteWire.base64(x963.subdata(in: 33..<65))
    }
    init(wire: WireValue) throws {
        try wire.closed(["kty", "crv", "x", "y"])
        kty = try wire.string("kty"); crv = try wire.string("crv")
        x = try wire.string("x"); y = try wire.string("y")
        _ = try P256.Signing.PublicKey(x963Representation: x963())
    }
    func x963() throws -> Data {
        guard kty == "EC", crv == "P-256", x.count == 43, y.count == 43 else { throw RemoteClientError.integrity }
        let xBytes = try RemoteWire.unbase64(x, maximum: 32)
        let yBytes = try RemoteWire.unbase64(y, maximum: 32)
        guard xBytes.count == 32, yBytes.count == 32 else { throw RemoteClientError.integrity }
        return Data([4]) + xBytes + yBytes
    }
    var wire: WireValue { .object(["kty": .string(kty), "crv": .string(crv), "x": .string(x), "y": .string(y)]) }
    func verify(signature: String, payload: WireValue) throws {
        let key = try P256.Signing.PublicKey(x963Representation: x963())
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: RemoteWire.unbase64(signature, maximum: 64))
        guard try key.isValidSignature(sig, for: payload.encoded()) else { throw RemoteClientError.integrity }
    }
}

struct RemoteSigningIdentity: Codable, Sendable {
    let installation: String
    let privateKey: Data
    init(installation: String) {
        self.installation = installation
        self.privateKey = P256.Signing.PrivateKey().rawRepresentation
    }
    var publicKey: RemotePublicKey {
        get throws { try RemotePublicKey(x963: P256.Signing.PrivateKey(rawRepresentation: privateKey).publicKey.x963Representation) }
    }
    func sign(_ data: Data) throws -> String {
        RemoteWire.base64(try P256.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: data).rawRepresentation)
    }
    func sign(_ wire: WireValue) throws -> String { try sign(wire.encoded()) }
}

/// One fresh ECDH handshake, with distinct HKDF keys and strictly ordered AEAD frames.
@MainActor
final class RemoteCryptoChannel {
    let host: String
    let device: String
    let connection: String
    let generation: String
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private(set) var outbound = 0
    private(set) var inbound = 0
    private(set) var closed = false

    init(host: String, device: String, connection: String, generation: String,
         shared: SharedSecret, transcript: WireValue) throws {
        self.host = host; self.device = device; self.connection = connection; self.generation = generation
        let salt = Data(SHA256.hash(data: try transcript.encoded()))
        sendKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("gian.remote/1|device_to_host|aes-256-gcm".utf8), outputByteCount: 32)
        receiveKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("gian.remote/1|host_to_device|aes-256-gcm".utf8), outputByteCount: 32)
    }

    private func aad(direction: String, sequence: Int) throws -> Data {
        try WireValue.object([
            "protocol": .string(RemoteWire.relay), "inner_protocol": .string(RemoteBaseline.remoteProtocol),
            "host_generation": .string(generation), "host_id": .string(host), "device_id": .string(device),
            "route_id": .string(device), "connection_id": .string(connection), "direction": .string(direction),
            "transport_sequence": .int(sequence),
        ]).encoded()
    }
    static func nonce(connection: String, direction: String, sequence: Int) throws -> AES.GCM.Nonce {
        guard (0...9_007_199_254_740_991).contains(sequence) else { throw RemoteClientError.integrity }
        var sequenceBE = UInt64(sequence).bigEndian
        var material = Data("gian.relay.nonce/1\0\(connection)\0\(direction)\0".utf8)
        withUnsafeBytes(of: &sequenceBE) { material.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: Data(SHA256.hash(data: material).prefix(12)))
    }
    func seal(_ plaintext: Data) throws -> (ciphertext: String, sequence: Int) {
        guard !closed, plaintext.count <= 256 * 1024, outbound < 9_007_199_254_740_991 else {
            throw RemoteClientError.bufferLimit
        }
        let sequence = outbound
        let box = try AES.GCM.seal(plaintext, using: sendKey,
            nonce: Self.nonce(connection: connection, direction: "device_to_host", sequence: sequence),
            authenticating: aad(direction: "device_to_host", sequence: sequence))
        outbound += 1
        return (RemoteWire.base64(box.ciphertext + box.tag), sequence)
    }
    func open(_ frame: WireValue) throws -> WireValue {
        do {
            guard !closed, try frame.identifier("host_id") == host,
                  try frame.identifier("device_id") == device, try frame.identifier("route_id") == device,
                  try frame.integer("transport_sequence") == inbound else { throw RemoteClientError.integrity }
            let data = try RemoteWire.unbase64(frame.string("ciphertext", maximum: RemoteWire.maxFrame))
            guard data.count >= 16 else { throw RemoteClientError.integrity }
            let box = try AES.GCM.SealedBox(
                nonce: Self.nonce(connection: connection, direction: "host_to_device", sequence: inbound),
                ciphertext: data.dropLast(16), tag: data.suffix(16))
            let plain = try AES.GCM.open(box, using: receiveKey,
                authenticating: aad(direction: "host_to_device", sequence: inbound))
            inbound += 1
            return try WireValue.decode(plain)
        } catch {
            closed = true
            throw RemoteClientError.integrity
        }
    }
    func close() { closed = true }
}
