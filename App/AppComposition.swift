import Foundation
import GianCore

/// Application composition.
///
/// Production uses the frozen wrapper exactly as handed off:
///
/// ```swift
/// let storage = try SQLiteGianStorage.applicationSupport(applicationIdentifier: "dev.gian.ios")
/// let client = try GianLiveClient(storage: storage)
/// client.start()
/// ```
///
/// The client is retained at application lifetime (in `GianApp`), never in a
/// transient view. Construction performs no networking and reads no
/// credentials; failures surface as honest bootstrap errors. There is NO
/// preview or in-memory fallback on the production path.
///
/// Restoration uses only a remembered NONSECRET hint (server/account/Host
/// strings in UserDefaults). The hint is not authorization; evidence comes
/// exclusively from the Remote service factories via
/// `restoreCachedAuthorization(server:account:selectedHost:)`.
enum GianAppComposition {

    /// Sanitized bootstrap failures. Never includes raw OS errors, paths or
    /// payload text.
    enum BootstrapError: Error, Equatable {
        /// Protected local storage could not be opened.
        case storageUnavailable
        /// The live client failed to initialize.
        case clientUnavailable
    }

    /// Production composition. Throws sanitized errors only.
    @MainActor
    static func makeLiveClient() throws -> GianLiveClient {
        let storage: SQLiteGianStorage
        do {
            storage = try SQLiteGianStorage.applicationSupport(
                applicationIdentifier: "dev.gian.ios"
            )
        } catch {
            throw BootstrapError.storageUnavailable
        }
        do {
            return try GianLiveClient(storage: storage)
        } catch {
            throw BootstrapError.clientUnavailable
        }
    }

    /// Explicit preview/test store. Selected ONLY by SwiftUI previews or by
    /// the UI-test launch argument — never as a production fallback. In-memory
    /// storage is explicit here and scoped to the fictional script.
    @MainActor
    static func makePreviewStore(script: PreviewScript) -> GianClientStore {
        GianClientStore(
            service: PreviewGianClientService(script: script),
            clock: SystemGianClock(),
            ids: SequenceIDGenerator(),
            storage: InMemoryGianStorage()
        )
    }

    /// Launch-argument hook for UI tests: `-previewScript legacyContract` or
    /// `-previewScript fullDirectory`. Absent in production operation; never
    /// inferred from failures.
    @MainActor
    static func makeStoreFromLaunchEnvironment() -> GianClientStore? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-previewScript"),
              arguments.indices.contains(flagIndex + 1)
        else { return nil }
        switch arguments[flagIndex + 1] {
        case "legacyContract": return makePreviewStore(script: .legacyContract)
        case "fullDirectory": return makePreviewStore(script: .fullDirectory)
        default: return nil
        }
    }
}

/// Remembers the nonsecret restoration hint (server/account/Host strings).
/// This is not a credential and not authorization evidence.
enum RestorationHintStore {
    private static let serverKey = "gian.hint.server"
    private static let accountKey = "gian.hint.account"
    private static let hostKey = "gian.hint.host"

    struct Hint: Equatable {
        var server: ServerAddress
        var account: AccountID
        var host: HostID?
    }

    static func load() -> Hint? {
        let defaults = UserDefaults.standard
        guard let serverRaw = defaults.string(forKey: serverKey),
              let server = ServerAddress(parsing: serverRaw),
              let accountRaw = defaults.string(forKey: accountKey),
              let account = AccountID(provider: .github, id: accountRaw)
        else { return nil }
        let host = defaults.string(forKey: hostKey).flatMap { HostID(rawValue: $0) }
        return Hint(server: server, account: account, host: host)
    }

    static func save(server: ServerAddress, account: AccountID, host: HostID?) {
        let defaults = UserDefaults.standard
        defaults.set(server.absoluteString, forKey: serverKey)
        defaults.set(account.id, forKey: accountKey)
        defaults.set(host?.rawValue, forKey: hostKey)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: serverKey)
        defaults.removeObject(forKey: accountKey)
        defaults.removeObject(forKey: hostKey)
    }
}
