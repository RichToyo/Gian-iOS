import SwiftUI
import GianCore

/// Ordered transcript rendering over projected rows. Persisted history
/// renders immediately; live updates arrive as ordered rows from the store.
/// Scroll position is the caller's concern so navigation never loses it.
struct TranscriptView: View {
    let rows: [TranscriptRow]
    var translationEnabled: Bool = false

    var onRespondToInteraction: (InteractionID, ActionID, [String: InteractionValue]) -> Void = { _, _, _ in }
    var onRequestTranslation: (TranscriptItemID, String) -> Void = { _, _ in }
    var onCancelTranslation: (TranscriptItemID) -> Void = { _ in }
    var onRetryTranslation: (TranscriptItemID, String) -> Void = { _, _ in }
    var onPageTranslation: (TranslationRecordID) -> Void = { _ in }
    var attachmentPresentation: (AttachmentID) -> AttachmentFilePresentation = { _ in .unknown }
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
                        onDownloadAttachment: onDownloadAttachment,
                        onPreviewAttachment: onPreviewAttachment
                    )
                case .assistant(let assistantRow):
                    AssistantMessageView(
                        row: assistantRow,
                        translationEnabled: translationEnabled,
                        onRequestTranslation: {
                            onRequestTranslation(assistantRow.id, assistantRow.markdown)
                        },
                        onRetryTranslation: {
                            onRetryTranslation(assistantRow.id, assistantRow.markdown)
                        },
                        onCancelTranslation: {
                            onCancelTranslation(assistantRow.id)
                        },
                        onPageTranslation: {
                            if case .needsPaging(let record) = assistantRow.reading {
                                onPageTranslation(record.id)
                            }
                        }
                    )
                case .work(let card):
                    WorkCardView(card: card)
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
