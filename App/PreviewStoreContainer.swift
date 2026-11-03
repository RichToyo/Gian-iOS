import SwiftUI
import GianCore

/// Explicit preview/UI-test support. Drives a `PreviewGianClientService`-
/// backed store, optionally through the scripted setup flow into `.ready`.
/// Selected only by previews and the `-previewScript` launch argument, never
/// by production bootstrap.
struct PreviewStoreContainer<Content: View>: View {
    let store: GianClientStore
    let content: (GianClientStore) -> Content

    /// When true, performs the scripted setup to reach `.ready`.
    var drivesSetupToReady: Bool = true

    // Explicit so `content` comes last: the memberwise init orders it before the
    // flag, which breaks trailing-closure calls that pass `drivesSetupToReady:`.
    init(
        store: GianClientStore,
        drivesSetupToReady: Bool = true,
        @ViewBuilder content: @escaping (GianClientStore) -> Content
    ) {
        self.store = store
        self.drivesSetupToReady = drivesSetupToReady
        self.content = content
    }

    var body: some View {
        content(store)
            .task {
                if drivesSetupToReady {
                    await driveToReady()
                }
            }
    }

    @MainActor
    private func driveToReady() async {
        _ = await store.dispatch(.setServerAddress(PreviewFixtures.server))
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))
        switch GianAppComposition.previewDestination {
        case "repos": _ = await store.dispatch(.selectDirectoryView(.repos))
        case "chat": _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        case "newChat": _ = await store.dispatch(.openNewChat)
        case "settings": _ = await store.dispatch(.openSettings)
        default: break
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
