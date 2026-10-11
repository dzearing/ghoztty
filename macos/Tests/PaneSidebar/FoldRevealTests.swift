import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The fold transition's mask: mid-fold the rows are cut off at a straight
/// edge where they are, never moved up over the header above them.
@MainActor
struct FoldRevealTests {
    private func render(_ fraction: CGFloat) throws -> NSBitmapImageRep {
        let view = Color.white.frame(width: 40, height: 100)
            .modifier(FoldReveal(fraction: fraction))
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    private func isWhite(_ rep: NSBitmapImageRep, y: Int) -> Bool {
        (rep.colorAt(x: 20, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.5
    }

    @Test func halfwayShowsTheTopHalfInPlace() throws {
        let half = try render(0.5)
        #expect(isWhite(half, y: 5), "the top of the rows stays where it is")
        #expect(isWhite(half, y: 45))
        #expect(!isWhite(half, y: 55), "below the edge is covered")
        #expect(!isWhite(half, y: 95))
        let open = try render(1)
        #expect(isWhite(open, y: 95))
        let shut = try render(0)
        #expect(!isWhite(shut, y: 5))
    }
}
