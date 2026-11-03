import SwiftUI
import GianCore

/// Main chat screen. The bar centers the conversation title over the current
/// Host (status dot + name), with Back on compact screens. Translation lives
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
    var onToggleAutomaticTranslation: (Bool) -> Void = { _ in }
    var onEditDraft: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onStop: () -> Void = {}
    var onRetryTranslationSend: () -> Void = {}
    var onSendOriginal: () -> Void = {}
    var onCancelTranslationSend: () -> Void = {}
    var onRecoverUncertain: () -> Void = {}
    var onRemoveAttachment: (AttachmentID) -> Void = { _ in }
    var onRetryAttachmentUpload: (AttachmentID) -> Void = { _ in }
    var onPageOlder: () -> Void = {}
    var onRespondToInteraction: (InteractionID, ActionID, [String: InteractionValue]) -> Void = { _, _, _ in }
    var onRequestTranslation: (TranscriptItemID, String) -> Void = { _, _ in }
    var onCancelReadingTranslation: (TranscriptItemID) -> Void = { _ in }
    var onPageTranslation: (TranslationRecordID) -> Void = { _ in }
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if conversation.hasOlderPages {
                        Button("Load earlier messages", action: onPageOlder)
                            .font(GianTheme.Typography.caption)
                            .foregroundStyle(GianTheme.Colors.tint)
                            .gianHitTarget()
                            .padding(.top, GianTheme.Metrics.paddingSmall)
                    }
                    TranscriptView(
                        rows: conversation.rows,
                        translationEnabled: mutationsReady
                            && conversation.translation?.capability == .configured,
                        onRespondToInteraction: mutationsReady ? onRespondToInteraction : { _, _, _ in },
                        onRequestTranslation: onRequestTranslation,
                        onCancelTranslation: { onCancelReadingTranslation($0) },
                        onRetryTranslation: onRequestTranslation,
                        onPageTranslation: onPageTranslation,
                        attachmentPresentation: attachmentPresentation,
                        onDownloadAttachment: mutationsReady ? onDownloadAttachment : { _ in },
                        onPreviewAttachment: previewAttachment
                    )
                    .padding(.top, topOverlayInset)
                }
                .frame(maxWidth: GianTheme.Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: conversation.rows.count) { _, _ in
                // Follow new content only at the tail; reading position
                // is preserved otherwise.
                if let last = conversation.rows.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            TopStatusStack(
                banner: conversation.banner,
                connectivity: conversation.connectivity,
                diagnostic: diagnostic,
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
                HostScopedTitle(title: conversation.title, host: host)
            }
            GlobalToolbarActions(atBottom: globalActionsAtBottom, onNewChat: onOpenNewChat, onSettings: onOpenSettings)
        }
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

    private var topOverlayInset: CGFloat {
        var rows = 0
        if conversation.banner != nil { rows += 1 }
        if conversation.connectivity != .hidden { rows += 1 }
        if diagnostic != .none { rows += 1 }
        return rows > 0 ? CGFloat(rows) * 44 + 12 : 0
    }

    // MARK: - Composer

    private var composerArea: some View {
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
            onSend: onSend,
            onStop: onStop,
            onRetryTranslationSend: onRetryTranslationSend,
            onSendOriginal: onSendOriginal,
            onCancelTranslation: onCancelTranslationSend,
            onRecoverUncertain: onRecoverUncertain,
            onRemoveAttachment: onRemoveAttachment,
            onRetryAttachmentUpload: onRetryAttachmentUpload,
            attachmentPicker: attachmentPicker
        )
        .frame(maxWidth: GianTheme.Metrics.readableWidth)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.bottom, GianTheme.Metrics.paddingSmall)
        .frame(maxWidth: .infinity)
    }
}
