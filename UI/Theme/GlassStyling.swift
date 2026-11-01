import SwiftUI

/// Liquid Glass treatments for control and navigation layers.
///
/// Glass is reserved for chrome (bars, pills, banners, buttons); content stays
/// on solid readable surfaces. When Reduce Transparency is enabled every glass
/// surface falls back to an opaque card fill so contrast never depends on blur.
enum GlassStyling {}

// MARK: - Surface modifier

struct GianGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var shape: AnyShape = AnyShape(Capsule())
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(GianTheme.Colors.card, in: shape)
                .overlay(shape.stroke(GianTheme.Colors.separator, lineWidth: 0.5))
        } else {
            content
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
        }
    }
}

extension View {
    /// Applies the standard Gian glass surface (Liquid Glass, or an opaque
    /// fallback under Reduce Transparency) to a control-layer element.
    func gianGlassSurface<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(GianGlassSurface(shape: AnyShape(shape), interactive: interactive))
    }

    /// Guarantees the Apple HIG 44pt minimum hit target without changing layout.
    func gianHitTarget() -> some View {
        frame(
            minWidth: GianTheme.Metrics.minHitTarget,
            minHeight: GianTheme.Metrics.minHitTarget
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Button styles

/// Primary filled action (Send, Allow once).
struct GianPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GianTheme.Typography.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: GianTheme.Metrics.minHitTarget)
            .background(
                GianTheme.Colors.tint.opacity(isEnabled ? 1 : 0.35),
                in: RoundedRectangle(
                    cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                    style: .continuous
                )
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Neutral secondary action (Deny, Cancel).
struct GianSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GianTheme.Typography.body.weight(.semibold))
            .foregroundStyle(GianTheme.Colors.label)
            .frame(maxWidth: .infinity, minHeight: GianTheme.Metrics.minHitTarget)
            .background(
                GianTheme.Colors.secondaryLabel.opacity(0.16),
                in: RoundedRectangle(
                    cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                    style: .continuous
                )
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Circular icon button used in the composer (Send, Stop, compose entry).
struct GianCircularButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = GianTheme.Colors.tint

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: GianTheme.Metrics.avatarMedium, height: GianTheme.Metrics.avatarMedium)
            .background(
                tint.opacity(isEnabled ? 1 : 0.35),
                in: Circle()
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .gianHitTarget()
    }
}
