import SwiftUI
import GianCore

/// Adaptive root for the ready phase: narrow (compact, folded Duo) is a
/// navigation stack whose path follows the store's destination (home → new
/// chat or chat, so a created conversation replaces new chat in place).
/// Expanded portrait uses the same navigation; wide landscape uses a split
/// view with the directory beside the detail column. Drafts live in the store (per
/// conversation target), so they survive layout changes and navigation by
/// construction. Back and new-chat dismissal dispatch `.returnHome`; no device
/// dimensions are hardcoded.
struct AdaptiveRoot: View {
    /// Store values, observed one by one. Each screen below is built inside its
    /// own `PresentationSurface`, so it re-renders only for the values it shows;
    /// this body reads navigation alone.
    let presentation: AppPresentation

    /// UI-local thumbnails captured at attachment pick time.
    var thumbnail: (AttachmentID) -> Image? = { _ in nil }

    // Dispatch closures (wired to `GianClientAction` by AppRootView).
    var onSelectHost: (HostID) -> Void = { _ in }
    var onSelectDirectoryView: (DirectoryView) -> Void = { _ in }
    var onSelectTimeFilter: (DirectoryTimeFilter) -> Void = { _ in }
    var onSelectConversation: (SessionID) -> Void = { _ in }
    var onSelectSearchResult: (SessionID) -> Void = { _ in }
    var onOpenNewChat: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onCloseSettings: () -> Void = {}
    var onSearch: (String) -> Void = { _ in }
    var onClearSearch: () -> Void = {}
    var onLoadMoreDirectory: (DirectoryCollection) -> Void = { _ in }
    var onRefreshDirectory: (DirectoryCollection) -> Void = { _ in }
    var onPullToRefresh: (DirectoryCollection) async -> Void = { _ in }
    var onBannerTap: (BannerID) -> Void = { _ in }
    var onBannerDismiss: (BannerID) -> Void = { _ in }
    var onRetrySynchronization: () -> Void = {}
    var onRetryTranscriptSync: () -> Void = {}
    var onToggleAutomaticTranslation: (Bool) -> Void = { _ in }
    var onEditDraft: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onStop: () -> Void = {}
    var onMutateQueue: (QueueMutation) -> Void = { _ in }
    var onRecoverQueue: () -> Void = {}
    var onRetryTranslationSend: () -> Void = {}
    var onSendOriginal: () -> Void = {}
    var onCancelTranslationSend: () -> Void = {}
    var onRecoverUncertain: () -> Void = {}
    var onRetryUncertainCreate: () -> Void = {}
    var onRemoveAttachment: (AttachmentID) -> Void = { _ in }
    var onRetryAttachmentUpload: (AttachmentID) -> Void = { _ in }
    var onPickAttachment: (AttachmentDraftInput, Image?) -> Void = { _, _ in }
    var onPageOlder: () -> Void = {}
    var onRespondToInteraction: (InteractionID, ActionID, [String: InteractionValue]) -> Void = { _, _, _ in }
    var onRequestTranslation: (String, String) -> Void = { _, _ in }
    var onCancelReadingTranslation: (String) -> Void = { _ in }
    var onRecoverReadingTranslation: (String) -> Void = { _ in }
    var onPageTranslation: (TranslationRecordID) -> Void = { _ in }
    var onSelectWorkspace: (WorkspaceID) -> Void = { _ in }
    var onSelectAgent: (AgentID) -> Void = { _ in }
    var onSelectModel: (String?) -> Void = { _ in }
    var onSelectTask: (TaskID?) -> Void = { _ in }
    var onEditNewChatTitle: (String) -> Void = { _ in }
    var onSetConversationModel: (String?) -> Void = { _ in }
    var onSetConversationThinking: (String?) -> Void = { _ in }
    var onSetConversationFast: (Bool) -> Void = { _ in }
    var onSetConversationApproval: (String?) -> Void = { _ in }
    var onSelectThinking: (String?) -> Void = { _ in }
    var onSelectFast: (Bool) -> Void = { _ in }
    var onSelectApproval: (String?) -> Void = { _ in }
    var onLoadConversationOptions: () -> Void = {}
    var onLoadNewChatOptions: () -> Void = {}
    var onReturnHome: () -> Void = {}
    var onSignOut: () -> Void = {}
    var onChangeServer: (String, String) -> Void = { _, _ in }
    var onEvictAttachmentCache: () -> Void = {}
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
    var attachmentIsImage: (AttachmentID) -> Bool = { _ in false }
    var onDownloadAttachment: (AttachmentID) -> Void = { _ in }
    var attachmentData: (AttachmentID) -> Data? = { _ in nil }
    var attachmentDescriptorName: (AttachmentID) -> String = { _ in "Attachment" }
    /// Pairing another Host from the Host menu or Settings.
    var addHost = AddHostPresentation()

