import SwiftUI
import UIKit
import GianCore

extension EnvironmentValues {
    /// Agent logos fetched from the current Host, keyed by plugin ID.
    @Entry var agentLogoImages: [String: AgentLogoImages] = [:]
}

/// Resolves an Agent's logo: the Host's own for the current appearance (or
/// the other one), then the bundled copy. Nil means use the name's initial.
@MainActor
enum AgentLogoArt {
    private static let decoded = NSCache<NSData, UIImage>()

    static func image(for logo: AgentLogo, in hostLogos: [String: AgentLogoImages], scheme: ColorScheme) -> UIImage? {
        if let fetched = hostLogos[logo.pluginID] {
            let preferred = scheme == .dark ? fetched.dark ?? fetched.light : fetched.light ?? fetched.dark
            if let data = preferred, let image = decode(data) { return image }
        }
        guard let assetName = logo.assetName else { return nil }
        return UIImage(named: assetName, in: nil, compatibleWith: traits(scheme))
    }

    /// The desktop app's fallback: the name's first letter.
    static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    /// A full-color logo at a fixed size for menu rows, which size images by
    /// their pixels and would tint a template image.
    static func menuIcon(for logo: AgentLogo, name: String, in hostLogos: [String: AgentLogoImages],
                         scheme: ColorScheme, side: CGFloat = 22) -> UIImage {
        let source = image(for: logo, in: hostLogos, scheme: scheme)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let format = UIGraphicsImageRendererFormat(for: traits(scheme))
        let rendered = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            UIBezierPath(roundedRect: bounds, cornerRadius: side * 0.24).addClip()
            if let source, source.size.width > 0, source.size.height > 0 {
                let scale = min(side / source.size.width, side / source.size.height)
                let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                source.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            } else {
                let ink = UIColor.secondaryLabel.resolvedColor(with: traits(scheme))
                ink.withAlphaComponent(0.16).setFill()
                UIRectFill(bounds)
                let letter = initial(of: name) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: side * 0.55, weight: .bold), .foregroundColor: ink,
                ]
                let size = letter.size(withAttributes: attributes)
                letter.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
            }
        }
        return rendered.withRenderingMode(.alwaysOriginal)
    }

    private static func decode(_ data: Data) -> UIImage? {
        if let cached = decoded.object(forKey: data as NSData) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        decoded.setObject(image, forKey: data as NSData)
        return image
    }

    private static func traits(_ scheme: ColorScheme) -> UITraitCollection {
        UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
    }
}

/// An Agent's logo (see `AgentLogo` for where it comes from), or the name's
/// initial when there is none, never a made-up logo.
struct AgentAvatar: View {
    @Environment(\.agentLogoImages) private var hostLogos
    @Environment(\.colorScheme) private var colorScheme
    let logo: AgentLogo
    var name: String = "Agent"
    var size: CGFloat = GianTheme.Metrics.avatarMedium

    var body: some View {
        Group {
            if let image = AgentLogoArt.image(for: logo, in: hostLogos, scheme: colorScheme) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                Text(AgentLogoArt.initial(of: name))
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .frame(width: size, height: size)
                    .background(
                        GianTheme.Colors.secondaryLabel.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    )
            }
        }
        .accessibilityLabel(name)
    }
}

#Preview("Avatars") {
    HStack(spacing: 16) {
        AgentAvatar(logo: .kimi, name: "Kimi")
        AgentAvatar(logo: .claude, name: "Claude")
        AgentAvatar(logo: .other, name: "Ada")
    }
    .padding()
}
