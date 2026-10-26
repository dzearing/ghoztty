import AppKit
import Combine
import ScreenCaptureKit
import WebKit
import GhosttyKit
import SwiftUI
import Testing
@testable import Ghostty

/// The pane sidebar in a REAL terminal window: layout geometry, and the
/// geometry property the design promises — a stashed terminal keeps its size,
/// so restoring it to its slot is not a reflow event.
///
/// Terminals run `/bin/cat` (no shell, no session agent), as in
/// `ViewerKeyFallbackWindowTests`. Set `PANE_SIDEBAR_SNAPSHOTS=<dir>` to also
/// write a PNG of each state — the window draws itself, so this needs no
/// screen-recording permission (glass materials don't composite offscreen;
/// geometry is exact).
@MainActor
@Suite(.serialized)
struct PaneSidebarWindowTests {
    private struct Harness {
        let controller: TerminalController
        let window: NSWindow
        let panes: [PaneView]
    }

    private func settle(_ seconds: TimeInterval = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await settle(0.05)
        }
        return condition()
    }

    private func terminalPane(_ app: ghostty_app_t) -> PaneView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        return PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
    }

    /// a | (b / c), three terminals, in a 1100×700 window.
    private func open(expanded: Bool, width: CGFloat = 1100) async throws -> Harness {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app), c = terminalPane(app)
        let tree = try SplitTree<PaneView>(view: a)
            .inserting(view: b, at: a, direction: .right)
            .inserting(view: c, at: b, direction: .down)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = false
        controller.paneSidebarState.isExpanded = expanded
        controller.paneSidebarState.width = 240
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: width, height: 700))
        await settle(0.8)
        return Harness(controller: controller, window: window, panes: [a, b, c])
    }

    private func close(_ h: Harness) async {
        h.controller.close()
        await settle(0.3)
    }

    /// The elevated pane style insets the grid by a margin; flat does not.
    private func gridMargin(_ h: Harness) -> CGFloat {
        h.controller.ghostty.config.macosPaneStyle == .elevated ? PaneElevation.margin : 0
    }

    private func frameInWindow(_ pane: PaneView) -> NSRect {
        pane.contentView.convert(pane.contentView.bounds, to: nil)
    }

    private func gridSize(_ pane: PaneView) -> (cols: UInt16, rows: UInt16, w: UInt32, h: UInt32)? {
        guard let surface = pane.surface else { return nil }
        let size = ghostty_surface_size(surface)
        return (size.columns, size.rows, size.width_px, size.height_px)
    }

    private func snapshot(_ h: Harness, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PANE_SIDEBAR_SNAPSHOTS"]
            ?? (FileManager.default.fileExists(atPath: "/tmp/pane-sidebar-snapshots") ? "/tmp/pane-sidebar-snapshots" : nil),
              let view = h.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A drag resizes a pane dozens of times a second, and every resize that
    /// reaches the program is a SIGWINCH — on which a full-screen TUI like
    /// Claude Code clears and repaints: the flicker. Resizes that arrive in a
    /// burst must reach the program as a few, not one per frame.
    @Test func aDragDoesNotStormTheProgramWithResizes() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let countFile = "/tmp/pane-sidebar-snapshots/winch-\(UUID().uuidString).txt"
        try? FileManager.default.createDirectory(atPath: "/tmp/pane-sidebar-snapshots", withIntermediateDirectories: true)
        var config = Ghostty.SurfaceConfiguration()
        config.command = """
            /usr/bin/python3 -c "import signal,sys
            n=[0]
            def h(*a):
                n[0]+=1
                open('\(countFile)','w').write(str(n[0]))
            signal.signal(signal.SIGWINCH,h)
            open('\(countFile)','w').write('0')
            while True: signal.pause()"
            """
        let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree(view: pane))
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 900, height: 600))
        _ = await poll(timeout: 10) { FileManager.default.fileExists(atPath: countFile) }
        await settle(1.0)
        let read = { Int((try? String(contentsOfFile: countFile, encoding: .utf8)) ?? "") ?? -1 }
        let before = read()

        // ~600ms of drag: 40 steps of 4pt, one every 15ms (longer on a busy
        // machine, which the bound below allows for).
        let started = Date()
        for step in 1...40 {
            window.setContentSize(NSSize(width: 900 + CGFloat(step) * 4, height: 600))
            await settle(0.015)
        }
        let dragSeconds = Date().timeIntervalSince(started)
        await settle(1.0)
        let during = read() - before
        try? "resizes delivered during the drag: \(during) over \(Int(dragSeconds * 1000))ms\n".write(
            toFile: "/tmp/pane-sidebar-snapshots/winch-result.txt", atomically: true, encoding: .utf8)
        #expect(during >= 1, "the final size must still arrive")
        // Was 35 (one per 25ms) before the debounce; 4 after, measured. A long
        // drag still updates every 350ms (the cap), so the bound scales with
        // how long the drag actually took.
        let allowed = Int(dragSeconds / 0.35) + 2
        #expect(during <= allowed,
                "a \(Int(dragSeconds * 1000))ms drag reached the program as \(during) resizes (allowed \(allowed))")

        controller.close()
        await settle(0.3)
        try? FileManager.default.removeItem(atPath: countFile)
    }

    /// The all-windows scope sorted by name, `<project>: <worktree>` windows
    /// under their project's header. Writes all-windows.png.
    @Test func allWindowsGroupsProjects() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var controllers: [TerminalController] = []
        for title in ["ghoztty: windows-amd64", "relay: main", "ghoztty: pane-sidebar", "Build logs"] {
            let c = TerminalController.newWindow(ghostty, tree: SplitTree(view: terminalPane(app)))
            c.windowTitleOverride = title
            controllers.append(c)
        }
        let main = controllers[2]
        main.paneSidebarState.isHidden = false
        main.paneSidebarState.isExpanded = true
        main.paneSidebarState.width = 260
        main.paneSidebarState.showsAllWindows = true
        _ = await poll(timeout: 10) { controllers.allSatisfy { $0.window?.isVisible == true } }
        let window = try #require(main.window)
        window.setContentSize(NSSize(width: 900, height: 560))
        await settle(1.2)
        try await captureComposited(window, "all-windows")
        // The empty field, then focused: the placeholder must not move.
        func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { all(type, in: $0) }
        }
        let content = try #require(window.contentView)
        let field = try #require(all(NSTextField.self, in: content).first { $0.placeholderString == "Search" })
        try await captureComposited(window, "search-idle")
        window.makeFirstResponder(field)
        await settle(0.4)
        try await captureComposited(window, "search-focused")
        window.makeFirstResponder(nil)
        // Searching: only matching windows, under their project.
        main.paneSidebarState.filter = "ghoztty side"
        await settle(0.6)
        try await captureComposited(window, "all-windows-search")
        // Leaving all windows drops the search.
        main.paneSidebarState.showsAllWindows = false
        #expect(main.paneSidebarState.filter.isEmpty)
        for c in controllers { c.close() }
        await settle(0.3)
    }

    /// Writes `window` as the window server composites it.
    @discardableResult
    private func captureComposited(_ window: NSWindow, _ name: String) async throws -> CGImage {
        let dir = "/tmp/pane-sidebar-snapshots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = try await SCShareableContent.currentProcess
        let scWindow = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let cfg = SCStreamConfiguration()
        cfg.width = Int(scWindow.frame.width * 2)
        cfg.height = Int(scWindow.frame.height * 2)
        cfg.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: cfg)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        return image
    }

    /// A column of pixels, as sRGB 0–255 triples: `x` in window points, rows
    /// down the lower part of `pane` (clear of its text, inside its rounded
    /// corners).
    private func column(_ image: CGImage, x: CGFloat, along pane: CGRect, in window: NSWindow) -> [[Double]] {
        let scale = CGFloat(image.width) / window.frame.width
        let rep = NSBitmapImageRep(cgImage: image)
        return stride(from: pane.minY + 30, to: pane.minY + 30 + pane.height * 0.25, by: 4).compactMap { y in
            guard let c = rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale))?
                .usingColorSpace(.sRGB) else { return nil }
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) * 255 }
        }
    }

    /// How much of the desk a pane HIDES: the mean per-channel distance
    /// (0–255) between the pane's glass just inside its outer edge and the
    /// bare desk in the gutter just outside it, row by row — the gradient
    /// is smooth over those few points, so 0 would be clear glass. `desk` is
    /// that gutter column taken while the pane is NOT focused, so the focus
    /// glow, which spills into the gutter, is not mistaken for the desk.
    private func occlusion(_ image: CGImage, pane: CGRect, edgeX: CGFloat, inward: CGFloat,
                           desk: [[Double]], in window: NSWindow) -> Double {
        let inside = column(image, x: edgeX + inward * 24, along: pane, in: window)
        let pairs = zip(inside, desk)
        let total = pairs.reduce(0.0) { sum, p in
            sum + (abs(p.0[0] - p.1[0]) + abs(p.0[1] - p.1[1]) + abs(p.0[2] - p.1[2])) / 3
        }
        return total / Double(max(pairs.underestimatedCount, 1))
    }

    /// A stacked row's cards on show lie over nothing but the desk, so they
    /// stay glass — and follow the focused/unfocused rule — rather than going
    /// solid for being in a stack (`PaneLayout.covering`). Five terminals in a
    /// window with room for four: four on show, one sliver past them.
    @Test func stackedRowCardsOnShowStayGlass() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        try #require(ghostty.config.paneGlass, "needs the default elevated + glass pane style")
        let app = try #require(ghostty.app)
        let panes = (0..<5).map { _ in terminalPane(app) }
        var tree = SplitTree<PaneView>(view: panes[0])
        for i in 1..<5 { tree = try tree.inserting(view: panes[i], at: panes[i - 1], direction: .right) }
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.deskVariant = PaneDeskVariant(seed: 7)
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 760))
        await settle(2.5)

        func frame(_ pane: PaneView) -> CGRect {
            pane.surfaceView.map { $0.convert($0.bounds, to: nil) } ?? .null
        }
        func capture(focusing pane: PaneView, _ name: String) async throws -> (CGImage, [CGRect]) {
            window.makeFirstResponder(pane.surfaceView)
            _ = await poll(timeout: 2) { pane.isFocusedPane }
            await settle(0.8)
            return (try await captureComposited(window, name), panes.map(frame))
        }
        // Focus the second card, then the third: both are on show either way,
        // and the cards stay where they are (focus moving within the run
        // slides nothing), so each state is measured over the same desk.
        let (focus1, frames1) = try await capture(focusing: panes[1], "glass-stack-focus-1")
        let (focus2, frames2) = try await capture(focusing: panes[2], "glass-stack-focus-2")
        #expect(frames1 == frames2, "the cards moved: \(frames1) → \(frames2)")
        let card = frames2[2]
        #expect(card.width < 400, "the row should be stacked, not side by side: \(frames2)")
        let next = frames2[3]
        #expect(next.minX > card.maxX, "the card after the third is on show beside it: \(frames2)")

        // The third card, measured at its RIGHT edge against the gutter
        // between it and the fourth (desk only while neither is focused).
        let desk = column(focus1, x: card.maxX + 5, along: card, in: window)
        let unfocused = occlusion(focus1, pane: card, edgeX: card.maxX, inward: -1, desk: desk, in: window)
        let focused = occlusion(focus2, pane: card, edgeX: card.maxX, inward: -1, desk: desk, in: window)
        let report = "stacked card: focused \(focused) unfocused \(unfocused)\nframes \(frames2)"
        try? report.write(toFile: "/tmp/pane-sidebar-snapshots/glass-stack.txt", atomically: true, encoding: .utf8)
        #expect(unfocused + 4 < focused, "\(report)")
    }

    /// Hero mode on glass shows its pane as the same glass card a focused
    /// pane is — not on an opaque fill of the terminal background. Measured as
    /// how much of the desk the pane hides at its left edge, against the desk in
    /// the margin beside it: the hero hides no more than the same pane focused
    /// in the grid did.
    @Test func heroModeIsGlassLikeAFocusedPane() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        try #require(ghostty.config.paneGlass, "needs the default elevated + glass pane style")
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let tree = try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.deskVariant = PaneDeskVariant(seed: 7)
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 760))
        await settle(2.5)
        let view = try #require(a.surfaceView)
        window.makeFirstResponder(view)
        await settle(0.8)

        let grid = try await captureComposited(window, "glass-hero-grid")
        let gridFrame = view.convert(view.bounds, to: nil)

        controller.toggleHeroMode(self)
        _ = await poll(timeout: 2) { controller.heroModeState.isActive }
        await settle(1.5)
        let hero = try await captureComposited(window, "glass-hero")
        // The hero pane is wherever its container is; the pane's own view sits
        // in a strip that scrolls inside it.
        func find(_ v: NSView) -> HeroPaneContainer? {
            (v as? HeroPaneContainer) ?? v.subviews.lazy.compactMap(find).first
        }
        let content = try #require(window.contentView)
        let container = try #require(find(content))
        let heroFrame = container.convert(container.bounds, to: nil)


        // The desk beside the pane's left edge — from the hero capture, where
        // no focus glow spills into the margin; both cards start at that edge.
        #expect(heroFrame.minX == gridFrame.minX)
        let heroDesk = column(hero, x: heroFrame.minX - 5, along: heroFrame, in: window)
        let focused = occlusion(grid, pane: gridFrame, edgeX: gridFrame.minX, inward: 1, desk: heroDesk, in: window)
        let heroOcclusion = occlusion(hero, pane: heroFrame, edgeX: heroFrame.minX, inward: 1, desk: heroDesk, in: window)
        // Same desk, same edge: the glass just inside it should be the same
        // pixels whether the pane is focused in the grid or the hero.
        let gridGlass = column(grid, x: gridFrame.minX + 24, along: gridFrame, in: window)
        let heroGlass = column(hero, x: heroFrame.minX + 24, along: heroFrame, in: window)
        let pairs = zip(gridGlass, heroGlass)
        let apart = pairs.reduce(0.0) { $0 + (abs($1.0[0] - $1.1[0]) + abs($1.0[1] - $1.1[1]) + abs($1.0[2] - $1.1[2])) / 3 }
            / Double(max(pairs.underestimatedCount, 1))
        controller.toggleHeroMode(self)
        await settle(0.4)

        let report = "focused in grid \(focused), hero \(heroOcclusion), apart \(apart), frames \(gridFrame) \(heroFrame)"
        try? report.write(toFile: "/tmp/pane-sidebar-snapshots/glass-hero.txt", atomically: true, encoding: .utf8)
        #expect(!gridGlass.isEmpty)
        #expect(apart < 2, "the hero is not the glass a focused pane is: \(report)")
    }

    /// Glass panes: an UNFOCUSED pane is more see-through than the focused
    /// one — the desk reads through it more — and the focused pane is the
    /// solid one. Measured on the composited window, per pane against itself
    /// in both states, for terminals and a viewer alike.
    @Test func unfocusedGlassPanesAreMoreTransparent() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        try #require(ghostty.config.paneGlass, "needs the default elevated + glass pane style")
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        // A short markdown page: a template page, so it goes see-through on
        // glass, with blank space below its one line to sample.
        let doc = FileManager.default.temporaryDirectory.appendingPathComponent("glass-focus-\(UUID().uuidString).md")
        try "# Glass\n".write(to: doc, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: doc) }
        let viewer = PaneView(viewer: ViewerView(location: doc.path))
        let tree = try SplitTree<PaneView>(view: a)
            .inserting(view: b, at: a, direction: .right)
            .inserting(view: viewer, at: b, direction: .down)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.deskVariant = PaneDeskVariant(seed: 7)
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 760))
        await settle(2.5)
        let views: [NSView] = [try #require(a.surfaceView), try #require(b.surfaceView), try #require(viewer.viewerView)]
        // Pane a is measured at its window-side LEFT edge, b and the viewer at
        // their window-side RIGHT edge: the gutter there is only desk.
        let frames = views.map { $0.convert($0.bounds, to: nil) }
        let edges: [(x: CGFloat, inward: CGFloat)] = [(frames[0].minX, 1), (frames[1].maxX, -1), (frames[2].maxX, -1)]

        func capture(focusing pane: PaneView, _ responder: NSView, _ name: String) async throws -> CGImage {
            window.makeFirstResponder(responder)
            _ = await poll(timeout: 2) { pane.isFocusedPane }
            #expect(pane.isFocusedPane)
            await settle(0.8)
            return try await captureComposited(window, name)
        }
        let shots = [
            try await capture(focusing: a, views[0], "glass-focus-a"),
            try await capture(focusing: b, views[1], "glass-focus-b"),
            try await capture(focusing: viewer, try #require(viewer.viewerView?.webView), "glass-focus-viewer"),
        ]
        // occlusion[pane][shot]; shot i has pane i focused. Each pane's
        // unfocused shot is one with a TERMINAL focused elsewhere (a's is b's,
        // everyone else's is a's).
        let unfocused = [1, 0, 0]
        let occ: [[Double]] = (0..<3).map { p in
            let unfocusedShot = shots[unfocused[p]]
            let desk = column(unfocusedShot, x: edges[p].x - edges[p].inward * 5, along: frames[p], in: window)
            return shots.map { occlusion($0, pane: frames[p], edgeX: edges[p].x, inward: edges[p].inward, desk: desk, in: window) }
        }
        let names = ["a", "b", "viewer"]
        let report = (0..<3).map { p in
            "\(names[p]): focused \(occ[p][p]) unfocused \(occ[p][unfocused[p]])"
        }.joined(separator: "\n")
        try? report.write(toFile: "/tmp/pane-sidebar-snapshots/glass-focus.txt", atomically: true, encoding: .utf8)

        // A terminal fades AS A WHOLE, text included: the brightest pixel of
        // its first row (the shell's "Last login" line) is dimmer unfocused.
        func brightestText(_ image: CGImage, _ pane: CGRect) -> Double {
            let scale = CGFloat(image.width) / window.frame.width
            let rep = NSBitmapImageRep(cgImage: image)
            var best = 0.0
            for y in stride(from: pane.maxY - 22, to: pane.maxY - 4, by: 1) {
                for x in stride(from: pane.minX + 6, to: pane.minX + 300, by: 1) {
                    guard let c = rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale))?
                        .usingColorSpace(.sRGB) else { continue }
                    best = max(best, Double(c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255)
                }
            }
            return best
        }
        let textFocused = brightestText(shots[0], frames[0]), textUnfocused = brightestText(shots[1], frames[0])
        try? (report + "\ntext a: focused \(textFocused) unfocused \(textUnfocused)\n")
            .write(toFile: "/tmp/pane-sidebar-snapshots/glass-focus.txt", atomically: true, encoding: .utf8)
        #expect(textFocused > 150, "no text found to measure: \(textFocused)")
        #expect(textUnfocused + 20 < textFocused, "an unfocused terminal's text fades with it: \(textFocused) → \(textUnfocused)")

        // Noticeably: a few levels of difference would be invisible.
        let margin = 4.0
        for p in 0..<3 {
            #expect(occ[p][unfocused[p]] + margin < occ[p][p], "\(names[p]) hides as much of the desk unfocused: \(report)")
        }
    }

    /// Pixels at window-point `x` over the window-point rows `ys` (y up), as
    /// sRGB 0–255 triples.
    private func samples(_ image: CGImage, x: CGFloat, ys: [CGFloat], in window: NSWindow) -> [[Double]] {
        let scale = CGFloat(image.width) / window.frame.width
        let rep = NSBitmapImageRep(cgImage: image)
        return ys.compactMap { y in
            guard let c = rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale))?
                .usingColorSpace(.sRGB) else { return nil }
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) * 255 }
        }
    }

    private func distance(_ a: [[Double]], _ b: [[Double]]) -> Double {
        let pairs = zip(a, b)
        return pairs.reduce(0.0) { $0 + (abs($1.0[0] - $1.1[0]) + abs($1.0[1] - $1.1[1]) + abs($1.0[2] - $1.1[2])) / 3 }
            / Double(max(pairs.underestimatedCount, 1))
    }

    /// Glass panes: the pane banner is a pane of glass of its own, layered
    /// on top — the desk's gradient reads through the card MORE than through
    /// the pane around it (the pane's sheet thins out under the card), and
    /// nothing lifts it toward grey. The card used to wash its area with
    /// white and a sheen, ~17 levels lighter than the bare pane, the hue
    /// washed out. Measured on the composited window: blank card pixels
    /// against the same pixels with no banner, and both against the desk in
    /// the gutter beside the pane.
    @Test func bannerOnGlassLetsTheGradientThrough() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        try #require(ghostty.config.paneGlass, "needs the default elevated + glass pane style")
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let tree = try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.deskVariant = PaneDeskVariant(seed: 7)
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 760))
        await settle(2.5)
        let view = try #require(a.surfaceView)
        window.makeFirstResponder(view)
        await settle(0.8)
        let frame = view.convert(view.bounds, to: nil)

        // Blank card: right of the short title and table, left of the
        // chevron, between the card's top edge and its last row.
        let ys = Array(stride(from: frame.maxY - 80, to: frame.maxY - 36, by: 4))
        let xs: [CGFloat] = [frame.midX, frame.midX + 100]
        func card(_ image: CGImage) -> [[Double]] { xs.flatMap { samples(image, x: $0, ys: ys, in: window) } }

        let bare = card(try await captureComposited(window, "banner-glass-without"))
        view.paneBanner = "## Glass banner\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
        await settle(1.5)
        let shot = try await captureComposited(window, "banner-glass-with")
        let banner = card(shot)
        let desk = samples(shot, x: frame.minX - 5, ys: ys, in: window)
        func mean(_ px: [[Double]]) -> [Double] { (0..<3).map { i in px.reduce(0.0) { $0 + $1[i] } / Double(max(px.count, 1)) } }
        let deskMean = [mean(desk)]
        let throughCard = distance([mean(banner)], deskMean), throughPane = distance([mean(bare)], deskMean)
        let report = "desk \(mean(desk)) pane \(mean(bare)) card \(mean(banner)): card-desk \(throughCard) pane-desk \(throughPane), frame \(frame)"
        try? report.write(toFile: "/tmp/pane-sidebar-snapshots/banner-glass.txt", atomically: true, encoding: .utf8)
        #expect(banner.count == bare.count && !banner.isEmpty)
        // More of the desk: the card's pixels are nearer the desk's color.
        #expect(throughCard + 3 < throughPane, "the banner is no more see-through than the pane: \(report)")
        // ...and no grey lift: the card is not lighter than the desk itself.
        #expect(mean(banner).reduce(0, +) <= mean(desk).reduce(0, +) + 6, "the banner lifts the gradient toward grey: \(report)")
    }

    /// Glass panes (the default): nothing paints over the window's gradient —
    /// not the terminal (the renderer drops its background), not a viewer's
    /// page, not the titlebar. Also writes the window as the WINDOW SERVER
    /// composites it (Liquid Glass and the Metal terminal included, which
    /// `cacheDisplay` cannot see) to /tmp/pane-sidebar-snapshots — capturing
    /// one's own window needs no screen-recording grant.
    @Test func glassPanesLetTheGradientThrough() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'ls -la /; echo; echo hello from a glass pane; cat'"
        let a = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let b = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/design/pane-sidebar.md")
        let viewer = PaneView(viewer: ViewerView(location: doc.path))
        let tree = try SplitTree<PaneView>(view: a)
            .inserting(view: b, at: a, direction: .right)
            .inserting(view: viewer, at: b, direction: .down)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.deskVariant = PaneDeskVariant(seed: 7)
        controller.paneSidebarState.isHidden = false
        controller.paneSidebarState.isExpanded = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 760))
        await settle(2.5)

        // The pieces that make it glass, each of which was found painting an
        // opaque layer over the gradient at some point.
        #expect(window.styleMask.contains(.fullSizeContentView), "the gradient can't reach under the titlebar")
        #expect(window.titlebarAppearsTransparent, "macOS 26 backs the titlebar with its own material")
        let v = try #require(viewer.viewerView)
        #expect(v.isOnGlass)
        #expect((v.webView.value(forKey: "drawsBackground") as? Bool) == false)
        let page = try await v.webView.evaluateJavaScript(
            "[document.documentElement.className, getComputedStyle(document.body).backgroundColor, getComputedStyle(document.querySelector('.markdown-body')).backgroundColor].join('|')") as? String
        #expect(page == "pane-glass|rgba(0, 0, 0, 0)|rgba(0, 0, 0, 0)", "the page paints over the sheet: \(page ?? "nil")")

        window.makeFirstResponder(a.surfaceView)
        await settle(0.5)
        #expect(a.isFocusedPane, "the focused pane is the one that glows")
        try await captureComposited(window, "glass-window")
        window.makeFirstResponder(b.surfaceView)
        await settle(0.6)
        try await captureComposited(window, "glass-window-b")
        // Collapsed: the rail. (A viewer page may come out blank here: the
        // test window opens behind others, occluded, and WebKit skips
        // repaints after the column change while occluded — the page is
        // there, unpainted.)
        controller.paneSidebarState.isExpanded = false
        await settle(0.8)
        try await captureComposited(window, "glass-rail")
        controller.close()
        await settle(0.3)
    }

    /// Diagnostic: the sidebar host alone, captured two ways, plus a dump
    /// of what is mounted in it.
    @Test func diagnoseSidebarRendering() async throws {
        let other = try await open(expanded: true)
        other.panes[1].surfaceView?.activityState = .needsInput
        let h = try await open(expanded: true)
        defer { other.controller.close() }
        h.controller.stashPane(h.panes[2])
        await settle(0.8)
        let host = try #require(h.controller.paneSidebarHost)
        var lines: [String] = []
        func dump(_ v: NSView, _ depth: Int) {
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden) alpha=\(v.alphaValue) layer=\(v.layer != nil)")
            for s in v.subviews.prefix(12) { dump(s, depth + 1) }
        }
        dump(host, 0)
        lines.append("bg=\(h.controller.ghostty.config.backgroundColor)")
        lines.append("visible=\(h.controller.surfaceTree.visibleLeaves.count) stashed=\(h.controller.surfaceTree.stashed.count)")
        try? lines.joined(separator: "\n").write(toFile: "/tmp/pane-sidebar-snapshots/dump.txt", atomically: true, encoding: .utf8)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pane-sidebar-snapshots/host-cache.png"))
        }
        if let layer = host.layer {
            let scale: CGFloat = 2
            let size = host.bounds.size
            if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                   bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                if let image = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pane-sidebar-snapshots/host-layer.png"))
                }
            }
        }
        // SwiftUI's own renderer: draws the view tree itself (AppKit
        // representables — the rows' click/drag views — are invisible anyway).
        for (name, rail, all) in [("render-expanded", false, false), ("render-rail", true, false),
                                  ("render-all", false, true)] {
            h.controller.paneSidebarState.showsAllWindows = all
            await settle(0.1)
            let bg = h.controller.ghostty.config.backgroundColor
            let view = PaneSidebarView(
                controller: h.controller, state: h.controller.paneSidebarState,
                geometry: PaneSidebarGeometry(), isRail: rail, isFlat: !rail)
                .frame(width: rail ? 44 : 240, height: 420, alignment: .top)
                .background(GlassCard.fill(isLightBackground: false))
                .background(bg)
                .environment(\.colorScheme, .dark)
                .environment(\.paneSidebarInteractive, false)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: "/tmp/pane-sidebar-snapshots/\(name).png"))
            }
        }
        // Rows on their own (ImageRenderer does not draw ScrollView content).
        h.panes[0].surfaceView?.activityState = .busy
        h.panes[2].surfaceView?.activityState = .needsInput
        h.panes[1].surfaceView?.paneBanner = "**Pane sidebar** — building the _rows_"
        await settle(0.2)
        for (name, rail) in [("rows", false), ("tiles", true)] {
            let tree = h.controller.surfaceTree
            let bg = h.controller.ghostty.config.backgroundColor
            let rows = VStack(alignment: .leading, spacing: 0) {
                ForEach(tree.visibleLeaves) { pane in
                    PaneSidebarRow(pane: pane, owner: h.controller, isStashed: false,
                                   isSelected: pane === tree.visibleLeaves.first, isForeign: false,
                                   isRail: rail, isBeingDragged: false)
                }
                PaneSidebarDivider(isRail: rail)
                ForEach(tree.stashedViews) { pane in
                    PaneSidebarRow(pane: pane, owner: h.controller, isStashed: true,
                                   isSelected: false, isForeign: false,
                                   isRail: rail, isBeingDragged: false)
                }
            }
            .padding(.vertical, 8)
            .frame(width: rail ? 44 : 240, alignment: .top)
            .background(GlassCard.fill(isLightBackground: false))
            .background(bg)
            .environment(\.colorScheme, .dark)
            .environment(\.paneSidebarInteractive, false)
            let renderer = ImageRenderer(content: rows)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: "/tmp/pane-sidebar-snapshots/\(name).png"))
            }
        }
        h.controller.paneSidebarState.showsAllWindows = false
        await close(h)
    }

    // MARK: Layout

    /// Expanded is the rail's card, wider: the same margins, top and
    /// height, the grid beside its column, the grip in the gutter.
    @Test func expandedIsTheRailsCardWider() async throws {
        let h = try await open(expanded: true)
        defer { Task { await close(h) } }

        let host = try #require(h.controller.paneSidebarHost)
        let hostFrame = host.convert(host.bounds, to: nil)
        let elevated = h.controller.ghostty.config.macosPaneStyle == .elevated
        let insets = PaneSidebarState.railInsets(elevated: elevated)
        let column = PaneSidebarState.columnWidth(for: .expanded, panelWidth: 240, elevated: elevated)
        let grip = PaneSidebarState.edgeGrip(for: .expanded, elevated: elevated)
        #expect(abs(hostFrame.width - (column + PaneSidebarState.edgeReach(for: .expanded, elevated: elevated))) < 1,
                "the column, plus the gutter its resize grip lies in")
        #expect(abs(hostFrame.minX) < 1, "flush with the window's left edge")
        #expect(host.cardRect == NSRect(x: insets.leading, y: insets.vertical, width: 240,
                                        height: host.bounds.height - 2 * insets.vertical),
                "the rail's card at the panel's width: its margins, its top, its height")
        let edgeX = host.frame.minX + host.cardRect.maxX
        let y = host.frame.midY
        #expect(host.hitTest(NSPoint(x: edgeX + grip.offset + 1, y: y)) is SidePanelResizeHandle, "its start")
        #expect(host.hitTest(NSPoint(x: edgeX + grip.offset + grip.width - 1, y: y)) is SidePanelResizeHandle,
                "its end")
        #expect(!(host.hitTest(NSPoint(x: edgeX - 3, y: y)) is SidePanelResizeHandle), "not over the card")
        #expect(host.hitTest(NSPoint(x: edgeX + grip.offset + grip.width + 1, y: y)) == nil,
                "nothing past the grip")

        // The grid starts where the column ends (plus the elevated margin).
        let leftPane = frameInWindow(h.panes[0])
        #expect(abs(leftPane.minX - (column + gridMargin(h))) < 1)
        snapshot(h, "expanded")
        await close(h)
    }

    /// A pane's icon is at the same height expanded and collapsed: one card,
    /// one row height.
    @Test func iconsStayAtTheSameHeightExpandedOrCollapsed() async throws {
        let h = try await open(expanded: true)
        let host = try #require(h.controller.paneSidebarHost)
        let expanded = h.panes.compactMap { rowFrame($0, in: host)?.midY }
        h.controller.setPaneSidebarExpanded(false)
        await settle(0.8)
        let collapsed = h.panes.compactMap { rowFrame($0, in: host)?.midY }
        #expect(expanded.count == 3 && collapsed.count == 3)
        for (e, c) in zip(expanded, collapsed) {
            #expect(abs(e - c) < 1, "a row at \(e) expanded is at \(c) collapsed")
        }
        await close(h)
    }

    @Test func collapsedIsTheRailAndOnlyTheButtonExpandsIt() async throws {
        let h = try await open(expanded: false)

        let host = try #require(h.controller.paneSidebarHost)
        let elevated = gridMargin(h) > 0
        let insets = PaneSidebarState.railInsets(elevated: elevated)
        let column = PaneSidebarState.railColumnWidth(elevated: elevated)
        let gridLeft = frameInWindow(h.panes[0]).minX
        #expect(abs(gridLeft - (column + gridMargin(h))) < 1, "the grid sits beside the rail column")
        #expect(host.cardRect.width == PaneSidebarState.railCardWidth)
        #expect(host.cardRect.minX == insets.leading, "the raised card keeps its margin")
        #expect(abs(host.frame.width - (column + PaneSidebarState.edgeReach(for: .collapsed, elevated: elevated))) < 1,
                "the column, plus the gutter its grip lies in — no room for a card opening over the grid")
        // Equal gutters: window edge → rail, and rail → panes.
        let railFrame = host.convert(host.cardRect, to: nil)
        #expect(abs(railFrame.minX - (gridLeft - railFrame.maxX)) < 1,
                "the gap left of the rail equals the gap right of it")
        if elevated {
            // ...and both equal the gap between two panes: one spacing.
            let paneGap = frameInWindow(h.panes[1]).minX - frameInWindow(h.panes[0]).maxX
            #expect(abs(paneGap - railFrame.minX) < 1, "pane gap \(paneGap) == rail gutter \(railFrame.minX)")
        }
        snapshot(h, "rail")

        // The button at the top of the bar is the way out (and in again) —
        // and the grid glides over rather than snapping: part way there a
        // moment in, its terminal still at its old size until the motion is
        // over, then resized once.
        let expandedLeft = PaneSidebarState.columnWidth(for: .expanded, panelWidth: 240, elevated: elevated)
            + gridMargin(h)
        let sizeBefore = try #require(gridSize(h.panes[0]))
        h.controller.setPaneSidebarExpanded(true)
        await settle(0.04)
        let midway = frameInWindow(h.panes[0]).minX
        #expect(midway > gridLeft + 1 && midway < expandedLeft - 1,
                "the grid glides: \(gridLeft) → \(midway) → \(expandedLeft)")
        #expect(gridSize(h.panes[0])?.cols == sizeBefore.cols, "no resize mid-glide")
        await settle(0.6)
        #expect(abs(frameInWindow(h.panes[0]).minX - expandedLeft) < 1, "expanded: the panel's column")
        #expect(gridSize(h.panes[0])?.cols != sizeBefore.cols, "resized once the glide is over")
        h.controller.setPaneSidebarExpanded(false)
        await settle(0.6)
        #expect(abs(frameInWindow(h.panes[0]).minX - gridLeft) < 1, "collapsed again")

        await close(h)
    }

    /// The rail's grip is the gutter between it and the panes — all of it,
    /// and none of the rail (it used to sit inside the card, its bar over the
    /// tiles). Past it, clicks fall through to the grid.
    @Test func theRailsGripIsTheGutterBesideIt() async throws {
        let h = try await open(expanded: false)
        let host = try #require(h.controller.paneSidebarHost)
        let elevated = gridMargin(h) > 0
        let grip = PaneSidebarState.edgeGrip(for: .collapsed, elevated: elevated)
        let edge = host.frame.minX + host.cardRect.maxX
        let y = host.frame.midY
        #expect(host.hitTest(NSPoint(x: edge + grip.offset + 1, y: y)) is SidePanelResizeHandle, "its start")
        #expect(host.hitTest(NSPoint(x: edge + grip.offset + grip.width - 1, y: y)) is SidePanelResizeHandle, "its end")
        #expect(!(host.hitTest(NSPoint(x: edge - 3, y: y)) is SidePanelResizeHandle), "not over the rail")
        #expect(host.hitTest(NSPoint(x: edge + grip.offset + grip.width + 2, y: y)) == nil, "the grid's past it")
        if elevated {
            #expect(abs(edge + grip.offset + grip.width - frameInWindow(h.panes[0]).minX) < 1,
                    "the grip ends where the panes begin")
        }
        await close(h)
    }

    /// Each tile is its pane's own shade, and a hovered tile tints its pane
    /// in that hue (sidebar-hue-*.png, by eye) — and the tint goes when the
    /// pointer leaves.
    @Test func aHoveredTileTintsItsPaneInItsHue() async throws {
        let h = try await open(expanded: false)
        let hover = PaneSidebarHover.shared
        let b = h.panes[1]
        hover.hover(b.id, color: PaneSidebarHue.color(for: b, in: h.controller))
        await settle(0.4)
        try await captureComposited(h.window, "sidebar-hue-hover")
        #expect(hover.pane == b.id)
        hover.leave(b.id)
        await settle(0.4)
        #expect(hover.pane == nil)
        try await captureComposited(h.window, "sidebar-hue-rest")
        // Neighbours never share a shade.
        let hues = (0..<6).map(PaneSidebarHue.hue(index:))
        for (x, y) in zip(hues, hues.dropFirst()) { #expect(abs(x - y) > 0.15) }
        await close(h)
    }

    /// A busy pane's tile carries a diagonal sheen, and the collapse/expand
    /// button sits at the same place in both modes (sidebar-busy-*.png, by
    /// eye: the sheen is Core Animation, the button SwiftUI).
    @Test func aBusyTileShinesAndTheToggleStaysPut() async throws {
        let h = try await open(expanded: false)
        h.panes[1].surfaceView?.activityState = .busy
        await settle(0.5)
        try await captureComposited(h.window, "sidebar-busy-rail")
        await settle(0.35)
        try await captureComposited(h.window, "sidebar-busy-rail-later")
        // A run of frames across a sweep, for checking its direction.
        for i in 0..<16 {
            try await captureComposited(h.window, "sidebar-busy-sweep-\(i)")
            await settle(0.05)
        }
        h.controller.setPaneSidebarExpanded(true)
        await settle(0.8)
        try await captureComposited(h.window, "sidebar-busy-expanded")
        h.panes[1].surfaceView?.activityState = .idle
        await close(h)
    }

    // MARK: Drag to reorder, into and out of the tray

    /// The dragged row is the row itself, following the pointer up and down
    /// only (`PaneSidebarRowDrag`), the list leaving its gap; let go, it
    /// settles where it landed. Captured composited, in both modes
    /// (drag-ghost-*.png): a check by eye, since no synthetic event drives a
    /// real drag.
    @Test(arguments: [true, false])
    func theDraggedRowFollowsThePointerVertically(expanded: Bool) async throws {
        let h = try await open(expanded: expanded)
        let (a, c) = (h.panes[0], h.panes[2])
        let session = PaneDragSession.shared
        let rowDrag = PaneSidebarRowDrag.shared
        let start = try screenPoint(on: a, h)
        session.begin(pane: a, from: h.controller, isListDrag: true)
        rowDrag.begin(a, screenY: start.y)
        session.update(screenPoint: start)
        await settle(0.3)
        // c's lower part, as laid out (the rows' own views slide).
        let cRow = try #require(h.controller.paneSidebarHost?.dropGeometry()?.paneRows.first { $0.id == c.id }?.rect)
        let end = CGPoint(x: cRow.midX, y: cRow.minY + cRow.height * 0.2)
        // Sideways too: the row must not follow that.
        let moved = CGPoint(x: end.x + 300, y: end.y)
        session.update(screenPoint: moved)
        rowDrag.move(screenY: moved.y)
        await settle(0.4)
        // Off the bar, over the grid: still a place in the list — a row
        // dragged in the list only rearranges, wherever it is let go.
        #expect(session.target == .sidebarOrder(window: PaneDropWindowRef(h.controller), index: 2),
                "released off the bar: \(String(describing: session.target))")
        // ...and past the window, too.
        session.update(screenPoint: CGPoint(x: moved.x + 3000, y: moved.y))
        #expect(session.target == .sidebarOrder(window: PaneDropWindowRef(h.controller), index: 2),
                "released past the window: \(String(describing: session.target))")
        session.update(screenPoint: moved)
        #expect(rowDrag.frame != nil, "the dragged row's place is known")
        #expect(rowDrag.dy > 0, "it follows the pointer down")
        try await captureComposited(h.window, expanded ? "drag-ghost-expanded" : "drag-ghost-rail")
        session.update(screenPoint: end)
        await settle(0.4)
        // b and c slide up into a's gap — and the geometry the drop is read
        // from still has them where they are laid out, so the index does not
        // chase them.
        #expect(session.target == .sidebarOrder(window: PaneDropWindowRef(h.controller), index: 2))
        let rows = try #require(h.controller.paneSidebarHost?.dropGeometry()?.paneRows)
        #expect(rows.first { $0.id == c.id }?.rect == cRow, "c's laid-out row did not move with its slide")
        #expect(Set(rows.map(\.rect.minY)).count == 3, "no two rows report the same place")
        session.end(commit: true)
        rowDrag.finish(a)
        await settle(0.5)
        #expect(rowDrag.pane == nil, "settled")
        #expect(h.controller.paneSidebarPanes.last === a)
        await close(h)
    }

    /// The drag source views of a pane's sidebar row, in window coordinates.
    private func rowFrame(_ pane: PaneView, in host: NSView) -> NSRect? {
        func all(_ view: NSView) -> [PaneDragSourceView] {
            ((view as? PaneDragSourceView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        return all(host).first { $0.pane === pane }.map { $0.convert($0.bounds, to: nil) }
    }

    /// A point on `pane`'s row, in screen coordinates; `fraction` of the way
    /// down it. Where the row is LAID OUT — the drop geometry, once a drag
    /// has the rows reporting it — not where its view has slid to.
    private func screenPoint(on pane: PaneView, _ h: Harness, fraction: CGFloat = 0.5) throws -> CGPoint {
        let host = try #require(h.controller.paneSidebarHost)
        if let geo = host.dropGeometry(),
           let rect = (geo.paneRows + geo.stashRows).first(where: { $0.id == pane.id })?.rect {
            return CGPoint(x: rect.midX, y: rect.maxY - rect.height * fraction)
        }
        let row = try #require(rowFrame(pane, in: host), "no row for the pane")
        let inWindow = NSPoint(x: row.midX, y: row.maxY - row.height * fraction)
        return h.window.convertPoint(toScreen: inWindow)
    }

    /// Drag-reorder, and dragging into and out of the tray, through the
    /// sidebar's own drag: the session, the resolver, and the coordinator
    /// as a row drag drives them. In both modes. Reordering changes the
    /// list and never the grid.
    @Test(arguments: [true, false])
    func dragReordersTheListAndTheTrayStashesAndRestores(expanded: Bool) async throws {
        let h = try await open(expanded: expanded)
        defer { PaneDragSession.shared.end(commit: false) }
        let (a, b, c) = (h.panes[0], h.panes[1], h.panes[2])
        let session = PaneDragSession.shared
        let host = try #require(h.controller.paneSidebarHost)
        let grid = h.controller.surfaceTree.root
        #expect(h.controller.paneSidebarPanes.map(\.id) == [a.id, b.id, c.id], "the tree's order to start")

        // a, dragged to c's lower half: the end of the list. While it is
        // held there, b and c slide up into the room it left.
        let bBefore = try #require(rowFrame(b, in: host))
        session.begin(pane: a, from: h.controller)
        session.update(screenPoint: try screenPoint(on: b, h))
        await settle(0.3)     // the rows report their frames once a drag is on
        session.update(screenPoint: try screenPoint(on: c, h, fraction: 0.8))
        #expect(session.target == .sidebarOrder(window: PaneDropWindowRef(h.controller), index: 2))
        await settle(0.5)
        let bDuring = try #require(rowFrame(b, in: host))
        #expect(bDuring.maxY > bBefore.maxY + bBefore.height * 0.5,
                "b slid up to make room: \(bBefore.maxY) → \(bDuring.maxY)")
        session.end(commit: true)
        await settle(0.4)
        #expect(h.controller.paneSidebarPanes.map(\.id) == [b.id, c.id, a.id])
        #expect(h.controller.surfaceTree.root == grid, "the grid did not change")
        #expect(h.controller.surfaceTree.stashed.isEmpty)

        // b, dragged below the tray's divider: stashed.
        session.begin(pane: b, from: h.controller)
        session.update(screenPoint: try screenPoint(on: c, h))
        await settle(0.3)
        let tray = try #require(host.dropGeometry()?.trayTop, "the tray reports where it begins")
        session.update(screenPoint: CGPoint(x: try screenPoint(on: c, h).x, y: tray - 12))
        #expect(session.target == .stash(window: PaneDropWindowRef(h.controller), index: 0))
        session.end(commit: true)
        await settle(0.5)
        #expect(h.controller.surfaceTree.stashed == [b.id])
        #expect(h.controller.paneSidebarPanes.map(\.id) == [c.id, a.id])
        snapshot(h, expanded ? "drag-tray-expanded" : "drag-tray-rail")

        // b, dragged out of the tray to the top of the list: restored, and
        // first in the list.
        session.begin(pane: b, from: h.controller)
        session.update(screenPoint: try screenPoint(on: b, h))
        await settle(0.3)
        session.update(screenPoint: try screenPoint(on: c, h, fraction: 0.1))
        #expect(session.target == .sidebarOrder(window: PaneDropWindowRef(h.controller), index: 0))
        session.end(commit: true)
        await settle(0.5)
        #expect(h.controller.surfaceTree.stashed.isEmpty, "back on the grid")
        #expect(h.controller.paneSidebarPanes.map(\.id) == [b.id, c.id, a.id])
        #expect(h.controller.surfaceTree.root == grid, "in the slot it left")

        await close(h)
    }

    // MARK: Geometry: a stashed pane keeps its size

    @Test func aStashedTerminalKeepsItsGridAndComesBackAtTheSameSize() async throws {
        let h = try await open(expanded: true)
        let b = h.panes[1], c = h.panes[2]

        let bBefore = try #require(gridSize(b))
        let cBefore = try #require(gridSize(c))
        #expect(bBefore.cols > 10 && bBefore.rows > 3, "a real size, not a placeholder")

        #expect(h.controller.stashPane(b))
        await settle(0.6)

        // b is unmounted but its terminal still holds its last real size —
        // not zero, not a placeholder — so its program saw no SIGWINCH.
        let bStashed = try #require(gridSize(b))
        #expect(bStashed.cols == bBefore.cols && bStashed.rows == bBefore.rows)
        #expect(bStashed.w == bBefore.w && bStashed.h == bBefore.h)
        // c took b's space.
        let cGrown = try #require(gridSize(c))
        #expect(cGrown.rows > cBefore.rows)
        snapshot(h, "stashed")

        h.controller.restorePane(b, focus: false)
        await settle(0.6)
        let bRestored = try #require(gridSize(b))
        let cRestored = try #require(gridSize(c))
        #expect(bRestored.cols == bBefore.cols && bRestored.rows == bBefore.rows,
                "restored to its own slot at its own size: not a reflow event")
        #expect(cRestored.rows == cBefore.rows)

        await close(h)
    }

    /// A window that OPENS with a pane already stashed — a session restore,
    /// or `+new-window` of a tree that carries a stash. The stashed terminal
    /// was never laid out, and it must still get its real slot size rather
    /// than the 800×600 placeholder (49×17 cells), or its program is told it
    /// is 49 columns wide and re-renders at that width.
    @Test func aPaneStashedAtLaunchGetsItsRealSlotSize() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app), c = terminalPane(app)
        let tree = try SplitTree<PaneView>(view: a)
            .inserting(view: b, at: a, direction: .right)
            .inserting(view: c, at: b, direction: .down)
            .stashing(b)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = false
        controller.paneSidebarState.isExpanded = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1100, height: 700))
        await settle(1.0)

        let stashed = try #require(gridSize(b))
        let sibling = try #require(gridSize(c))
        // Before restore, the stashed pane's slot is c's column at half its
        // height — the same width c has now.
        #expect(stashed.cols == sibling.cols,
                "the stashed pane is sized to its slot, not a placeholder (got \(stashed.cols)×\(stashed.rows))")
        #expect(!(stashed.cols == 49 && stashed.rows == 17), "never the 800×600 placeholder")

        // Restoring it is not a reflow: it already has the size it lands at.
        controller.restorePane(b, focus: false)
        await settle(0.6)
        let restored = try #require(gridSize(b))
        #expect(restored.cols == stashed.cols && restored.rows == stashed.rows)

        controller.close()
        await settle(0.3)
    }

    /// Viewer panes get the same hover grab handle terminals have — before,
    /// a viewer could only be dragged (onto the sidebar, say) in rearrange
    /// mode. Its drag source is mounted at the top center of the pane.
    @Test func aViewerPaneHasAGrabHandle() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let terminal = terminalPane(app)
        let viewer = PaneView(viewer: ViewerView(location: "about:blank"))
        let tree = try SplitTree<PaneView>(view: terminal)
            .inserting(view: viewer, at: terminal, direction: .right)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        await settle(0.8)

        func sources(in view: NSView) -> [PaneDragSourceView] {
            (view as? PaneDragSourceView).map { [$0] } ?? view.subviews.flatMap(sources)
        }
        let all = sources(in: try #require(window.contentView))
        let viewerSource = try #require(all.first { $0.pane === viewer }, "no drag source for the viewer")
        let sourceFrame = viewerSource.convert(viewerSource.bounds, to: nil)
        let paneFrame = viewer.contentView.convert(viewer.contentView.bounds, to: nil)
        #expect(abs(sourceFrame.midX - paneFrame.midX) < 1, "centered on the pane")
        #expect(abs(sourceFrame.maxY - paneFrame.maxY) < 1, "at the pane's top edge")
        #expect(all.contains { $0.pane === terminal }, "the terminal keeps its own")

        controller.close()
        await settle(0.3)
    }

    /// The sidebar's selection is `focusedPane`, read inside a view that
    /// observes the controller — so a focus change must PUBLISH, or the
    /// highlight stays on the old row until something unrelated redraws.
    /// Both kinds: a terminal (`focusedSurface`) and a viewer (derived from
    /// the window's first responder).
    /// A row's hover covers its −/↩ button. It used to be measured by the
    /// row's drag source, which stops short of the button — so reaching for
    /// the button ended the hover and hid it, and it could never be clicked.
    @Test func aRowsHoverCoversItsStashButton() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let tree = try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = false
        controller.paneSidebarState.isExpanded = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        // Wide enough for the full panel (narrower shows the rail).
        window.setContentSize(NSSize(width: 1000, height: 600))
        await settle(0.8)

        func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { all(type, in: $0) }
        }
        let root = try #require(window.contentView)
        // A sidebar row's drag source (the grid's grab handles have no controller).
        let source = try #require(all(PaneDragSourceView.self, in: root)
            .filter { $0.controller != nil }.first)
        let hovers = all(HoverTrackingArea.View.self, in: root)
        let sourceRect = source.convert(source.bounds, to: nil)
        let hover = try #require(hovers.first { $0.convert($0.bounds, to: nil).intersects(sourceRect) },
                                 "the row has no hover area of its own")
        hover.onHoverChanged?(true)
        await settle(0.4)
        let hoverRect = hover.convert(hover.bounds, to: nil)
        let shrunk = source.convert(source.bounds, to: nil)
        #expect(hoverRect.maxX > shrunk.maxX + 18, "the button sits outside the row's hover area")
        controller.close()
        await settle(0.3)
    }

    /// A busy pane's sidebar icon shimmers: two captures a moment apart
    /// differ around the icon (and only while busy). Writes busy-a/b.png.
    @Test func aBusyPaneShimmersInTheSidebar() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let tree = try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = false
        controller.paneSidebarState.isExpanded = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        await settle(0.8)

        b.surfaceView?.activityState = .busy
        await settle(0.3)
        #expect(b.activityState == .busy)
        // Frames across one whole shimmer period: two captures alone can both
        // land while the band is parked off the glyph.
        let first = try await captureImage(window)
        var frames: [CGImage] = []
        for _ in 0..<6 {
            await settle(0.23)
            frames.append(try await captureImage(window))
        }
        // The sidebar's strip: x 0…240pt (2x capture), below the titlebar.
        let strip = CGRect(x: 0, y: 120, width: 480, height: 400)
        let diffs = frames.map { Self.pixelsDiffering(first, $0, in: strip) }
        let changed = diffs.max() ?? 0
        if let best = frames.max(by: { Self.pixelsDiffering(first, $0, in: strip) < Self.pixelsDiffering(first, $1, in: strip) }) {
            try? NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/pane-sidebar-snapshots/busy-a.png"))
            try? NSBitmapImageRep(cgImage: best).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/pane-sidebar-snapshots/busy-b.png"))
        }
        try? "changed pixels in the sidebar per frame: \(diffs)\n".write(
            toFile: "/tmp/pane-sidebar-snapshots/busy-probe.txt", atomically: true, encoding: .utf8)
        #expect(changed > 20, "the busy icon did not move (\(changed) pixels changed)")
        controller.close()
        await settle(0.3)
    }

    private func captureImage(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        let scWindow = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let cfg = SCStreamConfiguration()
        cfg.width = Int(scWindow.frame.width * 2)
        cfg.height = Int(scWindow.frame.height * 2)
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: cfg)
    }

    private static func pixelsDiffering(_ a: CGImage, _ b: CGImage, in rect: CGRect) -> Int {
        let ra = NSBitmapImageRep(cgImage: a), rb = NSBitmapImageRep(cgImage: b)
        var count = 0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 1) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 1) {
                guard let ca = ra.colorAt(x: x, y: y), let cb = rb.colorAt(x: x, y: y) else { continue }
                if abs(ca.brightnessComponent - cb.brightnessComponent) > 0.06 { count += 1 }
            }
        }
        return count
    }

    @Test func aFocusChangeRedrawsTheSidebarSelection() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let viewer = PaneView(viewer: ViewerView(location: "about:blank"))
        let tree = try SplitTree<PaneView>(view: a)
            .inserting(view: b, at: a, direction: .right)
            .inserting(view: viewer, at: b, direction: .down)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = false
        controller.paneSidebarState.isExpanded = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        await settle(0.8)

        var changes = 0
        let watch = controller.objectWillChange.sink { _ in changes += 1 }
        defer { watch.cancel() }

        let surfaceB = try #require(b.surfaceView)
        window.makeFirstResponder(surfaceB)
        await settle(0.3)
        #expect(controller.focusedPane === b)
        #expect(controller.publishedFocusedPane === b)
        #expect(changes > 0, "terminal focus change published nothing")

        changes = 0
        let web = try #require(viewer.viewerView?.webView)
        window.makeFirstResponder(web)
        await settle(0.3)
        #expect(controller.focusedPane === viewer)
        #expect(controller.publishedFocusedPane === viewer)
        #expect(changes > 0, "viewer focus change published nothing")

        changes = 0
        window.makeFirstResponder(try #require(a.surfaceView))
        await settle(0.3)
        #expect(controller.focusedPane === a)
        #expect(controller.publishedFocusedPane === a)
        #expect(changes > 0, "focus back from a viewer published nothing")

        controller.close()
        await settle(0.3)
    }

    @Test func aStashedPaneIsStillInTheTreeAndAlive() async throws {
        let h = try await open(expanded: true)
        let b = h.panes[1]
        h.controller.stashPane(b)
        await settle(0.3)

        #expect(h.controller.surfaceTree.contains(b), "a stash never leaves the tree")
        #expect(h.controller.surfaceTree.isStashed(b))
        #expect(b.surfaceView?.processExited == false, "its process keeps running")
        #expect(h.controller.surfaceTree.visibleLeaves.count == 2)
        await close(h)
    }

    @Test func theLastVisiblePaneCannotBeStashed() async throws {
        let h = try await open(expanded: true)
        #expect(h.controller.stashPane(h.panes[1]))
        #expect(h.controller.stashPane(h.panes[2]))
        #expect(!h.controller.stashPane(h.panes[0]), "refused: it is the only pane on screen")
        #expect(h.controller.surfaceTree.visibleLeaves.count == 1)
        snapshot(h, "vertical-tabs")
        await close(h)
    }

    @Test func undoBringsAStashedPaneBack() async throws {
        let h = try await open(expanded: true)
        let b = h.panes[1]
        h.controller.stashPane(b)
        await settle(0.2)
        h.controller.undoManager?.undo()
        await settle(0.2)
        #expect(!h.controller.surfaceTree.isStashed(b))
        await close(h)
    }

    @Test func allWindowsRenders() async throws {
        let h = try await open(expanded: true)
        h.controller.stashPane(h.panes[2])
        h.controller.paneSidebarState.showsAllWindows = true
        await settle(0.4)
        snapshot(h, "all-windows")
        #expect(h.controller.paneSidebarHost != nil)
        await close(h)
    }
}

/// Cmd-N: the core's new_window action posts `ghosttyNewWindow`, which the
/// app delegate turns into a window. Drive that exact path and look at what
/// the window got.
@MainActor
@Suite(.serialized)
struct NewWindowDeskTests {
    @Test func cmdNWindowsGetTheirOwnGradient() async throws {
        let before = Set(NSApp.windows.compactMap { $0.windowController as? TerminalController }.map(ObjectIdentifier.init))
        for _ in 0..<2 {
            NotificationCenter.default.post(name: Ghostty.Notification.ghosttyNewWindow, object: nil, userInfo: [:])
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let created = NSApp.windows
            .compactMap { $0.windowController as? TerminalController }
            .filter { !before.contains(ObjectIdentifier($0)) }
        defer { created.forEach { $0.close() } }
        #expect(created.count == 2)
        let variants = created.map(\.deskVariant)
        try? "variants=\(variants) style=\(created.first?.ghostty.config.macosPaneStyle as Any)".write(
            toFile: "/tmp/pane-sidebar-snapshots/cmdn.txt", atomically: true, encoding: .utf8)
        #expect(variants.allSatisfy { $0 != nil }, "each Cmd-N window has its own gradient")
        #expect(variants[0] != variants[1])
    }
}
