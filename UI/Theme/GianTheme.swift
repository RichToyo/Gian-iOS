import SwiftUI

/// Native design tokens for the Gian iOS client.
///
/// Values mirror the approved V2 design board tokens: system-aligned light/dark
/// pairs plus the Gian brand gradient extracted from the current purple icon
/// (`oklch(0.64 0.18 274)` → `oklch(0.73 0.20 328)` → `oklch(0.56 0.18 380)`).
/// All chrome text is English; user content keeps its source language.
enum GianTheme {

    // MARK: - Color

    enum Colors {
        /// App background: #F5F5F7 light / #000000 dark.
        static let background = Color(light: 0xF5F5F7, dark: 0x000000)
        /// Card/content surface: #FFFFFF light / #1C1C1E dark.
        static let card = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
        /// Primary label: #1C1C1E light / #F5F5F7 dark.
        static let label = Color(light: 0x1C1C1E, dark: 0xF5F5F7)
        /// Secondary label, system-aligned.
        static let secondaryLabel = Color(light: 0x8E8E93, dark: 0x8E8E93)
        /// Hairline separator.
        static let separator = Color(
            light: 0x3C3C43, lightOpacity: 0.12,
            dark: 0x545458, darkOpacity: 0.55
        )
        /// Interactive tint (links, primary actions): #0A84FF.
        static let tint = Color(light: 0x0A84FF, dark: 0x0A84FF)
        /// Success / reachable / worked: #34C759.
        static let success = Color(light: 0x34C759, dark: 0x34C759)
        /// Warning / waiting / unknown: #FF9F0A.
        static let warning = Color(light: 0xFF9F0A, dark: 0xFF9F0A)
        /// Failure / destructive: #FF3B30.
        static let failure = Color(light: 0xFF3B30, dark: 0xFF3B30)
        /// Code block background.
        static let codeBackground = Color(light: 0xECECF1, dark: 0x1C1C1E)
        /// User bubble background (iMessage-style blue).
        static let userBubble = Color(light: 0x0A84FF, dark: 0x0A84FF)
        /// Tinted pill backgrounds for status badges.
        static func statusTint(_ color: Color, scheme: ColorScheme) -> Color {
            color.opacity(scheme == .dark ? 0.22 : 0.14)
        }
    }

    // MARK: - Brand

    enum Brand {
        static let gradientStart = Color(light: 0x6D7EF7, dark: 0x6D7EF7)
        static let gradientMid = Color(light: 0xE872E6, dark: 0xE872E6)
        static let gradientEnd = Color(light: 0xC83846, dark: 0xC83846)

        static var gradient: LinearGradient {
            LinearGradient(
                colors: [gradientStart, gradientMid, gradientEnd],
                startPoint: UnitPoint(x: 0, y: 0.2665),
                endPoint: UnitPoint(x: 1, y: 0.7335)
            )
        }
    }

    // MARK: - Typography
    //
    // Built on Dynamic Type text styles so sizes scale with user settings.

    enum Typography {
        /// Conversation titles, section headers.
        static let title = Font.body.weight(.semibold)
        /// Directory rows and message text.
        static let body = Font.body
        /// Repo subtitles, timestamps, metadata.
        static let caption = Font.subheadline
        /// Small badges and pills.
        static let badge = Font.caption.weight(.semibold)
        /// Code and command text.
        static let code = Font.system(.callout, design: .monospaced)
        /// Chat navigation title.
        static let navTitle = Font.headline
        /// Host subtitle under the chat title.
        static let navSubtitle = Font.caption
    }

    // MARK: - Metrics

    enum Metrics {
        static let cornerRadiusSmall: CGFloat = 10
        static let cornerRadiusMedium: CGFloat = 14
        static let cornerRadiusLarge: CGFloat = 22
        static let bubbleRadius: CGFloat = 20
        static let paddingSmall: CGFloat = 8
        static let paddingMedium: CGFloat = 12
        static let paddingLarge: CGFloat = 16
        /// Apple HIG minimum hit target.
        static let minHitTarget: CGFloat = 44
        static let avatarSmall: CGFloat = 24
        static let avatarMedium: CGFloat = 36
        static let avatarLarge: CGFloat = 44
        /// Single-line composer and the matching new-chat entry.
        static let composerHeight: CGFloat = 52
        static let composerRadius: CGFloat = 26
        /// Transcript and composer stop growing past this on wide screens.
        static let readableWidth: CGFloat = 720
        /// Setup flow column width on wide screens.
        static let formWidth: CGFloat = 440
    }
}

// MARK: - Hex color helper

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(light: UInt32, lightOpacity: Double = 1, dark: UInt32, darkOpacity: Double = 1) {
        self.init(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(Color(hex: dark, opacity: darkOpacity))
            }
            return UIColor(Color(hex: light, opacity: lightOpacity))
        })
    }
}
