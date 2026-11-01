import SwiftUI

/// Translation controls bound to the contract's per-session translation state.
/// All mutations dispatch typed actions; the Host owns model settings and
/// translation execution.

/// Session-level automatic-translation toggle with the language pair.
/// Unconfigured/unsupported capabilities render honest hints and stay inert.
struct TranslationToggle: View {
    let state: SessionTranslationPresentation
    var onToggleAutomatic: (Bool) -> Void

    var body: some View {
        switch state.capability {
        case .configured:
            Toggle(isOn: Binding(
                get: { state.isAutomatic },
                set: onToggleAutomatic
            )) {
                Label(
                    "\(state.sendingLanguage) ⇄ \(state.readingLanguage)",
                    systemImage: "translate"
                )
                .font(GianTheme.Typography.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("Automatic translation")
            if !state.notice.isEmpty {
                Text(state.notice)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
        case .unconfigured:
            hint(icon: "translate", text: "Translation is not configured on this Host.")
        case .unsupported:
            hint(icon: "exclamationmark.triangle", text: "This Host does not support conversation translation.")
        }
    }

    private func hint(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(GianTheme.Typography.caption)
            .foregroundStyle(GianTheme.Colors.secondaryLabel)
    }
}

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
