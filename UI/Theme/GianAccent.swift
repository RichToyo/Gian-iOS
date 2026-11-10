import SwiftUI

/// Gian's accent presets (desktop Settings → Appearance → Accent): eight evenly
/// spaced hues, Plum by default. The accent tints the user's bubble and the
/// conversation status icons. Every shade is derived from the preset's hue
/// and chroma in OKLCH, per appearance, with the desktop's token lightnesses
/// (`tokens.css`: light and dark themes).
enum GianAccent: String, CaseIterable, Identifiable, Sendable {
    case rose, ember, citron, moss, teal, azure, ink, plum

    static let storageKey = "gian.accent"
    static let `default` = GianAccent.plum

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    private var hue: Double {
        switch self {
        case .rose: 5
        case .ember: 35
        case .citron: 95
        case .moss: 150
        case .teal: 195
        case .azure: 230
        case .ink: 270
        case .plum: 320
        }
    }

    private var chroma: Double {
        switch self {
        case .rose: 0.15
        case .ember, .plum: 0.14
        case .citron, .azure, .ink: 0.13
        case .moss, .teal: 0.11
        }
    }

    /// The Settings swatch, as the desktop draws it.
    var swatch: Color { .oklch(0.55, chroma, hue) }
    /// `--accent`.
    var color: Color { .oklch(light: 0.55, dark: 0.72, chroma: chroma, hue: hue) }
    /// `--accent-text`: text on the soft accent, e.g. the user's bubble.
    var text: Color { .oklch(light: 0.42, dark: 0.80, chroma: chroma, hue: hue) }
    /// `--accent-soft`: the user's bubble.
    var soft: Color { .oklch(light: 0.55, dark: 0.72, chroma: chroma, hue: hue, lightOpacity: 0.12, darkOpacity: 0.18) }

    /// `--g1/--g2/--g3`: the status icon gradient, three stops swept around
    /// the accent hue.
    var statusGradient: [Color] {
        [
            .oklch(light: 0.66, dark: 0.70, chroma: chroma + 0.04, hue: hue - 46),
            .oklch(light: 0.74, dark: 0.80, chroma: chroma + 0.06, hue: hue + 8),
            .oklch(light: 0.58, dark: 0.62, chroma: chroma + 0.04, hue: hue + 60),
        ]
    }

    /// `--gGlow`.
    var statusGlow: Color {
        .oklch(light: 0.74, dark: 0.80, chroma: chroma, hue: hue + 8, lightOpacity: 0.6, darkOpacity: 0.6)
    }
}

extension EnvironmentValues {
    /// The accent chosen in Settings.
    @Entry var gianAccent: GianAccent = .default
}

extension Color {
    /// An OKLCH color, as the desktop's CSS specifies it, rendered in Display
    /// P3 (where the desktop's displays render it) and clipped to that gamut.
    static func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double, opacity: Double = 1) -> Color {
        Color(uiColor: OKLCH(lightness: lightness, chroma: chroma, hue: hue).uiColor(opacity: opacity))
    }

    static func oklch(
        light: Double, dark: Double, chroma: Double, hue: Double,
        lightOpacity: Double = 1, darkOpacity: Double = 1
    ) -> Color {
        let lightColor = OKLCH(lightness: light, chroma: chroma, hue: hue).uiColor(opacity: lightOpacity)
        let darkColor = OKLCH(lightness: dark, chroma: chroma, hue: hue).uiColor(opacity: darkOpacity)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }
}

private struct OKLCH {
    let lightness: Double
    let chroma: Double
    let hue: Double

    func uiColor(opacity: Double) -> UIColor {
        let a = chroma * cos(hue * .pi / 180)
        let b = chroma * sin(hue * .pi / 180)
        // OKLab → LMS → XYZ (D65) → linear Display P3.
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let x = 1.2270138511 * l - 0.5577999807 * m + 0.2812561490 * s
        let y = -0.0405801784 * l + 1.1122568696 * m - 0.0716766787 * s
        let z = -0.0763812845 * l - 0.4214819784 * m + 1.5861632204 * s
        let red = 2.4934969119 * x - 0.9313836179 * y - 0.4027107845 * z
        let green = -0.8294889696 * x + 1.7626640603 * y + 0.0236246858 * z
        let blue = 0.0358458302 * x - 0.0761723893 * y + 0.9568845240 * z
        return UIColor(displayP3Red: Self.encode(red), green: Self.encode(green), blue: Self.encode(blue), alpha: opacity)
    }

    /// The sRGB transfer function, which Display P3 shares.
    private static func encode(_ linear: Double) -> CGFloat {
        let value = min(max(linear, 0), 1)
        return CGFloat(value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055)
    }
}
