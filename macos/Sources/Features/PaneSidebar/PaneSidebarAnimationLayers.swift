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

/// A busy row's sheen (a rail tile is a row): an upright band of light
/// sweeping across the row's pill from its right edge to its left — now and then
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
            // Left to right across the band layer: an upright band of light
            // in its middle fifth (`PaneSidebarSheen`).
            band.locations = [NSNumber(value: Double(PaneSidebarSheen.light.lowerBound)), 0.5,
                              NSNumber(value: Double(PaneSidebarSheen.light.upperBound))]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
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
            band.bounds = CGRect(x: 0, y: 0, width: bounds.width * PaneSidebarSheen.bandWidthFactor,
                                 height: bounds.height)
            band.position = .zero
            CATransaction.commit()
            animateBand()
        }

        private func animateBand() {
            let width = bounds.width
            guard width > 0, window != nil else { return }
            let (from, to) = PaneSidebarSheen.travel(width: width)
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

/// The busy sheen's geometry, pure so it is tested (`PaneSidebarSheenTests`).
enum PaneSidebarSheen {
    /// The band layer is this many rows wide…
    static let bandWidthFactor: CGFloat = 3
    /// …and its light lies in this stretch of it.
    static let light: ClosedRange<CGFloat> = 0.4...0.6

    /// Where the band layer's left edge travels, for a row `width` wide: from
    /// the light just past the row's right edge to just past its left, so a
    /// sweep starts off the row, crosses it right to left, and leaves it
    /// entirely (one that stopped short at either end jumped in, or never
    /// quite left).
    static func travel(width: CGFloat) -> (from: CGFloat, to: CGFloat) {
        let margin = width * 0.15
        let lightStart = light.lowerBound * bandWidthFactor * width
        let lightEnd = light.upperBound * bandWidthFactor * width
        return (width - lightStart + margin, -lightEnd - margin)
    }
}
