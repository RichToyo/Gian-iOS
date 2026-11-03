import SwiftUI
import GianCore

/// Adaptive root for the ready phase: narrow (compact, folded Duo) is a
/// navigation stack whose path follows the store's destination (home → new
/// chat or chat, so a created conversation replaces new chat in place); wide (regular,
/// unfolded Duo, tablet) is a split view with the directory as sidebar and
/// chat or new chat in the detail column. Drafts live in the store (per
/// conversation target), so they survive layout changes and navigation by
/// construction. Back and new-chat dismissal dispatch `.returnHome`; no device
/// dimensions are hardcoded.
struct AdaptiveRoot: View {
    let hosts: [HostItem]
    let directory: DirectoryPresentation
    let navigation: NavigationState
    let conversation: ActiveConversationPresentation?
    let composer: ComposerProjection
    let workspaces: [WorkspaceRecord]
    let agents: [AgentRecord]
    let openTasks: [TaskGroupItem]
    /// Authoritative mutation gate from the store.
    var mutationsReady: Bool = true
    var directoryNegotiated: Bool = false
    var canRetryUncertainCreate: Bool = false
    var diagnostic: DiagnosticPresentation = .none
    /// Honest storage/sync disclosures from the store.
    var storageError: String? = nil
    var serverOutcomeUnconfirmed: Bool = false
    var invalidationUnconfirmed: Bool = false

    /// UI-local thumbnails captured at attachment pick time.
    var thumbnail: (AttachmentID) -> Image? = { _ in nil }

    // Dispatch closures (wired to `GianClientAction` by AppRootView).
    var onSelectHost: (HostID) -> Void = { _ in }
    var onSelectDirectoryView: (DirectoryView) -> Void = { _ in }
    var onSelectConversation: (SessionID) -> Void = { _ in }
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
    var onToggleAutomaticTranslation: (Bool) -> Void = { _ in }
    var onEditDraft: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onStop: () -> Void = {}
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
    var onRequestTranslation: (TranscriptItemID, String) -> Void = { _, _ in }
    var onCancelReadingTranslation: (TranscriptItemID) -> Void = { _ in }
    var onPageTranslation: (TranslationRecordID) -> Void = { _ in }
    var onSelectWorkspace: (WorkspaceID) -> Void = { _ in }
    var onSelectAgent: (AgentID) -> Void = { _ in }
    /// Model options of the currently selected Agent (Host catalog). Empty or
    /// absent means the legacy Host provides no catalog — no picker renders.
    var selectedAgentModels: [AgentModelRecord] = []
    var onSelectModel: (String?) -> Void = { _ in }
    var onSelectTask: (TaskID?) -> Void = { _ in }
    /// Composer ⋯ options: the open conversation (`session.update`) and the
    /// new-chat selection (sent with creation).
    var conversationSettings: ConversationSettingsPresentation? = nil
    var newChatSettings: ConversationSettingsPresentation? = nil
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
    var onChangeServer: (String) -> Void = { _ in }
    var onEvictAttachmentCache: () -> Void = {}
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
    var onDownloadAttachment: (AttachmentID) -> Void = { _ in }
    var attachmentData: (AttachmentID) -> Data? = { _ in nil }
    var attachmentDescriptorName: (AttachmentID) -> String = { _ in "Attachment" }
    var serverAddress: String = ""
    /// Pairing another Host from the Host menu or Settings.
    var addHost = AddHostPresentation()

