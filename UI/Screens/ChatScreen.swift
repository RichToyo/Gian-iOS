import SwiftUI
import GianCore

/// Main chat screen. Header shows the conversation title and Host only, with
/// a compact-screen Back control. The translation toggle lives near the
/// composer. Banner and connectivity share the non-colliding TopStatusStack.
/// All edits and operations dispatch typed `GianClientAction`s via closures.
struct ChatScreen: View {
    let conversation: ActiveConversationPresentation
    let composer: ComposerProjection
    var showsBack: Bool = true
    /// Authoritative mutation gate from the store; controls stay editable for
    /// drafts, but remote actions (send/interaction/translation/download) are
    /// disabled until catch-up completes.
    var mutationsReady: Bool = true
    var diagnostic: DiagnosticPresentation = .none
    /// UI-local thumbnails captured at attachment pick time.
    var thumbnail: (AttachmentID) -> Image? = { _ in nil }

    var onBack: () -> Void = {}
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

    @State private var previewedAttachment: (id: AttachmentID, name: String, data: Data)?

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                ScrollViewReader { proxy in
                    ScrollView {
                        if conversation.hasOlderPages {
                            Button("Load earlier messages", action: onPageOlder)
                                .font(GianTheme.Typography.caption)
                                .foregroundStyle(GianTheme.Colors.tint)
                                .gianHitTarget()
                                .frame(maxWidth: .infinity)
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
                .padding(.top, GianTheme.Metrics.paddingSmall)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GianTheme.Colors.background)

            composerArea
        }
        .background(GianTheme.Colors.background)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: GianTheme.Metrics.paddingSmall) {
            if showsBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GianTheme.Colors.label)
                        .gianHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            VStack(spacing: 1) {
                Text(conversation.title)
                    .font(GianTheme.Typography.navTitle)
                    .foregroundStyle(GianTheme.Colors.label)
                    .lineLimit(1)
                Text(conversation.hostName)
                    .font(GianTheme.Typography.navSubtitle)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            if showsBack {
                // Balance the back button so the title stays centered.
                Color.clear
                    .frame(
                        width: GianTheme.Metrics.minHitTarget,
                        height: GianTheme.Metrics.minHitTarget
                    )
            }
        }
        .padding(.horizontal, GianTheme.Metrics.paddingSmall)
        .padding(.vertical, 6)
        .background(GianTheme.Colors.card)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(GianTheme.Colors.separator)
                .frame(height: 0.5)
        }
    }

    // MARK: - Composer

    private var composerArea: some View {
        VStack(spacing: 4) {
            if let translation = conversation.translation {
                TranslationToggle(state: translation, onToggleAutomatic: onToggleAutomaticTranslation)
                    .disabled(!mutationsReady)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, GianTheme.Metrics.paddingMedium)
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
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)
            .padding(.bottom, GianTheme.Metrics.paddingSmall)
        }
    }
}
