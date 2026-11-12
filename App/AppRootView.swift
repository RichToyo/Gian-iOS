import SwiftUI
import Network
import CryptoKit
import GianCore

/// When to (re)load Agent logos: per Host, its Agents, and readiness.
struct AgentLogoTrigger: Equatable {
    let host: HostID?
    let pluginIDs: [String]
    let ready: Bool

    @MainActor init(_ store: GianClientStore) {
        host = store.state.currentHostID
        pluginIDs = store.state.agents.map(\.pluginID).sorted()
        ready = store.mutationsReady
    }
}

/// When to (re)load the ⋯ options: per Agent in view, catalog and readiness.
struct AgentOptionsTrigger: Equatable {
    let agent: AgentID?
    let catalogRevision: String
    let ready: Bool

    @MainActor init(_ store: GianClientStore) {
        switch store.state.navigation.destination {
        case .conversation: agent = store.state.conversation?.session.agentID
        case .newChat: agent = store.state.composer.selection.agentID
        case .home: agent = nil
        }
        catalogRevision = store.state.catalogRevision
        ready = store.mutationsReady
    }
}

struct RestorationHintSelection: Equatable {
    let phase: ClientPhase
    let server: ServerAddress?
    let account: AccountID?
    let host: HostID?

    init(_ state: GianClientState) {
        phase = state.phase
        server = state.server
        account = state.account.accountID
        host = state.currentHostID
    }
}

/// Composition root: projects store state into presentation values and wires
/// every UI intent to `GianClientAction` dispatches. Event consumption and
/// diagnostics consumption are owned by Core's coordinator
/// (GianLiveClient); this view forwards only `.setForeground` and
/// `.noteLocalConnectivity`, records the nonsecret restoration hint, and
/// renders sanitized diagnostic/storage disclosures.
struct AppRootView: View {
    let store: GianClientStore

    /// Store values observed one by one; see `AppPresentation`. This body reads
    /// only values that rarely change, so the screens below aren't rebuilt on
    /// every store change.
    @State private var presentation: AppPresentation

    /// UI-local thumbnail cache populated when the user picks an attachment.
    /// Presentation-only; bytes live in the core's scoped memory.
    @State private var thumbnails: [String: Image] = [:]

    @Environment(\.scenePhase) private var scenePhase

    init(store: GianClientStore) {
        self.store = store
        _presentation = State(initialValue: AppPresentation.shared(for: store))
    }

