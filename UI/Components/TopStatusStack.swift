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
        .accessibilityHint("Opens the conversation")
    }
}

/// Connectivity/sync row. Persisted history stays visible while offline;
/// revoked/mismatch states are honest and non-interactive.
struct ConnectivityBar: View {
    let state: ConnectivityPresentation

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .offlineHistory:
            row(icon: "wifi.slash", text: "Offline — showing saved history", color: GianTheme.Colors.secondaryLabel)
        case .reconnecting:
            row(icon: "arrow.triangle.2.circlepath", text: "Reconnecting…", color: GianTheme.Colors.warning)
        case .hostOffline:
            row(icon: "laptopcomputer.slash", text: "Host is offline", color: GianTheme.Colors.warning)
        case .resyncing:
            row(icon: "arrow.triangle.2.circlepath", text: "Catching up…", color: GianTheme.Colors.warning)
        case .deviceRevoked:
            row(icon: "hand.raised.fill", text: "This device's access was revoked. Sign in again.", color: GianTheme.Colors.failure)
        case .versionMismatch(let version):
            row(icon: "exclamationmark.triangle", text: "Host version \(version) is not supported by this app.", color: GianTheme.Colors.failure)
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

/// Top overlay stack for chat screens. The transient banner and the
/// connectivity row are vertically stacked in one container, so they can
/// never overlap; safe-area padding keeps them clear of cards and inputs.
struct TopStatusStack: View {
    var banner: BannerPresentation?
    var connectivity: ConnectivityPresentation
    var diagnostic: DiagnosticPresentation = .none
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
            DiagnosticBar(diagnostic: diagnostic)
            ConnectivityBar(state: connectivity)
        }
        .animation(.spring(duration: 0.3), value: banner)
        .animation(.easeInOut(duration: 0.2), value: connectivity)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
    }
}

/// Sanitized transient diagnostic from the service (login backoff, closed
/// connection, resync). Never raw error text, URLs or payloads.
struct DiagnosticBar: View {
    let diagnostic: DiagnosticPresentation

    var body: some View {
        switch diagnostic {
        case .none:
            EmptyView()
        case .retryingLogin(let message, let retryAt, _):
            row(
                icon: "arrow.clockwise",
                text: "\(message) Retrying sign-in at \(retryAt.formatted(date: .omitted, time: .shortened)).",
                color: GianTheme.Colors.warning
            )
        case .connectionClosed(let message):
            row(icon: "wifi.exclamationmark", text: message, color: GianTheme.Colors.warning)
        case .resyncRequired(let reason):
            row(
                icon: "arrow.triangle.2.circlepath",
                text: "A resync is required (\(reason)).",
                color: GianTheme.Colors.warning
            )
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
            ),
            connectivity: .resyncing
        )
        TopStatusStack(banner: nil, connectivity: .offlineHistory)
    }
    .padding()
}
