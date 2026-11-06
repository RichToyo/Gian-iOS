import SwiftUI
import GianCore

/// Main chat screen. The bar centers the conversation title over the current
/// conversation, with Back on compact screens. Translation lives
/// in the composer's ⋯ menu. Banner and connectivity share the non-colliding
/// TopStatusStack. All edits and operations dispatch typed `GianClientAction`s
/// via closures.
struct ChatScreen: View {
    let conversation: ActiveConversationPresentation
    let composer: ComposerProjection
    /// Authoritative mutation gate from the store; controls stay editable for
    /// drafts, but remote actions (send/interaction/translation/download) are
    /// disabled until catch-up completes.
    var mutationsReady: Bool = true
    var diagnostic: DiagnosticPresentation = .none
    /// UI-local thumbnails captured at attachment pick time.
    var thumbnail: (AttachmentID) -> Image? = { _ in nil }

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
    var onRemoveAttachment: (AttachmentID) -> Void = { _ in }
    var onRetryAttachmentUpload: (AttachmentID) -> Void = { _ in }
    var onPageOlder: () -> Void = {}
    var onRespondToInteraction: (InteractionID, ActionID, [String: InteractionValue]) -> Void = { _, _, _ in }
    var onRequestTranslation: (String, String) -> Void = { _, _ in }
    var onCancelReadingTranslation: (String) -> Void = { _ in }
    var onRecoverReadingTranslation: (String) -> Void = { _ in }
    var onPageTranslation: (TranslationRecordID) -> Void = { _ in }
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
    var attachmentIsImage: (AttachmentID) -> Bool = { _ in false }
    var onDownloadAttachment: (AttachmentID) -> Void = { _ in }
    var attachmentData: (AttachmentID) -> Data? = { _ in nil }
    var attachmentDescriptorName: (AttachmentID) -> String = { _ in "Attachment" }
    var attachmentPicker: AttachmentPickerButton
    /// Options for the composer's ⋯ (model, thinking, fast, approval).
    var settings: ConversationSettingsPresentation? = nil
    var onSelectModel: (String?) -> Void = { _ in }
    var onSelectThinking: (String?) -> Void = { _ in }
    var onSetFast: (Bool) -> Void = { _ in }
    var onSelectApproval: (String?) -> Void = { _ in }
    /// Reads the Agent's `catalog.agent` options when the conversation opens.
    var onLoadOptions: () -> Void = {}
    /// Global actions stay in the bar inside a conversation.
    var onOpenNewChat: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// The current Host, shown under the title.
    var host: HostItem? = nil

