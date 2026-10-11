import AppKit
import SwiftUI

/// The `elevated` pane style (`macos-pane-style`, the default): each pane is
/// a slightly raised rounded card on a soft "ocean" gradient, separated from
/// its neighbors by a real gap rather than a 1px line.
///
/// Geometry and palette live here once, so the grid, the hidden stashed-pane
/// slots (which must lay out EXACTLY like the grid, or a restored pane would
/// reflow), and the pane sidebar all agree.
enum PaneElevation {
    /// THE spacing of the elevated layout: between the outermost panes and
    /// the window's edge (room for their shadows), between the mini rail and
    /// the panes, and around the rail.
    static let margin: CGFloat = 10
    /// The gap between two panes — the same number, so every gutter in the
    /// window matches (an 8pt gap beside a 10pt margin read as uneven). It is
    /// still the divider: drag it.
    static var gap: CGFloat { margin }
    /// The card's corner radius.
    static let cornerRadius: CGFloat = 11

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// The gap a `SplitView` should leave, or nil for the classic 1pt line.
    static func paneGap(for style: Ghostty.Config.MacOSPaneStyle) -> CGFloat? {
        style == .elevated ? gap : nil
    }
}

/// The colors of one window's gradient desk.
///
/// The default is the "ocean" palette the style was chosen with: two pools,
/// blue and teal, at opposite corners. A window opened with `--color=random`
/// (or by hand, with Cmd-N) gets a `PaneDeskVariant` instead: a random hue
/// from the whole wheel with a soft spotlight from the top center, falling
/// away darker toward the bottom-trailing corner on a dark theme (lighter on
/// a light one) — where a dim pool of the COMPLEMENTARY hue subtly lights it.
struct PaneDeskPalette: Equatable {
    struct HSB: Equatable {
        var hue: Double        // 0...1
        var saturation: Double // 0...1
        var brightness: Double // 0...1

        var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }
    }

    enum Look: Equatable {
        /// A pool of color at the top-leading corner and another at the
        /// bottom-trailing one; each reach is a fraction of the window's
        /// longer side. (Ocean.)
        case pools(lead: HSB, trail: HSB, leadReach: Double, trailReach: Double)
        /// A spotlight from just above the top center, and a dim pool of the
        /// complementary hue lighting the bottom-trailing corner. (A variant.)
        case spotlight(light: HSB, accent: HSB)
    }

    /// The base the look sits on, from its top-leading end to its far end.
    var baseStart: HSB
    var baseEnd: HSB
    var look: Look

    /// The ocean palette: blue top-leading, teal bottom-trailing, over slate.
    static func ocean(isLight: Bool) -> PaneDeskPalette {
        isLight
            ? .init(
                baseStart: .init(hue: 206 / 360, saturation: 0.04, brightness: 0.98),
                baseEnd: .init(hue: 198 / 360, saturation: 0.03, brightness: 0.96),
                look: .pools(
                    lead: .init(hue: 205 / 360, saturation: 0.16, brightness: 0.97),
                    trail: .init(hue: 171 / 360, saturation: 0.14, brightness: 0.93),
                    leadReach: 0.75, trailReach: 0.65))
            : .init(
                baseStart: .init(hue: 213 / 360, saturation: 0.50, brightness: 0.14),
                baseEnd: .init(hue: 213 / 360, saturation: 0.39, brightness: 0.11),
                look: .pools(
                    lead: .init(hue: 205 / 360, saturation: 0.73, brightness: 0.42),
                    trail: .init(hue: 177 / 360, saturation: 0.77, brightness: 0.35),
                    leadReach: 0.75, trailReach: 0.65))
    }
}

/// A window's own gradient: a seed, from which the palette is DERIVED for the
/// current theme, so a window keeps its character across a light/dark switch
/// and across a session restore (the seed is what persists).
struct PaneDeskVariant: Codable, Equatable {
    let seed: UInt64

    static func random() -> PaneDeskVariant {
        PaneDeskVariant(seed: UInt64.random(in: 1...UInt64.max))
    }

