import SwiftUI
import GianCore

/// Transient cross-conversation banner. Tap dispatches `.openBanner` (the
/// store navigates and preserves drafts/scroll); dismiss dispatches
/// `.dismissBanner` and keeps the user in place.
struct TransientBanner: View {
    let banner: BannerPresentation
    var onTap: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: GianTheme.Metrics.paddingMedium) {
                AgentAvatar(logo: banner.agent, name: banner.title, size: GianTheme.Metrics.avatarMedium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title)
                        .font(GianTheme.Typography.title)
                        .foregroundStyle(GianTheme.Colors.label)
                        .lineLimit(1)
                    Text(banner.summary)
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
            .padding(.leading, GianTheme.Metrics.paddingMedium)
            .padding(.trailing, 44)
            .padding(.vertical, GianTheme.Metrics.paddingSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .gianHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .background(
            GianTheme.Colors.card,
            in: RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusLarge,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusLarge,
                style: .continuous
            )
            .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transient-banner")
        .accessibilityHint("Opens the conversation")
    }
}

/// Cross-conversation events remain transient; connection state lives in the title.
struct TopStatusStack: View {
    var banner: BannerPresentation?
    var onBannerTap: () -> Void = {}
    var onBannerDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingSmall) {
            if let banner {
                TransientBanner(
                    banner: banner,
                    onTap: onBannerTap,
                    onDismiss: onBannerDismiss
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: banner)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
    }
}

struct ConversationStatusView: View {
    let status: ConversationStatusPresentation
    var onRetryConnection: () -> Void
    var onRetryMessages: () -> Void
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails = true } label: {
            Label(status.label, systemImage: status.symbol)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(status.isError ? GianTheme.Colors.failure : GianTheme.Colors.secondaryLabel)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection status: \(status.label)")
        .accessibilityHint("Shows status details")
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(status.details.enumerated()), id: \.offset) { _, detail in
                    Text(detail).font(GianTheme.Typography.caption)
                }
                if status.retryConnection {
                    Button("Retry connection") { showsDetails = false; onRetryConnection() }
                }
                if status.retryMessages {
                    Button("Retry messages") { showsDetails = false; onRetryMessages() }
                }
            }
            .padding(16)
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 300, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Sanitized transient diagnostic from the service (closed connection,
/// resync). Never raw error text, URLs or payloads.
struct DiagnosticBar: View {
    let diagnostic: DiagnosticPresentation
    var onRetrySynchronization: (() -> Void)? = nil

    var body: some View {
        switch diagnostic {
        case .none:
            EmptyView()
        case .connectionClosed(let message):
            row(icon: "wifi.exclamationmark", text: message, color: GianTheme.Colors.warning)
        case .resyncRequired(let reason):
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                Label("Sync required", systemImage: "arrow.triangle.2.circlepath")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.warning)
                    .accessibilityHint("Reason: \(reason)")
                if let onRetrySynchronization {
                    Button("Retry", action: onRetrySynchronization)
                        .font(GianTheme.Typography.caption.weight(.semibold))
                        .gianHitTarget()
                }
            }
            .frame(maxWidth: .infinity)
            .background(GianTheme.Colors.card)
        }
    }

    private func row(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(GianTheme.Typography.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(GianTheme.Colors.card)
            .accessibilityElement(children: .combine)
    }
}

#Preview("Top status stack") {
    VStack(spacing: 24) {
        TopStatusStack(
            banner: BannerPresentation(
                id: BannerID(rawValue: "b1")!,
                sessionID: SessionID(rawValue: "c9")!,
                agent: .kimi,
                title: "iOS client design board",
                summary: "Task completed",
                eventCount: 2
            )
        )
        ConversationStatusView(status: .make(connectivity: .offlineHistory, diagnostic: .none, transcriptSync: .idle)!,
                               onRetryConnection: {}, onRetryMessages: {})
    }
    .padding()
}
