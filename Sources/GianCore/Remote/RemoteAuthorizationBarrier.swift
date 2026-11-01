import Foundation

extension LiveGianClientService {
    /// Both stores are independently attempted. A thrown write must never be
    /// described as persisted, even if the other barrier succeeded.
    func persistAccountInvalidation(server: ServerAddress, account: AccountID) throws {
        var firstFailure: (any Error)?
        do { try authorizationInvalidations.invalidateAuthorization(scope: DataScope(server: server, account: account), at: clock.now()) }
        catch { firstFailure = error }
        do { try secrets.write(Data([1]), for: tombstoneKey(server: server, account: account)) }
        catch { if firstFailure == nil { firstFailure = error } }
        if let firstFailure { throw firstFailure }
    }

    func authorizationPostdatesInvalidation(_ vault: RemoteAccountVault, server: ServerAddress, account: AccountID) throws -> Bool {
        let proof = vault.authorizationCreatedAt ?? vault.lastVerifiedAt
        guard proof.timeIntervalSince1970.isFinite, vault.lastVerifiedAt.timeIntervalSince1970.isFinite,
              proof <= vault.lastVerifiedAt, vault.lastVerifiedAt <= clock.now() else { throw RemoteClientError.integrity }
        guard let invalidatedAt = try authorizationInvalidations.authorizationInvalidatedAt(scope: DataScope(server: server, account: account)) else {
            return true
        }
        // Revalidating an old token is not a new login. Preserve the original
        // authorization proof time across /account/me and connection refreshes.
        return proof > invalidatedAt
    }
}