    @State private var showsSearch = false
    @State private var showsAddHost = false
    /// The window's size, from `WindowSizeProbe`.
    @State private var keyboardIndependentSize: CGSize = .zero
    /// This view's size from its first layout, until the probe reports.
    @State private var firstSize: CGSize = .zero
    @State private var appearance: SettingsScreen.Appearance = .system
    @AppStorage("gian.appearance") private var storedAppearance: String = SettingsScreen.Appearance.system.rawValue
    @AppStorage(GianAccent.storageKey) private var storedAccent: String = GianAccent.default.rawValue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isWide: Bool { horizontalSizeClass == .regular }

    // Presentation values, read where each surface builds its screen.
    private var hosts: [HostItem] { presentation.hosts }
    private var directory: DirectoryPresentation { presentation.directory }
    private var navigation: NavigationState { presentation.navigation }
    private var conversation: ActiveConversationPresentation? { presentation.conversation }
    private var composer: ComposerProjection { presentation.composer }
    private var workspaces: [WorkspaceRecord] { presentation.workspaces }
    private var agents: [AgentRecord] { presentation.agents }
    private var openTasks: [TaskGroupItem] { presentation.openTasks }
    /// Authoritative mutation gate from the store.
    private var mutationsReady: Bool { presentation.mutationsReady }
    private var directoryNegotiated: Bool { presentation.directoryNegotiated }
    private var canRetryUncertainCreate: Bool { presentation.canRetryUncertainCreate }
    private var diagnostic: DiagnosticPresentation { presentation.diagnostic }
    /// Honest storage/sync disclosures from the store.
    private var storageError: String? { presentation.storageError }
    private var serverOutcomeUnconfirmed: Bool { presentation.serverOutcomeUnconfirmed }
    private var invalidationUnconfirmed: Bool { presentation.invalidationUnconfirmed }
    /// Model options of the currently selected Agent (Host catalog). Empty or
    /// absent means the legacy Host provides no catalog — no picker renders.
    private var selectedAgentModels: [AgentModelRecord] { presentation.selectedAgentModels }
    /// Composer ⋯ options: the open conversation (`session.update`) and the
    /// new-chat selection (sent with creation).
    private var conversationSettings: ConversationSettingsPresentation? { presentation.conversationSettings }
    private var newChatSettings: ConversationSettingsPresentation? { presentation.newChatSettings }
    private var serverAddress: String { presentation.serverAddress }
    private var accent: GianAccent { GianAccent(rawValue: storedAccent) ?? .default }
    private var openConversationID: SessionID? {
        if case .conversation(let id) = navigation.destination { id } else { nil }
    }

