import SwiftUI
import GianCore

/// User message bubble. The original text always renders; a verified sent
/// translation is shown beneath with a language tag. Attachments render from
/// Core descriptors with cache-aware download/preview states.
struct UserMessageView: View {
    let row: UserRow
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
    var onDownloadAttachment: (AttachmentID) -> Void = { _ in }
    var onPreviewAttachment: (AttachmentID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(row.attachmentIDs, id: \.rawValue) { attachmentID in
                TranscriptAttachmentView(
                    presentation: attachmentPresentation(attachmentID),
                    onDownload: { onDownloadAttachment(attachmentID) },
                    onPreview: { onPreviewAttachment(attachmentID) }
                )
            }

            if !row.text.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(row.text)
                        .font(GianTheme.Typography.body)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)

                    if let sent = row.sentTranslation,
                       let translated = sent.presentableText {
                        Divider().overlay(Color.white.opacity(0.4))
                        HStack(spacing: 6) {
                            LanguageTag(label: "Sent as · \(sent.targetLanguage)")
                            Spacer(minLength: 0)
                        }
                        Text(translated)
                            .font(GianTheme.Typography.body)
                            .foregroundStyle(.white.opacity(0.9))
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                .padding(.vertical, GianTheme.Metrics.paddingSmall)
                .background(
                    GianTheme.Colors.userBubble,
                    in: RoundedRectangle(
                        cornerRadius: GianTheme.Metrics.bubbleRadius,
                        style: .continuous
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }
}

/// Assistant message: agent avatar, native markdown, and a reading
/// translation area. Translate requests, retries, cancels and descriptor
/// paging all dispatch typed actions; nothing is re-requested implicitly.
struct AssistantMessageView: View {
    let row: AssistantRow
    var translationEnabled: Bool = false

    var onRequestTranslation: () -> Void = {}
    var onRetryTranslation: () -> Void = {}
    var onCancelTranslation: () -> Void = {}
    /// Pages a descriptor-pending record's full verified text.
    var onPageTranslation: () -> Void = {}

    @State private var showsTranslation = true

    var body: some View {
        HStack(alignment: .top, spacing: GianTheme.Metrics.paddingSmall) {
            AgentAvatar(logo: row.agent, name: row.agentName, size: GianTheme.Metrics.avatarSmall)
            VStack(alignment: .leading, spacing: 6) {
                MarkdownView(source: row.markdown)
                translationArea
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var translationArea: some View {
        switch row.reading {
        case .none:
            if translationEnabled {
                Button(action: onRequestTranslation) {
                    Label("Translate", systemImage: "translate")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.tint)
                        .gianHitTarget()
                }
                .buttonStyle(.plain)
            }
        case .translating, .uncertain, .failed:
            ReadingTranslationStatus(
                presentation: row.reading,
                onRetry: onRetryTranslation,
                onCancel: onCancelTranslation
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
            }
        case .translated(let record):
            if let text = record.presentableText {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        LanguageTag(label: "Translation · \(record.targetLanguage)")
                        Button(showsTranslation ? "Hide" : "Show") {
                            showsTranslation.toggle()
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
                translationEnabled: true
            )
        }
        .padding()
    }
}
