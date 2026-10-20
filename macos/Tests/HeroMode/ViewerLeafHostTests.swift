import AppKit
import Testing
@testable import Ghostty

/// Who may mount a viewer pane: the grid's leaf host, except while hero mode
/// holds it. SwiftUI can build a leaf in the grid hero mode just replaced; if
/// that leaf took the pane, the hero went blank once the leaf was torn down.
@MainActor
struct ViewerLeafHostTests {
    private func makeViewer() throws -> ViewerView {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-leaf-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("doc.md")
        try "# doc".write(to: file, atomically: true, encoding: .utf8)
        return ViewerView(location: file.path)
    }

    @Test func aNewLeafTakesThePane() throws {
        let viewer = try makeViewer()
        let first = ViewerLeafHost(viewerView: viewer)
        #expect(viewer.superview === first)
        let second = ViewerLeafHost(viewerView: viewer)
        #expect(viewer.superview === second)
    }

    @Test func aLeafNeverTakesThePaneFromHero() throws {
        let viewer = try makeViewer()
        let grid = ViewerLeafHost(viewerView: viewer)
        let slot = NSView()
        slot.addSubview(viewer)
        viewer.holdForHero()

        // The replaced grid updating, and building a fresh leaf.
        grid.adoptIfOrphaned()
        let stale = ViewerLeafHost(viewerView: viewer)
        stale.adopt()
        #expect(viewer.superview === slot)

        // Hero mode lets go: the grid's latest leaf takes it back.
        viewer.releaseFromHero()
        #expect(viewer.superview === stale)
    }

    @Test func holdsCountSoARebuiltHeroKeepsThePane() throws {
        let viewer = try makeViewer()
        let grid = ViewerLeafHost(viewerView: viewer)
        let slot = NSView()
        slot.addSubview(viewer)
        viewer.holdForHero()
        // A rebuilt hero container claims before the old one lets go.
        viewer.holdForHero()
        viewer.releaseFromHero()
        #expect(viewer.isInHero)
        #expect(viewer.superview === slot)
        viewer.releaseFromHero()
        #expect(!viewer.isInHero)
        #expect(viewer.superview === grid)
        // An extra release is ignored.
        viewer.releaseFromHero()
        #expect(!viewer.isInHero)
    }

    @Test func anOrphanedPaneIsTakenBack() throws {
        let viewer = try makeViewer()
        let grid = ViewerLeafHost(viewerView: viewer)
        viewer.removeFromSuperview()
        grid.adoptIfOrphaned()
        #expect(viewer.superview === grid)
    }
}
