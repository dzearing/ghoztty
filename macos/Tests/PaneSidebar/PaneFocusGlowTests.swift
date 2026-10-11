import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The focused pane's backlit glow, rendered offscreen: light reaches
/// OUTSIDE the card (onto the desk) and never inside it.
@MainActor
struct PaneFocusGlowTests {
    private func render(focused: Bool) throws -> NSBitmapImageRep {
        let view = ZStack {
            Color(red: 0.1, green: 0.12, blue: 0.11)
            Color.clear
                .frame(width: 200, height: 140)
                .modifier(PaneCard(
                    isElevated: true, isGlass: true, isFocused: focused,
                    background: Color(red: 0.11, green: 0.12, blue: 0.14), isLight: false))
        }
        .frame(width: 300, height: 240)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    private func brightness(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0
    }

    @Test func theFocusedPaneLightsTheDeskAroundIt() throws {
        let lit = try render(focused: true), dark = try render(focused: false)
        try? lit.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "/tmp/pane-sidebar-snapshots/focus-glow.png"))
        // 3pt outside the card's right edge (card spans x 50...250).
        #expect(brightness(lit, 253, 120) > brightness(dark, 253, 120) + 0.02, "no light outside the card")
        // Nothing lights the pane itself: 6pt inside the same edge is unchanged.
        #expect(abs(brightness(lit, 244, 120) - brightness(dark, 244, 120)) < 0.01, "the glow reached inside the card")
        // Tight: it has died out by the 10pt gap to the next pane, so a
        // neighbouring glass pane never looks lit from behind.
        #expect(abs(brightness(lit, 260, 120) - brightness(dark, 260, 120)) < 0.01, "the glow spreads too far")
        // Far from the card, the desk is untouched.
        #expect(abs(brightness(lit, 296, 120) - brightness(dark, 296, 120)) < 0.02)
    }
}
