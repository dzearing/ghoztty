import AppKit
import QuartzCore
import SwiftUI

// The sidebar's two endless animations — the busy shimmer and the question
// ring — run on Core Animation, not SwiftUI.
//
// Measured: a SwiftUI animation that never ends (`TimelineView(.animation)`,
// `.repeatForever`) re-runs the whole sidebar's update on the main thread
// every frame — graph update, layout of the host, a redraw of the rows' text,
// and AppKit's opaque-region walk over every row's NSViews — in every window
// with a busy pane, visible or not. With ~40 windows and a dozen busy panes
// that held the main thread ~45% busy at rest, and scrolling the all-windows
// list dropped to ~40 fps (p50 25 ms a frame; 55–110 ms with every window
// expanded). A CA animation is played by the render server: once added, it
// costs the main thread nothing per frame.

/// The busy shimmer: `mask` (the glyph, drawn once into an image) filled
/// with `color` at `PaneSidebarShimmer.baseOpacity`, under a band of full
/// `color` that sweeps across it on `PaneSidebarShimmer`'s timing.
struct PaneSidebarShimmerLayer: NSViewRepresentable {
    let color: Color
    /// What the glyph is: the mask is re-rendered only when this, the size,
    /// or the backing scale changes.
    let maskKey: AnyHashable
    let renderMask: @MainActor (CGSize, CGFloat) -> CGImage?

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        view.color = NSColor(color)
        view.renderMask = renderMask
        view.maskKey = maskKey
    }

    final class View: NSView {
        var color: NSColor = .labelColor { didSet { if color != oldValue { applyColors() } } }
        var maskKey: AnyHashable? { didSet { if maskKey != oldValue { needsLayout = true } } }
        var renderMask: (@MainActor (CGSize, CGFloat) -> CGImage?)?

        private let base = CALayer()
        private let band = CAGradientLayer()
        private let glyphMask = CALayer()
        private var rendered: (key: AnyHashable, size: CGSize, scale: CGFloat)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            layer?.addSublayer(base)
            layer?.addSublayer(band)
            layer?.mask = glyphMask
            band.locations = [0.35, 0.5, 0.65]
            // SwiftUI's (0, 0.35) → (1, 0.65), in CA's y-up unit space.
            band.startPoint = CGPoint(x: 0, y: 0.65)
            band.endPoint = CGPoint(x: 1, y: 0.35)
            band.anchorPoint = .zero
            applyColors()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            needsLayout = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // CA drops a layer's animations when it leaves the window.
            if window != nil { needsLayout = true; animateBand() }
        }

        override func layout() {
            super.layout()
            let size = bounds.size
            let scale = window?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            base.frame = bounds
            glyphMask.frame = bounds
            band.bounds = CGRect(x: 0, y: 0, width: size.width * PaneSidebarShimmer.bandWidthFactor,
                                 height: size.height)
            band.position = .zero
            if let key = maskKey, size.width > 0, size.height > 0,
               rendered.map({ $0.key != key || $0.size != size || $0.scale != scale }) ?? true {
                glyphMask.contents = renderMask?(size, scale)
                glyphMask.contentsScale = scale
                rendered = (key, size, scale)
            }
            CATransaction.commit()
            animateBand()
        }

        private func applyColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let cg = color.cgColor
                base.backgroundColor = cg.copy(alpha: cg.alpha * PaneSidebarShimmer.baseOpacity)
                band.colors = [cg.copy(alpha: 0) ?? cg, cg, cg.copy(alpha: 0) ?? cg]
            }
        }

        /// One sweep of the band from parked off the leading edge to off the
        /// trailing one, eased, then a rest — repeated forever, in phase with
        /// the wall clock so every busy glyph in every window sweeps together.
        private func animateBand() {
            let width = bounds.width
            guard width > 0, window != nil else { return }
            let from = PaneSidebarShimmer.offset(position: 1, width: width)
            let to = PaneSidebarShimmer.offset(position: 0, width: width)
            if let existing = band.animation(forKey: "sweep") as? CAKeyframeAnimation,
               existing.values?.first as? CGFloat == from {
                return
            }
            let period = PaneSidebarShimmer.period
            let sweep = CAKeyframeAnimation(keyPath: "position.x")
            sweep.values = [from, to, to]
            sweep.keyTimes = [0, NSNumber(value: PaneSidebarShimmer.sweepFraction), 1]
            // Ease-in-out quad, the curve `bandPosition` traces.
            sweep.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.455, 0.03, 0.515, 0.955),
                CAMediaTimingFunction(name: .linear),
            ]
            sweep.duration = period
            sweep.repeatCount = .infinity
            let phase = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            sweep.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) - phase
            sweep.fillMode = .backwards
            sweep.isRemovedOnCompletion = false
            band.add(sweep, forKey: "sweep")
        }
    }
}