    var body: some View {
        let measured = keyboardIndependentSize == .zero ? firstSize : keyboardIndependentSize
        Group {
            if measured == .zero {
                // The first layout pass, before any size is known.
                GianTheme.Colors.background.ignoresSafeArea()
            } else if WideLayoutOrientation.usesSplitView(size: measured, isRegularWidth: isWide) {
                wideLayout
            } else {
                narrowLayout(isExpandedPortrait: isWide)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // In-app notifications show over every screen, in its own surface so
        // they re-render nothing else.
        .overlay(alignment: .top) {
            PresentationSurface {
                BannerHost(banner: presentation.banner, onTap: onBannerTap, onDismiss: onBannerDismiss)
            }
        }
        // Not a GeometryReader: its content re-runs on every size or safe-area
        // change, so the keyboard (each frame of an interactive dismissal)
        // re-ran this whole body, every screen with it. This keeps a size only
        // until the window probe reports; after that only the window decides.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            if keyboardIndependentSize == .zero, firstSize != size { firstSize = size }
        }
        // The layout follows the window, never the keyboard: re-deciding
        // split vs stack while it is up rebuilds the tree under the focused
        // composer, which dismisses the keyboard again (expanded portrait reads
        // as landscape above a keyboard). A geometry reader can't see the
        // window (even ignoring safe areas it measured an inset rect that bars
        // change), so a UIKit probe reports the window's bounds, which only
        // rotation, folding and resizing change — so a rotation with the
        // keyboard up still re-decides (holding it then kept landscape in the
        // portrait stack, without the list).
        .background {
            WindowSizeProbe { size in
                let split = WideLayoutOrientation.usesSplitView(size: size, isRegularWidth: isWide)
                GianLog.layout.debug("window \(size.width)x\(size.height), regular \(isWide): \(split ? "split" : "stack", privacy: .public)")
                keyboardIndependentSize = size
            }
            .allowsHitTesting(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            GianLog.keyboard.debug("will show \(String(describing: note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]), privacy: .public)")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            GianLog.keyboard.debug("will hide")
        }
        .preferredColorScheme(colorScheme)
        .onAppear {
            appearance = SettingsScreen.Appearance(rawValue: storedAppearance) ?? .system
        }
        .onChange(of: appearance) { _, value in
            storedAppearance = value.rawValue
        }
        .sheet(isPresented: $showsSearch) {
            PresentationSurface {
                SearchScreen(
                    directory: directory,
                    onQueryChange: onSearch,
                    onSelectConversation: { id in
                        showsSearch = false
                        onSelectSearchResult(id)
                    },
                    onLoadMore: onLoadMoreDirectory,
                    onRefresh: onRefreshDirectory,
                    onClose: {
                        showsSearch = false
                        onClearSearch()
                    }
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { navigation.settingsOpen },
                set: { if !$0 { onCloseSettings() } }
            )
        ) {
            NavigationStack {
                PresentationSurface {
                    SettingsScreen(
                        serverAddress: serverAddress,
                        hosts: hosts,
                        storageError: storageError,
                        serverOutcomeUnconfirmed: serverOutcomeUnconfirmed,
                        invalidationUnconfirmed: invalidationUnconfirmed,
                        appearance: $appearance,
                        accent: Binding(get: { accent }, set: { storedAccent = $0.rawValue }),
                        onBack: onCloseSettings,
                        onSignOut: onSignOut,
                        onChangeServer: onChangeServer,
                        onEvictAttachmentCache: onEvictAttachmentCache,
                        addHost: addHost
                    )
                }
            }
        }
        .addHostSheet(isPresented: $showsAddHost, pairing: addHost)
        // Outermost, so the sheets get it too.
        .environment(\.gianAccent, accent)
    }

    private var currentHost: HostItem? {
        hosts.first(where: \.isCurrent)
    }

    /// Compact navigation is a path derived from the store's destination.
    /// New chat is pushed, not presented: when the first send creates the
    /// conversation the path swaps New chat for it in one step, instead of a
    /// cover dismissal racing a push (which landed on Home).
    private enum Route: Hashable {
        case newChat
        case conversation(SessionID)
    }

    private var narrowPath: Binding<[Route]> {
        Binding(
            get: {
                switch navigation.destination {
                case .home: []
                case .newChat: [.newChat]
                case .conversation(let id): [.conversation(id)]
                }
            },
            set: { if $0.isEmpty { onReturnHome() } }
        )
    }

    // MARK: - Layouts

    private func narrowLayout(isExpandedPortrait: Bool) -> some View {
        NavigationStack(path: narrowPath) {
            PresentationSurface { home(selectedConversationID: nil, isSidebar: false, onToggleSidebar: nil) }
                .background(GianTheme.Colors.background)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .newChat:
                        PresentationSurface { newChatScreen }
                            // Close (top of the bar) dismisses; no Back too.
                            .navigationBarBackButtonHidden()
                    case .conversation:
                        PresentationSurface { chatSurface }
                    }
                }
        }
        .environment(\.globalActionsAtBottom, !isExpandedPortrait)
        .environment(\.titlesLeading, isExpandedPortrait)
    }

    /// Expanded landscape keeps the list beside the conversation.
    private var wideLayout: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            PresentationSurface { home(selectedConversationID: openConversationID, isSidebar: true, onToggleSidebar: nil) }
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack {
                PresentationSurface { detailContent }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.globalActionsAtBottom, true)
        .environment(\.titlesLeading, true)
    }

