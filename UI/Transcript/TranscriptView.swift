import SwiftUI
import GianCore

/// Ordered transcript rendering over projected rows. Persisted history
/// renders immediately; live updates arrive as ordered rows from the store.
/// Scroll position is the caller's concern so navigation never loses it.
struct TranscriptView: View {
    let rows: [TranscriptRow]
    var translationEnabled: Bool = false
    var translationAvailable: Bool = false
    var translationRecoveryEnabled: Bool = false

    var onRespondToInteraction: (InteractionID, ActionID, [String: InteractionValue]) -> Void = { _, _, _ in }
    var onRequestTranslation: (String, String) -> Void = { _, _ in }
    var onCancelTranslation: (String) -> Void = { _ in }
    var onRetryTranslation: (String, String) -> Void = { _, _ in }
    var onRecoverTranslation: (String) -> Void = { _ in }
    var onPageTranslation: (TranslationRecordID) -> Void = { _ in }
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
    var attachmentIsImage: (AttachmentID) -> Bool = { _ in false }
    var attachmentData: (AttachmentID) -> Data? = { _ in nil }
    var autoLoadImages: Bool = false
    var onDownloadAttachment: (AttachmentID) -> Void = { _ in }
    var onPreviewAttachment: (AttachmentID) -> Void = { _ in }

    var body: some View {
        LazyVStack(spacing: GianTheme.Metrics.paddingMedium) {
            ForEach(rows) { row in
                switch row {
                case .timeMarker(_, let label):
                    Text(label)
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                        .padding(.vertical, 4)
                        .background(
                            GianTheme.Colors.secondaryLabel.opacity(0.12),
                            in: Capsule()
                        )
                        .frame(maxWidth: .infinity)
                case .user(let userRow):
                    UserMessageView(
                        row: userRow,
                        attachmentPresentation: attachmentPresentation,
                        attachmentIsImage: attachmentIsImage,
                        attachmentData: attachmentData,
                        autoLoadImages: autoLoadImages,
                        onDownloadAttachment: onDownloadAttachment,
                        onPreviewAttachment: onPreviewAttachment
                    )
                case .assistant(let assistantRow):
                    AssistantMessageView(
                        row: assistantRow,
                        translationEnabled: translationEnabled,
                        translationAvailable: translationAvailable,
                        recoveryEnabled: translationRecoveryEnabled,
                        onRequestTranslation: {
                            onRequestTranslation(assistantRow.translationSourceID ?? assistantRow.id.rawValue, assistantRow.markdown)
                        },
                        onRetryTranslation: {
                            onRetryTranslation(assistantRow.translationSourceID ?? assistantRow.id.rawValue, assistantRow.markdown)
                        },
                        onCancelTranslation: {
                            onCancelTranslation(assistantRow.translationSourceID ?? assistantRow.id.rawValue)
                        },
                        onRecoverTranslation: {
                            onRecoverTranslation(assistantRow.translationSourceID ?? assistantRow.id.rawValue)
                        },
                        onPageTranslation: {
                            if case .needsPaging(let record) = assistantRow.reading {
                                onPageTranslation(record.id)
                            }
                        }
                    )
                    // Unchanged messages skip re-rendering (and re-reading their
                    // markdown) while another row streams.
                    .equatable()
                case .work(let card):
                    WorkCardView(card: card)
                        .equatable()
                case .interaction(let record):
                    InteractionCard(record: record) { actionID, values in
                        onRespondToInteraction(record.id, actionID, values)
                    }
                case .turnOutcome(_, let outcome):
                    switch outcome {
                    case .failed:
                        TurnOutcomeRow(outcome: .failed)
                    case .stopped:
                        TurnOutcomeRow(outcome: .stopped)
                    case .worked:
                        EmptyView()
                    }
                case .severeError:
                    TurnOutcomeRow(outcome: .severeError)
                case .notice(_, let severity, let code):
                    noticeRow(severity: severity, code: code)
                }
            }
        }
        .scrollTargetLayout()
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.vertical, GianTheme.Metrics.paddingSmall)
    }

    private func noticeRow(severity: NoticeSeverity, code: String) -> some View {
        HStack(spacing: GianTheme.Metrics.paddingSmall) {
            Image(systemName: severity == .error
                  ? "exclamationmark.octagon"
                  : severity == .warning ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(severity == .error
                                 ? GianTheme.Colors.failure
                                 : severity == .warning ? GianTheme.Colors.warning : GianTheme.Colors.secondaryLabel)
            Text(code)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
