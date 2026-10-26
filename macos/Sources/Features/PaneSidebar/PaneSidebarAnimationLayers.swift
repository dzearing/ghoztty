import AppKit
import QuartzCore
import SwiftUI

// The sidebar's endless animation — the busy sheen across a row — runs on
// Core Animation, not SwiftUI.
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

/// A busy row's sheen (a rail tile is a row), in two layers, both slanted 45°
/// (`PaneSidebarSheen.slant`: an upright band turned clockwise, "/") and both
/// moving right to left, in phase with every other busy tile:
/// - the **glint**: a band of light sweeping across the pill now and then
///   (`period`), faint (`peak`);
/// - the **drift**: a wide, soft, seamless gradient crossing it slowly and
///   without a gap (`PaneSidebarSheen.Drift`), inside a hairline rim, so a
///   busy pill's silhouette is always on screen, between glints too.
/// Core Animation, as the shimmer is (see the top of this file): played by
/// the render server, it costs the main thread nothing per frame. Its
/// arrival and departure are faded by the row (`PaneSidebarRow.busySheen`).
struct PaneSidebarTileSheenLayer: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        view.cornerRadius = cornerRadius
    }

    final class View: NSView {
        var cornerRadius: CGFloat = 8 { didSet { if cornerRadius != oldValue { needsLayout = true } } }

        private let band = CAGradientLayer()
        private let drift = CAGradientLayer()

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
            layer?.addSublayer(drift)
            layer?.addSublayer(band)
            let light = NSColor.white.cgColor
            // Faint: a glint that says "working", not a flash.
            band.colors = [light.copy(alpha: 0)!, light.copy(alpha: View.peak)!, light.copy(alpha: 0)!]
            // Left to right across the band layer: an upright band of light
            // in its middle fifth (`PaneSidebarSheen`), slanted by `layout`.
            band.locations = [NSNumber(value: Double(PaneSidebarSheen.light.lowerBound)), 0.5,
                              NSNumber(value: Double(PaneSidebarSheen.light.upperBound))]
            for gradient in [band, drift] {
                gradient.startPoint = CGPoint(x: 0, y: 0.5)
                gradient.endPoint = CGPoint(x: 1, y: 0.5)
                gradient.anchorPoint = .zero
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // CA drops a layer's animations when it leaves the window.
            if window != nil { needsLayout = true; animate() }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
            // An upright band, sheared: each line of it shifted right by its
            // height, so it leans 45° and its width across stays the same.
            var shear = CATransform3DIdentity
            shear.m21 = PaneSidebarSheen.slant * (isFlipped ? -1 : 1)
            band.bounds = CGRect(x: 0, y: 0, width: bounds.width * PaneSidebarSheen.bandWidthFactor,
                                 height: bounds.height)
            band.position = .zero
            band.transform = shear
            let drift = PaneSidebarSheen.Drift(width: bounds.width, height: bounds.height)
            self.drift.bounds = CGRect(x: 0, y: 0, width: drift.length, height: bounds.height)
            self.drift.position = CGPoint(x: drift.from, y: 0)
            self.drift.transform = shear
            self.drift.locations = drift.locations.map { NSNumber(value: Double($0)) }
            self.drift.colors = driftColors(count: drift.locations.count)
            // Drawn over the sublayers, and faded with them by the row.
            layer?.borderWidth = PaneSidebarRow.rimWidth
            layer?.borderColor = rimColor()
            CATransaction.commit()
            animate()
        }

        /// Light on a dark pill, dark on a light one — white alone vanishes on
        /// a light theme's card — alternating faint and fainter.
        private func driftColors(count: Int) -> [CGColor] {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let ink = (dark ? NSColor.white : NSColor.black).cgColor
            let (low, high) = dark ? PaneSidebarSheen.Drift.darkAlpha : PaneSidebarSheen.Drift.lightAlpha
            return (0..<count).map { ink.copy(alpha: $0.isMultiple(of: 2) ? low : high)! }
        }

        private func rimColor() -> CGColor {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (onDark, onLight) = PaneSidebarSheen.Drift.rimAlpha
            return (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? onDark : onLight).cgColor
        }

        private func animate() {
            let width = bounds.width
            guard width > 0, window != nil else { return }
            animateBand(width: width)
            animateDrift(PaneSidebarSheen.Drift(width: width, height: bounds.height))
        }

        private func animateBand(width: CGFloat) {
            let (from, to) = PaneSidebarSheen.travel(width: width, height: bounds.height)
            if let existing = band.animation(forKey: "sweep") as? CAKeyframeAnimation,
               existing.values?.first as? CGFloat == from,
               existing.values?.last as? CGFloat == to {
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
            inPhase(sweep, on: band)
            band.add(sweep, forKey: "sweep")
        }

        /// One pattern period a cycle, linear and repeated: where it ends
        /// looks exactly like where it began, so the drift never jumps.
        private func animateDrift(_ geometry: PaneSidebarSheen.Drift) {
            if let existing = drift.animation(forKey: "drift") as? CABasicAnimation,
               existing.fromValue as? CGFloat == geometry.from,
               existing.toValue as? CGFloat == geometry.to {
                return
            }
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = geometry.from
            move.toValue = geometry.to
            move.duration = PaneSidebarSheen.Drift.duration
            move.timingFunction = CAMediaTimingFunction(name: .linear)
            move.repeatCount = .infinity
            inPhase(move, on: drift)
            drift.add(move, forKey: "drift")
        }

        /// Keyed to the wall clock, so every busy tile moves in step.
        private func inPhase(_ animation: CAAnimation, on layer: CALayer) {
            let phase = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: animation.duration)
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - phase
            animation.fillMode = .backwards
            animation.isRemovedOnCompletion = false
        }
    }
}

