import Foundation

/// Nonsecret logout barriers survive credential-deletion failures. Implementations
/// must throw on failure; absence is meaningful only after a successful read.
@MainActor
public protocol AuthorizationInvalidationStoring: AnyObject {
    func invalidateAuthorization(scope: DataScope, at: Date) throws
    func authorizationInvalidatedAt(scope: DataScope) throws -> Date?
}
