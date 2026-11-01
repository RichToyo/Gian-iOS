import SwiftUI
import GianCore

/// Adaptive root for the ready phase: narrow (compact) shows home → chat
/// navigation; wide (regular / Duo / tablet) keeps the directory left and
/// chat right. Drafts live in the store (per conversation target), so they
/// survive layout changes and navigation by construction. Back and new-chat
/// dismissal dispatch `.returnHome`; no device dimensions are hardcoded.
struct AdaptiveRoot: View {
    let accountLogin: String
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
    var onReturnHome: () -> Void = {}
    var onSignOut: () -> Void = {}
    var onChangeServer: () -> Void = {}
    var onEvictAttachmentCache: () -> Void = {}
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
    var onDownloadAttachment: (AttachmentID) -> Void = { _ in }
    var attachmentData: (AttachmentID) -> Data? = { _ in nil }
    var attachmentDescriptorName: (AttachmentID) -> String = { _ in "Attachment" }
    var serverAddress: String = ""

    @State private var showsSearch = false
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
        .background(GianTheme.Colors.background)
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
                    accountLogin: accountLogin,
                    serverAddress: serverAddress,
                    hosts: hosts,
                    storageError: storageError,
                    serverOutcomeUnconfirmed: serverOutcomeUnconfirmed,
                    invalidationUnconfirmed: invalidationUnconfirmed,
                    appearance: $appearance,
                    onBack: onCloseSettings,
                    onSignOut: onSignOut,
                    onChangeServer: onChangeServer,
                    onEvictAttachmentCache: onEvictAttachmentCache
                )
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { navigation.destination == .newChat },
                set: { if !$0 { onReturnHome() } }
            )
        ) {
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
                attachmentPicker: AttachmentPickerButton(onPicked: onPickAttachment)
            )
        }
    }

    // MARK: - Layouts

    private var narrowLayout: some View {
        NavigationStack {
            HomeScreen(
                accountLogin: accountLogin,
                hosts: hosts,
                directory: directory,
                onOpenSettings: onOpenSettings,
                onOpenSearch: { showsSearch = true },
                onSelectHost: onSelectHost,
                onSelectDirectoryView: onSelectDirectoryView,
                onSelectConversation: onSelectConversation,
                onLoadMoreDirectory: onLoadMoreDirectory,
                onRefreshDirectory: onRefreshDirectory,
                onOpenNewChat: onOpenNewChat
            )
            .navigationDestination(
                isPresented: Binding(
                    get: {
                        if case .conversation = navigation.destination { return true }
                        return false
                    },
                    set: { if !$0 { onReturnHome() } }
                )
            ) {
                chatSurface(showsBack: true, onBack: onReturnHome)
            }
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            DirectorySidebar(
                accountLogin: accountLogin,
                hosts: hosts,
                directory: directory,
                selectedConversationID: conversation?.id,
                onOpenSettings: onOpenSettings,
                onOpenSearch: { showsSearch = true },
                onSelectHost: onSelectHost,
                onSelectDirectoryView: onSelectDirectoryView,
                onSelectConversation: onSelectConversation,
                onLoadMoreDirectory: onLoadMoreDirectory,
                onRefreshDirectory: onRefreshDirectory,
                onOpenNewChat: onOpenNewChat
            )
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            Rectangle()
                .fill(GianTheme.Colors.separator)
                .frame(width: 0.5)

            if conversation != nil {
                chatSurface(showsBack: false, onBack: {})
            } else {
                ContentUnavailableView(
                    "Select a conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation or start a new chat.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GianTheme.Colors.background)
            }
        }
    }

    // MARK: - Chat surface

    private func chatSurface(showsBack: Bool, onBack: @escaping () -> Void) -> some View {
        Group {
            if let conversation {
                ChatScreen(
                    conversation: conversation,
                    composer: composer,
                    showsBack: showsBack,
                    mutationsReady: mutationsReady,
                    diagnostic: diagnostic,
                    thumbnail: thumbnail,
                    onBack: onBack,
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
                    attachmentPicker: AttachmentPickerButton(onPicked: onPickAttachment)
                )
            } else {
                ContentUnavailableView(
                    "Conversation unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("It may have been archived on the Host.")
                )
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Sidebar column for wide layouts (design D): avatar + search, menu-style
/// Host selector, Tasks/Repos segmented list, new-chat bar at the bottom.
struct DirectorySidebar: View {
    let accountLogin: String
    let hosts: [HostItem]
    let directory: DirectoryPresentation
    var selectedConversationID: SessionID? = nil

    var onOpenSettings: () -> Void = {}
    var onOpenSearch: () -> Void = {}
    var onSelectHost: (HostID) -> Void = { _ in }
    var onSelectDirectoryView: (DirectoryView) -> Void = { _ in }
    var onSelectConversation: (SessionID) -> Void = { _ in }
    var onLoadMoreDirectory: (DirectoryCollection) -> Void = { _ in }
    var onRefreshDirectory: (DirectoryCollection) -> Void = { _ in }
    var onOpenNewChat: () -> Void = {}

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingSmall) {
            HStack {
                Button(action: onOpenSettings) {
                    UserAvatar(login: accountLogin, size: GianTheme.Metrics.avatarMedium)
                }
                .buttonStyle(.plain)
                .gianHitTarget()
                Spacer()
                Button(action: onOpenSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                        .foregroundStyle(GianTheme.Colors.label)
                        .gianHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search conversations")
            }
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)

            HostMenuSelector(hosts: hosts, onSelect: onSelectHost)
                .padding(.horizontal, GianTheme.Metrics.paddingMedium)

            DirectorySegmentedControl(selection: Binding(
                get: { directory.view },
                set: onSelectDirectoryView
            ))

            DirectoryContent(
                directory: directory,
                selectedConversationID: selectedConversationID,
                onSelectConversation: onSelectConversation,
                onLoadMore: onLoadMoreDirectory,
                onRefresh: onRefreshDirectory
            )

            NewChatEntryBar(onOpen: onOpenNewChat)
                .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                .padding(.bottom, GianTheme.Metrics.paddingSmall)
        }
        .padding(.top, GianTheme.Metrics.paddingSmall)
        .background(GianTheme.Colors.card)
    }
}