/// The busy sheen's geometry, pure so it is tested (`PaneSidebarSheenTests`).
enum PaneSidebarSheen {
    /// The band layer is this many rows wide…
    static let bandWidthFactor: CGFloat = 3
    /// …and its light lies in this stretch of it.
    static let light: ClosedRange<CGFloat> = 0.4...0.6
    /// How far right a band's top is from its bottom, per point of height:
    /// 1 is 45°, an upright band turned clockwise ("/").
    static let slant: CGFloat = 1

    /// Where the band layer's left edge (at the row's bottom) travels, for a
    /// row `width` wide and `height` tall: from the light just past the
    /// row's right edge to just past its left — its top included, which the
    /// slant puts `height` further right — so a sweep starts off the row,
    /// crosses it right to left, and leaves it entirely (one that stopped
    /// short at either end jumped in, or never quite left).
    static func travel(width: CGFloat, height: CGFloat) -> (from: CGFloat, to: CGFloat) {
        let margin = width * 0.15
        let lightStart = light.lowerBound * bandWidthFactor * width
        let lightEnd = light.upperBound * bandWidthFactor * width
        return (width - lightStart + margin, -lightEnd - slant * height - margin)
    }

    /// The slow drift under the glint: a gradient repeating every `period`
    /// points, long enough to cover the row at every height of the slant,
    /// sliding left by exactly one period per `duration` — so its last frame
    /// is its first.
    struct Drift {
        /// One cycle; the glint is 2s. Slow enough to read as a breath.
        static let duration: CFTimeInterval = 5
        /// (between, at) the crests' alpha: dark appearance, then light.
        static let darkAlpha: (CGFloat, CGFloat) = (0.02, 0.08)
        static let lightAlpha: (CGFloat, CGFloat) = (0.015, 0.05)
        /// The busy pill's hairline rim, so the drift sits in an outline
        /// instead of hanging in the list: dark appearance, then light.
        /// A pane card's rim: its 0.5pt hairline at its strength.
        static let rimAlpha: (dark: CGFloat, light: CGFloat) = (0.1, 0.08)

        /// Stretched: wider than the row, so a tile shows one soft crest at
        /// a time, never stripes.
        let period: CGFloat
        let length: CGFloat
        let from: CGFloat
        let to: CGFloat
        /// A trough at every even stop, a crest at every odd one.
        let locations: [CGFloat]

        init(width: CGFloat, height: CGFloat) {
            period = Swift.max(width * 1.5, 60)
            let reach = width + slant * height
            let periods = Int((reach / period).rounded(.up)) + 1
            length = period * CGFloat(periods)
            // Left of the row by the slant, so the top-left corner is covered.
            from = -slant * height
            to = from - period
            let stops = periods * 2
            locations = (0...stops).map { CGFloat($0) / CGFloat(stops) }
        }
    }
}
