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
/// The default is the "ocean" palette the style was chosen with. A window
/// opened with `--color=random` gets a `PaneDeskVariant` instead: tones drawn
/// at random from the SAME family (blues and teals), falling off darker toward
/// the bottom-trailing corner on a dark theme and lighter on a light one.
struct PaneDeskPalette: Equatable {
    struct HSB: Equatable {
        var hue: Double        // 0...1
        var saturation: Double // 0...1
        var brightness: Double // 0...1

        var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }
    }

    /// The pool of color at the top-leading corner, and at the bottom-trailing.
    var lead: HSB
    var trail: HSB
    /// The base the pools sit on, from its top-leading end to its far end.
    var baseStart: HSB
    var baseEnd: HSB
    /// How far each pool reaches, as a fraction of the window's longer side.
    var leadReach: Double
    var trailReach: Double

    /// The ocean palette: blue top-leading, teal bottom-trailing, over slate.
    static func ocean(isLight: Bool) -> PaneDeskPalette {
        isLight
            ? .init(
                lead: .init(hue: 205 / 360, saturation: 0.16, brightness: 0.97),
                trail: .init(hue: 171 / 360, saturation: 0.14, brightness: 0.93),
                baseStart: .init(hue: 206 / 360, saturation: 0.04, brightness: 0.98),
                baseEnd: .init(hue: 198 / 360, saturation: 0.03, brightness: 0.96),
                leadReach: 0.75, trailReach: 0.65)
            : .init(
                lead: .init(hue: 205 / 360, saturation: 0.73, brightness: 0.42),
                trail: .init(hue: 177 / 360, saturation: 0.77, brightness: 0.35),
                baseStart: .init(hue: 213 / 360, saturation: 0.50, brightness: 0.14),
                baseEnd: .init(hue: 213 / 360, saturation: 0.39, brightness: 0.11),
                leadReach: 0.75, trailReach: 0.65)
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

    /// The ocean family's ranges, in degrees.
    static let leadHues: ClosedRange<Double> = 196...224   // blues
    static let trailHues: ClosedRange<Double> = 164...190  // teals

    func palette(isLight: Bool) -> PaneDeskPalette {
        var rng = SplitMix64(seed: seed)
        func pick(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * rng.nextUnit()
        }
        let leadHue = pick(Self.leadHues) / 360
        let trailHue = pick(Self.trailHues) / 360
        let baseHue = pick(200...216) / 360
        let leadReach = pick(0.6...0.85)
        let trailReach = pick(0.5...0.75)

        if isLight {
            // Pale pools on a near-white base that gets LIGHTER away from the
            // top-leading corner.
            let start = pick(0.95...0.965)
            return .init(
                lead: .init(hue: leadHue, saturation: pick(0.12...0.22), brightness: pick(0.95...0.98)),
                trail: .init(hue: trailHue, saturation: pick(0.10...0.18), brightness: pick(0.92...0.96)),
                baseStart: .init(hue: baseHue, saturation: pick(0.03...0.06), brightness: start),
                baseEnd: .init(hue: baseHue, saturation: pick(0.01...0.03), brightness: min(0.995, start + pick(0.02...0.035))),
                leadReach: leadReach, trailReach: trailReach)
        }
        // Deep pools on a slate base that gets DARKER away from the
        // top-leading corner.
        let start = pick(0.13...0.17)
        return .init(
            lead: .init(hue: leadHue, saturation: pick(0.55...0.78), brightness: pick(0.34...0.46)),
            trail: .init(hue: trailHue, saturation: pick(0.55...0.78), brightness: pick(0.28...0.38)),
            baseStart: .init(hue: baseHue, saturation: pick(0.35...0.55), brightness: start),
            baseEnd: .init(hue: baseHue, saturation: pick(0.30...0.45), brightness: start - pick(0.04...0.06)),
            leadReach: leadReach, trailReach: trailReach)
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

/// The soft gradient the elevated panes sit on: two soft pools of color at
/// opposite corners over a gently graded base — simple on purpose, nothing
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
                LinearGradient(
                    colors: [palette.baseStart.color, palette.baseEnd.color],
                    startPoint: UnitPoint(x: 0.2, y: 0),
                    endPoint: UnitPoint(x: 0.8, y: 1))
                RadialGradient(
                    colors: [palette.lead.color, .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: reach * palette.leadReach)
                RadialGradient(
                    colors: [palette.trail.color, .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: reach * palette.trailReach)
            }
        }
        .opacity(opacity)
        .accessibilityHidden(true)
    }
}

/// A pane as a raised card: clipped to the card's shape, over an opaque
/// card-colored base that carries the shadow (an AppKit view can't cast a
/// SwiftUI shadow, so the base does it from behind).
struct PaneCard: ViewModifier {
    let isElevated: Bool
    let background: Color
    let isLight: Bool

    func body(content: Content) -> some View {
        if isElevated {
            content
                .clipShape(PaneElevation.cardShape)
                .overlay(
                    PaneElevation.cardShape
                        .strokeBorder(isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.07),
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
