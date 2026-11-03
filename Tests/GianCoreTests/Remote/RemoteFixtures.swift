import Foundation
import CryptoKit
import Testing
@testable import GianCore

@MainActor
final class FixtureSecrets: RemoteSecretStoring {
    var records: [RemoteSecretKey: Data] = [:]
    var reads = 0
    var failure: RemoteClientError?
    var mutationFailure: ((RemoteSecretKey, FixtureSecretOperation) -> RemoteClientError?)?
    var didWrite: ((RemoteSecretKey) throws -> Void)?
    var mutations: [(RemoteSecretKey, FixtureSecretOperation)] = []
    func read(_ key: RemoteSecretKey) throws -> Data? {
        reads += 1
        if let failure { throw failure }
        return records[key]
    }
    func write(_ data: Data, for key: RemoteSecretKey) throws {
        mutations.append((key, .write))
        if let failure { throw failure }
        if let failure = mutationFailure?(key, .write) { throw failure }
        records[key] = data
        try didWrite?(key)
    }
    func remove(_ key: RemoteSecretKey) throws {
        mutations.append((key, .remove))
        if let failure { throw failure }
        if let failure = mutationFailure?(key, .remove) { throw failure }
        records.removeValue(forKey: key)
    }
}

enum FixtureSecretOperation: Equatable { case write, remove }