    var body: some View {
        content
            .environment(\.agentLogoImages, presentation.agentLogos)
            .task {
                await observeConnectivity()
            }
            .task {
                await presentation.track(store)
            }
            // Agents' own logos, once the Host is connected and whenever its
            // Agents change.
            .task(id: presentation.logoTrigger) {
                if store.mutationsReady { _ = await store.dispatch(.loadAgentLogos) }
            }
            // The ⋯ options of the Agent in view: (re)read once the Host is
            // ready, so a conversation opened (or restored) mid-resync still
            // gets them.
            .task(id: presentation.optionsTrigger) {
                let trigger = presentation.optionsTrigger
                if trigger.ready, let agent = trigger.agent { _ = await store.dispatch(.loadAgentOptions(agent)) }
            }
            .onChange(of: scenePhase) { _, phase in
                dispatch(.setForeground(phase == .active ? .foreground : .background))
            }
            .onChange(of: presentation.restorationHint) { _, selection in
                recordRestorationHint(selection)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.phase {
        case .ready:
            AdaptiveRoot(
                presentation: presentation,
                thumbnail: { attachmentID in
                    presentation.composer.draft.attachments
                        .first { $0.id == attachmentID }
                        .flatMap { thumbnails[$0.sha256] }
                },
                onSelectHost: { dispatch(.selectHost($0)) },
                onSelectDirectoryView: { dispatch(.selectDirectoryView($0)) },
                onSelectTimeFilter: { dispatch(.setDirectoryTimeFilter(store.state.navigation.directoryView, $0)) },
                onSelectConversation: { dispatch(.selectConversation($0)) },
                onSelectSearchResult: { dispatch(.selectSearchResult($0)) },
                onOpenNewChat: { dispatch(.openNewChat) },
                onOpenSettings: { dispatch(.openSettings) },
                onCloseSettings: { dispatch(.closeSettings) },
                onSearch: { dispatch(.search($0)) },
                onClearSearch: { dispatch(.clearSearch) },
                onLoadMoreDirectory: { dispatch(.loadMoreDirectory($0)) },
                onRefreshDirectory: { dispatch(.refreshDirectoryView($0)) },
                onPullToRefresh: { _ = await store.dispatch(.refreshDirectoryView($0)) },
                onBannerTap: { dispatch(.openBanner($0)) },
                onBannerDismiss: { dispatch(.dismissBanner($0)) },
                onRetrySynchronization: { dispatch(.retrySynchronization) },
                onRetryTranscriptSync: { dispatch(.retryTranscriptSync) },
                onToggleAutomaticTranslation: { dispatch(.setAutoTranslation(enabled: $0)) },
                onEditDraft: { dispatch(.editDraftText($0)) },
                onSend: { dispatch(.send) },
                onStop: { dispatch(.stop) },
                onMutateQueue: { dispatch(.mutateQueue($0)) },
                onRecoverQueue: { dispatch(.recoverQueueCommand) },
                onRetryTranslationSend: { dispatch(.retryTranslationSend) },
                onSendOriginal: { dispatch(.sendOriginal) },
                onCancelTranslationSend: { dispatch(.reclaimTranslationDraft) },
                onRecoverUncertain: { dispatch(.recoverUncertainOperation) },
                onRetryUncertainCreate: { dispatch(.retryUncertainCreate) },
                onRemoveAttachment: { dispatch(.removeDraftAttachment($0)) },
                onRetryAttachmentUpload: { dispatch(.retryAttachmentUpload($0)) },
                onPickAttachment: { input, thumbnail in
                    if let thumbnail {
                        // Keyed by the same SHA-256 hex the core stores on the
                        // draft attachment, so the composer can resolve it.
                        let digest = SHA256.hash(data: input.bytes)
                            .map { String(format: "%02x", $0) }.joined()
                        thumbnails[digest] = thumbnail
                    }
                    dispatch(.addDraftAttachment(input))
                },
                onPageOlder: { dispatch(.pageOlderTranscript) },
                onRespondToInteraction: { dispatch(.respondToInteraction($0, actionID: $1, values: $2)) },
                onRequestTranslation: { dispatch(.requestReadingTranslation(sourceID: $0, text: $1)) },
                onCancelReadingTranslation: { dispatch(.cancelReadingTranslation(sourceID: $0)) },
                onRecoverReadingTranslation: { dispatch(.recoverReadingTranslation(sourceID: $0)) },
                onPageTranslation: { dispatch(.retryTranslationText($0)) },
                onSelectWorkspace: { dispatch(.selectWorkspace($0)) },
                onSelectAgent: { agentID in
                    // Changing Agent resets the model to that Agent's default.
                    dispatch(.selectAgent(agentID))
                    dispatch(.selectModel(nil))
                },
                onSelectModel: { dispatch(.selectModel($0)) },
                onSelectTask: { dispatch(.selectTask($0)) },
                onSetConversationModel: { dispatch(.setConversationModel($0)) },
                onSetConversationThinking: { dispatch(.setConversationThinking($0)) },
                onSetConversationFast: { dispatch(.setConversationFast($0)) },
                onSetConversationApproval: { dispatch(.setConversationApprovalMode($0)) },
                onSelectThinking: { dispatch(.selectThinking($0)) },
                onSelectFast: { dispatch(.selectFast($0)) },
                onSelectApproval: { dispatch(.selectApprovalMode($0)) },
                onLoadConversationOptions: {
                    if let agentID = store.state.conversation?.session.agentID { dispatch(.loadAgentOptions(agentID)) }
                },
                onLoadNewChatOptions: {
                    if let agentID = store.state.composer.selection.agentID { dispatch(.loadAgentOptions(agentID)) }
                },
                onReturnHome: { dispatch(.returnHome) },
                onSignOut: { dispatch(.logout) },
                // Confirmed in Settings first; then sign out and connect to
                // the new server (Host pairing follows).
                onChangeServer: { address, enrollmentToken in
                    Task {
                        await store.dispatch(.logout)
                        await store.dispatch(.setServerAddress(address, enrollmentToken: enrollmentToken))
                    }
                },
                onEvictAttachmentCache: { dispatch(.clearAttachmentCache) },
                // From the presentation: message views call these while
                // rendering, and reading the store there would re-render them
                // on every store change.
                attachmentPresentation: { presentation.attachments[$0]?.presentation ?? .unknown },
                attachmentIsImage: { presentation.attachments[$0]?.isImage ?? false },
                onDownloadAttachment: { dispatch(.downloadAttachment($0)) },
                attachmentData: { store.attachmentData(for: $0) },
                attachmentDescriptorName: {
                    store.transcriptFileDescriptor(for: $0)?.name ?? "Attachment"
                },
                addHost: AddHostPresentation(
                    isWaiting: presentation.pairing.isWaiting,
                    didPair: presentation.pairing.didPair,
                    notice: presentation.pairing.notice,
                    onPairPayload: { dispatch(.beginHostPairingFromQR($0)) },
                    onPairCode: { dispatch(.beginHostPairingWithCode($0)) },
                    onRefresh: { dispatch(.refreshHostPairing) },
                    onReset: { dispatch(.cancelHostPairing) }
                )
            )
        case .signedOut, .serverEntered, .awaitingHostPairing:
            VStack(spacing: 0) {
                DiagnosticBar(diagnostic: StoreProjection.diagnostic(store.serviceDiagnostic))
                    .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                if let storageError = store.state.storageError {
                    Text("Local storage error: \(storageError). Changes may not be saved.")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.failure)
                        .padding(.horizontal, GianTheme.Metrics.paddingLarge)
                }
                if store.serverOutcomeUnconfirmed {
                    Text("The last server sign-out is not confirmed. Local data stays hidden on this device.")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.warning)
                        .padding(.horizontal, GianTheme.Metrics.paddingLarge)
                }
                if store.authorizationInvalidationUnconfirmed {
                    Text("Durable removal of saved authorization could not be confirmed. Do not treat this device as clean after a restart without connecting again.")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.warning)
                        .padding(.horizontal, GianTheme.Metrics.paddingLarge)
                }
                SetupFlowView(
                    phase: store.state.phase,
                    account: store.state.account,
                    server: store.state.server,
                    pendingPairing: store.state.pendingPairing,
                    pairingNotice: StoreProjection.pairingNotice(store.state.pairingOutcome),
                    onSubmitServer: { dispatch(.setServerAddress($0, enrollmentToken: $1)) },
                    onTrustNewServerIdentity: { dispatch(.forgetServerIdentity(enrollmentToken: $0)) },
                    onPairPayload: { dispatch(.beginHostPairingFromQR($0)) },
                    onPairCode: { dispatch(.beginHostPairingWithCode($0)) },
                    onRefreshPairing: { dispatch(.refreshHostPairing) },
                    onStartOver: { dispatch(.logout) }
                )
            }
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ action: GianClientAction) {
        Task { await store.dispatch(action) }
    }

    // MARK: - Restoration hint (nonsecret)

    /// Remembers the selected server/account/Host hint once ready, including
    /// same-phase selection changes, and clears it after logout. The hint is
    /// not authorization; evidence comes only from the Remote service factories.
    private func recordRestorationHint(_ selection: RestorationHintSelection) {
        switch selection.phase {
        case .ready:
            guard let server = selection.server,
                  let account = selection.account
            else { return }
            RestorationHintStore.save(
                server: server,
                account: account,
                host: selection.host
            )
        case .signedOut:
            RestorationHintStore.clear()
        case .serverEntered, .awaitingHostPairing:
            break
        }
    }

    // MARK: - Connectivity forwarding

    /// Local connectivity watch. One long-lived monitor feeding
    /// `.noteLocalConnectivity`; the store decides connection transitions.
    private func observeConnectivity() async {
        let monitor = NWPathMonitor()
        let stream = AsyncStream<LocalConnectivity> { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied ? .available : .unavailable)
            }
            monitor.start(queue: .global(qos: .utility))
            continuation.onTermination = { _ in monitor.cancel() }
        }
        for await connectivity in stream {
            await store.dispatch(.noteLocalConnectivity(connectivity))
        }
    }
}
