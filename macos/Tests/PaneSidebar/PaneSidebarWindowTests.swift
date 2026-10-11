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
    private func open(pinned: Bool) async throws -> Harness {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app), c = terminalPane(app)
        let tree = try SplitTree<PaneView>(view: a)
            .inserting(view: b, at: a, direction: .right)
            .inserting(view: c, at: b, direction: .down)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = false
        controller.paneSidebarState.isPinned = pinned
        controller.paneSidebarState.width = 240
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1100, height: 700))
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
        try? "resizes delivered during the drag: \(during)\n".write(
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
        main.paneSidebarState.isPinned = true
        main.paneSidebarState.width = 260
        main.paneSidebarState.showsAllWindows = true
        _ = await poll(timeout: 10) { controllers.allSatisfy { $0.window?.isVisible == true } }
        let window = try #require(main.window)
        window.setContentSize(NSSize(width: 900, height: 560))
        await settle(1.2)
        try await captureComposited(window, "all-windows")
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
    private func captureComposited(_ window: NSWindow, _ name: String) async throws {
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
        controller.paneSidebarState.isPinned = true
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
        // Unpinned: the mini rail, then the card opened over the grid. (A
        // viewer page may come out blank in these two: the test window opens
        // behind others, occluded, and WebKit skips repaints after the
        // column change while occluded — the page is there, unpainted.)
        controller.paneSidebarState.isPinned = false
        await settle(0.8)
        try await captureComposited(window, "glass-rail")
        controller.paneSidebarState.isHoverOpen = true
        await settle(0.8)
        try await captureComposited(window, "glass-overlay")
        controller.close()
        await settle(0.3)
    }

    /// Diagnostic: the sidebar host alone, captured two ways, plus a dump
    /// of what is mounted in it.
    @Test func diagnoseSidebarRendering() async throws {
        let other = try await open(pinned: true)
        other.panes[1].surfaceView?.activityState = .needsInput
        let h = try await open(pinned: true)
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
        for (name, rail, quick, all) in [("render-pinned", false, false, false), ("render-rail", true, false, false),
                                          ("render-trash", false, true, false), ("render-all", false, false, true),
                                          ("render-all-trash", false, true, true)] {
            h.controller.paneSidebarState.isQuickKill = quick
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
        for (name, rail, quick) in [("rows", false, false), ("rows-trash", false, true), ("tiles", true, false)] {
            let tree = h.controller.surfaceTree
            let bg = h.controller.ghostty.config.backgroundColor
            let rows = VStack(alignment: .leading, spacing: 0) {
                ForEach(tree.visibleLeaves) { pane in
                    PaneSidebarRow(pane: pane, owner: h.controller, isStashed: false,
                                   isSelected: pane === tree.visibleLeaves.first, isForeign: false,
                                   isRail: rail, isQuickKill: quick, isBeingDragged: false)
                }
                PaneSidebarDivider(isRail: rail)
                ForEach(tree.stashedViews) { pane in
                    PaneSidebarRow(pane: pane, owner: h.controller, isStashed: true,
                                   isSelected: false, isForeign: false,
                                   isRail: rail, isQuickKill: quick, isBeingDragged: false)
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
        h.controller.paneSidebarState.isQuickKill = false
        h.controller.paneSidebarState.showsAllWindows = false
        await close(h)
    }

    // MARK: Layout

    @Test func pinnedIsAFlatColumnTheGridSitsBeside() async throws {
        let h = try await open(pinned: true)
        defer { Task { await close(h) } }

        let host = try #require(h.controller.paneSidebarHost)
        let hostFrame = host.convert(host.bounds, to: nil)
        #expect(abs(hostFrame.width - (240 + SidePanelResizeHandle.grabWidth / 2)) < 1,
                "the column, plus the resize handle's outer half")
        #expect(abs(hostFrame.minX) < 1, "flush with the window's left edge")
        #expect(abs(host.cardRect.width - 240) < 1, "the panel fills its column, no card margin")
        // The resize handle straddles the panel's edge, and BOTH halves take
        // the mouse (the outer half used to fall outside the host).
        let edgeX = host.frame.minX + host.cardRect.maxX
        #expect(host.hitTest(NSPoint(x: edgeX - 2, y: host.frame.midY)) != nil, "inner half")
        #expect(host.hitTest(NSPoint(x: edgeX + 2, y: host.frame.midY)) != nil, "outer half")
        #expect(host.hitTest(NSPoint(x: edgeX + SidePanelResizeHandle.grabWidth, y: host.frame.midY)) == nil,
                "nothing past the handle")

        // The grid starts where the column ends (plus the elevated margin).
        let leftPane = frameInWindow(h.panes[0])
        #expect(abs(leftPane.minX - (240 + gridMargin(h))) < 1)
        snapshot(h, "pinned")
        await close(h)
    }

    @Test func unpinnedIsTheMiniRailAndHoverOpenDoesNotMoveTheGrid() async throws {
        let h = try await open(pinned: false)

        let host = try #require(h.controller.paneSidebarHost)
        let elevated = gridMargin(h) > 0
        let insets = PaneSidebarState.railInsets(elevated: elevated)
        let column = PaneSidebarState.railColumnWidth(elevated: elevated)
        let gridLeft = frameInWindow(h.panes[0]).minX
        #expect(abs(gridLeft - (column + gridMargin(h))) < 1, "the grid sits beside the rail column")
        #expect(host.cardRect.width == PaneSidebarState.railCardWidth)
        #expect(host.cardRect.minX == insets.leading, "the raised card keeps its margin")
        // Equal gutters: window edge → rail, and rail → panes.
        let railFrame = host.convert(host.cardRect, to: nil)
        #expect(abs(railFrame.minX - (gridLeft - railFrame.maxX)) < 1,
                "the gap left of the rail equals the gap right of it")
        if elevated {
            // ...and both equal the gap between two panes: one spacing.
            let paneGap = frameInWindow(h.panes[1]).minX - frameInWindow(h.panes[0]).maxX
            #expect(abs(paneGap - railFrame.minX) < 1, "pane gap \(paneGap) == rail gutter \(railFrame.minX)")
        }
        let sizeBefore = gridSize(h.panes[0])
        snapshot(h, "mini")

        // Open it as the pointer would.
        h.controller.paneSidebarState.isHoverOpen = true
        await settle(0.5)
        #expect(host.cardRect.width == 240, "the card opens to the panel width")
        #expect(abs(frameInWindow(h.panes[0]).minX - gridLeft) < 1,
                "hover-open floats over the grid: the column does not widen")
        let sizeOpen = gridSize(h.panes[0])
        #expect(sizeBefore?.cols == sizeOpen?.cols, "no terminal resized on hover")
        snapshot(h, "mini-open")

        await close(h)
    }

    @Test func clicksOutsideTheClosedRailFallThroughToTheGrid() async throws {
        let h = try await open(pinned: false)
        let host = try #require(h.controller.paneSidebarHost)
        // The host is wide enough for the open card; with it closed, the
        // part to the right of the rail must not swallow clicks.
        let inGap = NSPoint(x: host.frame.minX + 120, y: host.frame.midY)
        #expect(host.hitTest(inGap) == nil)
        let onRail = NSPoint(x: host.frame.minX + GlassCard.outerMargin + 10, y: host.frame.midY)
        #expect(host.hitTest(onRail) != nil)
        await close(h)
    }

    // MARK: Geometry: a stashed pane keeps its size

    @Test func aStashedTerminalKeepsItsGridAndComesBackAtTheSameSize() async throws {
        let h = try await open(pinned: true)
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
        controller.paneSidebarState.isPinned = true
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
        controller.paneSidebarState.isPinned = true
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
        controller.paneSidebarState.isPinned = true
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
        controller.paneSidebarState.isPinned = true
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
        let h = try await open(pinned: true)
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
        let h = try await open(pinned: true)
        #expect(h.controller.stashPane(h.panes[1]))
        #expect(h.controller.stashPane(h.panes[2]))
        #expect(!h.controller.stashPane(h.panes[0]), "refused: it is the only pane on screen")
        #expect(h.controller.surfaceTree.visibleLeaves.count == 1)
        snapshot(h, "vertical-tabs")
        await close(h)
    }

    @Test func undoBringsAStashedPaneBack() async throws {
        let h = try await open(pinned: true)
        let b = h.panes[1]
        h.controller.stashPane(b)
        await settle(0.2)
        h.controller.undoManager?.undo()
        await settle(0.2)
        #expect(!h.controller.surfaceTree.isStashed(b))
        await close(h)
    }

    @Test func trashModeAndAllWindowsRender() async throws {
        let h = try await open(pinned: true)
        h.controller.stashPane(h.panes[2])
        h.controller.paneSidebarState.isQuickKill = true
        await settle(0.4)
        snapshot(h, "trash")
        h.controller.paneSidebarState.isQuickKill = false
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
