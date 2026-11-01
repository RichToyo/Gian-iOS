import SwiftUI

/// Agent logo backed by the bundled proxy assets (light/dark aware).
/// Unknown plugins fall back to a neutral SF Symbol, never a fake logo.
struct AgentAvatar: View {
    let logo: AgentLogo
    var name: String = "Agent"
    var size: CGFloat = GianTheme.Metrics.avatarMedium

    var body: some View {
        if let assetName = logo.assetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(
                    cornerRadius: size * 0.24,
                    style: .continuous
                ))
                .accessibilityLabel(name)
        } else {
            Image(systemName: "cpu")
                .font(.system(size: size * 0.5))
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .frame(width: size, height: size)
                .background(
                    GianTheme.Colors.secondaryLabel.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                )
                .accessibilityLabel(name)
        }
    }
}

/// GitHub account avatar. The contract exposes the account login only (no
/// avatar URL), so this renders a brand-gradient identicon with the account
/// initial plus a GitHub-source badge. Tapping opens Settings (parent's job).
struct UserAvatar: View {
    let login: String
    var size: CGFloat = GianTheme.Metrics.avatarMedium

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            identicon
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(
                    cornerRadius: size * 0.24,
                    style: .continuous
                ))
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: size * 0.32))
                .foregroundStyle(.white, GianTheme.Colors.label)
                .background(Circle().fill(GianTheme.Colors.card).padding(-2))
                .offset(x: size * 0.08, y: size * 0.08)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Account \(login). Opens Settings.")
    }

    private var identicon: some View {
        ZStack {
            GianTheme.Brand.gradient
            Text(String(login.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

#Preview("Avatars") {
    HStack(spacing: 16) {
        AgentAvatar(logo: .kimi, name: "Kimi")
        AgentAvatar(logo: .claude, name: "Claude")
        AgentAvatar(logo: .other, name: "Ada")
        UserAvatar(login: "octocat")
    }
    .padding()
}
