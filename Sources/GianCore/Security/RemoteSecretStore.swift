import Foundation
import Security

/// Opaque Keychain scope. Its description never contains a token or private key.
public struct RemoteSecretKey: Hashable, Sendable {
    public let server: ServerAddress
    public let account: AccountID?
    public let installation: String
    public let purpose: String

    public init(server: ServerAddress, account: AccountID?, installation: String, purpose: String) {
        self.server = server
        self.account = account
        self.installation = installation
        self.purpose = purpose
    }

    var storageName: String {
        let fields = [server.absoluteString, account?.provider.rawValue ?? "", account?.id ?? "", installation, purpose]
        // Length encoding avoids ambiguous delimiters in untrusted server names.
        return RemoteWire.hash(Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }
}

@MainActor
public protocol RemoteSecretStoring: AnyObject {
    func read(_ key: RemoteSecretKey) throws -> Data?
    func write(_ data: Data, for key: RemoteSecretKey) throws
    func remove(_ key: RemoteSecretKey) throws
}

public enum RemoteKeychainError: Error, Sendable, Equatable {
    case unavailable(OSStatus)
}

/// Device-only, non-synchronizing storage. No insecure fallback on Keychain failure.
@MainActor
public final class KeychainRemoteSecretStore: RemoteSecretStoring {
    private let service: String
    public init(service: String = "com.richlogic.gian.ios.remote.v1") { self.service = service }

    private func query(_ key: RemoteSecretKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key.storageName, kSecAttrSynchronizable as String: false]
    }
    public func read(_ key: RemoteSecretKey) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RemoteKeychainError.unavailable(status) }
        return data
    }
    public func write(_ data: Data, for key: RemoteSecretKey) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(key).merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
            guard added == errSecSuccess else { throw RemoteKeychainError.unavailable(added) }
        } else if status != errSecSuccess { throw RemoteKeychainError.unavailable(status) }
    }
    public func remove(_ key: RemoteSecretKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteKeychainError.unavailable(status) }
    }
}
