import SwiftUI
import GianCore

/// Explicit preview/UI-test support. Drives a `PreviewGianClientService`-
/// backed store, optionally through the scripted setup flow into `.ready`.
///
/// The production coordinator owns login polling, so this container provides
/// the equivalent loop for the preview path ONLY (no LiveGianClientService
/// exists there). Selected only by previews and the `-previewScript` launch
/// argument — never by production bootstrap.
struct PreviewStoreContainer<Content: View>: View {
    let store: GianClientStore
    @ViewBuilder var content: (GianClientStore) -> Content

    /// When true, performs the scripted setup to reach `.ready`.
    var drivesSetupToReady: Bool = true
    /// When true, mirrors Core's device-login polling for the preview path.
    var drivesLoginPolling: Bool = true

    var body: some View {
        content(store)
            .task {
                if drivesSetupToReady {
                    await driveToReady()
                }
            }
            .task(id: store.state.phase) {
                await drivePreviewLoginPolling()
            }
    }

    @MainActor
    private func driveToReady() async {
        _ = await store.dispatch(.setServerAddress(PreviewFixtures.server))
        _ = await store.dispatch(.startGitHubDeviceLogin)
        // The scripted poll authorizes immediately.
        _ = await store.dispatch(.pollGitHubDeviceLogin)
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))
    }

    @MainActor
    private func drivePreviewLoginPolling() async {
        guard drivesLoginPolling,
              store.state.phase == .awaitingGitHubDeviceLogin else { return }
        while !Task.isCancelled, store.state.phase == .awaitingGitHubDeviceLogin {
            let nextPoll = store.state.account.deviceLogin?.nextPollAt ?? Date()
            let delay = max(nextPoll.timeIntervalSinceNow, 0.1)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await store.dispatch(.pollGitHubDeviceLogin)
        }
    }
}

#Preview("App · ready (preview service)") {
    PreviewStoreContainer(
        store: GianAppComposition.makePreviewStore(script: .fullDirectory)
    ) { store in
        AppRootView(store: store)
    }
}

#Preview("App · signed out (preview service)") {
    PreviewStoreContainer(
        store: GianAppComposition.makePreviewStore(script: .legacyContract),
        drivesSetupToReady: false
    ) { store in
        AppRootView(store: store)
    }
}