    private func home(selectedConversationID: SessionID?, isSidebar: Bool, onToggleSidebar: (() -> Void)?) -> some View {
        HomeScreen(
            hosts: hosts,
            directory: directory,
            selectedConversationID: selectedConversationID,
            isSidebar: isSidebar,
            onToggleSidebar: onToggleSidebar,
            onOpenSettings: onOpenSettings,
            onOpenSearch: { showsSearch = true },
            onSelectHost: onSelectHost,
            onSelectDirectoryView: onSelectDirectoryView,
            onSelectTimeFilter: onSelectTimeFilter,
            onSelectConversation: onSelectConversation,
            onLoadMoreDirectory: onLoadMoreDirectory,
            onRefreshDirectory: onRefreshDirectory,
            onPullToRefresh: onPullToRefresh,
            onOpenNewChat: onOpenNewChat,
            onAddHost: { showsAddHost = true },
            canLoad: mutationsReady
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch navigation.destination {
        case .newChat:
            newChatScreen
        case .conversation:
            chatSurface
        case .home:
            ContentUnavailableView(
                "Select a conversation",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a conversation or start a new chat.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GianTheme.Colors.background)
            .modifier(PlaceholderToolbar(onNewChat: onOpenNewChat, onSettings: onOpenSettings))
        }
    }

    private var newChatScreen: some View {
        NewChatScreen(
            workspaces: workspaces,
            agents: agents,
            openTasks: openTasks,
            composer: composer,
            translation: nil,
            selectedAgentModels: selectedAgentModels,
            mutationsReady: mutationsReady,
            directoryNegotiated: directoryNegotiated,
            canRetryUncertainCreate: canRetryUncertainCreate,
            thumbnail: thumbnail,
            onSelectWorkspace: onSelectWorkspace,
            onSelectAgent: onSelectAgent,
            onSelectModel: onSelectModel,
            onSelectTask: onSelectTask,
            onEditTitle: onEditNewChatTitle,
            onEditDraft: onEditDraft,
            onSend: onSend,
            onRetryTranslationSend: onRetryTranslationSend,
            onSendOriginal: onSendOriginal,
            onCancelTranslationSend: onCancelTranslationSend,
            onRecoverUncertain: onRecoverUncertain,
            onRetryUncertainCreate: onRetryUncertainCreate,
            onRemoveAttachment: onRemoveAttachment,
            onRetryAttachmentUpload: onRetryAttachmentUpload,
            onClose: onReturnHome,
            attachmentPicker: AttachmentPickerButton(onPicked: onPickAttachment),
            settings: newChatSettings,
            onSelectThinking: onSelectThinking,
            onSetFast: onSelectFast,
            onSelectApproval: onSelectApproval,
            onLoadOptions: onLoadNewChatOptions,
            onOpenSettings: onOpenSettings,
            host: currentHost
        )
    }

    // MARK: - Chat surface

    @ViewBuilder
    private var chatSurface: some View {
        if let conversation {
            ChatScreen(
                conversation: conversation,
                // Read where the composer is built, so typing re-renders the
                // composer and not the transcript.
                composer: { presentation.composer },
                mutationsReady: mutationsReady,
                diagnostic: diagnostic,
                thumbnail: thumbnail,
                onRetrySynchronization: onRetrySynchronization,
                onRetryTranscriptSync: onRetryTranscriptSync,
                onToggleAutomaticTranslation: onToggleAutomaticTranslation,
                onEditDraft: onEditDraft,
                onSend: onSend,
                onStop: onStop,
                onMutateQueue: onMutateQueue,
                onRecoverQueue: onRecoverQueue,
                onRetryTranslationSend: onRetryTranslationSend,
                onSendOriginal: onSendOriginal,
                onCancelTranslationSend: onCancelTranslationSend,
                onRecoverUncertain: onRecoverUncertain,
                onRemoveAttachment: onRemoveAttachment,
                onRetryAttachmentUpload: onRetryAttachmentUpload,
                onPageOlder: onPageOlder,
                onRespondToInteraction: onRespondToInteraction,
                onRequestTranslation: onRequestTranslation,
                onCancelReadingTranslation: onCancelReadingTranslation,
                onRecoverReadingTranslation: onRecoverReadingTranslation,
                onPageTranslation: onPageTranslation,
                attachmentPresentation: attachmentPresentation,
                attachmentIsImage: attachmentIsImage,
                onDownloadAttachment: onDownloadAttachment,
                attachmentData: attachmentData,
                attachmentDescriptorName: attachmentDescriptorName,
                attachmentPicker: AttachmentPickerButton(onPicked: onPickAttachment),
                settings: conversationSettings,
                onSelectModel: onSetConversationModel,
                onSelectThinking: onSetConversationThinking,
                onSetFast: onSetConversationFast,
                onSelectApproval: onSetConversationApproval,
                onLoadOptions: onLoadConversationOptions,
                onOpenNewChat: onOpenNewChat,
                onOpenSettings: onOpenSettings,
                host: currentHost
            )
        } else {
            ContentUnavailableView(
                "Conversation unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("It may have been archived on the Host.")
            )
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum WideLayoutOrientation {
    static func isLandscape(_ size: CGSize) -> Bool { size.width > size.height }
    static func usesSplitView(size: CGSize, isRegularWidth: Bool) -> Bool {
        isRegularWidth && isLandscape(size)
    }
}

/// Reports its window's bounds whenever they change (rotation, folding,
/// resizing). Unlike a geometry reader, the window never shrinks for the
/// keyboard or for bars.
private struct WindowSizeProbe: UIViewRepresentable {
    let onChange: (CGSize) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: UIView {
        var onChange: (CGSize) -> Void = { _ in }
        private var reported: CGSize = .zero

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let size = window?.bounds.size, size.width > 0, size.height > 0, size != reported else { return }
            reported = size
            // Outside the layout pass that noticed it.
            DispatchQueue.main.async { [weak self] in self?.onChange(size) }
        }
    }
}

/// The detail placeholder's global pair, placed for the layout.
private struct PlaceholderToolbar: ViewModifier {
    @Environment(\.globalActionsAtBottom) private var atBottom
    var onNewChat: () -> Void
    var onSettings: () -> Void

    func body(content: Content) -> some View {
        content.toolbar { GlobalToolbarActions(atBottom: atBottom, onNewChat: onNewChat, onSettings: onSettings) }
    }
}
