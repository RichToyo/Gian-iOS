import SwiftUI
import GianCore

/// Application entry.
///
/// Production composes `GianLiveClient` over explicit protected SQLite storage
/// and retains it for the application's lifetime. Bootstrap failures render an
/// honest error — no preview or in-memory fallback is ever substituted.
///
/// One long-lived coordinator (owned by the client) consumes events and
/// diagnostics; views contain no socket or stream tasks. Restoration passes
/// only the remembered nonsecret hint to the service factory; the UI never
/// manufactures authorization.
@main
struct GianApp: App {
    private let liveClient: GianLiveClient?
    private let previewStore: GianClientStore?
    private let bootstrapError: GianAppComposition.BootstrapError?

    @MainActor
    init() {
        if let injected = GianAppComposition.makeStoreFromLaunchEnvironment() {
            // Explicit UI-test injection; never a failure fallback.
            self.liveClient = nil
            self.previewStore = injected
            self.bootstrapError = nil
            return
        }
        self.previewStore = nil
        do {
            let client = try GianAppComposition.makeLiveClient()
            client.start()
            self.liveClient = client
            self.bootstrapError = nil
        } catch let error as GianAppComposition.BootstrapError {
            self.liveClient = nil
            self.bootstrapError = error
        } catch {
            self.liveClient = nil
            self.bootstrapError = .clientUnavailable
        }
    }

    var body: some Scene {
        WindowGroup {
            if let liveClient {
                AppRootView(store: liveClient.store)
                    .task {
                        // Restore from cached evidence when a remembered hint
                        // exists. A hint is not authorization; the service
                        // factory alone produces evidence.
                        guard let hint = RestorationHintStore.load() else { return }
                        await liveClient.restoreCachedAuthorization(
                            server: hint.server,
                            account: hint.account,
                            selectedHost: hint.host
                        )
                    }
            } else if let previewStore {
                PreviewStoreContainer(
                    store: previewStore,
                    drivesSetupToReady: GianAppComposition.previewDrivesSetupToReady
                ) { store in
                    AppRootView(store: store)
                }
            } else {
                BootstrapFailureView(error: bootstrapError)
            }
        }
    }
}

/// Honest bootstrap failure surface. No fake data, no silent preview, no raw
/// error text, paths or payloads.
struct BootstrapFailureView: View {
    let error: GianAppComposition.BootstrapError?

    var body: some View {
        ContentUnavailableView(
            "Gian can't start",
            systemImage: "exclamationmark.triangle",
            description: Text(failureDescription)
        )
        .background(GianTheme.Colors.background)
    }

    private var failureDescription: String {
        switch error {
        case .storageUnavailable:
            "Local protected storage could not be opened. No data is shown and nothing is stored in memory instead."
        case .clientUnavailable, nil:
            "The client failed to initialize. No cached or preview data is shown instead."
        }
    }
}
