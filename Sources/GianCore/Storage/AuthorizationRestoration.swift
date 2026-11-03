import Foundation

public enum AuthorizationValidation: Sendable, Equatable {
    case cached
    case online
}

/// Evidence created only by the module's secure authorization loader. This is
/// not a serialized grant, a credential container or a promise of online access.
public struct AuthorizedHostRestoration: Sendable, Equatable {
    public let host: HostSummary
    public let deviceID: DeviceID
    public let hostKeyFingerprint: String
    public let deviceKeyFingerprint: String
    public let lastVerifiedAt: Date
    public let validation: AuthorizationValidation

    init(host: HostSummary, deviceID: DeviceID, hostKeyFingerprint: String,
         deviceKeyFingerprint: String, lastVerifiedAt: Date, validation: AuthorizationValidation) {
        self.host = host
        self.deviceID = deviceID
        self.hostKeyFingerprint = hostKeyFingerprint
        self.deviceKeyFingerprint = deviceKeyFingerprint
        self.lastVerifiedAt = lastVerifiedAt
        self.validation = validation
    }
}

/// This app's controller identity on a Server, with its paired Hosts. Access
/// tokens and socket tickets are separate, short leases; the protocol defines
/// no expiry for a paired Host grant.
public struct AuthorizedSessionRestoration: Sendable, Equatable {
    public let server: ServerAddress
    public let serverIdentityFingerprint: String
    public let identity: AccountIdentity
    public let accountKeyFingerprint: String
    /// When this app last verified the Server's identity for this controller.
    public let accountLastVerifiedAt: Date
    public let hosts: [AuthorizedHostRestoration]

    init(server: ServerAddress, serverIdentityFingerprint: String, identity: AccountIdentity,
         accountKeyFingerprint: String, accountLastVerifiedAt: Date, hosts: [AuthorizedHostRestoration]) {
        self.server = server
        self.serverIdentityFingerprint = serverIdentityFingerprint
        self.identity = identity
        self.accountKeyFingerprint = accountKeyFingerprint
        self.accountLastVerifiedAt = accountLastVerifiedAt
        self.hosts = hosts
    }
}
