import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The progress bar to show a surface progress report. We implement this from scratch because the
/// standard ProgressView is broken on macOS 26 and this is simple anyways and gives us a ton of
/// control.
struct SurfaceProgressBar: View {
    let report: Ghostty.Action.ProgressReport
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        switch report.state {
        case .error: return .red
        case .pause: return .orange
        // Same light as the busy border: white on dark, charcoal on light.
        default: return colorScheme == .dark ? .white : Color(white: 0.2)
        }
    }

    private var progress: UInt8? {
        // If we have an explicit progress use that.
        if let v = report.progress { return v }

        // Otherwise, if we're in the pause state, we act as if we're at 100%.
        if report.state == .pause { return 100 }

        return nil
    }

    private var accessibilityLabel: String {
        switch report.state {
        case .error: return "Terminal progress - Error"
        case .pause: return "Terminal progress - Paused"
        case .indeterminate: return "Terminal progress - In progress"
        default: return "Terminal progress"
        }
    }

    private var accessibilityValue: String {
        if let progress {
            return "\(progress) percent complete"
        } else {
            switch report.state {
            case .error: return "Operation failed"
            case .pause: return "Operation paused at completion"
            case .indeterminate: return "Operation in progress"
            default: return "Indeterminate progress"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let progress {
                    // Determinate progress bar with specific percentage
                    // A glowing line rather than a flat bar: the core plus a
                    // tight and a wide halo spilling down into the pane.
                    Capsule()
                        .fill(color)
                        .frame(
                            width: geometry.size.width * CGFloat(progress) / 100,
                            height: geometry.size.height
                        )
                        .shadow(color: color.opacity(0.9), radius: 2)
                        .shadow(color: color.opacity(0.5), radius: 6)
                        .animation(.easeInOut(duration: 0.2), value: progress)
                } else {
                    // Indeterminate states without specific progress - all use bouncing animation
                    BouncingProgressBar(color: color)
                }
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}

/// Bouncing progress bar for indeterminate states
private struct BouncingProgressBar: View {
    let color: Color
    @State private var position: CGFloat = 0

    private let barWidthRatio: CGFloat = 0.25

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(color.opacity(0.3))

                Rectangle()
                    .fill(color)
                    .frame(
                        width: geometry.size.width * barWidthRatio,
                        height: geometry.size.height
                    )
                    .offset(x: position * (geometry.size.width * (1 - barWidthRatio)))
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: true)
            ) {
                position = 1
            }
        }
        .onDisappear {
            position = 0
        }
    }
}


#if canImport(AppKit)
extension NSColor {
    /// The progress light: white on a dark appearance, charcoal on a light
    /// one, so it reads as a glow on either without borrowing the accent color.
    static let progressGlow = NSColor(name: "progressGlow") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .white
            : NSColor(white: 0.2, alpha: 1)
    }
}

/// The busy indicator for a progress report with no percentage (what an
/// agent reports while it works): a soft highlight that travels around the
/// pane's border, instead of a bar bouncing along its top edge.
///
/// Core Animation, not a SwiftUI animation: the rotation runs in the render
/// server, so a window full of busy agents costs no per-frame view updates,
/// and no enclosing `.transaction { $0.animation = nil }` (the pane sidebar's
/// container has one, and it froze the bouncing bar) can stop it.
struct SurfaceBusyBorder: NSViewRepresentable {
    let report: Ghostty.Action.ProgressReport
    /// The pane's corner radius, so the light follows the card's edge.
    let cornerRadius: CGFloat

    /// True when the report has a percentage to show, which the bar still
    /// does better than a border.
    static func usesBar(_ report: Ghostty.Action.ProgressReport) -> Bool {
        report.progress != nil || report.state == .pause
    }

    private var color: NSColor {
        switch report.state {
        case .error: return .systemRed
        default: return .progressGlow
        }
    }

    func makeNSView(context: Context) -> BusyBorderView {
        let view = BusyBorderView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.progressIndicator)
        view.setAccessibilityLabel(report.state == .error
            ? "Terminal progress - Error" : "Terminal progress - In progress")
        return view
    }

    func updateNSView(_ view: BusyBorderView, context: Context) {
        view.color = color
        view.cornerRadius = cornerRadius
    }
}

final class BusyBorderView: NSView {
    var color: NSColor = .progressGlow { didSet { applyColors() } }
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    /// One revolution.
    private static let period: CFTimeInterval = 2.4
    /// The line itself.
    private static let lineWidth: CGFloat = 1

    /// A 1pt line whose brightness sweeps around the border (`sweep`, a conic
    /// gradient clipped to the border by `mask`), wrapped in two shadows — a
    /// tight one and a wide one. A shadow is a real blur of whatever is
    /// beneath it, so the glow is brightest at the head and fades with the
    /// tail. (Stacked wider strokes were tried first and showed as bands.)
    /// The shadows are re-rendered as the sweep turns; that is the cost of a
    /// glow that follows a moving light.
    private let wideGlow = CALayer()
    private let tightGlow = CALayer()
    private let ring = CALayer()
    private let sweep = CAGradientLayer()
    private let mask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sweep.type = .conic
        sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweep.endPoint = CGPoint(x: 0.5, y: 0)
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = Self.lineWidth
        ring.mask = mask
        ring.addSublayer(sweep)
        tightGlow.addSublayer(ring)
        wideGlow.addSublayer(tightGlow)
        for (glow, radius, opacity) in [(tightGlow, 2.0, 0.5), (wideGlow, 7.0, 0.3)] {
            glow.shadowOffset = .zero
            glow.shadowRadius = radius
            glow.shadowOpacity = Float(opacity)
        }
        layer?.addSublayer(wideGlow)
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A tail that trails off over almost half the turn, easing up to a bright
    /// head and then ending sharply, so the light reads as a comet's tip.
    private func applyColors() {
        let ramp: [(location: NSNumber, alpha: CGFloat)] = [
            (0, 0), (0.55, 0), (0.8, 0.07), (0.92, 0.22), (0.975, 0.45), (0.995, 0.6), (1, 0),
        ]
        var resolved = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: color.cgColor) ?? color
        }
        sweep.colors = ramp.map { resolved.withAlphaComponent($0.alpha).cgColor }
        sweep.locations = ramp.map(\.location)
        tightGlow.shadowColor = resolved.cgColor
        wideGlow.shadowColor = resolved.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [wideGlow, tightGlow, ring, mask] { l.frame = bounds }
        let w = Self.lineWidth
        let inset = bounds.insetBy(dx: w / 2, dy: w / 2)
        let radius = Swift.max(0, cornerRadius - w / 2)
        mask.path = inset.width > 0 && inset.height > 0
            ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
            : nil
        // Square and big enough to cover the pane at every angle.
        let side = hypot(bounds.width, bounds.height)
        sweep.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        sweep.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        startSpinning()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startSpinning()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func startSpinning() {
        guard window != nil, sweep.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        // Clockwise on screen (layers are y-up).
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = Self.period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        sweep.add(spin, forKey: "spin")
    }
}
#endif