    /// The base config for a window the user opens BY HAND (Cmd-N, the New
    /// Window menu item or palette command): in the elevated style it gets
    /// its own random gradient, the same as `+new-window --color=random`, so
    /// side-by-side windows are easy to tell apart. A variant already on the
    /// config is kept; the flat style has no desk to vary.
    static func forNewWindow(
        _ base: Ghostty.SurfaceConfiguration?,
        style: Ghostty.Config.MacOSPaneStyle
    ) -> Ghostty.SurfaceConfiguration? {
        guard style == .elevated else { return base }
        var config = base ?? Ghostty.SurfaceConfiguration()
        if config.deskVariant == nil { config.deskVariant = .random() }
        return config
    }

    func palette(isLight: Bool) -> PaneDeskPalette {
        var rng = SplitMix64(seed: seed)
        func pick(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * rng.nextUnit()
        }
        // A hue from the whole wheel (what `--color=random` has always drawn
        // from) for everything, except the corner light: its complement.
        // (A NEIGHBORING second hue read as duo-toned; the complement, dim and
        // confined to one corner, reads as light from elsewhere.)
        let degrees = pick(0...360)
        let hue = degrees / 360
        let complement = (degrees + 180).truncatingRemainder(dividingBy: 360) / 360

        if isLight {
            // A tinted near-white, brightening toward the top center and
            // getting LIGHTER toward the bottom-trailing corner, which the
            // complement faintly colors.
            let start = pick(0.93...0.945)
            return .init(
                baseStart: .init(hue: hue, saturation: pick(0.07...0.10), brightness: start),
                baseEnd: .init(hue: hue, saturation: pick(0.02...0.04), brightness: start + pick(0.035...0.045)),
                look: .spotlight(
                    light: .init(hue: hue, saturation: pick(0.02...0.04), brightness: 1.0),
                    accent: .init(hue: complement, saturation: pick(0.10...0.15), brightness: pick(0.96...0.99))))
        }
        // A deep slate of the hue, lit from the top center and getting DARKER
        // toward the bottom-trailing corner — where the complement glows,
        // dimly: well under the spotlight, a little over the base.
        let start = pick(0.15...0.18)
        return .init(
            baseStart: .init(hue: hue, saturation: pick(0.38...0.50), brightness: start),
            baseEnd: .init(hue: hue, saturation: pick(0.35...0.45), brightness: start - pick(0.07...0.09)),
            look: .spotlight(
                light: .init(hue: hue, saturation: pick(0.30...0.42), brightness: pick(0.40...0.48)),
                accent: .init(hue: complement, saturation: pick(0.40...0.55), brightness: pick(0.22...0.28))))
    }
}

/// A tiny seeded generator, so a variant's palette is the same every time
/// it is derived (and on every machine).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in 0..<1.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// The soft gradient the elevated panes sit on: a gently graded base under
/// either two soft corner pools (ocean) or a spotlight from the top center
/// and a dim complementary light in the far corner (a variant) — simple on purpose, nothing
/// that competes with the terminals.
struct PaneDesk: View {
    let palette: PaneDeskPalette
    /// The terminal's `background-opacity`: a translucent terminal gets a
    /// translucent desk, so the desktop still shows through.
    let opacity: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let reach = max(size.width, size.height)
            ZStack {
                switch palette.look {
                case let .pools(lead, trail, leadReach, trailReach):
                    LinearGradient(
                        colors: [palette.baseStart.color, palette.baseEnd.color],
                        startPoint: UnitPoint(x: 0.2, y: 0),
                        endPoint: UnitPoint(x: 0.8, y: 1))
                    RadialGradient(
                        colors: [lead.color, .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: reach * leadReach)
                    RadialGradient(
                        colors: [trail.color, .clear],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: reach * trailReach)

                case let .spotlight(light, accent):
                    LinearGradient(
                        colors: [palette.baseStart.color, palette.baseEnd.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                    // An ellipse fitted to the window, so the light spreads
                    // wide across the top and only part way down.
                    EllipticalGradient(
                        colors: [light.color, light.color.opacity(0.45), .clear],
                        center: UnitPoint(x: 0.5, y: -0.1),
                        startRadiusFraction: 0,
                        endRadiusFraction: 0.95)
                    RadialGradient(
                        colors: [accent.color, accent.color.opacity(0.35), .clear],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: reach * 0.6)
                }
            }
        }
        .opacity(opacity)
        .accessibilityHidden(true)
    }
}

/// A pane as a raised card: clipped to the card's shape, over an opaque
/// card-colored base that carries the shadow (an AppKit view can't cast a
/// SwiftUI shadow, so the base does it from behind) — or, with
/// `macos-pane-glass`, over a translucent glass sheet tinted with the same
/// color, through which the window's gradient reads. The terminal draws no
/// background of its own in that case (the renderer applies the same rule),
/// so the sheet IS the pane's background.
struct PaneCard: ViewModifier {
    let isElevated: Bool
    var isGlass: Bool = false
    var isFocused: Bool = false
    let background: Color
    let isLight: Bool

