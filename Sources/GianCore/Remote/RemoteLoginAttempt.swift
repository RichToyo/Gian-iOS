import Foundation

struct RemoteLoginAttemptKey: Hashable {
    let server: ServerAddress
    let loginID: LoginID
}

struct RemoteLoginAuthorization {
    let account: AccountID
    let installation: String
    let authorizationID: String
    let previous: RemoteActiveAccount?
}

/// Retains attempt provenance after poll returns, without retaining credential bytes.
@MainActor
final class RemoteLoginAttempt {
    enum Phase {
        case pending
        case committing(RemoteLoginAuthorization)
        case authorized(RemoteLoginAuthorization)
        case cancelled(RemoteLoginAuthorization?)
    }
    let key: RemoteLoginAttemptKey
    let installation: String
    let authorizationID: String
    var phase: Phase = .pending

    init(server: ServerAddress, loginID: LoginID, installation: String, authorizationID: String) {
        key = RemoteLoginAttemptKey(server: server, loginID: loginID)
        self.installation = installation
        self.authorizationID = authorizationID
    }
    var authorization: RemoteLoginAuthorization? {
        switch phase {
        case .pending: nil
        case .committing(let value), .authorized(let value): value
        case .cancelled(let value): value
        }
    }
}

extension LiveGianClientService {
    func activeAuthorization(server: ServerAddress) throws -> RemoteActiveAccount? {
        guard let data = try secrets.read(activeKey(server)) else { return nil }
        guard data.count <= 1024 else { throw RemoteClientError.bufferLimit }
        return try JSONDecoder().decode(RemoteActiveAccount.self, from: data)
    }

    func cancellationKey(server: ServerAddress, authorization: RemoteLoginAuthorization) -> RemoteSecretKey {
        RemoteSecretKey(server: server, account: authorization.account, installation: authorization.installation,
            purpose: "cancelled-authorization:\(authorization.authorizationID)")
    }

    func checkLoginAttempt(_ attempt: RemoteLoginAttempt, epoch captured: Int) throws {
        try checkEpoch(captured)
        guard login?.attempt === attempt else { throw RemoteClientError.cancelled }
        if case .cancelled = attempt.phase { throw RemoteClientError.cancelled }
    }

    func persistLogin(_ vault: RemoteAccountVault, account: AccountID, attempt: RemoteLoginAttempt, epoch captured: Int) throws {
        try checkLoginAttempt(attempt, epoch: captured)
        var previous = try activeAuthorization(server: attempt.key.server)
        if let pointer = previous {
            guard let previousAccount = AccountID(provider: .github, id: pointer.account) else { throw RemoteClientError.integrity }
            if try loadVault(server: attempt.key.server, account: previousAccount) == nil { previous = nil }
        }
        let binding = RemoteLoginAuthorization(account: account, installation: attempt.installation,
            authorizationID: attempt.authorizationID, previous: previous)
        attempt.phase = .committing(binding)
        do {
            try saveVault(vault, server: attempt.key.server, account: account, epoch: captured)
            try checkLoginAttempt(attempt, epoch: captured)
            let pointer = RemoteActiveAccount(account: account.id, installation: attempt.installation, authorizationID: attempt.authorizationID)
            try secrets.write(JSONEncoder().encode(pointer), for: activeKey(attempt.key.server))
            try checkLoginAttempt(attempt, epoch: captured)
            try secrets.remove(tombstoneKey(server: attempt.key.server, account: account))
            try checkLoginAttempt(attempt, epoch: captured)
            invalidAccounts.remove(DataScope(server: attempt.key.server, account: account))
            attempt.phase = .authorized(binding)
        } catch {
            // Partial persistence must not become an authorization on a later load.
            try cancelLoginLocally(attempt)
            throw error
        }
    }

    func cancelLoginLocally(_ attempt: RemoteLoginAttempt) throws {
        let binding = attempt.authorization
        attempt.phase = .cancelled(binding)
        let wasPending = login?.attempt === attempt
        if wasPending { login = nil }
        var firstFailure: (any Error)?
        let current: RemoteActiveAccount?
        do { current = try activeAuthorization(server: attempt.key.server) }
        catch { current = nil; firstFailure = error }
        let ownsPointer = binding.map {
            current?.account == $0.account.id && current?.installation == $0.installation
                && current?.authorizationID == $0.authorizationID
        } ?? false
        if wasPending || ownsPointer { disconnectNow() }
        guard let binding else {
            if let firstFailure { throw firstFailure }
            return
        }
        let tombstone = cancellationKey(server: attempt.key.server, authorization: binding)
        invalidAuthorizations.insert(tombstone)
        func clean(_ operation: () throws -> Void) {
            do { try operation() } catch { if firstFailure == nil { firstFailure = error } }
        }
        // Try every independent cleanup even if one Keychain operation fails.
        clean { try secrets.write(Data([1]), for: tombstone) }
        clean {
            try secrets.remove(vaultKey(server: attempt.key.server, account: binding.account,
                installation: binding.installation, authorizationID: binding.authorizationID))
        }
        if ownsPointer {
            var previous: RemoteActiveAccount?
            clean {
                if let candidate = binding.previous {
                    guard let account = AccountID(provider: .github, id: candidate.account) else { throw RemoteClientError.integrity }
                    if try loadVault(server: attempt.key.server, account: account, authorization: candidate) != nil { previous = candidate }
                }
            }
            clean {
                if let previous { try secrets.write(JSONEncoder().encode(previous), for: activeKey(attempt.key.server)) }
                else { try secrets.remove(activeKey(attempt.key.server)) }
            }
        }
        // Installation keys can belong to a different, already-authorized login.
        // Never erase them or an unrelated active pointer when cancelling this attempt.
        if let firstFailure { throw firstFailure }
    }
}
