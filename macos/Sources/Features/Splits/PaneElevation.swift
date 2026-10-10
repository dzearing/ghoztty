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
    /// The gap between two panes. It is still the divider: drag it.
    static let gap: CGFloat = 8
    /// Space between the outermost panes and the window's edge, so their
    /// shadows have room.
    static let margin: CGFloat = 10
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

/// The soft gradient the elevated panes sit on: blue at the top-leading
/// corner, teal at the bottom-trailing, over a deep slate (or, on a light
/// terminal theme, their pale counterparts). Deliberately simple — two soft
/// pools of color, nothing that competes with the terminals.
struct PaneDesk: View {
    /// Whether the terminal background is light.
    let isLight: Bool
    /// The terminal's `background-opacity`: a translucent terminal gets a
    /// translucent desk, so the desktop still shows through.
    let opacity: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let reach = max(size.width, size.height)
            ZStack {
                LinearGradient(
                    colors: isLight
                        ? [Color(hex: 0xF1F6FA), Color(hex: 0xEDF2F4)]
                        : [Color(hex: 0x121A24), Color(hex: 0x11161C)],
                    startPoint: UnitPoint(x: 0.2, y: 0),
                    endPoint: UnitPoint(x: 0.8, y: 1))
                RadialGradient(
                    colors: [isLight ? Color(hex: 0xCFE6F7) : Color(hex: 0x1D4B6C), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: reach * 0.75)
                RadialGradient(
                    colors: [isLight ? Color(hex: 0xCDEEE9) : Color(hex: 0x155A57), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: reach * 0.65)
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

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
