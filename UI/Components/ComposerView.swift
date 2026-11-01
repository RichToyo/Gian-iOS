import SwiftUI
import GianCore

/// Composer bound to the contract composer projection. Text edits dispatch
/// `.editDraftText`; Send dispatches `.send`; Stop dispatches `.stop`.
/// Send stays disabled until a draft exists. Translation-stage failures offer
/// Retry (`.retryTranslationSend`) and Send original (`.sendOriginal`);
/// awaiting-translation offers Cancel (`.reclaimTranslationDraft`). An
/// uncertain outcome offers Check status (`.recoverUncertainOperation`); only
/// an eligible uncertain create also offers explicit same-identity retry.
/// Ordinary Send is disabled for every uncertain stage.
struct ComposerView: View {
    @Binding var draft: String
    let attachments: [DraftAttachment]
    var sendPhase: SendPhasePresentation = .editable
    var notice: ComposerNoticePresentation = .none
    var isTurnActive: Bool = false
    var placeholder: String = "Message…"
    /// Authoritative mutation gate; send/stop/attachment actions disable
    /// until the store is ready. The draft stays editable regardless.
    /// Declared here so the synthesized memberwise argument order matches
    /// every call site (before `thumbnail`).
    var remoteReady: Bool = true
    /// UI-local thumbnails captured at pick time.
    var thumbnail: (AttachmentID) -> Image? = { _ in nil }
    /// True only for an eligible uncertain create, never for uncertain send.
    var canRetryUncertainCreate: Bool = false

    var onSend: () -> Void = {}
    var onStop: () -> Void = {}
    var onRetryTranslationSend: () -> Void = {}
    var onSendOriginal: () -> Void = {}
    var onCancelTranslation: () -> Void = {}
    var onRecoverUncertain: () -> Void = {}
    var onRetryUncertainCreate: () -> Void = {}
    var onRemoveAttachment: (AttachmentID) -> Void = { _ in }
    var onRetryAttachmentUpload: (AttachmentID) -> Void = { _ in }
    var attachmentPicker: AttachmentPickerButton = AttachmentPickerButton(onPicked: { _, _ in })

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    private var isBusy: Bool {
        switch sendPhase {
        case .creating, .translating, .sending: true
        case .editable, .failed, .uncertain: false
        }
    }

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingSmall) {
            if let message = notice.message {
                noticeRow(message)
            }
            phaseAccessory
            if !attachments.isEmpty {
                attachmentStrip
            }
            HStack(alignment: .bottom, spacing: GianTheme.Metrics.paddingSmall) {
                attachmentPicker
                    .disabled(isBusy || !remoteReady)

                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .font(GianTheme.Typography.body)
                    .disabled(isBusy)

                if isTurnActive {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(GianCircularButtonStyle(tint: GianTheme.Colors.failure))
                    .disabled(!remoteReady)
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(GianCircularButtonStyle())
                    .disabled(!canSend || isBusy || !remoteReady || sendPhase == .uncertain)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, GianTheme.Metrics.paddingSmall)
            .padding(.vertical, 6)
        }
        .gianGlassSurface(
            in: RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusLarge,
                style: .continuous
            ),
            interactive: true
        )
    }

    // MARK: - Send phase accessory

    @ViewBuilder
    private var phaseAccessory: some View {
        switch sendPhase {
        case .editable:
            EmptyView()
        case .creating:
            busyRow("Creating conversation…")
        case .translating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Translating…")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                Spacer()
                Button("Cancel", action: onCancelTranslation)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.tint)
                    .gianHitTarget()
            }
        case .sending:
            busyRow("Sending…")
        case .failed(let message, let isTranslationStage):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.failure)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: GianTheme.Metrics.paddingMedium) {
                    if isTranslationStage {
                        Button("Retry translation", action: onRetryTranslationSend)
                            .font(GianTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(GianTheme.Colors.tint)
                            .gianHitTarget()
                        Button("Send original", action: onSendOriginal)
                            .font(GianTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(GianTheme.Colors.tint)
                            .gianHitTarget()
                    } else {
                        Button("Retry send", action: onSend)
                            .font(GianTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(GianTheme.Colors.tint)
                            .gianHitTarget()
                            .disabled(!remoteReady)
                    }
                }
            }
        case .uncertain:
            VStack(alignment: .leading, spacing: GianTheme.Metrics.paddingSmall) {
                Label("Status unknown — not resent", systemImage: "exclamationmark.triangle")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: GianTheme.Metrics.paddingMedium) {
                    Button("Check status", action: onRecoverUncertain)
                        .font(GianTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(GianTheme.Colors.tint)
                        .gianHitTarget()
                        .accessibilityHint("Checks the existing operation without resending it.")
                    if canRetryUncertainCreate {
                        Button("Retry creation", action: onRetryUncertainCreate)
                            .font(GianTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(GianTheme.Colors.tint)
                            .gianHitTarget()
                            .accessibilityLabel("Retry conversation creation")
                            .accessibilityHint("Reuses the original create identity. Does not send the message.")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
            Spacer()
        }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(GianTheme.Colors.warning)
            Text(text)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                ForEach(attachments) { attachment in
                    DraftAttachmentChip(
                        attachment: attachment,
                        thumbnail: thumbnail(attachment.id),
                        onRemove: { onRemoveAttachment(attachment.id) },
                        onRetryUpload: { onRetryAttachmentUpload(attachment.id) }
                    )
                }
            }
            .padding(.horizontal, GianTheme.Metrics.paddingSmall)
        }
    }
}

/// Non-editing long entry on home/directory surfaces: "Start a new chat…".
/// Tapping dispatches `.openNewChat`.
struct NewChatEntryBar: View {
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                Text("Start a new chat…")
                    .font(GianTheme.Typography.body)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                Spacer(minLength: 0)
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(
                        width: GianTheme.Metrics.avatarMedium,
                        height: GianTheme.Metrics.avatarMedium
                    )
                    .background(GianTheme.Colors.tint, in: Circle())
            }
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)
            .padding(.vertical, 6)
            .frame(minHeight: GianTheme.Metrics.minHitTarget)
            .gianGlassSurface(
                in: RoundedRectangle(
                    cornerRadius: GianTheme.Metrics.cornerRadiusLarge,
                    style: .continuous
                ),
                interactive: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a new chat")
    }
}

#Preview("Composer") {
    VStack(spacing: 16) {
        ComposerView(draft: .constant(""), attachments: [])
        ComposerView(
            draft: .constant("Fix the failing snapshot"),
            attachments: [],
            sendPhase: .failed(message: "Translation is unavailable.", isTranslationStage: true),
            notice: .translationNeedsChoice
        )
        ComposerView(draft: .constant("Chart our build times"), attachments: [], sendPhase: .uncertain)
        ComposerView(
            draft: .constant("Retain this first message"),
            attachments: [],
            sendPhase: .uncertain,
            canRetryUncertainCreate: true
        )
        NewChatEntryBar(onOpen: {})
    }
    .padding()
}
