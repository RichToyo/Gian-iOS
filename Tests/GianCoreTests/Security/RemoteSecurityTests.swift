import Foundation
import CryptoKit
import Testing
@testable import GianCore

@MainActor
struct RemoteSecurityTests {
    @Test func canonicalSignatureUsesRawP256AndStableJSON() throws {
        let identity = RemoteSigningIdentity(installation: "00000000-0000-7000-8000-000000000001")
        let payload = WireValue.object(["z": .int(7), "a": .string("a/b")])
        #expect(String(data: try payload.encoded(), encoding: .utf8) == "{\"a\":\"a/b\",\"z\":7}")
        let signature = try identity.sign(payload)
        #expect(try RemoteWire.unbase64(signature).count == 64)
        try identity.publicKey.verify(signature: signature, payload: payload)
        #expect(throws: (any Error).self) {
            try identity.publicKey.verify(signature: signature, payload: .object(["z": .int(8)]))
        }
    }

    @Test func nonceAndKeyScopesAreDistinct() throws {
        let a = try RemoteCryptoChannel.nonce(connection: "fixture", direction: "device_to_host", sequence: 0)
        let b = try RemoteCryptoChannel.nonce(connection: "fixture", direction: "host_to_device", sequence: 0)
        #expect(Data(a) != Data(b))
        let server = try #require(ServerAddress(parsing: "https://fixture.example.test"))
        let account = try #require(AccountID(provider: .controller, id: "123"))
        let first = RemoteSecretKey(server: server, account: account, installation: "install-a", purpose: "vault")
        let second = RemoteSecretKey(server: server, account: account, installation: "install-b", purpose: "vault")
        #expect(first.storageName != second.storageName)
        #expect(first.storageName.count == 64)
    }

    @Test func boundedDecodingRejectsNonCanonicalAndOversizedInputs() throws {
        #expect(throws: RemoteClientError.self) { try RemoteWire.unbase64("AA==") }
        #expect(throws: RemoteClientError.self) { try RemoteWire.unbase64("AB") }
        #expect(throws: RemoteClientError.self) { try RemoteWire.id("../../secrets") }
        #expect(throws: RemoteClientError.self) { try WireValue.decode(Data(repeating: 32, count: 200), maximum: 100) }
        #expect(try RemoteWire.commandDate("01900000-0000-7000-8000-000000000001") == 0x019000000000)
    }
}