/// The question badge's breathing ring: a 3pt capsule outline, `color` at
/// 22%, fading in and out. Laid out 1.5pt outside the badge on every side.
struct PaneSidebarPulseRing: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        view.color = NSColor(color)
    }

    final class View: NSView {
        var color: NSColor = .controlAccentColor { didSet { if color != oldValue { applyColor() } } }

        private let ring = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            ring.fillColor = nil
            ring.lineWidth = 3
            layer?.addSublayer(ring)
            applyColor()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColor()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { breathe() }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            let radius = bounds.height / 2
            ring.path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            CATransaction.commit()
            breathe()
        }

        private func applyColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = color.withAlphaComponent(0.22).cgColor
            }
        }

        private func breathe() {
            guard window != nil, ring.animation(forKey: "breathe") == nil else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 1.2
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.isRemovedOnCompletion = false
            ring.add(fade, forKey: "breathe")
        }
    }
}

/// A busy rail tile's sheen: a band of light sweeping diagonally across the
/// whole glass tile — the tile's own sheen, set moving — now and then
/// (`period`), faint (`peak`), and in phase with every other busy tile.
/// Core Animation, as the shimmer is (see the top of this file): played by
/// the render server, it costs the main thread nothing per frame.
struct PaneSidebarTileSheenLayer: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        view.cornerRadius = cornerRadius
    }

    final class View: NSView {
        var cornerRadius: CGFloat = 8 { didSet { if cornerRadius != oldValue { needsLayout = true } } }

        private let band = CAGradientLayer()

        /// A sweep every `period`, taking `sweep` of it: an occasional glint,
        /// not a strobe (the shimmer's 1.4s was too busy on a whole tile).
        static let period: CFTimeInterval = 2.0
        static let sweep: CFTimeInterval = 0.8
        static let peak: CGFloat = 0.25

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            layer?.masksToBounds = true
            layer?.addSublayer(band)
            let light = NSColor.white.cgColor
            // Faint: a glint that says "working", not a flash.
            band.colors = [light.copy(alpha: 0)!, light.copy(alpha: View.peak)!, light.copy(alpha: 0)!]
            band.locations = [0.33, 0.5, 0.67]
            // Top-left to bottom-right, in CA's y-up unit space: a band
            // running from the lower left up to the upper right.
            band.startPoint = CGPoint(x: 0, y: 1)
            band.endPoint = CGPoint(x: 1, y: 0)
            band.anchorPoint = .zero
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // CA drops a layer's animations when it leaves the window.
            if window != nil { needsLayout = true; animateBand() }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
            // Square, so the 45° band crosses the tile corner to corner.
            let side = Swift.max(bounds.width, bounds.height)
            band.bounds = CGRect(x: 0, y: 0, width: side * PaneSidebarShimmer.bandWidthFactor,
                                 height: side * PaneSidebarShimmer.bandWidthFactor)
            band.position = CGPoint(x: 0, y: -(band.bounds.height - bounds.height) / 2)
            CATransaction.commit()
            animateBand()
        }

        /// The band's travel runs past the shimmer's at each end: the
        /// diagonal band is wide enough that at the shimmer's ends it still
        /// lay over a corner of the tile — each sweep jumped in there and
        /// stopped short of leaving. Parked further out, it starts off the
        /// tile, sweeps through, and leaves it entirely.
        private func animateBand() {
            let width = Swift.max(bounds.width, bounds.height)
            guard width > 0, window != nil else { return }
            // The bright band (40% of the gradient's diagonal) clears a
            // square tile at -3w before and +w after; a fifth of a tile more
            // either way, for its soft edges.
            let from = PaneSidebarShimmer.offset(position: 1, width: width) - width * 1.2
            let to = PaneSidebarShimmer.offset(position: 0, width: width) + width * 1.2
            if let existing = band.animation(forKey: "sweep") as? CAKeyframeAnimation,
               existing.values?.first as? CGFloat == from {
                return
            }
            let period = View.period
            let sweep = CAKeyframeAnimation(keyPath: "position.x")
            sweep.values = [from, to, to]
            sweep.keyTimes = [0, NSNumber(value: View.sweep / View.period), 1]
            sweep.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.455, 0.03, 0.515, 0.955),
                CAMediaTimingFunction(name: .linear),
            ]
            sweep.duration = period
            sweep.repeatCount = .infinity
            let phase = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            sweep.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) - phase
            sweep.fillMode = .backwards
            sweep.isRemovedOnCompletion = false
            band.add(sweep, forKey: "sweep")
        }
    }
}
