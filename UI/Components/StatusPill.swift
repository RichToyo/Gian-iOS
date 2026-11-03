import SwiftUI

/// Conversation state pill: Working (tint, with spinner), Waiting (amber),
/// Failed (red). Idle rows show no pill.
struct StatusPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let badge: StatusBadge

    var body: some View {
        switch badge {
        case .working, .waiting, .failed:
            HStack(spacing: 4) {
                if badge == .working {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(badgeColor)
                }
                Text(badge.label)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(GianTheme.Typography.badge)
            .foregroundStyle(badgeColor)
            .padding(.horizontal, GianTheme.Metrics.paddingSmall)
            .padding(.vertical, 4)
            .background(
                GianTheme.Colors.statusTint(badgeColor, scheme: colorScheme),
                in: Capsule()
            )
            .accessibilityElement(children: .combine)
        case .idle:
            EmptyView()
        }
    }

    private var badgeColor: Color {
        switch badge {
        case .working: GianTheme.Colors.tint
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
