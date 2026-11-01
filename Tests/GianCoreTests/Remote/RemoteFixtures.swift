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
    let account = AccountID(provider: .github, id: "31415")!
    let hostID = "00000000-0000-7000-8000-000000000011"
    let pairingID = "00000000-0000-7000-8000-000000000012"
    var loginID = "00000000-0000-7000-8000-000000000013"
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
    var peer: WireValue = .null
    var loginChallenge: WireValue = .null
    var pairKey: RemotePublicKey?
    var pollFailure: RemoteClientError?
    var differentAccount = false
    var invalidRole = false
    var pollStatus = "authorized"
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
        case "/api/v1/account/start":
            peer = body["peer"]
            loginChallenge = .object(["type": .string("gian.remote.account_challenge/1"), "challenge_id": .string(challengeID), "nonce": .string("ZmljdGlvbmFs"),
                "server_identity_fingerprint": .string(String(repeating: "a", count: 64)), "peer": peer, "expires_at": .int(milliseconds + 600_000)])
            return try response(.object([
                "protocol": .string(RemoteBaseline.accountProtocol), "login_id": .string(loginID), "user_code": .string("TEST-CODE"),
                "verification_uri": .string(RemoteBaseline.githubDeviceVerificationURI), "expires_at": .int(milliseconds + 600_000), "interval_seconds": .int(5),
                "challenge": loginChallenge,
            ]))
        case "/api/v1/account/poll":
            if let pollFailure { throw pollFailure }
            if pollStatus == "pending" { return try response(.object(["protocol": .string(RemoteBaseline.accountProtocol), "status": .string("pending"), "interval_seconds": .int(5)])) }
            if pollStatus != "authorized" { return try response(.object(["protocol": .string(RemoteBaseline.accountProtocol), "status": .string(pollStatus)])) }
            try RemotePublicKey(wire: peer["public_key"]).verify(signature: body.string("signature"), payload: loginChallenge)
            return try response(.object(["protocol": .string(RemoteBaseline.accountProtocol), "status": .string("authorized"),
                "account": accountWire, "account_token": .string("ZmljdGlvbmFsLWFjY291bnQtdG9rZW4"), "installation_id": peer["installation_id"],
                "role": .string(invalidRole ? "host" : "controller"), "expires_at": .int(milliseconds + 86_400_000)]))
        case "/api/v1/account/me":
            return try response(.object(["protocol": .string(RemoteBaseline.accountProtocol), "account": accountWire,
                "installation_id": peer["installation_id"], "role": .string(invalidRole ? "host" : "controller"), "expires_at": .int(milliseconds + 86_400_000)]))
        case "/api/v1/pairings/claim":
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
        case "/api/v1/account/logout": throw RemoteClientError.transport
        default: throw RemoteClientError.unsupported
        }
    }
    var accountWire: WireValue { .object(["provider": .string("github"), "id": .string(differentAccount ? "27182" : account.id), "login": .string("fixture-user")]) }
    func loginAndClaim() async throws {
        guard case .started(let challenge) = await service.startGitHubDeviceLogin(server: server) else { throw RemoteClientError.invalidPayload }
        clock.instant = clock.instant.addingTimeInterval(5)
        guard case .authorized = await service.pollGitHubDeviceLogin(server: server, loginID: challenge.loginID) else { throw RemoteClientError.notAuthorized }
        guard case .pendingConfirmation = await service.claimHostQR(server: server, account: account, qr: HostPairingQR(grantNonce: "fictional-qr-nonce")) else { throw RemoteClientError.invalidPayload }
    }
}
