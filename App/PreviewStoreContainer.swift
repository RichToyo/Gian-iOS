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
        _ = await store.dispatch(.setServerAddress(PreviewFixtures.server, enrollmentToken: PreviewFixtures.enrollmentToken))
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))
        switch GianAppComposition.previewDestination {
        case "repos": _ = await store.dispatch(.selectDirectoryView(.repos))
        case "chat": _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        case "chatLong", "chatLongStream":
            _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
            if let server = ServerAddress(parsing: PreviewFixtures.server) {
                let scope = ClientScope(server: server, account: PreviewFixtures.account, host: PreviewFixtures.hostID)
                for number in 1...30 {
                    guard let itemID = TranscriptItemID(rawValue: "preview-scroll-message-\(number)"),
                          let turnID = TurnID(rawValue: "preview-scroll-turn-\(number)") else { continue }
                    let item = TranscriptItem(id: itemID, turnID: turnID, turn: number,
                                              timestamp: PreviewFixtures.instant.addingTimeInterval(Double(number)),
                                              body: .assistant(text: "Preview message \(number)", delta: false))
                    _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: item)))
                }
                if GianAppComposition.previewDestination == "chatLongStream",
                   let itemID = TranscriptItemID(rawValue: "preview-long-stream-message"),
                   let turnID = TurnID(rawValue: "preview-long-stream-turn") {
                    for number in 1...100 {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        let item = TranscriptItem(id: itemID, turnID: turnID, turn: 31,
                                                  timestamp: PreviewFixtures.instant.addingTimeInterval(Double(30 + number)),
                                                  body: .assistant(text: "Preview update ", delta: true))
                        _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: item)))
                    }
                }
            }
        case "chatStream":
            _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
            if let server = ServerAddress(parsing: PreviewFixtures.server),
               let itemID = TranscriptItemID(rawValue: "preview-stream-message"),
               let turnID = TurnID(rawValue: "preview-stream-turn") {
                let scope = ClientScope(server: server, account: PreviewFixtures.account, host: PreviewFixtures.hostID)
                for number in 1...100 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    let item = TranscriptItem(id: itemID, turnID: turnID, turn: 10,
                                              timestamp: PreviewFixtures.instant.addingTimeInterval(Double(number)),
                                              body: .assistant(text: "Preview update ", delta: true))
                    _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: PreviewFixtures.sessionID, item: item)))
                }
            }
        case "chatWithBanner":
            _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
            if let server = ServerAddress(parsing: PreviewFixtures.server),
               let session = SessionID(rawValue: "session-night"),
               let itemID = TranscriptItemID(rawValue: "preview-banner-message"),
               let turnID = TurnID(rawValue: "preview-banner-turn") {
                let scope = ClientScope(server: server, account: PreviewFixtures.account, host: PreviewFixtures.hostID)
                let item = TranscriptItem(id: itemID, turnID: turnID, turn: 1, timestamp: PreviewFixtures.instant,
                                          body: .assistant(text: "Fictional notification", delta: false))
                _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: session, item: item)))
            }
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
