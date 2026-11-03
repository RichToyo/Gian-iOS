import Foundation
import CryptoKit
import Testing
@testable import GianCore

@MainActor
struct RemoteFrameTests {
    @Test func aeadRejectsReplayGapCrossRouteAndTamper() throws {
        let local = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([3]))
        let remote = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([2]))
        let shared = try local.sharedSecretFromKeyAgreement(with: remote.publicKey)
        let host = "00000000-0000-7000-8000-000000000001"
        let device = "00000000-0000-7000-8000-000000000002"
        let crypto = "00000000-0000-7000-8000-000000000003"
        let generation = "00000000-0000-7000-8000-000000000004"
        let bindingTranscript = WireValue.object(["fixture": .string("same-platform-crypto")])
        let bindingKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: try bindingTranscript.encoded())),
            sharedInfo: Data("gian.remote/1|host_to_device|aes-256-gcm".utf8), outputByteCount: 32)
        func validFrame(sequence: Int = 0, tamper: Bool = false) throws -> WireValue {
            let aad = try WireValue.object(["protocol": .string("gian.relay/1"), "inner_protocol": .string("gian.remote/1"),
                "host_generation": .string(generation), "host_id": .string(host), "device_id": .string(device), "route_id": .string(device),
                "connection_id": .string(crypto), "direction": .string("host_to_device"), "transport_sequence": .int(sequence)]).encoded()
            let box = try AES.GCM.seal(Data("{\"type\":\"fixture\"}".utf8), using: bindingKey,
                nonce: RemoteCryptoChannel.nonce(connection: crypto, direction: "host_to_device", sequence: sequence), authenticating: aad)
            // `ciphertext` is a slice of the combined box, so rebase before indexing from 0.
            var data = Data(box.ciphertext + box.tag)
            if tamper { data[data.startIndex] ^= 1 }
            return .object(["host_id": .string(host), "device_id": .string(device), "route_id": .string(device), "transport_sequence": .int(sequence), "ciphertext": .string(RemoteWire.base64(data))])
        }
        func boundChannel() throws -> RemoteCryptoChannel {
            try RemoteCryptoChannel(host: host, device: device, connection: crypto, generation: generation, shared: shared, transcript: bindingTranscript)
        }
        let valid = try boundChannel()
        #expect(try valid.open(validFrame()).string("type") == "fixture")
        #expect(throws: RemoteClientError.self) { try valid.open(validFrame()) }
        #expect(valid.closed)
        #expect(throws: RemoteClientError.self) { try boundChannel().open(validFrame(sequence: 1)) }
        #expect(throws: RemoteClientError.self) { try boundChannel().open(validFrame(tamper: true)) }
        guard case .object(var foreign) = try validFrame() else { return }
        foreign["route_id"] = .string(host)
        #expect(throws: RemoteClientError.self) { try boundChannel().open(.object(foreign)) }
    }
}
