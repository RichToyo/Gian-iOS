import SwiftUI

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

#Preview("Host reachability") {
    HStack { HostReachabilityDot(isReachable: true); HostReachabilityDot(isReachable: false) }
        .padding()
}
