import SwiftUI
import GianCore

/// Composer bound to the contract composer projection: a one-line box that
/// grows with line breaks, attach (+) on the far left and Send on the far
/// right. Every other option lives behind ⋯ (`moreMenu`). Text edits dispatch
/// `.editDraftText`; Send (or ⌘Return) dispatches `.send`; Stop dispatches `.stop`. Send stays disabled until a
/// draft exists. Translation-stage failures offer Retry
/// (`.retryTranslationSend`) and Send original (`.sendOriginal`);
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
    var placeholder: String = "Message"
    /// Authoritative mutation gate; send/stop/attachment actions disable
    /// until the store is ready. The draft stays editable regardless.
    /// Declared here so the synthesized memberwise argument order matches
    /// every call site (before `thumbnail`).
    var remoteReady: Bool = true
    /// Stop has its own, lighter readiness (it must not gray out mid-turn).
    var stopEnabled: Bool = true
    /// UI-local thumbnails captured at pick time.
    var thumbnail: (AttachmentID) -> Image? = { _ in nil }
    /// True only for an eligible uncertain create, never for uncertain send.
    var canRetryUncertainCreate: Bool = false
    /// Options that are not text, attach or send. Nil hides the ⋯ button.
    var moreMenu: ComposerMoreMenu? = nil

    var onSend: () -> Void = {}
    var onStop: () -> Void = {}
    var onRetryTranslationSend: () -> Void = {}
    var onSendOriginal: () -> Void = {}
    var onCancelTranslation: () -> Void = {}
    var onRecoverUncertain: () -> Void = {}
    var onRetryUncertainCreate: () -> Void = {}
    var onRemoveAttachment: (AttachmentID) -> Void = { _ in }
    var onRetryAttachmentUpload: (AttachmentID) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var attachmentPicker: AttachmentPickerButton = AttachmentPickerButton(onPicked: { _, _ in })

    @FocusState private var isFocused: Bool
    @Environment(\.gianAccent) private var accent
    /// What the field shows while edits travel to the store. Dispatch is
    /// async, so reading the store back mid-typing would drop keystrokes (and
    /// break an input method's marked text). Nil shows the store's draft.
    @State private var localText: String?
    /// Edits sent but not yet reflected by the store, oldest first.
    @State private var pendingEchoes: [String] = []

    private var text: String { localText ?? draft }

    private var fieldText: Binding<String> {
        Binding(
            get: { text },
            set: { value in
                guard value != text else { return }
                localText = value
                pendingEchoes.append(value)
                if pendingEchoes.count > 64 { pendingEchoes.removeFirst(pendingEchoes.count - 64) }
                draft = value
            }
        )
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    private var isBusy: Bool {
        switch sendPhase {
        case .creating, .translating, .sending, .held: true
        case .editable, .failed, .uncertain: false
        }
    }

    private var sendEnabled: Bool {
        canSend && !isBusy && remoteReady && sendPhase != .uncertain
    }

    private var hasAccessory: Bool {
        notice.message != nil || (sendPhase != .editable && sendPhase != .held) || !attachments.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasAccessory {
                VStack(alignment: .leading, spacing: GianTheme.Metrics.paddingSmall) {
                    if let message = notice.message {
                        noticeRow(message)
                    }
                    phaseAccessory
                    if !attachments.isEmpty {
                        attachmentStrip
                    }
                }
                .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                .padding(.top, GianTheme.Metrics.paddingMedium)
            }
            inputRow
        }
        .gianGlassSurface(
            in: RoundedRectangle(
                cornerRadius: GianTheme.Metrics.composerRadius,
                style: .continuous
            )
        )
        .onChange(of: isFocused) { _, focused in
            GianLog.keyboard.debug("composer focus \(focused), busy \(isBusy)")
            onFocusChange(focused)
        }
        .onChange(of: draft) { _, value in
            if let index = pendingEchoes.firstIndex(of: value) {
                // One of our own edits arriving; later ones are still on the way.
                pendingEchoes.removeFirst(index + 1)
                if pendingEchoes.isEmpty, value == localText { localText = nil }
            } else {
                // Changed elsewhere (sent, another conversation's draft): show it.
                pendingEchoes.removeAll()
                localText = nil
            }
        }
    }

    /// + · text · ⋯ · Send/Stop. One line by default; Return adds a line and
    /// the field grows to six lines while the buttons stay on the bottom line.
    /// Send is the button (or ⌘Return on a hardware keyboard).
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            attachmentPicker
                .disabled(isBusy || !remoteReady)
                .padding(.bottom, 4)

            TextField(placeholder, text: fieldText, axis: .vertical)
                .font(GianTheme.Typography.body)
                .lineLimit(1...6)
                .focused($isFocused)
                .disabled(isBusy)
                .padding(.horizontal, 4)
                // Centers a single line in the 52 pt row (≈ 22 pt line + 2 × 15).
                .padding(.vertical, 15)
                // The padding is part of the box: a tap anywhere in it edits.
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            GianLog.keyboard.debug("composer box tapped, busy \(isBusy)")
                            if !isBusy { isFocused = true }
                        }
                }

            if let moreMenu, !moreMenu.isEmpty {
                moreMenu
                    .padding(.bottom, 4)
            }

            trailingButton
                .padding(.trailing, 6)
                .padding(.bottom, 4)
        }
        .frame(minHeight: GianTheme.Metrics.composerHeight)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if isTurnActive && !canSend {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.footnote.weight(.bold))
            }
            .buttonStyle(GianCircularButtonStyle(tint: GianTheme.Colors.failure))
            .disabled(!stopEnabled)
            .accessibilityLabel("Stop")
        } else {
            Button {
                isFocused = false
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
            }
            .buttonStyle(GianCircularButtonStyle(tint: accent.color))
            .disabled(!sendEnabled)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
        }
    }

    // MARK: - Send phase accessory

    @ViewBuilder
    private var phaseAccessory: some View {
        switch sendPhase {
        case .editable, .held:
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
    }
    .padding()
}
