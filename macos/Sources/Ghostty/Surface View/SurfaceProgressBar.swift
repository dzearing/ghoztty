import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The progress bar to show a surface progress report. We implement this from scratch because the
/// standard ProgressView is broken on macOS 26 and this is simple anyways and gives us a ton of
/// control.
struct SurfaceProgressBar: View {
    let report: Ghostty.Action.ProgressReport

    private var color: Color {
        switch report.state {
        case .error: return .red
        case .pause: return .orange
        default: return .accentColor
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
                    Rectangle()
                        .fill(color)
                        .frame(
                            width: geometry.size.width * CGFloat(progress) / 100,
                            height: geometry.size.height
                        )
                        .animation(.easeInOut(duration: 0.2), value: progress)
                } else {
                    // Indeterminate states without specific progress - all use bouncing animation
                    BouncingProgressBar(color: color)
                }
            }
        }
        .frame(height: 2)
        .clipped()
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
        default: return .controlAccentColor
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
    var color: NSColor = .controlAccentColor { didSet { applyColors() } }
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    /// One revolution.
    private static let period: CFTimeInterval = 2.4

    /// A crisp line and a wide, faint halo around it: together they read as a
    /// soft light rather than a drawn stroke.
    private let rings: [(ring: CALayer, sweep: CAGradientLayer, mask: CAShapeLayer, width: CGFloat, alpha: CGFloat)] = [
        (CALayer(), CAGradientLayer(), CAShapeLayer(), 6, 0.35),
        (CALayer(), CAGradientLayer(), CAShapeLayer(), 1.5, 0.9),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for r in rings {
            r.sweep.type = .conic
            r.sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
            r.sweep.endPoint = CGPoint(x: 0.5, y: 0)
            r.mask.fillColor = nil
            r.mask.strokeColor = NSColor.black.cgColor
            r.mask.lineWidth = r.width
            r.ring.mask = r.mask
            r.ring.addSublayer(r.sweep)
            layer?.addSublayer(r.ring)
        }
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A tail that fades in over a third of the turn up to a bright head.
    private func applyColors() {
        for r in rings {
            let c = color.withAlphaComponent(r.alpha).cgColor
            let clear = color.withAlphaComponent(0).cgColor
            r.sweep.colors = [clear, clear, c, clear]
            r.sweep.locations = [0, 0.62, 0.97, 1]
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Square and big enough to cover the pane at every angle.
        let side = hypot(bounds.width, bounds.height)
        for r in rings {
            r.ring.frame = bounds
            r.mask.frame = bounds
            let inset = bounds.insetBy(dx: r.width / 2, dy: r.width / 2)
            let radius = Swift.max(0, cornerRadius - r.width / 2)
            r.mask.path = inset.width > 0 && inset.height > 0
                ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : nil
            r.sweep.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            r.sweep.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
        startSpinning()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startSpinning()
    }

    private func startSpinning() {
        guard window != nil else { return }
        // Shared start time so the line and its halo stay in step.
        let begin = CACurrentMediaTime()
        for r in rings where r.sweep.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            // Clockwise on screen (layers are y-up).
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = Self.period
            spin.repeatCount = .infinity
            spin.beginTime = begin
            spin.isRemovedOnCompletion = false
            r.sweep.add(spin, forKey: "spin")
        }
    }
}
#endif
