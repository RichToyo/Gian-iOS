import SwiftUI

/// Conversation state badge: Working (spinner), Waiting (amber), Failed (red).
/// Idle rows show no badge, matching the design board.
struct StatusPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let badge: StatusBadge

    var body: some View {
        switch badge {
        case .working:
            ProgressView()
                .controlSize(.small)
                .tint(GianTheme.Colors.tint)
                .gianHitTarget()
                .accessibilityLabel("Working")
        case .waiting, .failed:
            Text(badge.label)
                .font(GianTheme.Typography.badge)
                .foregroundStyle(badgeColor)
                .padding(.horizontal, GianTheme.Metrics.paddingSmall)
                .padding(.vertical, 4)
                .background(
                    GianTheme.Colors.statusTint(badgeColor, scheme: colorScheme),
                    in: Capsule()
                )
        case .idle:
            EmptyView()
        }
    }

    private var badgeColor: Color {
        switch badge {
        case .waiting: GianTheme.Colors.warning
        case .failed: GianTheme.Colors.failure
        default: GianTheme.Colors.secondaryLabel
        }
    }
}

/// Host reachability dot used by the Host selector.
struct HostReachabilityDot: View {
    let isReachable: Bool

    var body: some View {
        Circle()
            .fill(isReachable ? GianTheme.Colors.success : GianTheme.Colors.secondaryLabel)
            .frame(width: 8, height: 8)
            .accessibilityLabel(isReachable ? "Reachable" : "Unreachable")
    }
}

#Preview("Status pills") {
    VStack(spacing: 12) {
        StatusPill(badge: .working)
        StatusPill(badge: .waiting)
        StatusPill(badge: .failed)
        HStack { HostReachabilityDot(isReachable: true); HostReachabilityDot(isReachable: false) }
    }
    .padding()
}
