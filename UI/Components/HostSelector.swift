import SwiftUI
import GianCore

/// Horizontally scrolling Host selector pills for the narrow home screen.
/// Selection dispatches `.selectHost`; the store owns the current Host.
struct HostPillSelector: View {
    let hosts: [HostItem]
    var onSelect: (HostID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                ForEach(hosts) { host in
                    Button {
                        onSelect(host.id)
                    } label: {
                        HStack(spacing: 6) {
                            HostReachabilityDot(isReachable: host.isReachable)
                            Text(host.name)
                                .font(GianTheme.Typography.body)
                                .foregroundStyle(
                                    host.isCurrent
                                        ? Color.white
                                        : GianTheme.Colors.label
                                )
                        }
                        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                        .frame(minHeight: GianTheme.Metrics.minHitTarget)
                        .background {
                            if host.isCurrent {
                                Capsule().fill(GianTheme.Colors.label)
                            } else {
                                Capsule().fill(GianTheme.Colors.secondaryLabel.opacity(0.14))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(host.isCurrent ? .isSelected : [])
                }
            }
            .padding(.horizontal, GianTheme.Metrics.paddingLarge)
        }
    }
}

/// Menu-style Host selector used in the wide sidebar (design D).
struct HostMenuSelector: View {
    let hosts: [HostItem]
    var onSelect: (HostID) -> Void

    private var current: HostItem? {
        hosts.first(where: \.isCurrent)
    }

    var body: some View {
        Menu {
            ForEach(hosts) { host in
                Button {
                    onSelect(host.id)
                } label: {
                    HStack {
                        Text(host.name)
                        if host.isCurrent {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!host.isReachable)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                Text(current?.name ?? "Select Host")
                    .font(GianTheme.Typography.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                HostReachabilityDot(isReachable: current?.isReachable ?? false)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)
            .frame(minHeight: GianTheme.Metrics.minHitTarget)
            .background(
                GianTheme.Colors.card,
                in: RoundedRectangle(
                    cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                    style: .continuous
                )
                .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
            )
        }
        .accessibilityLabel("Host selector")
    }
}

#Preview("Host selectors") {
    let hosts = [
        HostItem(id: HostID(rawValue: "h1")!, name: "MacBook Pro", isReachable: true, isCurrent: true),
        HostItem(id: HostID(rawValue: "h2")!, name: "Mac Studio", isReachable: true, isCurrent: false),
        HostItem(id: HostID(rawValue: "h3")!, name: "Old iMac", isReachable: false, isCurrent: false),
    ]
    return VStack(spacing: 20) {
        HostPillSelector(hosts: hosts) { _ in }
        HostMenuSelector(hosts: hosts) { _ in }
            .padding(.horizontal)
    }
}
