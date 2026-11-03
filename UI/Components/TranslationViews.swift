import SwiftUI

/// Translation controls bound to the contract's per-session translation state.
/// All mutations dispatch typed actions; the Host owns model settings and
/// translation execution. The automatic-translation toggle lives in the
/// composer's ⋯ menu (`ComposerMoreMenu`).

/// Per-message reading-translation state row: progress with cancel, failure
/// with explicit retry, and an honest uncertain state that never re-requests
/// implicitly.
struct ReadingTranslationStatus: View {
    let presentation: ReadingTranslationPresentation
    var onRetry: () -> Void
    var onCancel: () -> Void

    var body: some View {
        switch presentation {
        case .none, .translated, .needsPaging:
            EmptyView()
        case .translating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Translating…")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                Button("Cancel", action: onCancel)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.tint)
                    .gianHitTarget()
            }
        case .uncertain:
            Label("Translation outcome unknown — not re-requested", systemImage: "exclamationmark.triangle")
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.warning)
        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(GianTheme.Colors.warning)
                Text("Translation failed: \(reason)")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .lineLimit(2)
                Button("Retry", action: onRetry)
                    .font(GianTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.tint)
                    .gianHitTarget()
            }
        }
    }
}

/// Language tag shown when a translation is displayed alongside the original,
/// e.g. "Translation · Chinese" / "Sent as · English".
struct LanguageTag: View {
    let label: String

    var body: some View {
        Text(label)
            .font(GianTheme.Typography.badge)
            .foregroundStyle(GianTheme.Colors.secondaryLabel)
            .padding(.horizontal, GianTheme.Metrics.paddingSmall)
            .padding(.vertical, 2)
            .background(
                GianTheme.Colors.secondaryLabel.opacity(0.12),
                in: Capsule()
            )
    }
}
