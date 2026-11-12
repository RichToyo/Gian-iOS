import SwiftUI
import GianCore

/// User message bubble. The original text always renders; a verified sent
/// translation is shown beneath it, labelled, in its own box. Attachments render from
/// Core descriptors with cache-aware download/preview states.
struct UserMessageView: View {
    let row: UserRow
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
    var attachmentIsImage: (AttachmentID) -> Bool = { _ in false }
    var attachmentData: (AttachmentID) -> Data? = { _ in nil }
    var autoLoadImages: Bool = false
    var onDownloadAttachment: (AttachmentID) -> Void = { _ in }
    var onPreviewAttachment: (AttachmentID) -> Void = { _ in }

    @Environment(\.gianAccent) private var accent

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !row.text.isEmpty {
                Text(row.text)
                    .font(GianTheme.Typography.body)
                    .foregroundStyle(accent.text)
                    .textSelection(.enabled)
                .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                .padding(.vertical, GianTheme.Metrics.paddingSmall)
                // Gian's bubble: the soft accent under accent-colored text.
                .background(
                    accent.soft,
                    in: RoundedRectangle(
                        cornerRadius: GianTheme.Metrics.bubbleRadius,
                        style: .continuous
                    )
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("user-message-bubble")
            }
            ForEach(Array(row.attachmentIDs.enumerated()), id: \.element.rawValue) { index, attachmentID in
                TranscriptAttachmentView(
                    presentation: attachmentPresentation(attachmentID),
                    isImage: attachmentIsImage(attachmentID),
                    imageData: { attachmentData(attachmentID) },
                    thumbnailKey: attachmentID.rawValue,
                    autoLoadEnabled: autoLoadImages,
                    attachmentNumber: index + 1,
                    onDownload: { onDownloadAttachment(attachmentID) },
                    onPreview: { onPreviewAttachment(attachmentID) }
                )
            }
            // As on the desktop: the original stays the message; what the Agent
            // received sits beneath it, labelled, in its own box.
            if let sent = row.sentTranslation, let translated = sent.presentableText {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("The translated text sent to the LM is shown below")
                        .font(.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                        .accessibilityIdentifier("sent-translation-label")
                    Text(translated)
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.label)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(GianTheme.Colors.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(GianTheme.Colors.separator, lineWidth: 1)
                        )
                        .accessibilityIdentifier("sent-translation")
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }
}

/// Assistant message: native markdown and a reading translation area.
/// Translate requests, retries, cancels and descriptor
/// paging all dispatch typed actions; nothing is re-requested implicitly.
struct AssistantMessageView: View {
    let row: AssistantRow
    var translationEnabled: Bool = false
    var translationAvailable: Bool = false
    var recoveryEnabled: Bool = false

    var onRequestTranslation: () -> Void = {}
    var onRetryTranslation: () -> Void = {}
    var onCancelTranslation: () -> Void = {}
    var onRecoverTranslation: () -> Void = {}
    /// Pages a descriptor-pending record's full verified text.
    var onPageTranslation: () -> Void = {}

    @State private var translationOverride: Bool?

    private var showsTranslation: Bool { translationOverride ?? row.translationExpandedByDefault }
    private var automaticPageID: TranslationRecordID? {
        guard row.isFinalResult, translationEnabled, showsTranslation, case .needsPaging(let record) = row.reading else { return nil }
        return record.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownView(source: row.markdown)
                // While a reply streams, each step's new lines are uncovered as
                // the message grows (the step glides), rather than cross-faded
                // or drawn over what follows before it has made room.
                .contentTransition(.identity)
                .clipped()
            if row.isFinalResult { translationArea }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.agentName) message")
        .task(id: automaticPageID) {
            if automaticPageID != nil { onPageTranslation() }
        }
    }

    @ViewBuilder
    private var translationArea: some View {
        switch row.reading {
        case .none:
            if translationAvailable {
                Button(action: onRequestTranslation) {
                    Label("Translate", systemImage: "translate")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.tint)
                        .gianHitTarget()
                }
                .buttonStyle(.plain)
                .disabled(!translationEnabled)
            }
        case .translating, .uncertain, .failed, .unavailable:
            ReadingTranslationStatus(
                presentation: row.reading,
                canCancel: row.canCancelTranslation,
                onRetry: onRetryTranslation,
                onCancel: onCancelTranslation,
                onRecover: onRecoverTranslation,
                canRecover: recoveryEnabled
            )
        case .needsPaging:
            HStack(spacing: 6) {
                Text("Translation is large — load the full text.")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                Button("Load", action: onPageTranslation)
                    .font(GianTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.tint)
                    .gianHitTarget()
                    .disabled(!recoveryEnabled)
            }
        case .translated(let record):
            if let text = record.presentableText {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        LanguageTag(label: "Translation · \(record.targetLanguage)")
                        Button(showsTranslation ? "Hide" : "Show") {
                            translationOverride = !showsTranslation
                        }
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.tint)
                        .gianHitTarget()
                    }
                    if showsTranslation {
                        MarkdownView(source: text)
                    }
                }
                .padding(GianTheme.Metrics.paddingMedium)
                .background(
                    GianTheme.Colors.secondaryLabel.opacity(0.08),
                    in: RoundedRectangle(
                        cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                        style: .continuous
                    )
                )
            }
        }
    }
}

extension AssistantMessageView: Equatable {
    /// The closures only dispatch for this row; the row and the flags decide
    /// what renders.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
            && lhs.translationEnabled == rhs.translationEnabled
            && lhs.translationAvailable == rhs.translationAvailable
            && lhs.recoveryEnabled == rhs.recoveryEnabled
    }
}

#Preview("Messages") {
    ScrollView {
        VStack(spacing: 20) {
            UserMessageView(row: UserRow(
                id: TranscriptItemID(rawValue: "u1")!,
                text: "Use this palette as a reference and chart our build times.",
                attachmentIDs: [AttachmentID(rawValue: "remote-file-1")!],
                sentTranslation: SentTranslation(
                    id: TranslationRecordID(rawValue: "tr1")!,
                    presentableText: "Use this palette as a reference to chart our build times.",
                    textLength: 18,
                    textSHA256: "",
                    targetLanguage: "zh",
                    integrity: .inlineVerified
                )
            ))
            AssistantMessageView(
                row: AssistantRow(
                    id: TranscriptItemID(rawValue: "a1")!,
                    agent: .claude,
                    agentName: "Claude",
                    markdown: "Done — Prod is the outlier ([build report](https://example.com)).",
                    reading: .none
                ),
                translationEnabled: true,
                translationAvailable: true
            )
        }
        .padding()
    }
}
