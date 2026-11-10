import SwiftUI

/// Gian's row-end status glyph (the desktop's `StatusIcon`): a spinning
/// gradient ring while the Agent works; a gradient disc with a knocked-out
/// glyph when the conversation needs you (waiting, or an unread result or
/// failure), flowing and breathing; a static accent disc for a failure already
/// read. A read, finished conversation shows nothing (the initializer fails).
struct SessionStatusIcon: View {
    enum Kind: Equatable { case running, waiting, failed, done }

    let kind: Kind
    let needsAttention: Bool

    init?(badge: StatusBadge, unread: Bool) {
        switch badge {
        case .working: kind = .running; needsAttention = true
        case .waiting: kind = .waiting; needsAttention = true
        case .failed: kind = .failed; needsAttention = unread
        case .idle:
            guard unread else { return nil }
            kind = .done; needsAttention = true
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let size: CGFloat = 16

    var body: some View {
        Group {
            if kind == .running { ring } else { disc }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        switch kind {
        case .running: "Working"
        case .waiting: "Waiting for you"
        case .failed: needsAttention ? "Failed, unread" : "Failed"
        case .done: "Unread"
        }
    }

    // MARK: - Running

    @ViewBuilder
    private var ring: some View {
        let ring = Circle()
            .strokeBorder(
                AngularGradient(colors: [Palette.g1, Palette.g2, Palette.g3, Palette.g2, Palette.g1], center: .center),
                lineWidth: size * 0.21
            )
            .shadow(color: Palette.glow.opacity(0.6), radius: 2)
        if reduceMotion {
            ring
        } else {
            ring.keyframeAnimator(initialValue: 0.0, repeating: true) { content, turn in
                content.rotationEffect(.degrees(turn))
            } keyframes: { _ in
                LinearKeyframe(360.0, duration: 1.2)
            }
        }
    }

    // MARK: - Disc

    @ViewBuilder
    private var disc: some View {
        if !needsAttention {
            Palette.accent.mask(knockout)
        } else if reduceMotion {
            Palette.flow.mask(knockout).shadow(color: Palette.glow.opacity(0.6), radius: 2)
        } else {
            // Flowing gradient and a slow breathe, as on the desktop (4 s
            // each); every loop ends where it starts.
            Rectangle()
                .fill(Palette.flow)
                .keyframeAnimator(initialValue: 0.0, repeating: true) { content, phase in
                    content.scaleEffect(2.3, anchor: UnitPoint(x: phase, y: 0.5))
                } keyframes: { _ in
                    CubicKeyframe(1.0, duration: 2)
                    CubicKeyframe(0.0, duration: 2)
                }
                .mask(knockout)
                .shadow(color: Palette.glow.opacity(0.6), radius: 2)
                .keyframeAnimator(initialValue: 1.125, repeating: true) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    CubicKeyframe(0.875, duration: 2)
                    CubicKeyframe(1.125, duration: 2)
                }
        }
    }

    /// The disc with the glyph cut out of it.
    private var knockout: some View {
        ZStack {
            Circle().inset(by: size * 0.6 / 16)
            glyph.blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .done: Checkmark().stroke(style: StrokeStyle(lineWidth: size * 2.2 / 16, lineCap: .round, lineJoin: .round))
        case .failed: Exclamation()
        case .waiting, .running: Pause()
        }
    }
}

/// Gian's status gradient for the default (azure) accent, from the desktop's
/// oklch tokens: three stops swept around the accent hue, plus its glow.
private enum Palette {
    static let g1 = Color(light: 0x00B29E, dark: 0x00BFAA)
    static let g2 = Color(light: 0x00B8FF, dark: 0x00CCFF)
    static let g3 = Color(light: 0x7C63D6, dark: 0x876FE4)
    static let glow = Color(light: 0x4EB6F3, dark: 0x62C9FF)
    static let accent = Color(light: 0x007DAE, dark: 0x32B3E6)
    /// 115° like the desktop's `linear-gradient(115deg, …)`.
    static let flow = LinearGradient(
        colors: [g1, g2, g3, g1],
        startPoint: UnitPoint(x: 0.08, y: 0.18),
        endPoint: UnitPoint(x: 0.92, y: 0.82)
    )
}

// Glyphs in the desktop's 16-unit viewBox, scaled to the frame.

private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 16
        var path = Path()
        path.move(to: CGPoint(x: 5 * unit, y: 8 * unit))
        path.addLine(to: CGPoint(x: 7 * unit, y: 10 * unit))
        path.addLine(to: CGPoint(x: 11 * unit, y: 6 * unit))
        return path
    }
}

private struct Exclamation: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 16
        var path = Path(roundedRect: CGRect(x: 7.05 * unit, y: 3.8 * unit, width: 1.9 * unit, height: 5.3 * unit),
                        cornerRadius: 0.95 * unit)
        path.addEllipse(in: CGRect(x: (8 - 1.05) * unit, y: (11.4 - 1.05) * unit, width: 2.1 * unit, height: 2.1 * unit))
        return path
    }
}

private struct Pause: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 16
        var path = Path(roundedRect: CGRect(x: 5.5 * unit, y: 4.8 * unit, width: 1.7 * unit, height: 6.4 * unit),
                        cornerRadius: 0.85 * unit)
        path.addRoundedRect(in: CGRect(x: 8.8 * unit, y: 4.8 * unit, width: 1.7 * unit, height: 6.4 * unit),
                            cornerSize: CGSize(width: 0.85 * unit, height: 0.85 * unit))
        return path
    }
}

#Preview("Status icons") {
    HStack(spacing: 20) {
        SessionStatusIcon(badge: .working, unread: false)
        SessionStatusIcon(badge: .waiting, unread: false)
        SessionStatusIcon(badge: .failed, unread: true)
        SessionStatusIcon(badge: .failed, unread: false)
        SessionStatusIcon(badge: .idle, unread: true)
    }
    .padding()
}
