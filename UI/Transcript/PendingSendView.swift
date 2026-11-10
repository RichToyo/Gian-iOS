import SwiftUI

/// The user's message on its way, as the desktop shows it: the bubble at once
/// (dimmed until the Host has it) with the translation's progress beneath —
/// "Translating • • •" and Send original; after a failure, the error with
/// Retry translation, Send original and Take text back. Nothing is sent or
/// dropped without the user's choice.
struct PendingSendView: View {
    let row: PendingSendRow
    /// Remote actions wait for a ready connection; Take text back never does.
    var actionsEnabled = true
    var onSendOriginal: () -> Void = {}
    var onRetryTranslation: () -> Void = {}
    var onTakeTextBack: () -> Void = {}

    @Environment(\.gianAccent) private var accent

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !row.text.isEmpty {
                Text(row.text)
                    .font(GianTheme.Typography.body)
                    .foregroundStyle(accent.text)
                    .opacity(0.6)
                    .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                    .padding(.vertical, GianTheme.Metrics.paddingSmall)
                    .background(
                        accent.soft,
                        in: RoundedRectangle(cornerRadius: GianTheme.Metrics.bubbleRadius, style: .continuous)
                    )
                    .accessibilityIdentifier("pending-user-message")
            }
            if row.attachmentCount > 0 {
                Label("\(row.attachmentCount) attachment\(row.attachmentCount == 1 ? "" : "s")", systemImage: "paperclip")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        switch row.phase {
        case .translating:
            HStack(spacing: 8) {
                progress("Translating")
                link("Send original", action: onSendOriginal).disabled(!actionsEnabled)
            }
        case .sending(let showsStatus):
            if showsStatus { progress("Sending") }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.failure)
                    .multilineTextAlignment(.trailing)
                HStack(spacing: GianTheme.Metrics.paddingMedium) {
                    link("Retry translation", action: onRetryTranslation).disabled(!actionsEnabled)
                    link("Send original", action: onSendOriginal).disabled(!actionsEnabled)
                    link("Take text back", action: onTakeTextBack)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
            TranslationDots()
        }
        .font(GianTheme.Typography.caption)
        .foregroundStyle(GianTheme.Colors.secondaryLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(GianTheme.Typography.caption)
            .foregroundStyle(accent.text)
            .buttonStyle(.plain)
            .gianHitTarget()
    }
}

/// The desktop's three-dot wave: each dot rises 3 pt and brightens in turn
/// (1.2 s, staggered by 0.15 s); still under Reduce Motion.
struct TranslationDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots { _ in (0, 0.6) }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                dots { index in Self.wave(time - Double(index) * 0.15) }
            }
        }
    }

    private func dots(_ state: @escaping (Int) -> (offset: Double, opacity: Double)) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                let (offset, opacity) = state(index)
                Circle()
                    .frame(width: 4, height: 4)
                    .offset(y: offset)
                    .opacity(opacity)
            }
        }
        .frame(height: 8)
    }

    /// Up to −3 pt and full opacity at 30 % of the cycle, back down by 60 %.
    private static func wave(_ time: Double) -> (offset: Double, opacity: Double) {
        let phase = (time.truncatingRemainder(dividingBy: 1.2) + 1.2).truncatingRemainder(dividingBy: 1.2) / 1.2
        let rise: Double
        if phase < 0.3 { rise = phase / 0.3 } else if phase < 0.6 { rise = 1 - (phase - 0.3) / 0.3 } else { rise = 0 }
        let eased = rise * rise * (3 - 2 * rise)
        return (-3 * eased, 0.35 + 0.65 * eased)
    }
}
