import Foundation

/// Baseline-only contracts. Importing this file requires no live transport or secure-store implementation.
@MainActor
public protocol GianClientLifecycle: AnyObject {
    func connect(scope: ClientScope) async throws
    func disconnect() async
    func logout(server: ServerAddress, account: AccountID) async throws
    func forgetServer(_ server: ServerAddress) async throws
    func revoke(scope: ClientScope) async throws
}

/// A local producer generation, never a canonical wire event sequence.
@MainActor
public protocol GianClientEventSource: AnyObject {
    var eventEpoch: Int { get }
}

public enum RemoteDiagnosticStatus: Sendable, Equatable {
    case connectionClosed(RemoteClientError)
    case resyncRequired(SnapshotRequiredReason)
    case cleared
}

public struct RemoteServiceDiagnostic: Sendable, Equatable {
    public let server: ServerAddress?
    public let account: AccountID?
    public let host: HostID?
    public let epoch: Int
    public let status: RemoteDiagnosticStatus
    /// `connectionClosed` only: the connection had been working and the
    /// service is already reconnecting on its own.
    public var reconnecting = false
}

/// Deliberately excludes remote error text, URLs, tokens and payloads.
public enum RemoteClientError: Error, Sendable, Equatable {
    case invalidServer, invalidPayload, integrity, versionMismatch, capabilityDenied
    case notAuthorized, deviceRevoked, expired, cancelled, disconnected, timeout, bufferLimit
    case unsupported, transport, deliveryNotStarted, server(code: String, retryAfter: Int?)
    /// The Server's identity proof doesn't match the identity pinned on first use.
    case serverIdentityChanged

    public var safeDescription: String {
        switch self {
        case .invalidServer: "A valid HTTPS server origin is required."
        case .serverIdentityChanged: "This server's identity changed since this device last connected."
        case .invalidPayload: "The Host returned an invalid response."
        case .integrity: "Remote content integrity verification failed."
        case .versionMismatch: "The Host protocol is not compatible."
        case .capabilityDenied: "The Host has not granted this capability."
        case .notAuthorized: "This device isn't authorized on the Server or Host."
        case .deviceRevoked: "The Host device grant was revoked."
        case .expired: "The remote reference has expired."
        case .cancelled: "The operation was cancelled."
        case .disconnected: "The Host connection is closed."
        case .timeout: "No final response was received. Check status before retrying."
        case .bufferLimit: "The remote response exceeded a safety limit."
        case .unsupported: "This operation is not supported by the inspected Host."
        case .transport: "The remote service is temporarily unavailable."
        case .deliveryNotStarted: "The Host did not start this message."
        case .server("HOST_OFFLINE", _): "The Host is offline."
        case .server("RATE_LIMITED", _): "The Server is busy. Trying again shortly."
        case .server(let code, _): "Remote operation failed (\(code))."
        }
    }

    /// The Host isn't connected to the Server (asleep, quit, no network).
    public var isHostOffline: Bool {
        if case .server("HOST_OFFLINE", _) = self { return true }
        return false
    }
}

/// How long to wait before connecting again, like remote-web: 0.5, 1, 2, 4,
/// 8, 10, 10… × `unit` (seconds in the app); at most 5 while the Host is
/// offline (it comes back on its own); the Server's Retry-After when it is
/// rate limiting. It used to back off to 32 s.
public enum ReconnectBackoff {
    public static func delay(attempt: Int, unit: Duration, error: RemoteClientError) -> Duration {
        if case .server("RATE_LIMITED", let retryAfter) = error, let retryAfter { return .seconds(retryAfter) }
        let cap: Double = error.isHostOffline ? 5 : 10
        let factor = min(cap, 0.5 * Double(1 << min(max(attempt - 1, 0), 5)))
        return unit * factor
    }

    /// Errors another attempt can't fix: they need the user (pair again,
    /// update, trust the Server again).
    public static func retries(after error: RemoteClientError) -> Bool {
        switch error {
        case .notAuthorized, .deviceRevoked, .versionMismatch, .serverIdentityChanged, .integrity, .invalidServer, .cancelled:
            false
        default:
            true
        }
    }
}
