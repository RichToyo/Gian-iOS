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
    let content: (GianClientStore) -> Content

    /// When true, performs the scripted setup to reach `.ready`.
    var drivesSetupToReady: Bool = true
    /// When true, mirrors Core's device-login polling for the preview path.
    var drivesLoginPolling: Bool = true

    // Explicit so `content` comes last: the memberwise init orders it before the
    // flags, which breaks trailing-closure calls that pass `drivesSetupToReady:`.
    init(
        store: GianClientStore,
        drivesSetupToReady: Bool = true,
        drivesLoginPolling: Bool = true,
        @ViewBuilder content: @escaping (GianClientStore) -> Content
    ) {
        self.store = store
        self.drivesSetupToReady = drivesSetupToReady
        self.drivesLoginPolling = drivesLoginPolling
        self.content = content
    }

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
        // Core rejects a poll before `nextPollAt`, so let the polling task make
        // the scripted (authorizing) first poll instead of polling here.
        while !Task.isCancelled, store.state.phase == .awaitingGitHubDeviceLogin {
            try? await Task.sleep(for: .milliseconds(100))
        }
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))
        switch GianAppComposition.previewDestination {
        case "repos": _ = await store.dispatch(.selectDirectoryView(.repos))
        case "chat": _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        case "newChat": _ = await store.dispatch(.openNewChat)
        case "settings": _ = await store.dispatch(.openSettings)
        default: break
        }
    }

    @MainActor
    private func drivePreviewLoginPolling() async {
        guard drivesLoginPolling,
              store.state.phase == .awaitingGitHubDeviceLogin else { return }
        while !Task.isCancelled, store.state.phase == .awaitingGitHubDeviceLogin {
            let nextPoll = store.state.account.deviceLogin?.nextPollAt ?? PreviewGianClock.shared.now()
            let delay = max(nextPoll.timeIntervalSince(PreviewGianClock.shared.now()), 0.1)
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