    @State private var showsSearch = false
    @State private var showsAddHost = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var appearance: SettingsScreen.Appearance = .system
    @AppStorage("gian.appearance") private var storedAppearance: String = SettingsScreen.Appearance.system.rawValue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isWide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if isWide {
                wideLayout
            } else {
                narrowLayout
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear {
            appearance = SettingsScreen.Appearance(rawValue: storedAppearance) ?? .system
        }
        .onChange(of: appearance) { _, value in
            storedAppearance = value.rawValue
        }
        .sheet(isPresented: $showsSearch) {
            SearchScreen(
                directory: directory,
                onQueryChange: onSearch,
                onSelectConversation: { id in
                    showsSearch = false
                    onSelectConversation(id)
                },
                onLoadMore: onLoadMoreDirectory,
                onRefresh: onRefreshDirectory,
                onClose: {
                    showsSearch = false
                    onClearSearch()
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { navigation.settingsOpen },
                set: { if !$0 { onCloseSettings() } }
            )
        ) {
            NavigationStack {
                SettingsScreen(
                            serverAddress: serverAddress,
                    hosts: hosts,
                    storageError: storageError,
                    serverOutcomeUnconfirmed: serverOutcomeUnconfirmed,
                    invalidationUnconfirmed: invalidationUnconfirmed,
                    appearance: $appearance,
                    onBack: onCloseSettings,
                    onSignOut: onSignOut,
                    onChangeServer: onChangeServer,
                    onEvictAttachmentCache: onEvictAttachmentCache,
                    addHost: addHost
                )
            }
        }
        .addHostSheet(isPresented: $showsAddHost, pairing: addHost)
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

    private var narrowLayout: some View {
        NavigationStack(path: narrowPath) {
            home(selectedConversationID: nil, isSidebar: false, onToggleSidebar: nil)
                .background(GianTheme.Colors.background)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .newChat:
                        newChatScreen
                            // Close (top of the bar) dismisses; no Back too.
                            .navigationBarBackButtonHidden()
                    case .conversation:
                        chatSurface
                    }
                }
        }
    }

    /// Landscape keeps the sidebar open beside the chat (nothing to collapse,
    /// no toggle). Portrait shows it as a wider overlay, collapsible from a
    /// toggle on its far left. Size classes are regular both ways on the inner
    /// display, so the split view's own aspect ratio decides.
    private var wideLayout: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            NavigationSplitView(columnVisibility: isLandscape ? .constant(.all) : $columnVisibility) {
                // The detail column's bar (vertical on the unfolded Duo)
                // carries the global actions, so the sidebar keeps list actions.
                home(
                    selectedConversationID: conversation?.id,
                    isSidebar: true,
                    onToggleSidebar: isLandscape ? nil : { withAnimation { columnVisibility = .detailOnly } }
                )
                // Tiled in landscape; in portrait the overlay is the system's
                // 320 pt (wider than the ~250 pt a tiled portrait column got).
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                .toolbar(removing: .sidebarToggle)
            } detail: {
                // Removing the system toggle from the sidebar removes it here
                // too, so portrait supplies its own Show sidebar on the far left.
                NavigationStack {
                    detailContent
                        .toolbar {
                            if !isLandscape, columnVisibility == .detailOnly {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Show sidebar", systemImage: "sidebar.left") {
                                        withAnimation { columnVisibility = .all }
                                    }
                                }
                            }
                        }
                }
            }
            .modifier(SplitStyleModifier(isLandscape: isLandscape))
            // Portrait overlay: show the list when nothing is open, get out of
            // the way once a conversation (or new chat) is.
            // The split view picks its own visibility on first layout, so
            // re-apply after it settles (and on rotation).
            .task(id: isLandscape) {
                try? await Task.sleep(for: .milliseconds(350))
                syncPortraitSidebar(isLandscape: isLandscape)
            }
            .onChange(of: navigation.destination) { _, _ in syncPortraitSidebar(isLandscape: isLandscape) }
        }
    }

    private func syncPortraitSidebar(isLandscape: Bool) {
        guard !isLandscape else { return }
        withAnimation {
            columnVisibility = navigation.destination == .home ? .all : .detailOnly
        }
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
            .toolbar {
                GlobalToolbarActions(onNewChat: onOpenNewChat, onSettings: onOpenSettings)
            }
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
                composer: composer,
                mutationsReady: mutationsReady,
                diagnostic: diagnostic,
                thumbnail: thumbnail,
                onBannerTap: onBannerTap,
                onBannerDismiss: onBannerDismiss,
                onToggleAutomaticTranslation: onToggleAutomaticTranslation,
                onEditDraft: onEditDraft,
                onSend: onSend,
                onStop: onStop,
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
                onPageTranslation: onPageTranslation,
                attachmentPresentation: attachmentPresentation,
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

/// Side-by-side columns in landscape; an overlay sidebar in portrait so it can
/// be wider than a tiled column without squeezing the conversation.
private struct SplitStyleModifier: ViewModifier {
    let isLandscape: Bool

    func body(content: Content) -> some View {
        if isLandscape {
            content.navigationSplitViewStyle(.balanced)
        } else {
            content.navigationSplitViewStyle(.prominentDetail)
        }
    }
}