    func body(content: Content) -> some View {
        card(content)
            .background {
                if isElevated {
                    PaneFocusGlow(isLight: isLight)
                        .opacity(isFocused ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.25), value: isFocused)
    }

    @ViewBuilder
    private func card(_ content: Content) -> some View {
        if isElevated && isGlass {
            content
                .clipShape(PaneElevation.cardShape)
                .overlay(
                    PaneElevation.cardShape
                        // The focused pane's rim is a touch brighter, with its glow.
                        .strokeBorder(isLight
                                      ? Color.black.opacity(isFocused ? 0.12 : 0.08)
                                      : Color.white.opacity(isFocused ? 0.20 : 0.10),
                                      lineWidth: 0.5)
                        .allowsHitTesting(false))
                .background(PaneGlass(tint: background, isLight: isLight))
        } else if isElevated {
            content
                .clipShape(PaneElevation.cardShape)
                .overlay(
                    PaneElevation.cardShape
                        .strokeBorder(isLight
                                      ? Color.black.opacity(isFocused ? 0.10 : 0.06)
                                      : Color.white.opacity(isFocused ? 0.16 : 0.07),
                                      lineWidth: 0.5)
                        .allowsHitTesting(false))
                .background(
                    PaneElevation.cardShape
                        .fill(background)
                        .shadow(color: .black.opacity(isLight ? 0.08 : 0.28), radius: 1, y: 1)
                        .shadow(color: .black.opacity(isLight ? 0.12 : 0.24), radius: 11, y: 8))
        } else {
            content
        }
    }
}

/// The focused pane's glow: the pane reads as BACKLIT — a soft light from
/// under the card spilling out about 8pt past its edges onto the desk. It sits BEHIND
/// the card and is masked to outside its shape, so it never lightens the
/// pane's own glass.
struct PaneFocusGlow: View {
    let isLight: Bool

    var body: some View {
        let shape = PaneElevation.cardShape
        shape
            .stroke(Color.white.opacity(isLight ? 0.8 : 0.4), lineWidth: 4)
            // Tight: the light dies out ~8pt past the edge.
            .blur(radius: 4)
            .mask {
                ZStack {
                    Rectangle().padding(-48)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
    }
}

/// The glass sheet behind a glass pane. It is tinted with the terminal's own
/// background — neutral, so text keeps its contrast — and lets the desk's
/// light and shade through.
struct PaneGlass: View {
    let tint: Color
    let isLight: Bool
    var cornerRadius: CGFloat = PaneElevation.cornerRadius
    var tintStrength: Double = PaneGlass.tint

    /// How much of the terminal's background the sheet keeps — 40%: chosen
    /// as 50% in the pane-sidebar mock, lowered after living with it in the
    /// app so the gradient's light and shade carry through more strongly,
    /// while text keeps its contrast.
    static let tint: Double = 0.4
    /// A glass card floating over glass panes (the unpinned sidebar).
    static let overlayTint: Double = 0.3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(tint.opacity(tintStrength)), in: shape)
        } else {
            shape
                .fill(tint.opacity(tintStrength))
                .shadow(color: .black.opacity(isLight ? 0.06 : 0.2), radius: 9, y: 6)
        }
    }
}
