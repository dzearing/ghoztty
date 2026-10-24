import SwiftUI
import IOSurface

extension Ghostty {
    /// The path the terminal's content takes while the pane banner collapses
    /// or expands (see `SurfaceWrapper.bannerFrozen`): `delta` points down,
    /// over one step of `progress`. The frozen copy starts where the content
    /// was and ends there + `delta`; the live terminal, already laid out at
    /// the new size, starts at - `delta` and ends at rest — so whenever the
    /// one replaces the other, they are in the same place.
    ///
    /// Only `progress` animates. `base` and `delta` are set instantly at the
    /// start of a toggle, and a plain `.offset` would interpolate the whole
    /// product from wherever the last toggle left it.
    struct BannerGlide {
        var progress: CGFloat = 1
        var base: CGFloat = 0
        var delta: CGFloat = 0

        var frozen: Effect { Effect(progress: progress, base: base, delta: delta, lead: 0) }
        var live: Effect { Effect(progress: progress, base: base, delta: delta, lead: -1) }

        struct Effect: GeometryEffect {
            var progress: CGFloat
            let base: CGFloat
            let delta: CGFloat
            let lead: CGFloat

            var animatableData: CGFloat {
                get { progress }
                set { progress = newValue }
            }

            func effectValue(size: CGSize) -> ProjectionTransform {
                let t = min(max(progress - base, 0), 1)
                return ProjectionTransform(CGAffineTransform(translationX: 0, y: (t + lead) * delta))
            }
        }
    }

    /// A copy of the terminal's last frame (`SurfaceView.frozenFrame`), laid
    /// out where the terminal was.
    struct FrozenTerminal {
        let surface: IOSurface
        let scale: CGFloat
        let top: CGFloat
        let size: CGSize
    }

    #if canImport(AppKit)
    /// Shows a `FrozenTerminal` exactly as the renderer's layer showed it: the
    /// same IOSurface pixels, top-left gravity and scale.
    struct FrozenTerminalView: NSViewRepresentable {
        let frozen: FrozenTerminal?

        func makeNSView(context: Context) -> FrozenLayerView { FrozenLayerView() }

        func updateNSView(_ view: FrozenLayerView, context: Context) {
            view.frozen = frozen
        }
    }

    /// Sets its layer's contents in `updateLayer`: a layer-backed view's
    /// contents set from outside are wiped by AppKit's next display of it
    /// (its frame changing is enough), which blanked the copy for a frame or
    /// three just as it was put in the terminal's place.
    final class FrozenLayerView: NSView {
        var frozen: FrozenTerminal? {
            didSet { needsDisplay = true }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            guard let layer else { return }
            layer.contentsGravity = .topLeft
            layer.contents = frozen?.surface
            if let frozen { layer.contentsScale = frozen.scale }
        }
    }
    #else
    struct FrozenTerminalView: View {
        let frozen: FrozenTerminal?
        var body: some View { EmptyView() }
    }
    #endif
}