@MainActor
final class FixtureTransport: RemoteTransport {
    var requests: [URLRequest] = []
    var handler: ((URLRequest) async throws -> RemoteHTTPResponse)?
    var socket: (any RemoteWebSocket)?
    func request(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RemoteHTTPResponse {
        requests.append(request)
        guard let handler else { throw RemoteClientError.transport }
        let response = try await handler(request)
        guard response.body.count <= maximumResponseBytes else { throw RemoteClientError.bufferLimit }
        return response
    }
    func openWebSocket(_ request: URLRequest) async throws -> any RemoteWebSocket {
        requests.append(request)
        guard let socket else { throw RemoteClientError.transport }
        return socket
    }
}

@MainActor
final class RemoteFixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    let server = ServerAddress(parsing: "https://remote.fixture.test")!
    /// This app's controller identity on the fixture Server; known once connected.
    var account = AccountID(provider: .controller, id: "not-connected")!
    let hostID = "00000000-0000-7000-8000-000000000011"
    let pairingID = "00000000-0000-7000-8000-000000000012"
    let challengeID = "00000000-0000-7000-8000-000000000014"
    let cryptoID = "00000000-0000-7000-8000-000000000015"
    let generation = "00000000-0000-7000-8000-000000000016"
    let sessionID = "00000000-0000-7000-8000-000000000017"
    let workspaceID = "00000000-0000-7000-8000-000000000018"
    let agentID = "00000000-0000-7000-8000-000000000019"
    let taskID = "00000000-0000-7000-8000-000000000020"
    let transport = FixtureTransport()
    let secrets = FixtureSecrets()
    let invalidations: any AuthorizationInvalidationStoring
    let clock = ManualGianClock(instant: RemoteFixture.now)
    let service: LiveGianClientService
    let hostSigning = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
    let serverSigning = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([2]))
    let otherServerSigning = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([3]))
    /// The Server answers with a different identity key (e.g. reinstalled).
    var serverKeyChanged = false
    var identityFailure: RemoteClientError?
    /// Enrollment tokens the fixture Server accepts once each.
    var enrollmentTokens: Set<String> = ["fixture-enrollment-token"]
    var enrollmentError: String?
    var controllerKey: RemotePublicKey?
    var controllerToken = "fixture-controller-access"
    var lastClaim: WireValue = .null
    var pairKey: RemotePublicKey?
    var deviceConfirmed = true

    init(invalidations: any AuthorizationInvalidationStoring = InMemoryGianStorage()) {
        self.invalidations = invalidations
        service = LiveGianClientService(transport: transport, secrets: secrets, authorizationInvalidations: invalidations,
            clock: clock, ids: SequenceIDGenerator())
        transport.handler = { [unowned self] request in try await self.respond(request) }
    }
    var scope: ClientScope { ClientScope(server: server, account: account, host: HostID(rawValue: hostID)!) }
    var milliseconds: Int { Int(clock.now().timeIntervalSince1970 * 1000) }
    func response(_ body: WireValue, status: Int = 200) throws -> RemoteHTTPResponse { RemoteHTTPResponse(status: status, body: try body.encoded()) }
    func respond(_ request: URLRequest) async throws -> RemoteHTTPResponse {
        let body = try request.httpBody.map { try WireValue.decode($0) } ?? .null
        switch request.url?.path {
        case "/api/v1/server-identity":
            if let identityFailure { throw identityFailure }
            let signing = serverKeyChanged ? otherServerSigning : serverSigning
            let key = try RemotePublicKey(x963: signing.publicKey.x963Representation)
            let fingerprint = RemoteWire.hash(try key.wire.encoded())
            let expires = milliseconds + 120_000
            let payload = WireValue.object(["type": .string(RemoteBaseline.serverIdentityProofType), "nonce": body["nonce"],
                "fingerprint": .string(fingerprint), "expires_at": .int(expires)])
            let signature = try signing.signature(for: payload.encoded()).rawRepresentation
            return try response(.object(["protocol": .string(RemoteBaseline.authProtocol),
                "server_identity": .object(["algorithm": .string("P-256"), "public_key": key.wire, "fingerprint": .string(fingerprint)]),
                "expires_at": .int(expires), "signature": .string(RemoteWire.base64(signature))]))
        case "/api/v1/controller-enrollments/claim":
            if let enrollmentError { return try response(.object(["error": .object(["code": .string(enrollmentError)])]), status: 409) }
            guard enrollmentTokens.remove(try body.string("enrollment_token")) != nil else {
                return try response(.object(["error": .object(["code": .string("AUTH_REQUIRED")])]), status: 401)
            }
            controllerKey = try RemotePublicKey(wire: body["device_public_key"])
            let key = try RemotePublicKey(x963: (serverKeyChanged ? otherServerSigning : serverSigning).publicKey.x963Representation)
            return try response(.object(["protocol": .string(RemoteBaseline.authProtocol), "browser_installation_id": body["browser_installation_id"],
                "server_identity": .object(["algorithm": .string("P-256"), "public_key": key.wire,
                    "fingerprint": .string(RemoteWire.hash(try key.wire.encoded()))])]))
        case "/api/v1/sessions/controller-challenge":
            guard controllerKey != nil else { return try response(.object(["error": .object(["code": .string("CONTROLLER_NOT_ADMITTED")])]), status: 401) }
            return try response(.object(["protocol": .string(RemoteBaseline.authProtocol), "challenge_id": .string(challengeID),
                "challenge": .string("ZmljdGlvbmFs"), "expires_at": .int(milliseconds + 600_000)]))
        case "/api/v1/sessions/controller-login":
            guard let controllerKey else { throw RemoteClientError.notAuthorized }
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: RemoteWire.unbase64(body.string("signature")))
            guard try P256.Signing.PublicKey(x963Representation: controllerKey.x963()).isValidSignature(signature, for: Data(challengeID.utf8)) else {
                throw RemoteClientError.integrity
            }
            return try response(.object(["protocol": .string(RemoteBaseline.authProtocol), "controller_access_token": .string(controllerToken),
                "expires_at": .int(milliseconds + 600_000), "browser_installation_id": body["browser_installation_id"]]))
        case "/api/v1/pairings/claim":
            // An admitted controller must claim as one, with its access token.
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(controllerToken)",
                  body["controller_admission"] == .int(1) else {
                return try response(.object(["error": .object(["code": .string("CONTROLLER_NOT_ADMITTED")])]), status: 401)
            }
            lastClaim = body
            pairKey = try RemotePublicKey(wire: body["device_public_key"])
            return try response(.object(["protocol": .string(RemoteBaseline.authProtocol), "status": .string("pending_confirmation"),
                "pairing_id": .string(pairingID), "host_id": .string(hostID), "crypto_connection_id": .string(cryptoID)]))
        case "/api/v1/sessions/device-challenge":
            if !deviceConfirmed { return try response(.object(["error": .object(["code": .string("DEVICE_NOT_PAIRED")])]), status: 401) }
            return try response(.object(["protocol": .string(RemoteBaseline.authProtocol), "challenge_id": .string(challengeID),
                "challenge": .string("ZmljdGlvbmFs"), "expires_at": .int(milliseconds + 60_000)]))
        case "/api/v1/sessions/device-login":
            guard let pairKey else { throw RemoteClientError.notAuthorized }
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: RemoteWire.unbase64(body.string("signature")))
            let key = try P256.Signing.PublicKey(x963Representation: pairKey.x963())
            guard key.isValidSignature(signature, for: Data(challengeID.utf8)) else { throw RemoteClientError.integrity }
            return try response(.object(["protocol": .string(RemoteBaseline.authProtocol), "access_token": .string("fixture-access"),
                "expires_at": .int(milliseconds + 600_000), "device_id": .string(pairingID), "host_id": .string(hostID),
                "crypto_connection_id": .string(cryptoID), "host_public_key": try RemotePublicKey(x963: hostSigning.publicKey.x963Representation).wire]))
        case "/api/v1/ws-tickets": return try response(.object(["protocol": .string(RemoteBaseline.authProtocol), "ticket": .string("fixture-ticket"), "expires_at": .int(milliseconds + 60_000)]))
        default: throw RemoteClientError.unsupported
        }
    }
    func connect(enrollmentToken: String? = "fixture-enrollment-token") async throws {
        guard case .connected(let identity) = await service.connectServer(server: server, enrollmentToken: enrollmentToken) else {
            throw RemoteClientError.notAuthorized
        }
        account = identity.account
    }
    func connectAndClaim(_ invitation: HostPairingInvitation = .grantNonce("fictional-qr-nonce")) async throws {
        try await connect()
        guard case .pendingConfirmation = await service.claimHost(server: server, account: account, invitation: invitation) else {
            throw RemoteClientError.invalidPayload
        }
    }
}
