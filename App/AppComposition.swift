import Foundation
import CryptoKit
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
            clock: PreviewGianClock.shared,
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
        case "fullDirectory":
            var script = PreviewScript.fullDirectory
            if arguments.contains("-previewHostName") { script.directory.host.name = "Work Gian" }
            if arguments.contains("-previewSentTranslation"),
               let itemID = TranscriptItemID(rawValue: "preview-translated-user"),
               let turnID = TurnID(rawValue: "preview-translated-turn"),
               let translationID = TranslationRecordID(rawValue: "preview-sent-translation") {
                let text = "Hello there."
                let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                let sent = SentTranslation(id: translationID, presentableText: text, textLength: text.utf16.count,
                                           textSHA256: digest, targetLanguage: "en", integrity: .inlineVerified)
                script.transcript.append(TranscriptItem(id: itemID, turnID: turnID, turn: 10,
                    timestamp: PreviewFixtures.instant, body: .user(text: "Hello.", deliveryID: nil, attachmentIDs: [], translation: sent)))
            }
            if arguments.contains("-previewQueue"),
               let index = script.directory.sessions.firstIndex(where: { $0.id == PreviewFixtures.sessionID }) {
                script.directory.sessions[index].status = .running
                script.directory.sessions[index].queue = SessionQueue(revision: "preview-queue-1", entries: [
                    QueuedMessage(id: "preview-queued-1", text: "Fictional queued message")
                ])
            }
            return makePreviewStore(script: script)
        default: return nil
        }
    }

    /// `-previewReady` (alongside `-previewScript`) runs the scripted setup
    /// programmatically so UI tests can start from the home directory.
    static var previewDrivesSetupToReady: Bool {
        ProcessInfo.processInfo.arguments.contains("-previewReady")
    }

    /// `-previewDestination repos|chat|newChat|settings` (with `-previewReady`)
    /// opens that surface once ready, so screenshots need no UI automation.
    static var previewDestination: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-previewDestination"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// Preview time starts at the fixture instant and then advances in real time.
/// Scripted deadlines (the 15-minute device code) are fixture-relative, so a
/// wall clock would see them as long expired once the fixtures are in the past.
@MainActor
final class PreviewGianClock: GianClock {
    static let shared = PreviewGianClock()
    private let offset = PreviewFixtures.instant.timeIntervalSinceNow

    func now() -> Date { Date().addingTimeInterval(offset) }
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
              let account = AccountID(provider: .controller, id: accountRaw)
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