    @Environment(\.globalActionsAtBottom) private var globalActionsAtBottom
    @State private var previewedAttachment: (id: AttachmentID, name: String, data: Data)?
    @State private var followsLatest = true
    @State private var latestScrollRequest = 0
    /// Per-frame scroll bookkeeping; a plain reference, so dragging does not
    /// re-render the transcript.
    @State private var scroll = TranscriptScrollTracker()
    @State private var olderPageAnchor: String?
    @State private var awaitingOlderPage = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if conversation.hasOlderPages {
                        Button("Load earlier messages") {
                            followsLatest = false
                            awaitingOlderPage = true
                            olderPageAnchor = stableAnchor(for: scroll.topRowID)
                            onPageOlder()
                        }
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.tint)
                        .gianHitTarget()
                        .padding(.top, GianTheme.Metrics.paddingSmall)
                    }
                    TranscriptView(
                        rows: conversation.rows,
                        translationEnabled: mutationsReady
                            && conversation.translation?.capability == .configured,
                        translationAvailable: conversation.translation?.capability == .configured,
                        translationRecoveryEnabled: mutationsReady,
                        onRespondToInteraction: mutationsReady ? onRespondToInteraction : { _, _, _ in },
                        onRequestTranslation: onRequestTranslation,
                        onCancelTranslation: { onCancelReadingTranslation($0) },
                        onRetryTranslation: onRequestTranslation,
                        onRecoverTranslation: onRecoverReadingTranslation,
                        onPageTranslation: onPageTranslation,
                        attachmentPresentation: attachmentPresentation,
                        attachmentIsImage: attachmentIsImage,
                        attachmentData: attachmentData,
                        autoLoadImages: mutationsReady,
                        onDownloadAttachment: mutationsReady ? onDownloadAttachment : { _ in },
                        onPreviewAttachment: previewAttachment
                    )
                    Color.clear.frame(height: 1).id("transcript-latest")
                }
                .padding(.top, 144)
                .frame(maxWidth: GianTheme.Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .id(conversation.id)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollPosition(id: Binding(
                get: { scroll.topRowID },
                set: { value in
                    scroll.topRowID = value
                    if awaitingOlderPage && scroll.userScrolling { olderPageAnchor = stableAnchor(for: value) }
                }
            ), anchor: .top)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: TranscriptScrollEdges.self) { geometry in
                return TranscriptScrollEdges(
                    nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY <= 64,
                    viewportHeight: geometry.visibleRect.height,
                    contentHeight: geometry.contentSize.height
                )
            } action: { previous, value in
                scroll.nearBottom = value.nearBottom
                if scroll.userScrolling, followsLatest != value.nearBottom { followsLatest = value.nearBottom }
                // Size changes (streaming text, keyboard, composer) keep the
                // latest line in place.
                if previous.viewportHeight != value.viewportHeight || previous.contentHeight != value.contentHeight {
                    followLatest(proxy, animated: false)
                }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    scroll.userScrolling = true
                case .idle:
                    if scroll.userScrolling {
                        if followsLatest != scroll.nearBottom { followsLatest = scroll.nearBottom }
                        // Back at the latest messages, an unanswered older page no longer holds the view.
                        if scroll.nearBottom { awaitingOlderPage = false; olderPageAnchor = nil }
                    }
                    scroll.userScrolling = false
                default: break
                }
            }
            .onChange(of: TranscriptFollowSignal(rows: conversation.rows)) { old, new in
                if awaitingOlderPage && new.isPrepend(after: old) {
                    if let anchor = olderPageAnchor, new.ids.contains(anchor) { proxy.scrollTo(anchor, anchor: .top) }
                    awaitingOlderPage = false
                    olderPageAnchor = nil
                    return
                }
                if new.shouldFollow(after: old) {
                    followLatest(proxy, animated: false)
                }
            }
            .onChange(of: conversation.id) { _, _ in
                followsLatest = true
                scroll = TranscriptScrollTracker()
                awaitingOlderPage = false
                olderPageAnchor = nil
            }
            .onChange(of: latestScrollRequest) { _, _ in
                awaitingOlderPage = false
                olderPageAnchor = nil
                followLatest(proxy, animated: false, force: true)
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        awaitingOlderPage = false
                        olderPageAnchor = nil
                        followLatest(proxy, animated: true, force: true)
                    } label: {
                        Image(systemName: "arrow.down")
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to latest")
                    .padding(GianTheme.Metrics.paddingMedium)
                }
            }
        }
        .overlay(alignment: .top) {
            TopStatusStack(
                banner: conversation.banner,
                onBannerTap: {
                    if let banner = conversation.banner { onBannerTap(banner.id) }
                },
                onBannerDismiss: {
                    if let banner = conversation.banner { onBannerDismiss(banner.id) }
                }
            )
            .frame(maxWidth: GianTheme.Metrics.readableWidth)
            .padding(.top, GianTheme.Metrics.paddingSmall)
        }
        .safeAreaBar(edge: .bottom) {
            composerArea
        }
        .background(GianTheme.Colors.background)
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: conversation.id) { onLoadOptions() }
        .toolbar {
            // Centered on every layout, including the Duo's vertical-bar one,
            // where the system title sits on the leading edge.
            ToolbarItem(placement: .principal) {
                let status = ConversationStatusPresentation.make(
                    connectivity: conversation.connectivity,
                    diagnostic: diagnostic,
                    transcriptSync: conversation.transcriptSync
                )
                HStack(spacing: 6) {
                    HostScopedTitle(title: conversation.title, host: nil)
                        .accessibilityIdentifier("conversation-title")
                        .layoutPriority(1)
                    if let status {
                        ConversationStatusView(status: status, onRetryConnection: onRetrySynchronization,
                                               onRetryMessages: onRetryTranscriptSync)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: status)
            }
            GlobalToolbarActions(atBottom: globalActionsAtBottom, onNewChat: onOpenNewChat, onSettings: onOpenSettings)
        }
        .toolbarVisibility(.visible, for: .navigationBar)
        .modifier(PersistentChatToolbar())
        .sheet(item: previewBinding) { preview in
            AttachmentPreviewSheet(
                name: preview.name,
                data: preview.data,
                onClose: { previewedAttachment = nil }
            )
        }
    }

    /// Opens the preview sheet only when Core returns verified cached bytes.
    private func previewAttachment(_ id: AttachmentID) {
        guard let data = attachmentData(id) else { return }
        previewedAttachment = (id, attachmentDescriptorName(id), data)
    }

    private struct PreviewItem: Identifiable {
        let id: AttachmentID
        let name: String
        let data: Data
    }

    private var previewBinding: Binding<PreviewItem?> {
        Binding(
            get: {
                previewedAttachment.map { PreviewItem(id: $0.id, name: $0.name, data: $0.data) }
            },
            set: { newValue in
                if newValue == nil { previewedAttachment = nil }
            }
        )
    }

    /// Keeps the latest line in view while following, deferred a turn so the
    /// new layout exists. Following never animates: an animated scroll fights
    /// a swipe that starts during it. Only Jump to latest glides, and size
    /// changes during it wait instead of cutting it short. `force` is the
    /// user's own request (send, focus, Jump to latest), even mid-fling.
    private func followLatest(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        let scroll = scroll
        if animated { scroll.animationEnds = .now + 0.25 }
        func following() -> Bool { force || (followsLatest && !scroll.userScrolling && !awaitingOlderPage) }
        Task { @MainActor in
            await Task.yield()
            guard following() else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("transcript-latest", anchor: .bottom) }
                // Content that grew during the animation is caught up after it.
                try? await Task.sleep(for: .milliseconds(250))
                guard followsLatest, !scroll.userScrolling else { return }
                proxy.scrollTo("transcript-latest", anchor: .bottom)
            } else if force || Date.now >= scroll.animationEnds {
                proxy.scrollTo("transcript-latest", anchor: .bottom)
            }
        }
    }

    private func stableAnchor(for visible: String?) -> String? {
        guard let visible, let index = conversation.rows.firstIndex(where: { $0.id == visible }) else { return visible }
        if case .timeMarker = conversation.rows[index] {
            return conversation.rows.dropFirst(index + 1).first?.id ?? visible
        }
        return visible
    }

    // MARK: - Composer

    private var composerArea: some View {
        VStack(spacing: GianTheme.Metrics.paddingSmall) {
            if conversation.queue?.entries.isEmpty == false || conversation.queueCommand != nil {
                let queue = conversation.queue ?? SessionQueue(revision: "", entries: [])
                QueueList(queue: queue, command: conversation.queueCommand,
                          enabled: mutationsReady, canUpdate: conversation.canUpdateQueue,
                          canRemove: conversation.canRemoveQueue, canClear: conversation.canClearQueue,
                          canSendNow: conversation.canSendQueueNow,
                          onMutation: onMutateQueue, onRecover: onRecoverQueue)
                    .id(conversation.id)
            }
            ComposerView(
            draft: Binding(
                get: { composer.draft.text },
                set: onEditDraft
            ),
            attachments: composer.draft.attachments,
            sendPhase: SendPhasePresentation(composer.send),
            notice: ComposerNoticePresentation(composer.notice),
            isTurnActive: conversation.isTurnActive,
            remoteReady: mutationsReady,
            thumbnail: thumbnail,
            moreMenu: ComposerMoreMenu(
                settings: settings,
                translation: conversation.translation,
                translationEnabled: mutationsReady,
                onSelectModel: onSelectModel,
                onSelectThinking: onSelectThinking,
                onSetFast: onSetFast,
                onSelectApproval: onSelectApproval,
                onToggleAutomaticTranslation: onToggleAutomaticTranslation
            ),
            onSend: {
                followsLatest = true
                latestScrollRequest += 1
                onSend()
            },
            onStop: onStop,
            onRetryTranslationSend: onRetryTranslationSend,
            onSendOriginal: onSendOriginal,
            onCancelTranslation: onCancelTranslationSend,
            onRecoverUncertain: onRecoverUncertain,
            onRemoveAttachment: onRemoveAttachment,
            onRetryAttachmentUpload: onRetryAttachmentUpload,
            onFocusChange: { focused in
                if focused {
                    followsLatest = true
                    latestScrollRequest += 1
                }
            },
            attachmentPicker: attachmentPicker
            )
        }
        .frame(maxWidth: GianTheme.Metrics.readableWidth)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.bottom, GianTheme.Metrics.paddingSmall)
        .frame(maxWidth: .infinity)
    }
}

