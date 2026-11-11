import SwiftUI
import UIKit

/// Gian's row-end status glyph (the desktop's `StatusIcon`): a spinning
/// gradient ring while the Agent works; a gradient disc with a knocked-out
/// glyph when the conversation needs you (waiting, or an unread result or
/// failure), flowing and breathing; a static accent disc for a failure already
/// read. A read, finished conversation shows nothing (the initializer fails).
///
/// Drawn with Core Animation: the spin, flow and breathe run in the render
/// server, so a list full of them scrolls without per-frame work on the main
/// thread (a SwiftUI version re-rendered masks, blends and blurs every frame).
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
    @Environment(\.gianAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        StatusGlyph(style: style)
            .frame(width: StatusGlyphView.side, height: StatusGlyphView.side)
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

    private var style: StatusGlyphView.Style {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        func resolved(_ color: Color) -> UIColor { UIColor(color).resolvedColor(with: traits) }
        return StatusGlyphView.Style(
            kind: kind,
            needsAttention: needsAttention,
            gradient: accent.statusGradient.map(resolved),
            glow: resolved(accent.statusGlow),
            accent: resolved(accent.color),
            animated: !reduceMotion
        )
    }
}

private struct StatusGlyph: UIViewRepresentable {
    let style: StatusGlyphView.Style

    func makeUIView(context: Context) -> StatusGlyphView { StatusGlyphView() }

    func updateUIView(_ view: StatusGlyphView, context: Context) {
        view.style = style
    }
}

/// The layers behind `SessionStatusIcon`, in the desktop's 16-unit geometry.
final class StatusGlyphView: UIView {
    static let side: CGFloat = 16

    struct Style: Equatable {
        var kind: SessionStatusIcon.Kind
        var needsAttention: Bool
        var gradient: [UIColor]
        var glow: UIColor
        var accent: UIColor
        var animated: Bool
    }

    var style: Style? {
        didSet { if style != oldValue { rebuild() } }
    }

    /// Breathes, and casts the glow.
    private let host = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.side, height: Self.side) }

    override func layoutSubviews() {
        super.layoutSubviews()
        if host.frame != bounds { rebuild() }
    }

    // Animations don't survive leaving the window; restart them on return.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { rebuild() }
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        host.removeAllAnimations()
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        host.frame = bounds
        host.shadowOpacity = 0
        guard let style, bounds.width > 0 else { return }
        let side = bounds.width

        if style.kind == .running {
            let ring = CAGradientLayer()
            ring.type = .conic
            ring.frame = host.bounds
            ring.startPoint = CGPoint(x: 0.5, y: 0.5)
            ring.endPoint = CGPoint(x: 0.5, y: 0)
            ring.colors = Self.cycle(style.gradient, through: [0, 1, 2, 1, 0])
            let mask = CAShapeLayer()
            mask.frame = ring.bounds
            mask.path = Self.ringPath(side: side)
            ring.mask = mask
            host.addSublayer(ring)
            glow(style, path: Self.ringPath(side: side))
            if style.animated {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = 1.2
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                ring.add(spin, forKey: "spin")
            }
            return
        }

        let disc = CALayer()
        disc.frame = host.bounds
        let mask = CALayer()
        mask.frame = disc.bounds
        mask.contents = Self.discMask(style.kind, side: side, scale: traitCollection.displayScale)
        mask.contentsScale = traitCollection.displayScale
        disc.mask = mask
        host.addSublayer(disc)

        guard style.needsAttention else {
            // Read: a static accent disc.
            disc.backgroundColor = style.accent.cgColor
            return
        }
        // 230 % wide, 115°, sliding across the disc and back like the
        // desktop's background-position flow.
        let flow = CAGradientLayer()
        let size = side * 2.3
        flow.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        flow.position = CGPoint(x: size / 2, y: side / 2)
        flow.startPoint = CGPoint(x: 0.08, y: 0.18)
        flow.endPoint = CGPoint(x: 0.92, y: 0.82)
        flow.colors = Self.cycle(style.gradient, through: [0, 1, 2, 0])
        disc.addSublayer(flow)
        glow(style, path: UIBezierPath(ovalIn: host.bounds.insetBy(dx: side * 0.6 / 16, dy: side * 0.6 / 16)).cgPath)
        guard style.animated else { return }
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = size / 2
        slide.toValue = side - size / 2
        slide.duration = 2
        slide.autoreverses = true
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        slide.isRemovedOnCompletion = false
        flow.add(slide, forKey: "flow")
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.875
        breathe.toValue = 1.125
        breathe.duration = 2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.isRemovedOnCompletion = false
        host.add(breathe, forKey: "breathe")
    }

    /// A soft glow along `path` (a fixed path, so no offscreen pass).
    private func glow(_ style: Style, path: CGPath) {
        host.shadowColor = style.glow.cgColor
        host.shadowOpacity = 1
        host.shadowRadius = 2
        host.shadowOffset = .zero
        host.shadowPath = path
    }

    private static func cycle(_ colors: [UIColor], through indices: [Int]) -> [CGColor] {
        indices.compactMap { colors.indices.contains($0) ? colors[$0].cgColor : nil }
    }

    /// The ring: outer and inner circles wound opposite ways.
    private static func ringPath(side: CGFloat) -> CGPath {
        let center = CGPoint(x: side / 2, y: side / 2)
        let path = UIBezierPath(arcCenter: center, radius: side / 2, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        path.append(UIBezierPath(arcCenter: center, radius: side / 2 * 0.58, startAngle: 0, endAngle: 2 * .pi, clockwise: false))
        return path.cgPath
    }

    private static var masks: [String: CGImage] = [:]

    /// The disc with its glyph cut out, rendered once per glyph and scale.
    private static func discMask(_ kind: SessionStatusIcon.Kind, side: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(kind)-\(side)-\(scale)"
        if let cached = masks[key] { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            let unit = side / 16
            cg.setFillColor(UIColor.black.cgColor)
            cg.fillEllipse(in: CGRect(x: 0.6 * unit, y: 0.6 * unit, width: 14.8 * unit, height: 14.8 * unit))
            cg.setBlendMode(.clear)
            switch kind {
            case .done:
                cg.setLineWidth(2.2 * unit)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.move(to: CGPoint(x: 5 * unit, y: 8 * unit))
                cg.addLine(to: CGPoint(x: 7 * unit, y: 10 * unit))
                cg.addLine(to: CGPoint(x: 11 * unit, y: 6 * unit))
                cg.strokePath()
            case .failed:
                cg.addPath(UIBezierPath(roundedRect: CGRect(x: 7.05 * unit, y: 3.8 * unit, width: 1.9 * unit, height: 5.3 * unit),
                                        cornerRadius: 0.95 * unit).cgPath)
                cg.addEllipse(in: CGRect(x: (8 - 1.05) * unit, y: (11.4 - 1.05) * unit, width: 2.1 * unit, height: 2.1 * unit))
                cg.fillPath()
            case .waiting, .running:
                cg.addPath(UIBezierPath(roundedRect: CGRect(x: 5.5 * unit, y: 4.8 * unit, width: 1.7 * unit, height: 6.4 * unit),
                                        cornerRadius: 0.85 * unit).cgPath)
                cg.addPath(UIBezierPath(roundedRect: CGRect(x: 8.8 * unit, y: 4.8 * unit, width: 1.7 * unit, height: 6.4 * unit),
                                        cornerRadius: 0.85 * unit).cgPath)
                cg.fillPath()
            }
        }
        masks[key] = image.cgImage
        return image.cgImage
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