private struct QueueList: View {
    let queue: SessionQueue
    let command: QueueCommandState?
    let enabled: Bool
    let canUpdate: Bool
    let canRemove: Bool
    let canClear: Bool
    let canSendNow: Bool
    let onMutation: (QueueMutation) -> Void
    let onRecover: () -> Void
    @State private var expanded = true
    @State private var editing: QueuedMessage?
    @State private var showingEditor = false
    @State private var editedText = ""
    @State private var confirmingSendNow = false
    @State private var confirmingClear = false

    private var controlsEnabled: Bool {
        guard enabled else { return false }
        switch command {
        case .pending, .uncertain: return false
        case .failed, nil: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(queue.entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "clock")
                                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                            Text(entry.text.isEmpty ? "Attachment" : entry.text)
                                .lineLimit(2)
                            if entry.attachmentCount > 0 {
                                Label("\(entry.attachmentCount)", systemImage: "paperclip")
                                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                            }
                            Spacer(minLength: 0)
                            if canUpdate {
                                Button {
                                    editing = entry
                                    editedText = entry.text
                                    showingEditor = true
                                } label: { Image(systemName: "pencil").frame(width: 36, height: 36).contentShape(Rectangle()) }
                                    .accessibilityLabel("Edit queued message")
                                    .disabled(!controlsEnabled)
                            }
                            if canRemove {
                                Button { onMutation(.remove(id: entry.id)) } label: {
                                    Image(systemName: "xmark").frame(width: 36, height: 36).contentShape(Rectangle())
                                }
                                    .accessibilityLabel("Remove queued message")
                                    .disabled(!controlsEnabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(GianTheme.Typography.caption)
                .padding(.top, 8)
            }
            .frame(maxHeight: 120)
        } label: {
            HStack {
                Label("Queued (\(queue.entries.count))", systemImage: "text.line.first.and.arrowtriangle.forward")
                Spacer()
                if canSendNow && !queue.entries.isEmpty {
                    Button { confirmingSendNow = true } label: {
                        Image(systemName: "arrow.up.circle").frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                        .accessibilityLabel("Send queue now")
                        .disabled(!controlsEnabled)
                }
                if canClear && !queue.entries.isEmpty {
                    Button { confirmingClear = true } label: {
                        Image(systemName: "trash").frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                        .accessibilityLabel("Clear queued messages")
                        .disabled(!controlsEnabled)
                }
            }
            .font(GianTheme.Typography.caption)
        }
        switch command {
        case .pending: ProgressView().controlSize(.mini)
        case .uncertain: Button("Check queue status", action: onRecover).font(GianTheme.Typography.caption)
        case .failed(let message): Text(message).font(GianTheme.Typography.caption).foregroundStyle(GianTheme.Colors.failure).lineLimit(2)
        case nil: EmptyView()
        }
        }
        .alert("Edit queued message", isPresented: $showingEditor) {
            TextField("Message", text: $editedText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let editing { onMutation(.update(id: editing.id, text: editedText)) }
                editing = nil
            }
        }
        .confirmationDialog("Send queued messages now?",
                            isPresented: $confirmingSendNow, titleVisibility: .visible) {
            Button("Send now") { onMutation(.sendNow) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("While a turn is running, all queued messages are steered into it. Otherwise, the next queued message starts a new turn.")
        }
        .confirmationDialog("Clear all queued messages?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear queue", role: .destructive) { onMutation(.clear) }
            Button("Cancel", role: .cancel) {}
        }
        .padding(10)
        .background(GianTheme.Colors.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
private final class TranscriptScrollTracker {
    var topRowID: String?
    var nearBottom = true
    var userScrolling = false
    var animationEnds = Date.distantPast
}

private struct TranscriptScrollEdges: Equatable {
    let nearBottom: Bool
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
}

private struct PersistentChatToolbar: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content
                .toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            content
        }
    }
}

struct TranscriptFollowSignal: Equatable {
    let ids: [String]
    let lastAssistantID: String?
    let lastAssistantText: String?

    init(rows: [TranscriptRow]) {
        ids = rows.map(\.id)
        let assistant = rows.reversed().compactMap { row -> AssistantRow? in
            if case .assistant(let item) = row { return item }
            return nil
        }.first
        lastAssistantID = assistant?.id.rawValue
        lastAssistantText = assistant?.markdown
    }

    func shouldFollow(after old: TranscriptFollowSignal) -> Bool {
        if isPrepend(after: old) { return false }
        return ids.last != old.ids.last || lastAssistantID != old.lastAssistantID || lastAssistantText != old.lastAssistantText
    }

    func isPrepend(after old: TranscriptFollowSignal) -> Bool {
        let current = Set(ids)
        guard let shared = old.ids.first(where: { current.contains($0) }),
              let oldIndex = old.ids.firstIndex(of: shared), let newIndex = ids.firstIndex(of: shared) else { return false }
        return newIndex > oldIndex
    }
}
