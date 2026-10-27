import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreImage
import CoreMedia
import GhosttyKit
import Testing
@testable import Ghostty

/// A stacked row in a real window: what the pure layout tests can't see —
/// the click on a tab, and the slide Core Animation runs.
///
/// Also writes the window as the window server composites it (the Metal
/// terminal included) to /tmp/pane-stack-snapshots, before, mid-slide and
/// after.
@MainActor
@Suite(.serialized)
struct PaneStackWindowTests {
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func capture(_ window: NSWindow, _ name: String) async throws {
        let dir = "/tmp/pane-stack-snapshots"
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

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// A pane's minimum (`PaneLayout.Metrics.minimumPaneSize`). Window sizes
    /// below are written as "room for k panes" — k of these and the rest for
    /// strips, gutters and slack — so they keep their meaning if it changes.
    private static var m: CGSize { PaneLayout.Metrics.minimumPaneSize }

    /// Four terminals side by side, in a window too narrow for them.
    private func stackedWindow(count: Int = 4, width: CGFloat = 600) async throws -> (TerminalController, NSWindow, [PaneView]) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'ls -la /; cat'"
        let panes = (0..<count).map { _ in PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)) }
        var tree = SplitTree<PaneView>(view: panes[0])
        for i in 1..<count { tree = try tree.inserting(view: panes[i], at: panes[i - 1], direction: .right) }
        tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: width, height: 600))
        window.makeFirstResponder(panes[count - 1].surfaceView)
        await settle(1.2)
        return (controller, window, panes)
    }

    @Test func clickingATabSlidesTheCardsWithoutResizingAnyTerminalMidSlide() async throws {
        let (controller, window, panes) = try await stackedWindow()
        defer { controller.close() }
        let cards = all(PaneCardView.self, in: window.contentView!)
        let stage = try #require(cards.first?.superview)
        func card(_ pane: PaneView) -> PaneCardView? { cards.first { $0.paneID == pane.id } }
        func sizes() -> [String] {
            panes.map { p in
                let s = ghostty_surface_size(p.surface!)
                return "\(p.contentView.frame.size) \(s.columns)x\(s.rows)"
            }
        }

        let before = sizes()
        let x0 = try #require(card(panes[1])).frame.minX
        try await capture(window, "before")

        // Click the leftmost tab: the first pane comes forward where it is,
        // and the cards after it slide right.
        let tabs = all(PaneStackTabView.self, in: window.contentView!).filter { $0.isStrip }
        let leftmost = try #require(tabs.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        #expect(leftmost.pane === panes[0])
        let point = leftmost.convert(NSPoint(x: leftmost.bounds.midX, y: leftmost.bounds.midY), to: nil)
        let hit = try #require(window.contentView!.superview!.hitTest(point))
        #expect(hit.isDescendant(of: leftmost), "the tab wins the click")
        hit.mouseUp(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))

        // Mid-glide, the card is on its way, and nothing has been resized.
        var placed: [CGFloat] = []
        var shot = 0
        for _ in 0..<60 {
            await settle(0.008)
            // While the cards are still on their way, nothing has been resized
            // (the pane coming forward takes its slot's size once it is there).
            if cards.contains(where: \.isGliding) {
                #expect(sizes() == before, "a glide never resizes a terminal mid-glide")
                if shot < 2 { try await capture(window, "mid-\(shot)"); shot += 1 }
            }
            if let x = card(panes[1])?.placedFrame?.minX { placed.append(x) }
            // A card hanging past the stack's end never shows past it.
            for c in cards {
                guard let cardLayer = c.layer, let clip = c.clipLayer else { continue }
                let right = cardLayer.frame.minX + clip.frame.maxX
                let paneRight = cardLayer.frame.maxX - PaneCardView.outset
                if paneRight > stage.bounds.maxX + 0.5 {
                    #expect(right <= stage.bounds.maxX + 0.5, "cut at the stack's edge mid-glide: pane \(panes.firstIndex { $0.id == c.paneID } ?? -1) frame \(cardLayer.frame) clip \(clip.frame) stage \(stage.bounds) placed \(String(describing: c.placedFrame)) collapse \(c.collapse)")
                }
            }
        }
        let target = try #require(placed.last)
        #expect(placed.contains { $0 > x0 + 4 && $0 < target - 4 }, "the cards glide: \(placed.map { Int($0) })")

        await settle(0.6)
        try await capture(window, "after")
        #expect(panes[0].isFocusedPane)
        // Once it is over, only the pane that came forward has a new size:
        // its slot's, the size of the pane that was on show. It was hidden
        // while minimized, and hidden panes are not resized (the window
        // shrank around it); the panes still minimized are untouched.
        let after = sizes()
        #expect(after[1...] == before[1...], "a pane that stayed minimized was resized")
        #expect(after[0] == before[3], "the pane brought forward is not its slot's size")
        let xs = panes.compactMap { card($0)?.frame.minX }
        #expect(xs == xs.sorted(), "left stays left")
        #expect(try #require(card(panes[1])).frame.minX > x0, "the cards after it moved right")
    }

    /// The drag handles (dividers and stack grips) left to right.
    private func handles(_ window: NSWindow) -> [DividerHandle.DividerHandleView] {
        all(DividerHandle.DividerHandleView.self, in: window.contentView!)
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// The grips between two cards on show, left to right: not the ones
    /// where a run meets its strips.
    private func gripsBetweenCards(_ window: NSWindow) -> [DividerHandle.DividerHandleView] {
        let strips = all(PaneStackTabView.self, in: window.contentView!).filter { $0.isStrip }
            .map { $0.convert($0.bounds, to: nil).insetBy(dx: -12, dy: 0) }
        return handles(window).filter { h in
            let r = h.convert(h.bounds, to: nil)
            return !strips.contains { $0.intersects(r) }
        }
    }

    private func drag(_ handle: DividerHandle.DividerHandleView, by delta: CGFloat) {
        handle.onDragBegan?()
        let start = handle.currentSplit?() ?? 0.5
        for step in 1...10 { handle.onDragDelta?(delta * CGFloat(step) / 10, start) }
        handle.onDragEnded?()
    }

    /// The pane sidebar is the row's first item too: a divider pushed left
    /// past every pane it has tucked away tucks the expanded sidebar into
    /// its rail, as a pane tucks at its minimum — and dragged back, in the
    /// same drag, brings it out again.
    @Test func aDividerPushedPastTheTuckedPanesTucksTheSidebarToo() async throws {
        let (controller, window, _) = try await stackedWindow(count: 3, width: 1400)
        defer { controller.close() }
        controller.paneSidebarState.width = 240
        controller.paneSidebarState.isHidden = false
        controller.setPaneSidebarExpanded(true)
        await settle(1.0)
        let divider = try #require(handles(window).last)
        let start = divider.currentSplit?() ?? 0.5
        divider.onDragBegan?()
        // Left, step by step, until the panes before it are strips and past.
        var tuckedAt: CGFloat?
        for step in 1...40 {
            divider.onDragDelta?(-CGFloat(step) * 40, start)
            await settle(0.02)
            if tuckedAt == nil, !controller.paneSidebarState.isExpanded { tuckedAt = CGFloat(step) * 40 }
        }
        #expect(tuckedAt != nil, "the sidebar tucked into its rail")
        await settle(0.4)
        // Back where it began, still held: out again.
        for step in (0...39).reversed() {
            divider.onDragDelta?(-CGFloat(step) * 40, start)
            await settle(0.02)
        }
        divider.onDragEnded?()
        await settle(0.6)
        #expect(controller.paneSidebarState.isExpanded, "dragged back, the sidebar came back out")
    }

    @Test func squeezingAPanePastItsMinimumTucksItAsideAndAGripBringsItBack() async throws {
        // Three panes side by side with room to spare.
        let (controller, window, panes) = try await stackedWindow(count: 3, width: 1300)
        defer { controller.close() }
        let state = controller.paneStackState
        #expect(state.pins.isEmpty)
        #expect(handles(window).count == 2)
        #expect(panes[2].isFocusedPane)

        // Drag the right divider far past the last pane's minimum.
        drag(try #require(handles(window).last), by: 500)
        await settle(0.8)
        try await capture(window, "collapsed")
        let key = Set(panes.map(\.id))
        #expect(state.pin(for: key) == .init(start: 0, count: 2))
        let tabs = all(PaneStackTabView.self, in: window.contentView!).filter { $0.isStrip }
        #expect(tabs.map { $0.pane?.id } == [panes[2].id], "the squeezed pane is a strip")
        #expect(panes[1].isFocusedPane, "the caret left the tucked pane for its neighbour")

        // Clicking the strip restores it: there is room, so the row is side
        // by side again.
        let strip = try #require(tabs.first)
        let point = strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        let hit = try #require(window.contentView!.superview!.hitTest(point))
        hit.mouseDown(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        hit.mouseUp(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
        await settle(0.8)
        #expect(panes[2].isFocusedPane)
        #expect(state.pin(for: key) == nil)
        #expect(all(PaneStackTabView.self, in: window.contentView!).allSatisfy { !$0.isStrip })

        // Collapse again, from the other side this time, and widen it back
        // with the grip where the run meets the minimized card.
        drag(try #require(handles(window).first), by: -500)
        await settle(0.8)
        #expect(state.pin(for: key) == .init(start: 1, count: 2))
        // The grip where the run meets the tucked card is its divider: pulled
        // past a pane's minimum, it widens the row again.
        drag(try #require(handles(window).first), by: 400)
        await settle(0.8)
        #expect(state.pin(for: key) == nil)
        let left = all(PaneStackTabView.self, in: window.contentView!).filter { $0.isStrip }
        #expect(left.isEmpty, "\(left.map { t in "\(panes.firstIndex { $0.id == t.pane?.id } ?? -1) a=\(t.alphaValue) f=\(t.frame)" })")
        #expect(handles(window).count == 2, "side by side, with its dividers back")
    }

    /// A strip click that changes how many cards are on show (2 → 3), so every
    /// card changes size: each terminal is resized ONCE, together, after the
    /// slide — never mid-slide (it used to be resized on every frame of a focus
    /// fade, seven times in 250ms); a pane that stays minimized is not resized
    /// at all, and shows nothing through its strip; and, recorded at the
    /// display's frame rate,
    /// no frame of the slide blanks or flashes the card that stays put.
    /// Frames go to /tmp/pane-stack-snapshots/frames.
    @Test func aResizingSlideResizesEachTerminalOnceAfterIt() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 4, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        drag(try #require(handles(window).last), by: 500)
        await settle(0.8)
        drag(try #require(handles(window)[1]), by: 500)
        await settle(0.8)
        try #require(controller.paneStackState.pin(for: key) == .init(start: 0, count: 2))
        func grid() -> [String] {
            panes.map { p in let s = ghostty_surface_size(p.surface!); return "\(s.columns)x\(s.rows)" }
        }
        let tabs = all(PaneStackTabView.self, in: window.contentView!).filter { $0.isStrip }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let strip = try #require(tabs.first)
        let point = strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        let hit = try #require(window.contentView!.superview!.hitTest(point))
        // The first card stays where it is through the slide: its text is what
        // a flash would show up in.
        let still = try #require(panes[0].surfaceView)
        let stillFrame = still.convert(still.bounds, to: nil)

        let recorder = WindowFrameRecorder()
        try await recorder.start(window)
        await settle(0.2)
        let start = CACurrentMediaTime()
        var changes: [(CFTimeInterval, [String])] = [(0, grid())]
        hit.mouseDown(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        hit.mouseUp(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
        var moving = false, stopped: CFTimeInterval?
        while CACurrentMediaTime() - start < 1.0 {
            let g = grid()
            if g != changes.last?.1 { changes.append((CACurrentMediaTime() - start, g)) }
            let gliding = all(PaneCardView.self, in: window.contentView!).contains(where: \.isGliding)
            if gliding { moving = true } else if moving, stopped == nil { stopped = CACurrentMediaTime() - start }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let frames = await recorder.stop()
        let log = changes.map { String(format: "t=%.3f ", $0.0) + $0.1.joined(separator: " ") }.joined(separator: "\n")
        try? log.write(toFile: "/tmp/pane-stack-snapshots/resize-log.txt", atomically: true, encoding: .utf8)

        #expect(controller.paneStackState.pin(for: key) == .init(start: 0, count: 3))
        #expect(changes.count == 2, "each terminal is resized once, all together:\n\(log)")
        if changes.count == 2 {
            #expect(moving, "the cards glided")
            #expect(changes[1].0 >= (stopped ?? 1) - 0.02, "resized mid-glide (it ended at \(stopped ?? -1)):\n\(log)")
            // The three on show all take the same slot size; the one still a
            // strip is never resized at all.
            let after = changes[1].1
            #expect(Set(after[0...2]).count == 1, "the cards on show are not all their slot's size:\n\(log)")
            #expect(after[3] == changes[0].1[3], "a minimized pane was resized:\n\(log)")
        }

        // A strip shows nothing of its pane.
        let cards = all(PaneCardView.self, in: window.contentView!)
        let tucked = try #require(cards.first { $0.paneID == panes[3].id })
        #expect(tucked.isContentHidden, "a minimized pane's content shows through its strip")
        #expect(!(try #require(cards.first { $0.paneID == panes[2].id })).isContentHidden)

        // The recording: dense through the slide, and the still card's text
        // never vanishes from a frame of it.
        let dir = "/tmp/pane-stack-snapshots/frames"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func text(_ image: CGImage) -> Int {
            let scale = CGFloat(image.width) / window.frame.width
            let rep = NSBitmapImageRep(cgImage: image)
            var n = 0
            for y in stride(from: stillFrame.minY + 20, to: stillFrame.maxY - 20, by: 3) {
                for x in stride(from: stillFrame.minX + 6, to: stillFrame.minX + 200, by: 2) {
                    if let c = rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale)),
                       (c.redComponent + c.greenComponent + c.blueComponent) / 3 > 0.55 { n += 1 }
                }
            }
            return n
        }
        let during = frames.filter { $0.0 - start >= 0 && $0.0 - start <= (stopped ?? 0.4) + 0.15 }
        #expect(during.count >= 15, "the slide was recorded at \(during.count) frames")
        let baseline = frames.first.map { text($0.1) } ?? 0
        #expect(baseline > 100, "no text to watch in the still card")
        for (n, frame) in frames.enumerated() {
            let ms = Int((frame.0 - start) * 1000)
            let t = text(frame.1)
            #expect(t * 2 > baseline, "frame \(n) at \(ms)ms: the still card flashed (\(t) of \(baseline) text pixels)")
            try NSBitmapImageRep(cgImage: frame.1).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: String(format: "%@/f%03d-%+05dms.png", dir, n, ms)))
        }
    }

    @Test func aTuckedPaneDroppedOnOneOnShowSwapsWithItAndTheRowStaysCollapsed() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 3, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        controller.performSplitAction(.restack(.init(items: panes.map { [$0.id] }, run: 0...2), .collapse(.trailing)))
        await settle(0.8)
        #expect(controller.paneStackState.pin(for: key) == .init(start: 0, count: 2))

        // Drag c's strip onto a.
        PaneMoveCoordinator.apply(.swap(window: controller.rearrangeWindowRef, pane: panes[0].id),
                                  pane: panes[2], from: controller)
        await settle(0.8)
        try await capture(window, "swapped")
        #expect(controller.surfaceTree.root?.leaves().map(\.id) == [panes[2].id, panes[1].id, panes[0].id])
        #expect(controller.paneStackState.pin(for: key) == .init(start: 0, count: 2))
        let tabs = all(PaneStackTabView.self, in: window.contentView!).filter { $0.isStrip }
        #expect(tabs.map { $0.pane?.id } == [panes[0].id], "a took c's place as the strip")
        #expect(panes[2].isFocusedPane)
        _ = window
    }

    @Test func dividersAndTheWindowEdgeTakeTheMouse() async throws {
        let (controller, window, _) = try await stackedWindow(count: 3, width: 1300)
        defer { controller.close() }
        var report = "minSize=\(window.minSize) maxSize=\(window.maxSize) contentMin=\(window.contentMinSize) contentMax=\(window.contentMaxSize) resizable=\(window.styleMask.contains(.resizable))\n"
        for handle in handles(window) {
            let r = handle.convert(handle.bounds, to: nil)
            let p = NSPoint(x: r.midX, y: r.midY)
            let hit = window.contentView!.superview!.hitTest(p)
            report += "handle \(r) -> hit \(hit.map { "\(type(of: $0))" } ?? "nil")\n"
            #expect(hit === handle, "a divider takes its own clicks")
        }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 900, height: 600)), display: true)
        await settle(0.5)
        report += "after setFrame 900: \(window.frame.size)\n"
        try? report.write(toFile: "/tmp/pane-stack-snapshots/probe.txt", atomically: true, encoding: .utf8)
        #expect(window.frame.width == 900)
    }

    @Test func cardsOnShowInAStackResizeAndSqueezeAside() async throws {
        // Four panes with room for three: three cards on show, one tucked.
        let (controller, window, panes) = try await stackedWindow(count: 4, width: 3 * Self.m.width + 200)
        defer { controller.close() }
        let width = { (p: PaneView) in p.contentView.frame.width }
        let grips = gripsBetweenCards(window)
        #expect(grips.count == 2, "a grip between each pair of cards on show")
        let before = panes.map(width)

        // Widen the first card on show by 40.
        drag(try #require(grips.first), by: 40)
        await settle(0.8)
        let after = panes.map(width)
        #expect(after != before, "the cards on show resized: \(before) -> \(after) shares \(controller.paneStackState.shares)")
        #expect(after.max()! - after.min()! >= 70, "one slot grew at another's expense: \(before) -> \(after) shares \(controller.paneStackState.shares)")

        // Squeeze the next card well past its minimum: the far card tucks.
        drag(try #require(gripsBetweenCards(window).first), by: 120)
        await settle(0.8)
        let key = Set(panes.map(\.id))
        #expect(controller.paneStackState.pin(for: key)?.count == 2)
    }

    @Test func aGripBetweenCardsFollowsThePointer() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 4, width: 3 * Self.m.width + 200)
        defer { controller.close() }
        // The card on show just before the grip.
        let grip = try #require(gripsBetweenCards(window).first)
        let gripX = grip.convert(grip.bounds, to: nil).midX
        let frame = { (p: PaneView) in p.contentView.convert(p.contentView.bounds, to: nil) }
        let first = try #require(panes.filter { frame($0).maxX <= gripX }.max { frame($0).maxX < frame($1).maxX })
        let edge = { frame(first).maxX }
        let before = edge()

        // A real drag: the layout catches up between mouse events. Short of
        // taking the card under a pane's minimum (cards here are a little
        // over it), so the edge is free to follow.
        grip.onDragBegan?()
        for step in 1...6 {
            grip.onDragDelta?(CGFloat(step) * -5, 0.5)
            await settle(0.1)
        }
        let held = edge()
        grip.onDragEnded?()
        #expect(abs(held - (before - 30)) <= 1, "30pt left moved the edge 30pt: \(before) -> \(held)")
    }

    @Test func oneDragCollapsesTheRowAndComingBackUndoesIt() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 3, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        let divider = try #require(handles(window).last)
        let start = divider.currentSplit?() ?? 0.5
        let widths = { panes.map { $0.contentView.frame.width } }
        let before = widths()

        divider.onDragBegan?()
        for step in 1...10 { divider.onDragDelta?(CGFloat(step) * 50, start) }
        await settle(0.5)
        #expect(controller.paneStackState.pin(for: key)?.count == 2, "snapped collapsed mid-drag")
        // Still held: the divider that started the drag is gone, and the
        // drag carries on through it. Back to where it began:
        for step in (0...9).reversed() { divider.onDragDelta?(CGFloat(step) * 50, start) }
        await settle(0.5)
        #expect(controller.paneStackState.pin(for: key) == nil, "pulled back open")
        divider.onDragEnded?()
        await settle(0.5)
        // As it was, give or take the divider's rounding to a ratio (as for
        // any drag that ends where it began).
        #expect(zip(widths(), before).allSatisfy { abs($0 - $1) <= 3 }, "and as it was: \(before) -> \(widths())")
        #expect(!controller.paneStackState.isGesturing)
    }

    @Test func collapsingARowKeepsTheColumnInsideItCollapsed() async throws {
        // A | (B over C), with room for all three.
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let panes = (0..<3).map { _ in PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)) }
        var tree = SplitTree<PaneView>(view: panes[0])
        tree = try tree.inserting(view: panes[1], at: panes[0], direction: .right)
        tree = try tree.inserting(view: panes[2], at: panes[1], direction: .down)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1300, height: 900))
        window.makeFirstResponder(panes[1].surfaceView)
        await settle(1.2)
        let state = controller.paneStackState
        let column = Set([panes[1].id, panes[2].id])
        let row = Set(panes.map(\.id))

        // Drag B/C's divider down: C minimizes.
        let sorted = handles(window)
        #expect(sorted.count == 2)
        drag(try #require(sorted.last), by: 500)
        await settle(0.8)
        #expect(state.pin(for: column) == .init(start: 0, count: 1), "C minimized")

        // Then drag A's divider right: the column minimizes beside A, and C
        // stays minimized inside it.
        drag(try #require(handles(window).first), by: 800)
        await settle(0.8)
        #expect(state.pin(for: row) == .init(start: 0, count: 1), "the column minimized")
        #expect(state.pin(for: column) == .init(start: 0, count: 1), "C is still minimized")
    }

    /// Six panes in one row (or column), collapsed by hand to two on show
    /// with two strips on each side, the second of the two focused.
    private func collapsedRow(
        _ direction: SplitTree<PaneView>.NewDirection,
        viewerAt viewer: Int? = nil
    ) async throws -> (TerminalController, NSWindow, [PaneView]) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let panes = (0..<6).map { i in
            i == viewer
                ? PaneView(viewer: ViewerView(location: "about:blank"))
                : PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        }
        var tree = SplitTree<PaneView>(view: panes[0])
        for i in 1..<6 { tree = try tree.inserting(view: panes[i], at: panes[i - 1], direction: direction) }
        tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(direction == .right ? NSSize(width: 1600, height: 600) : NSSize(width: 900, height: 1000))
        window.makeFirstResponder(panes[3].surfaceView ?? panes[3].contentView)
        await settle(1.2)
        let items = panes.map { [$0.id] }
        controller.performSplitAction(.restack(.init(items: items, run: 1...4), .collapse(.leading)))
        controller.performSplitAction(.restack(.init(items: items, run: 2...4), .collapse(.trailing)))
        await settle(0.8)
        #expect(controller.paneStackState.pin(for: Set(panes.map(\.id))) == .init(start: 2, count: 2))
        return (controller, window, panes)
    }

    /// The panes drawn as strips, in order.
    private func strips(_ window: NSWindow) -> [UUID?] {
        all(PaneStackTabView.self, in: window.contentView!).filter { $0.isStrip }
            .sorted {
                let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
                return a.minX == b.minX ? a.minY > b.minY : a.minX < b.minX
            }
            .map { $0.pane?.id }
    }

    /// A strip whose pane has a banner is the same glass top to bottom: the
    /// pane's sheet is thinner under its banner card on show, and that patch
    /// fades with the banner as the pane goes into its strip — left behind,
    /// it was a pale rectangle at the strip's top. Measured on the composited
    /// window: the strip's brightness where the card is, against below it.
    @Test func aStripWithABannerIsTheSameGlassTopToBottom() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        panes[0].surfaceView?.paneBanner = "## Bedtime story\n**Status:** Working"
        await settle(1.0)
        let strip = try #require(all(PaneStackTabView.self, in: window.contentView!)
            .first { $0.isStrip && $0.pane === panes[0] })
        let rect = strip.convert(strip.bounds, to: nil)
        // Another strip, with no banner: the window's own gradient shows
        // through both, so its top-to-bottom difference is what isn't a patch.
        let plain = try #require(all(PaneStackTabView.self, in: window.contentView!)
            .first { $0.isStrip && $0.pane !== panes[0] })
        let plainRect = plain.convert(plain.bounds, to: nil)
        let content = try await SCShareableContent.currentProcess
        let scWindow = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let cfg = SCStreamConfiguration()
        cfg.width = Int(scWindow.frame.width * 2)
        cfg.height = Int(scWindow.frame.height * 2)
        cfg.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: cfg)
        try await capture(window, "strip-with-banner")
        let rep = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(image.width) / window.frame.width
        func brightness(atTop offset: CGFloat, in rect: CGRect) -> Double {
            // A band across the strip's middle, `offset` points below its top,
            // clear of its title (which runs down its middle lower down).
            var total = 0.0, n = 0.0
            for x in stride(from: rect.minX + 4, to: rect.maxX - 4, by: 1) {
                let y = rect.maxY - offset
                guard let c = rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale))?
                    .usingColorSpace(.sRGB) else { continue }
                total += Double(c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255
                n += 1
            }
            return total / max(n, 1)
        }
        let underCard = brightness(atTop: 30, in: rect), below = brightness(atTop: 150, in: rect)
        let gradient = brightness(atTop: 30, in: plainRect) - brightness(atTop: 150, in: plainRect)
        #expect(abs(underCard - below - gradient) < 3,
                "the strip is paler where the banner was: \(underCard) vs \(below), the gradient alone \(gradient)")
    }

    @Test(arguments: [false, true])
    func closingAPaneOnShowKeepsTheStripsMinimized(vertical: Bool) async throws {
        let direction: SplitTree<PaneView>.NewDirection = vertical ? .down : .right
        let (controller, window, panes) = try await collapsedRow(direction)
        defer { controller.close() }
        let name = direction == .right ? "row" : "column"
        try await capture(window, "close-\(name)-before")
        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id))

        // Close the first of the two on show (the caret's neighbour, so the
        // caret has to go somewhere).
        window.makeFirstResponder(panes[2].surfaceView)
        await settle(0.4)
        controller.closeSurface(try #require(panes[2].surfaceView), withConfirmation: false)
        await settle(1.0)
        try await capture(window, "close-\(name)-after")

        let rest = [panes[0], panes[1], panes[3], panes[4], panes[5]]
        #expect(controller.paneStackState.pin(for: Set(rest.map(\.id))) == .init(start: 2, count: 1))
        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id), "the strips stay minimized")
        #expect(panes[3].isFocusedPane, "the caret went to the pane still on show")
        // The one left on show takes the whole run: the row's extent less the
        // four strips and their gutters.
        let extent = direction == .right ? panes[3].contentView.frame.width : panes[3].contentView.frame.height
        let stage = try #require(all(PaneCardView.self, in: window.contentView!).first?.superview)
        let total = direction == .right ? stage.bounds.width : stage.bounds.height
        let margins = 2 * PaneElevation.margin
        #expect(extent >= total - margins - 4 * (PaneLayout.Metrics.peek + PaneElevation.gap) - 1, "\(extent) of \(total)")
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func splittingAPaneOnShowKeepsTheStripsMinimized(vertical: Bool, across: Bool) async throws {
        let direction: SplitTree<PaneView>.NewDirection = vertical ? .down : .right
        let (controller, window, panes) = try await collapsedRow(direction)
        defer { controller.close() }
        let name = "\(vertical ? "column" : "row")-\(across ? "across" : "along")"
        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id))

        // Split the focused pane on show, as Cmd-D / Cmd-Shift-D do.
        let split: SplitTree<PaneView>.NewDirection = across ? (vertical ? .right : .down) : direction
        let anchor = try #require(panes[3].surfaceView)
        let surface = try #require(controller.newSplit(at: anchor, direction: split))
        await settle(1.2)
        try await capture(window, "split-\(name)-after")
        let added = try #require(controller.surfaceTree.pane(for: surface))

        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id), "the strips stay minimized")
        #expect(added.isFocusedPane)
    }

    @Test(arguments: [false, true])
    func splittingTheOnlyPaneOnShowWithNoRoomForTwoShowsTheNewOne(vertical: Bool) async throws {
        // Room for two on show: c d, then d splits. The new pane comes on
        // show beside d, c minimizes to make room, and nothing else moves.
        let direction: SplitTree<PaneView>.NewDirection = vertical ? .down : .right
        let (controller, window, panes) = try await collapsedRow(direction)
        defer { controller.close() }
        window.setContentSize(vertical
            ? NSSize(width: 900, height: 2 * Self.m.height + 360)
            : NSSize(width: 2 * Self.m.width + 350, height: 600))
        await settle(1.0)
        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id))

        let anchor = try #require(panes[3].surfaceView)
        let surface = try #require(controller.newSplit(at: anchor, direction: direction))
        await settle(1.2)
        try await capture(window, "split-\(vertical ? "column" : "row")-no-room")
        let added = try #require(controller.surfaceTree.pane(for: surface))
        #expect(strips(window) == [panes[0], panes[1], panes[2], panes[4], panes[5]].map(\.id))
        #expect(added.isFocusedPane)
    }

    /// An agent's side pane: `+split --view` from the pane with the caret,
    /// which keeps the caret. In a row with no room for one more, the new
    /// pane must still come on show — it is what was asked for — rather than
    /// be born a strip nobody notices.
    @Test(arguments: [2, 3])
    func aSidePaneOpenedWithoutFocusComesOnShow(count: Int) async throws {
        let width = CGFloat(count) * Self.m.width + CGFloat(count + 1) * PaneElevation.gap + 40
        let (controller, window, panes) = try await stackedWindow(count: count, width: width)
        defer { controller.close() }
        #expect(strips(window).isEmpty, "\(count) fit side by side")

        let caller = panes[count - 1]
        let viewer = ViewerView(location: "about:blank")
        let added = try #require(controller.newViewerSplit(atPane: caller, direction: .right, viewer: viewer))
        // The row stacks once it is laid out; under load that takes a while.
        for _ in 0..<50 where strips(window).count < 2 { await settle(0.1) }
        await settle(0.5)
        try await capture(window, "side-pane-\(count)")

        #expect(!strips(window).contains(added.id), "the side pane is on show, not a strip")
        #expect(caller.isFocusedPane, "the caller keeps the caret")
        #expect(caller.surfaceView.map { window.firstResponder === $0 } == true, "the caret really is there")
        // Two cards and a strip fit in the wider window: the caller stays on
        // show beside its side pane and the other panes make room. The
        // narrower one has room for one card once a strip is needed, and the
        // side pane is that card — the caller makes room, caret and all.
        #expect(strips(window).contains(caller.id) == (count == 2), "\(strips(window))")
        #expect(strips(window).count == 2, "3 panes with 1 on show, or 4 with 2")
    }

    /// Room for one pane only: the side pane is still the one on show, and
    /// the caller — now the strip — keeps the caret. Focus never MOVES onto a
    /// strip; here it stays where it was.
    @Test func aSidePaneInARowWithRoomForOneTakesItAndTheCallerKeepsTheCaret() async throws {
        let width = 300 + 2 * PaneElevation.gap + 40
        let (controller, window, panes) = try await stackedWindow(count: 1, width: width)
        defer { controller.close() }

        let caller = panes[0]
        let viewer = ViewerView(location: "about:blank")
        let added = try #require(controller.newViewerSplit(atPane: caller, direction: .right, viewer: viewer))
        for _ in 0..<50 where strips(window).isEmpty { await settle(0.1) }
        await settle(0.5)
        try await capture(window, "side-pane-room-for-one")

        #expect(!strips(window).contains(added.id), "the side pane is on show")
        #expect(strips(window).contains(caller.id), "the caller made room")
        #expect(caller.isFocusedPane, "the caller keeps the caret")
        #expect(caller.surfaceView.map { window.firstResponder === $0 } == true, "the caret really is there")
    }

    /// The user's flow: ask for a side pane, switch to another app, come
    /// back. The split lands while the window is covered (occluded), and must
    /// be on screen when the window is uncovered.
    @Test func aSidePaneOpenedWhileTheWindowIsCoveredIsThereWhenUncovered() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 1, width: 1200)
        defer { controller.close() }
        let cover = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless], backing: .buffered, defer: false)
        cover.backgroundColor = .black
        cover.level = .floating
        cover.orderFrontRegardless()
        for _ in 0..<30 where window.occlusionState.contains(.visible) { await settle(0.1) }
        let occluded = !window.occlusionState.contains(.visible)

        let viewer = ViewerView(location: "about:blank")
        let added = try #require(controller.newViewerSplit(atPane: panes[0], direction: .right, viewer: viewer))
        await settle(3)
        cover.orderOut(nil)
        await settle(1.2)
        try await capture(window, "side-pane-covered")

        #expect(occluded, "the window was covered")
        let card = try #require(cardRect(window, added), "the side pane has a card")
        #expect(card.width > 300, "the side pane is on show: \(card)")
        #expect(added.contentView.window === window)
        #expect(added.contentView.frame.width > 300, "its content is laid out: \(added.contentView.frame)")
    }

    // MARK: - A drag that goes on squeezing

    /// The user's repro: three panes side by side, the LEFT divider dragged
    /// right with the mouse. The rightmost pane tucks into a strip; as the
    /// drag goes on, the next one does too, until one pane is left on show;
    /// and coming back, still held, they return in reverse. Driven with real
    /// mouse events through the divider the window hit-tests at its gutter,
    /// for both tree shapes a row of three can have.
    @Test(arguments: [false, true])
    func draggingTheLeftDividerOnCollapsesOnePaneAfterAnother(leftNested: Bool) async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let panes = (0..<3).map { _ in PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)) }
        var tree = SplitTree<PaneView>(view: panes[0])
        tree = try tree.inserting(view: panes[1], at: panes[0], direction: .right)
        // a | (b | c), or (a | b) | c.
        tree = try tree.inserting(view: panes[2], at: panes[leftNested ? 1 : 1], direction: .right)
        if leftNested {
            tree = SplitTree<PaneView>(view: panes[0])
            tree = try tree.inserting(view: panes[1], at: panes[0], direction: .right)
            tree = tree.insertingAtTopLevel(view: panes[2], side: .right)
        }
        tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1300, height: 600))
        window.makeFirstResponder(panes[0].surfaceView)
        await settle(1.2)
        let key = Set(panes.map(\.id))

        // The left divider, as the window hit-tests it in its gutter.
        let divider = try #require(handles(window).first)
        let gutter = divider.convert(divider.bounds, to: nil)
        let start = NSPoint(x: gutter.midX, y: gutter.midY)
        let hit = try #require(window.contentView?.superview?.hitTest(start))
        #expect(hit === divider, "the gutter is the divider's")

        // Every step of the drag, the row as it stood after it.
        var steps: [(x: CGFloat, count: Int?)] = []
        let deliver = divider.onDragDelta
        divider.onDragDelta = { delta, split in
            deliver?(delta, split)
            let pin = controller.paneStackState.pin(for: key)
            steps.append((start.x + delta, pin == nil ? nil : pin!.count))
        }
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let far = gutter.midX + 1200
        let out = Array(stride(from: start.x + 10, through: far, by: 10))
        for x in out + out.reversed() + [start.x] { NSApp.postEvent(try event(.leftMouseDragged, x), atStart: false) }
        NSApp.postEvent(try event(.leftMouseUp, start.x), atStart: false)
        divider.mouseDown(with: try event(.leftMouseDown, start.x))
        await settle(0.8)

        // Out: side by side, then c tucked (two on show), then b (one on
        // show), and nothing past that.
        let counts = steps.map(\.count)
        let outward = Array(counts.prefix(out.count))
        func runs(_ values: [Int?]) -> [Int?] {
            values.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        }
        #expect(runs(outward) == [nil, 2, 1], "out: \(runs(outward)) at \(steps.map { Int($0.x) })")
        // Back: b, then c, in reverse, and side by side where it began.
        let back = Array(counts.suffix(out.count + 1))
        #expect(runs(back) == [1, 2, nil], "back: \(runs(back))")
        #expect(controller.paneStackState.pin(for: key) == nil)
        #expect(!controller.paneStackState.isGesturing)
    }

    /// A terminal beside a viewer, the sidebar expanded, the divider dragged to
    /// the window's edge so the terminal is a strip; then the grip between
    /// the strip and the viewer pulled away from the strip, with real mouse
    /// events, like the divider it stands in for. The terminal comes out
    /// once it would be a pane's minimum wide, with its edge under the
    /// pointer; pulled back under the minimum in the same drag, it goes back.
    /// (The grip used to want a drag the other way, out over the strip, of
    /// 48pt — more than the strip and its gutter span before the sidebar.)
    @Test(arguments: [
        ([0.5], false),
        ([4.0 / 3], true),
        ([4.0 / 3, 1.0 / 3], false),
    ] as [([CGFloat], Bool)])
    func aStripIsPulledBackOutByItsGutterLikeADivider(path minimums: [CGFloat], comesOut: Bool) async throws {
        // In pane minimums, so it reads the same whatever the minimum is.
        let path = minimums.map { $0 * Self.m.width }
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let terminal = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let doc = FileManager.default.temporaryDirectory.appendingPathComponent("strip-gutter.html")
        try "<body style='background:orange'><h1>page</h1></body>".write(to: doc, atomically: true, encoding: .utf8)
        let viewer = PaneView(viewer: ViewerView(location: doc.path))
        var tree = SplitTree<PaneView>(view: terminal)
        tree = try tree.inserting(view: viewer, at: terminal, direction: .right)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.paneSidebarState.isHidden = false
        controller.paneSidebarState.isExpanded = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.makeFirstResponder(try #require(viewer.viewerView))
        await settle(1.5)
        let key = Set([terminal.id, viewer.id])

        func event(_ type: NSEvent.EventType, _ p: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        /// A real drag from `from` through each offset in `path`, delivered
        /// to whatever the window hit-tests there.
        func drag(from: NSPoint, through path: [CGFloat]) async throws -> NSView? {
            let hit = window.contentView?.superview?.hitTest(from)
            var x = from.x
            for target in path.map({ from.x + $0 }) {
                let step: CGFloat = target > x ? 10 : -10
                while abs(target - x) >= 10 {
                    x += step
                    NSApp.postEvent(try event(.leftMouseDragged, NSPoint(x: x, y: from.y)), atStart: false)
                }
            }
            NSApp.postEvent(try event(.leftMouseUp, NSPoint(x: x, y: from.y)), atStart: false)
            hit?.mouseDown(with: try event(.leftMouseDown, from))
            await settle(1.0)
            return hit
        }

        // The divider, dragged to the window's leading edge.
        let divider = try #require(handles(window).first)
        let gutter = divider.convert(divider.bounds, to: nil)
        _ = try await drag(from: NSPoint(x: gutter.midX, y: gutter.midY), through: [-gutter.midX + 5])
        #expect(controller.paneStackState.pin(for: key) != nil, "collapsed")
        #expect(strips(window) == [terminal.id], "the terminal is a strip")

        // The gutter between the strip and the viewer: the one grip left.
        let grips = handles(window)
        #expect(grips.count == 1, "\(grips.count) grips")
        let grip = try #require(grips.first).convert(try #require(grips.first).bounds, to: nil)
        let point = NSPoint(x: grip.midX, y: grip.midY)
        let hit = try await drag(from: point, through: path)
        try await capture(window, "strip-gutter-after")
        #expect(hit is DividerHandle.DividerHandleView, "the gutter at \(point) hit \(String(describing: hit))")
        if comesOut {
            #expect(controller.paneStackState.pin(for: key) == nil, "pulled back out")
            #expect(strips(window).isEmpty)
            // Its edge where the pointer let go: the divider is there.
            let edge = try #require(handles(window).first)
            let at = edge.convert(edge.bounds, to: nil).midX
            #expect(abs(at - (point.x + path.last!)) <= 12, "the divider at \(at), the pointer at \(point.x + path.last!)")
        } else {
            #expect(controller.paneStackState.pin(for: key) != nil, "still collapsed")
            #expect(strips(window) == [terminal.id])
        }
    }

    /// A drag from `start` through `path` (offsets along x), paced like a
    /// hand's — posted from another thread, a step every 8ms, so frames are
    /// drawn between — recorded as the window server composites it. Returns
    /// the frames drawn while the mouse was held, each with the range the
    /// pointer's offset took in the 150ms before it (a frame trails the
    /// events it shows, by a varying amount).
    private func recordedDrag(
        _ window: NSWindow, from start: NSPoint, through path: [CGFloat]
    ) async throws -> [(image: CGImage, pointer: ClosedRange<CGFloat>)] {
        let windowNumber = window.windowNumber
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        let recorder = WindowFrameRecorder()
        try await recorder.start(window, scale: 2)
        await settle(0.3)
        let steps = Steps()
        let posted = DispatchSemaphore(value: 0)
        let last = path.last ?? 0
        DispatchQueue.global().async {
            for dx in path {
                usleep(8000)
                steps.append(CACurrentMediaTime(), dx)
                if let e = event(.leftMouseDragged, start.x + dx) { NSApp.postEvent(e, atStart: false) }
            }
            usleep(50000)
            if let e = event(.leftMouseUp, start.x + last) { NSApp.postEvent(e, atStart: false) }
            posted.signal()
        }
        GutterBar.pointerOverride = CGPoint(x: start.x + last, y: start.y)
        defer { GutterBar.pointerOverride = nil }
        let hit = try #require(window.contentView?.superview?.hitTest(start))
        hit.mouseDown(with: try #require(event(.leftMouseDown, start.x)))
        let released = CACurrentMediaTime()
        posted.wait()
        await settle(0.3)
        let all = steps.all
        return await recorder.stop().compactMap { t, image in
            let recent = all.filter { $0.0 <= t && $0.0 >= t - 0.15 }.map(\.1)
            guard let first = all.first, t > first.0 + 0.05, t < released - 0.06,
                  let lo = recent.min(), let hi = recent.max() else { return nil }
            return (image, lo...hi)
        }
    }

    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [(CFTimeInterval, CGFloat)] = []
        func append(_ t: CFTimeInterval, _ dx: CGFloat) { lock.lock(); steps.append((t, dx)); lock.unlock() }
        var all: [(CFTimeInterval, CGFloat)] { lock.lock(); defer { lock.unlock() }; return steps }
    }

    /// The accent bars across a frame's row at `y` (window points): the x of
    /// each run of saturated accent.
    private func bars(_ image: CGImage, _ window: NSWindow, y: CGFloat) -> [CGFloat] {
        let scale = CGFloat(image.width) / window.frame.width
        let rep = NSBitmapImageRep(cgImage: image)
        let row = Int((window.frame.height - y) * scale)
        var runs: [CGFloat] = []
        var inRun = false
        for px in 0..<image.width {
            guard let c = rep.colorAt(x: px, y: row)?.usingColorSpace(.sRGB) else { continue }
            let lit = c.blueComponent > 0.75 && c.blueComponent - c.redComponent > 0.4
            if lit && !inRun { runs.append(CGFloat(px) / scale) }
            inRun = lit
        }
        return runs
    }

    /// The bar stays in the gutter it is dragging, lit, and is the only bar:
    /// a strip's grip pulled out past the pane's minimum, then back so the
    /// pane goes back, recorded frame by frame. Under the minimum it stays
    /// at the strip's gutter (the pane has not come out, so the gutter has
    /// not moved); out, it is the divider's, at the pointer. It used to
    /// vanish as the pane came out and as it went back, and to double up
    /// with the hover bar of a grip that came back under the pointer.
    @Test func theBarStaysInTheGutterAsAStripComesOutAndGoesBack() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        drag(try #require(handles(window).first), by: -800)
        await settle(0.8)
        #expect(controller.paneStackState.pin(for: key) != nil, "collapsed")
        let grip = try #require(handles(window).first)
        let gutter = grip.convert(grip.bounds, to: nil)
        let start = NSPoint(x: gutter.midX, y: gutter.midY)

        var path = Array(stride(from: CGFloat(10), through: 400, by: 10)) + Array(repeating: 400, count: 15)
        path += Array(stride(from: CGFloat(390), through: 100, by: -10)) + Array(repeating: 100, count: 30)
        let frames = try await recordedDrag(window, from: start, through: path)
        #expect(controller.paneStackState.pin(for: key) != nil, "back under the minimum, it went back")
        #expect(frames.count > 20, "only \(frames.count) frames while held")
        try expectOneBar(frames, window, y: start.y) { pointer, bar in
            // In the gutter: at the strip's until the pane comes out, then
            // the divider's, gliding with it as the pane comes out and goes
            // back — never past the strip, nor out ahead of the pointer.
            bar >= start.x - 8 && bar <= start.x + pointer.upperBound + 8
        }
        // Let go away from any gutter: nothing stays lit.
        await settle(0.3)
        #expect(handles(window).allSatisfy { !$0.showsBar }, "a bar stayed lit after the drag")
    }

    /// A divider dragged until its pane tucks away, then on, and back: the
    /// bar stays in the gutter — at the pane's minimum while it squeezes, at
    /// the strip's edge once it snaps there — lit, one bar, never at the
    /// pointer out past where the gutter can go.
    @Test func theBarStaysInTheGutterAsADividerCollapsesAPaneAndBack() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        let divider = try #require(handles(window).first)
        let gutter = divider.convert(divider.bounds, to: nil)
        let start = NSPoint(x: gutter.midX, y: gutter.midY)
        let paneStart = try #require(cardRects(window).map(\.minX).min())
        let minimumAt = paneStart + PaneLayout.Metrics.minimumPaneSize.width - start.x

        var path = Array(stride(from: CGFloat(-10), through: -450, by: -10)) + Array(repeating: -450, count: 15)
        path += Array(stride(from: CGFloat(-440), through: 0, by: 10)) + Array(repeating: 0, count: 15)
        let frames = try await recordedDrag(window, from: start, through: path)
        #expect(controller.paneStackState.pin(for: key) == nil, "back where it began, side by side")
        #expect(frames.count > 20, "only \(frames.count) frames while held")
        try expectOneBar(frames, window, y: start.y) { pointer, bar in
            // Out past where the gutter can go, the bar is not at the
            // pointer: it is at the pane's minimum, or — the pane tucked —
            // at the strip's edge, where the gutter snapped.
            pointer.upperBound < minimumAt - 100 ? abs(bar - (start.x + pointer.lowerBound)) > 40 : true
        }
    }

    /// A pane collapsed by its divider narrows into its strip as a glass
    /// card — its content fading out and its title in, step by step with how
    /// far in it is — and its strip is that card, the desk reading through
    /// it like any unfocused pane. It used to glide in as a glass card, then
    /// switch in one frame to a dark, nearly opaque bar.
    @Test func aPaneCollapsesIntoAGlassStripWithNothingSnapping() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        let divider = try #require(handles(window).first)
        let gutter = divider.convert(divider.bounds, to: nil)

        var samples: [(collapse: CGFloat, title: CGFloat)] = []
        var mismatched: [String] = []
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let card = self.all(PaneCardView.self, in: window.contentView!)
                    .first(where: { $0.paneID == panes[0].id }) else { return }
                samples.append((card.collapse, card.titleOpacity))
                if abs(card.collapse - card.titleOpacity) > 0.01 {
                    mismatched.append("collapse \(card.collapse) title \(card.titleOpacity)")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let path = Array(stride(from: CGFloat(-20), through: -700, by: -20)) + Array(repeating: -700, count: 10)
        _ = try await recordedDrag(window, from: NSPoint(x: gutter.midX, y: gutter.midY), through: path)
        await settle(0.6)
        timer.invalidate()

        #expect(controller.paneStackState.pin(for: key) != nil, "the left pane is a strip")
        #expect(mismatched.isEmpty, "the title is not the content's complement: \(mismatched.prefix(5))")
        let collapses = samples.map(\.collapse)
        #expect(collapses.last == 1, "settled as a strip: \(collapses.suffix(5))")
        #expect(collapses.contains { $0 > 0.05 && $0 < 0.95 }, "it faded through, never seen part way: \(collapses)")
        let steps = zip(collapses.dropFirst(), collapses).map { abs($0 - $1) }
        #expect((steps.max() ?? 0) < 0.5, "it snapped: \(collapses.map { String(format: "%.2f", $0) })")

        // The strip is glass: about as light as the desk beside it.
        let strip = try #require(cardRect(window, panes[0]))
        let recorder = WindowFrameRecorder()
        try await recorder.start(window)
        await settle(0.2)
        let image = try #require(await recorder.stop().last?.1)
        let rep = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(image.width) / window.frame.width
        func luminance(_ rect: CGRect) -> CGFloat {
            var sum: CGFloat = 0, n: CGFloat = 0
            for y in stride(from: rect.minY, to: rect.maxY, by: 4) {
                for x in stride(from: rect.minX, to: rect.maxX, by: 2) {
                    guard let c = rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale)) else { continue }
                    sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3
                    n += 1
                }
            }
            return n > 0 ? sum / n : 0
        }
        // Away from the title down its middle, and from the rim.
        let side = CGRect(x: strip.minX + 3, y: strip.minY + 40, width: 6, height: strip.height / 3)
        let desk = CGRect(x: strip.minX - 7, y: side.minY, width: 4, height: side.height)
        let (s, d) = (luminance(side), luminance(desk))
        #expect(s > d * 0.75, "the strip is a dark bar, not glass: \(s) against the desk's \(d)")
    }

    /// A pane collapsing onto a stack of strips lands between the run and
    /// the strip that was nearest it — and that strip does not move: its
    /// outer edge stays put, and none of it ever shows past where it showed
    /// before (it reaches under the newcomer, `bladeTuck`, only where the
    /// newcomer covers it). Both sides of the run.
    @Test(arguments: [true, false])
    func aStripStaysPutWhenAnotherCollapsesOntoIt(leading: Bool) async throws {
        let (controller, window, panes) = try await stackedWindow(count: 4, width: 1300)
        defer { controller.close() }
        // Leading: tuck pane 0, then pane 1 onto it. Trailing: 3, then 2.
        let (first, second) = leading ? (panes[0], panes[1]) : (panes[3], panes[2])
        let dx: CGFloat = leading ? -700 : 700
        func gutter(_ index: Int) throws -> NSPoint {
            let h = try #require(handles(window)[safe: index])
            let r = h.convert(h.bounds, to: nil)
            return NSPoint(x: r.midX, y: r.midY)
        }
        func path() -> [CGFloat] {
            Array(stride(from: dx / 35, through: dx, by: dx / 35)) + Array(repeating: dx, count: 10)
        }
        _ = try await recordedDrag(window, from: try gutter(leading ? 0 : handles(window).count - 1), through: path())
        await settle(0.8)
        #expect(controller.paneStackState.pin(for: Set([first.id])) != nil || cardRect(window, first).map { $0.width < 60 } == true,
                "the first pane is a strip")
        let cards = all(PaneCardView.self, in: window.contentView!)
        let a = try #require(cards.first { $0.paneID == second.id })
        let b = try #require(cards.first { $0.paneID == first.id })
        let before = try #require(b.placedTab?.rect, "the first pane is a strip")

        // Where B is drawn, and how far of it shows past A (A is above it).
        var outer: [CGFloat] = [], shows: [CGFloat] = []
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let tab = b.placedTab?.rect else { return }
                let over = a.placedTab?.rect ?? a.placedFrame
                outer.append(leading ? tab.minX : tab.maxX)
                if leading {
                    shows.append(Swift.min(tab.maxX, over.map { $0.minX } ?? .infinity) - tab.minX)
                } else {
                    shows.append(tab.maxX - Swift.max(tab.minX, over.map { $0.maxX } ?? -.infinity))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // The divider between the second pane and the run (past the grip
        // where the run meets the first strip).
        let next = try gutter(leading ? 1 : handles(window).count - 2)
        _ = try await recordedDrag(window, from: next, through: path())
        await settle(0.8)
        timer.invalidate()

        let after = try #require(b.placedTab?.rect)
        let visible = before.width
        let report = "before \(before) after \(after); outer \(outer.map { Int($0) }); shows \(shows.map { String(format: "%.1f", $0) })"
        try? report.write(toFile: "/tmp/pane-stack-snapshots/strip-stays-\(leading ? "leading" : "trailing").txt",
                          atomically: true, encoding: .utf8)
        #expect(cardRect(window, second).map { $0.width < 60 } == true, "the second pane is a strip: \(report)")
        #expect(!outer.isEmpty)
        #expect(outer.allSatisfy { abs($0 - outer[0]) < 0.5 }, "its outer edge moved: \(report)")
        #expect(shows.allSatisfy { $0 <= visible + 0.5 }, "more of it showed than before: \(report)")
    }

    private func expectOneBar(
        _ frames: [(image: CGImage, pointer: ClosedRange<CGFloat>)], _ window: NSWindow, y: CGFloat,
        where placed: (ClosedRange<CGFloat>, CGFloat) -> Bool
    ) throws {
        let dir = "/tmp/pane-stack-snapshots/bar-frames"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (n, frame) in frames.enumerated() {
            let found = bars(frame.image, window, y: y)
            let ok = found.count == 1 && placed(frame.pointer, found[0])
            try? NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: String(format: "%@/f%03d%@.png", dir, n, ok ? "" : "-bad")))
            if !ok {
                Issue.record("frame \(n), pointer \(frame.pointer): bars at \(found.map { Int($0) })")
            }
        }
    }

    /// The user's layout: two terminals stacked on the left; on the right a
    /// viewer over a row of four terminals, the first two tucked away as
    /// strips with no room for a third card. Returns the panes: a, b (left),
    /// v (viewer), c, d, e, f (the row).
    private func nestedCollapsedRow(width: CGFloat = 1700) async throws -> (TerminalController, NSWindow, [PaneView]) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        func terminal() -> PaneView { PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)) }
        let a = terminal(), b = terminal(), c = terminal(), d = terminal(), e = terminal(), f = terminal()
        let v = PaneView(viewer: ViewerView(location: "about:blank"))
        var tree = SplitTree<PaneView>(view: a)
        tree = try tree.inserting(view: v, at: a, direction: .right)
        tree = try tree.inserting(view: b, at: a, direction: .down)
        tree = try tree.inserting(view: c, at: v, direction: .down)
        tree = try tree.inserting(view: d, at: c, direction: .right)
        tree = try tree.inserting(view: e, at: d, direction: .right)
        tree = try tree.inserting(view: f, at: e, direction: .right)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: width, height: 900))
        window.makeFirstResponder(f.surfaceView)
        await settle(1.2)
        return (controller, window, [a, b, v, c, d, e, f])
    }

    /// The bottom row stacked for want of room — two strips to the left, no
    /// room for a third card, collapsed by nobody: the gutter between the
    /// strips and the first card on show is a grip all the same, and pulling
    /// it past a pane's minimum brings the nearer strip out, the card at the
    /// far end tucking away to make room. It used to be no grip at all — a
    /// gutter that could not be taken.
    @Test func aRunEdgeWithNoRoomForOneMoreIsStillAGrip() async throws {
        let (controller, window, panes) = try await nestedCollapsedRow(width: 4 * Self.m.width + 250)
        defer { controller.close() }
        let row = panes[3...].map { [$0.id] }
        try await capture(window, "nested-before")
        let stack = try #require(controller.paneStackState.stacks.first { $0.items == row }, "the row is stacked")
        #expect(stack.run.lowerBound > 0 && stack.fits <= stack.run.count,
                "strips before the run, no room for more: run \(stack.run), fits \(stack.fits)")

        // The gutter between the last strip and the first card on show.
        let firstOnShow = try #require(cardRect(window, panes[3 + stack.run.lowerBound]))
        let point = NSPoint(x: firstOnShow.minX - 5, y: firstOnShow.midY)
        let hit = window.contentView?.superview?.hitTest(point)
        let grip = try #require(hit as? DividerHandle.DividerHandleView, "the gutter at \(point) hit \(String(describing: hit))")
        // Far enough for a pane's minimum on this side (a card, a strip and
        // the gutter between), not so far that the other side has no room
        // left for one card and a strip: a few points under a minimum
        // (274...282 when it was 300) slides by exactly one.
        let reach = Self.m.width - 22
        grip.onDragBegan?()
        for step in 1...24 { grip.onDragDelta?(CGFloat(step) * reach / 24, 0.5); await settle(0.01) }
        grip.onDragEnded?()
        await settle(0.8)
        try await capture(window, "nested-slid")
        let after = try #require(controller.paneStackState.stacks.first { $0.items == row })
        #expect(after.run == (stack.run.lowerBound - 1)...(stack.run.upperBound - 1),
                "slid along by one: \(stack.run) -> \(after.run); row \(stack.frame), cards \(panes[3...].map { cardRect(window, $0).map { Int($0.width) } ?? -1 })")
    }

    /// Five panes, four on show at their minimums and the fifth a strip on
    /// the right, no room for another: pulling the strip's gutter out slides
    /// the row along — the leftmost pane tucks away, the strip's pane comes
    /// out. It used to refuse: bringing the strip out first made "all five on
    /// show", which is no collapse at all, so there was nothing left to tuck
    /// and the row stacked back exactly as it was.
    @Test func pullingTheLastStripOutOfAFullRowTucksTheFarPane() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 5, width: 4 * Self.m.width + 140)
        defer { controller.close() }
        window.makeFirstResponder(panes[0].surfaceView)
        await settle(0.6)
        #expect(strips(window) == [panes[4].id], "four on show, the fifth a strip: \(strips(window))")
        // Far enough for the fifth's minimum, not so far that the four give
        // up two: the row slides by one.
        let grip = try #require(handles(window).last)
        drag(grip, by: -(Self.m.width - 20))
        await settle(0.8)
        #expect(strips(window) == [panes[0].id], "slid along: \(strips(window))")
    }

    /// The same full row, its last strip pulled out with a hand-paced drag
    /// and let go: once settled, every card sits where the layout puts it,
    /// whole — nothing cut, nothing still mid-glide. It used to end with the
    /// pane that came out cut short on its leading side and a gap before it:
    /// its cut was taken from where it was first headed, and the glide never
    /// heard that the drag was over.
    @Test func pullingTheLastStripOutOfAFullRowSettlesWhole() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 5, width: 4 * Self.m.width + 140)
        defer { controller.close() }
        window.makeFirstResponder(panes[0].surfaceView)
        await settle(0.6)
        #expect(strips(window) == [panes[4].id])
        let grip = try #require(handles(window).last)
        let gutter = grip.convert(grip.bounds, to: nil)
        let reach = -(Self.m.width - 20)
        let path = Array(stride(from: CGFloat(-10), through: reach, by: -10)) + Array(repeating: reach, count: 10)
        _ = try await recordedDrag(window, from: NSPoint(x: gutter.midX, y: gutter.midY), through: path)
        await settle(0.6)
        #expect(strips(window) == [panes[0].id], "slid along")
        // Every card on show is drawn where the layout puts it, uncut.
        for card in all(PaneCardView.self, in: window.contentView!) where !card.isContentHidden {
            let id = try #require(card.paneID)
            #expect(!card.isGliding, "\(id) still mid-glide")
            let clip = try #require(card.clipLayer).frame
            let o = PaneCardView.outset
            #expect(clip.minX <= o + 0.5 && clip.maxX >= card.bounds.width - o - 0.5,
                    "\(id) cut: clip \(clip) in a card \(card.bounds.width) wide")
        }
        let shown = panes[1...].compactMap { cardRect(window, $0) }.sorted { $0.minX < $1.minX }
        for (a, b) in zip(shown, shown.dropFirst()) {
            let gap = PaneElevation.paneGap(for: controller.ghostty.config.macosPaneStyle) ?? PaneLayout.Metrics.flatGap
            #expect(abs(b.minX - a.maxX - gap) <= 1.5, "a gutter of \(b.minX - a.maxX)")
        }
    }

    /// The whole of it, as a person does it: enough panes that some are
    /// strips on either side; the gutter in the middle of the run dragged all
    /// the way left (panes on the left tuck away, the ones on the right grow),
    /// all the way right (the reverse), and back to where it began, let go.
    /// Every sampled frame: no two cards overlap, every gutter between
    /// neighbours is the row's gutter, every card on show is inside the row
    /// and at least a pane's minimum, no strip has come out (a drag only
    /// collapses, or pulls one strip out by its own gutter), one bar. And let
    /// go where it began, the row is as it was.
    @Test func aGutterDraggedAcrossTheWholeRowAndBackIsCoherentThroughout() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 7, width: 4 * Self.m.width + 300)
        defer { controller.close() }
        window.makeFirstResponder(panes[3].surfaceView)
        await settle(0.8)
        // Strips on both sides: the innermost strip on the left clicked, its
        // pane coming on show and the far one going to a strip on the right.
        if let innermost = all(PaneStackTabView.self, in: window.contentView!).filter({ $0.isStrip })
            .max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) {
            let point = innermost.convert(NSPoint(x: innermost.bounds.midX, y: innermost.bounds.midY), to: nil)
            let hit = try #require(window.contentView!.superview!.hitTest(point))
            hit.mouseDown(with: try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            hit.mouseUp(with: try #require(NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
            await settle(1.0)
        }
        let gap = PaneElevation.paneGap(for: controller.ghostty.config.macosPaneStyle) ?? PaneLayout.Metrics.flatGap
        let minimum = PaneLayout.Metrics.minimumPaneSize.width
        func state() -> [String] {
            panes.map { p in strips(window).contains(p.id) ? "strip" : "\(Int((cardRect(window, p)?.width ?? -1).rounded()))" }
        }
        let before = state()
        let left = strips(window).filter { id in (cardRect(window, panes.first { $0.id == id }!)?.minX ?? 0) < window.frame.width / 2 }
        #expect(!left.isEmpty && left.count < strips(window).count, "strips on both sides: \(before)")

        let startStrips = Set(strips(window).compactMap { $0 })
        // The gutter in the middle of the run.
        let grips = gripsBetweenCards(window)
        let grip = try #require(grips[grips.count / 2])
        let gutter = grip.convert(grip.bounds, to: nil)
        let row = (lo: window.contentView!.bounds.minX, hi: window.contentView!.bounds.maxX)

        var problems: [String] = []
        var layoutProblems: [String] = []
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                var shown: [(CGRect, UUID)] = []
                for card in self.all(PaneCardView.self, in: window.contentView!) where !card.isContentHidden {
                    let r = card.drawnPaneInWindow
                    guard r.width > 1, let id = card.paneID else { continue }
                    shown.append((r, id))
                }
                shown.sort { $0.0.minX < $1.0.minX }
                let target = controller.paneStackState.layoutGrid?()
                for (a, b) in zip(shown, shown.dropFirst()) {
                    // Two strips lie side by side as blades: on the way there,
                    // anything from touching to a gutter apart. Anything else,
                    // a gutter apart.
                    let blades = target?.leaves[a.1]?.isTucked == true && target?.leaves[b.1]?.isTucked == true
                    let space = b.0.minX - a.0.maxX
                    if a.0.maxX > b.0.minX + 0.5 { problems.append("overlap \(Int(a.0.maxX)) > \(Int(b.0.minX))") }
                    else if blades ? space > gap + 1.5 : abs(space - gap) > 1.5 {
                        let ia = panes.firstIndex { $0.id == a.1 } ?? -1, ib = panes.firstIndex { $0.id == b.1 } ?? -1
                        let la = controller.paneStackState.layoutGrid?().leaves[a.1], lb = controller.paneStackState.layoutGrid?().leaves[b.1]
                        let ca = self.all(PaneCardView.self, in: window.contentView!).first { $0.paneID == a.1 }
                        let cb = self.all(PaneCardView.self, in: window.contentView!).first { $0.paneID == b.1 }
                        problems.append("placed \(String(describing: ca?.placedFrame)) clip \(String(describing: ca?.clipLayer?.frame)) | placed \(String(describing: cb?.placedFrame)) clip \(String(describing: cb?.clipLayer?.frame))")
                        problems.append("gutter \(Int(b.0.minX - a.0.maxX)) between \(ia) \(Int(a.0.minX))...\(Int(a.0.maxX)) [to \(Int(la?.frame.minX ?? -1))...\(Int(la?.frame.maxX ?? -1)) t=\(la?.isTucked == true)] and \(ib) \(Int(b.0.minX))...\(Int(b.0.maxX)) [to \(Int(lb?.frame.minX ?? -1))...\(Int(lb?.frame.maxX ?? -1)) t=\(lb?.isTucked == true)]")
                    }
                }
                for (r, _) in shown {
                    if r.minX < row.lo - 0.5 || r.maxX > row.hi + 0.5 { problems.append("outside \(Int(r.minX))...\(Int(r.maxX))") }
                }
                // The layout itself, as the drag has left it: items end to
                // end, a gutter between each.
                if let layout = controller.paneStackState.layoutGrid?() {
                    for id in startStrips where layout.leaves[id]?.isTucked == false {
                        layoutProblems.append("strip \(panes.firstIndex { $0.id == id } ?? -1) came out")
                    }
                    let items = panes.compactMap { p -> (rect: CGRect, tucked: Bool)? in
                        guard let leaf = layout.leaves[p.id] else { return nil }
                        return (leaf.isTucked ? (leaf.tab ?? leaf.frame) : leaf.frame, leaf.isTucked)
                    }.sorted { $0.rect.minX < $1.rect.minX }
                    // A gutter between each, but none between two strips — and
                    // a strip away from the run reaches `bladeTuck` under the
                    // next one in.
                    for (a, b) in zip(items, items.dropFirst()) {
                        let space = b.rect.minX - a.rect.maxX
                        let wants = a.tucked && b.tucked
                            ? [PaneLayout.Metrics.bladeGap, PaneLayout.Metrics.bladeGap - PaneLayout.Metrics.bladeTuck]
                            : [gap]
                        if !wants.contains(where: { abs(space - $0) <= 1.5 }) {
                            layoutProblems.append("layout gutter \(Int(b.rect.minX - a.rect.maxX)) at \(Int(a.rect.maxX))")
                        }
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let start = NSPoint(x: gutter.midX, y: gutter.midY)
        let toLeft = row.lo + 20 - start.x, toRight = row.hi - 20 - start.x
        var path = Array(stride(from: CGFloat(-10), through: toLeft, by: -10))
        path += Array(stride(from: toLeft, through: toRight, by: 10))
        path += Array(stride(from: toRight, through: 0, by: -10)) + Array(repeating: 0, count: 10)
        let frames = try await recordedDrag(window, from: start, through: path)
        await settle(0.8)
        timer.invalidate()
        try expectOneBar(frames, window, y: start.y) { _, _ in true }
        #expect(layoutProblems.isEmpty, "\(layoutProblems.count) incoherent layouts: \(Array(Set(layoutProblems)).prefix(8))")
        #expect(problems.isEmpty, "\(problems.count) incoherent samples: \(Array(Set(problems)).prefix(8))")
        #expect(state() == before, "let go where it began, as it was: \(before) -> \(state())")
        for card in all(PaneCardView.self, in: window.contentView!) where !card.isContentHidden {
            #expect(!card.isGliding)
            if let r = cardRect(window, panes.first { $0.id == card.paneID }!) {
                #expect(r.width >= minimum - 1, "a card under the minimum: \(r.width)")
            }
        }
    }

    /// Dragging the divider between the left column and the right one, whose
    /// row is already collapsed: the right column narrows as its row stacks
    /// further, as a column whose row can stack does. It used to collapse
    /// the whole right column at the first pixel, its minimum taken as the
    /// row's four panes side by side.
    @Test func aDividerBesideAColumnWithACollapsedRowResizesIt() async throws {
        let (controller, window, panes) = try await nestedCollapsedRow()
        defer { controller.close() }
        // Collapse the bottom row by dragging its first divider far left:
        // the one at c's trailing edge.
        let c = try #require(cardRect(window, panes[3]))
        let first = try #require(handles(window).min {
            abs($0.convert($0.bounds, to: nil).minX - c.maxX) + abs($0.convert($0.bounds, to: nil).midY - c.midY)
                < abs($1.convert($1.bounds, to: nil).minX - c.maxX) + abs($1.convert($1.bounds, to: nil).midY - c.midY)
        })
        first.onDragBegan?()
        for step in 1...20 { first.onDragDelta?(CGFloat(step) * -30, first.currentSplit?() ?? 0.5); await settle(0.01) }
        first.onDragEnded?()
        await settle(0.8)
        let row = Set(panes[3...].map(\.id))
        #expect(controller.paneStackState.pin(for: row) != nil, "the bottom row is collapsed")

        // The main divider: the tall one between the columns.
        let main = try #require(handles(window).first { $0.convert($0.bounds, to: nil).height > window.frame.height * 0.6 })
        let viewerBefore = try #require(cardRect(window, panes[2]))
        let mainBefore = main.convert(main.bounds, to: nil)
        let split = main.currentSplit?() ?? 0.5
        main.onDragBegan?()
        for step in 1...6 { main.onDragDelta?(CGFloat(step) * 10, split); await settle(0.01) }
        main.onDragEnded?()
        await settle(0.8)
        let top = Set([panes[0], panes[1]].map(\.id) + panes[2...].map(\.id))
        #expect(controller.paneStackState.pins.keys.allSatisfy { !$0.isSuperset(of: top) }, "the columns did not collapse")
        try await capture(window, "nested-main-dragged")
        let viewerAfter = try #require(cardRect(window, panes[2]))
        #expect(abs((viewerBefore.width - viewerAfter.width) - 60) < 4,
                "the right column narrowed by the drag: \(viewerBefore) -> \(viewerAfter); main \(mainBefore) -> \(main.convert(main.bounds, to: nil)); a \(String(describing: cardRect(window, panes[0])))")
    }

    /// A strip's pane pulled out by hand: it follows the hand — every card
    /// where the layout puts it, every step, nothing sliding, fading or held
    /// at another size on its own clock. It used to run the click's slide
    /// against the drag: the pane beside it jumped, the one coming out lagged
    /// with its content held at its old size, its sheet faded in and its
    /// strip out on their own schedules, all visibly out of step.
    /// Two strips on the right: the inner one's gutter pulled far to the
    /// left brings out that pane alone, however far it goes — the strip
    /// beyond it stays a strip, and the panes on show give way instead.
    @Test(arguments: [(3, false), (3, true), (4, false), (5, false)])
    func aStripPulledFarBringsOutItsPaneAlone(count: Int, throughHandle: Bool) async throws {
        let (controller, window, panes) = try await stackedWindow(count: count, width: 1700)
        defer { controller.close() }
        drag(try #require(handles(window).last), by: 900)
        await settle(0.8)
        let hs = handles(window)
        drag(hs[hs.count - 2], by: 900)
        await settle(0.8)
        let n = panes.count
        try #require(strips(window) == [panes[n - 2].id, panes[n - 1].id], "two strips on the right: \(strips(window))")
        let grip = try #require(handles(window).last)
        let gutter = grip.convert(grip.bounds, to: nil)
        var seen: [[UUID?]] = []
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated { seen.append(self.strips(window)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        if throughHandle {
            drag(grip, by: -1100)
        } else {
            let path = Array(stride(from: CGFloat(-20), through: -1100, by: -20)) + Array(repeating: -1100, count: 10)
            _ = try await recordedDrag(window, from: NSPoint(x: gutter.midX, y: gutter.midY), through: path)
        }
        await settle(0.6)
        timer.invalidate()
        let bad = seen.filter { $0.contains(panes[n - 1].id) == false }
        #expect(bad.isEmpty, "the strip beyond came out: \(bad.first.map { $0.map { u in panes.firstIndex { $0.id == u } ?? -1 } } ?? [])")
        #expect(strips(window).contains(panes[n - 1].id), "settled with the far pane a strip: \(strips(window))")
    }

    @Test func aStripPulledOutFollowsTheHandWithNothingSliding() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        drag(try #require(handles(window).first), by: 800)
        await settle(0.8)
        #expect(controller.paneStackState.pin(for: key) != nil, "the right pane is a strip")
        let grip = try #require(handles(window).last)
        let gutter = grip.convert(grip.bounds, to: nil)

        // Sampled while the hand drags, out past the minimum and on: nothing
        // on a clock of its own, the gutter between the two panes its width
        // in every sample, and the pane coming out seen on its way in.
        var offClock: [String] = []
        var gutters: [CGFloat] = []
        var widths: [CGFloat] = []
        var misplaced: [String] = []
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                for card in self.all(PaneCardView.self, in: window.contentView!) {
                    if card.isAnimating { offClock.append("animating") }
                    if card.isFrozen, !self.strips(window).contains(card.paneID) { offClock.append("frozen") }
                }
                guard self.strips(window).isEmpty,
                      let a = self.cardRect(window, panes[0]), let b = self.cardRect(window, panes[1]) else { return }
                gutters.append(b.minX - a.maxX)
                widths.append(b.width)
                // The bar over the gutter as it is drawn, not ahead of it.
                if let bar = grip.barInWindow, bar.midX < a.maxX - 1 || bar.midX > b.minX + 1 {
                    misplaced.append("bar \(Int(bar.midX)) gutter \(Int(a.maxX))...\(Int(b.minX))")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let path = Array(stride(from: CGFloat(-10), through: -560, by: -10)) + Array(repeating: -560, count: 20)
        let frames = try await recordedDrag(window, from: NSPoint(x: gutter.midX, y: gutter.midY), through: path)
        timer.invalidate()
        let dir = "/tmp/pane-stack-snapshots/pull-frames"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (n, f) in frames.enumerated() {
            try? NSBitmapImageRep(cgImage: f.image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: String(format: "%@/f%03d-%d.png", dir, n, Int(f.pointer.upperBound))))
        }
        #expect(controller.paneStackState.pin(for: key) == nil, "pulled out")
        #expect(offClock.isEmpty, "\(offClock.count) samples off the hand's clock: \(Set(offClock))")
        let gap = PaneElevation.paneGap(for: controller.ghostty.config.macosPaneStyle) ?? PaneLayout.Metrics.flatGap
        #expect(!gutters.isEmpty && gutters.allSatisfy { abs($0 - gap) <= 1.5 },
                "the gutter held \(gap)pt: \(gutters.map { Int($0) })")
        // On its way in: drawn narrower than where it landed.
        await settle(0.3)
        let landed = try #require(cardRect(window, panes[1])).width
        let onItsWay = widths.filter { $0 < landed - 20 }.count
        #expect(onItsWay > 2, "the pane glided in, not appeared (\(onItsWay) samples on its way)")
        #expect(misplaced.isEmpty, "\(misplaced.count) samples with the bar off the gutter: \(misplaced.prefix(5))")
    }

    /// A strip's pane pulled out FAST: the glide keeps chasing the hand —
    /// every frame of it the pane at the size the card is drawn (its content
    /// held at where the layout now puts it, not where it was when the glide
    /// began), and its edge never jumping as the glide ends. It used to hold
    /// the content at the first target, so a fast pull stopped short and
    /// snapped to the pointer at the end.
    @Test func aFastPullKeepsTheGlideOnTheHand() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        drag(try #require(handles(window).first), by: -800)
        await settle(0.8)
        #expect(strips(window) == [panes[0].id], "the left pane is a strip")
        let grip = try #require(handles(window).first)
        let gutter = grip.convert(grip.bounds, to: nil)

        var edges: [(t: CFTimeInterval, x: CGFloat)] = []
        var stale: [String] = []
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard self.strips(window).isEmpty, let a = self.cardRect(window, panes[0]) else { return }
                edges.append((CACurrentMediaTime(), a.maxX))
                // The content fills the card it is drawn in (or more, cut).
                let content = panes[0].contentView.frame.width
                if content + 2 < a.width { stale.append("content \(Int(content)) card \(Int(a.width))") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // 600pt in about 160ms, then held.
        let path = Array(stride(from: CGFloat(30), through: 600, by: 30)) + Array(repeating: 600, count: 40)
        _ = try await recordedDrag(window, from: NSPoint(x: gutter.midX, y: gutter.midY), through: path)
        timer.invalidate()
        // A jump measured against the time it took: a starved timer (a busy
        // machine) samples further apart, and a smooth glide covers more
        // ground between them. 120pt per 8ms sample at most.
        let jumps = zip(edges.dropFirst(), edges).map { abs($0.x - $1.x) / Swift.max(1, ($0.t - $1.t) / 0.008) }
        #expect(stale.isEmpty, "\(stale.count) samples with the content short of its card: \(stale.prefix(4))")
        #expect((jumps.max() ?? 0) < 120, "the edge jumped \(Int(jumps.max() ?? 0))pt in one sample: \(edges.map { Int($0.x) })")
    }

    /// The same fast pull, let go of at once: the pane goes on gliding to
    /// where it was headed and settles there — no jump on release. It used
    /// to be placed there at once the moment the mouse came up.
    @Test func aFastPullLetGoOfSettlesWithoutASnap() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        drag(try #require(handles(window).first), by: -800)
        await settle(0.8)
        #expect(strips(window) == [panes[0].id], "the left pane is a strip")
        let grip = try #require(handles(window).first)
        let gutter = grip.convert(grip.bounds, to: nil)

        var edges: [(x: CGFloat, t: CFTimeInterval)] = []
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard self.strips(window).isEmpty, let a = self.cardRect(window, panes[0]) else { return }
                edges.append((a.maxX, CACurrentMediaTime()))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let path = Array(stride(from: CGFloat(40), through: 600, by: 40))
        _ = try await recordedDrag(window, from: NSPoint(x: gutter.midX, y: gutter.midY), through: path)
        await settle(0.5)
        timer.invalidate()
        // Per 8ms of the time it took, as in `aFastPullKeepsTheGlideOnTheHand`.
        let jumps = zip(edges.dropFirst(), edges).map { abs($0.x - $1.x) / Swift.max(1, ($0.t - $1.t) / 0.008) }
        #expect((jumps.max() ?? 0) < 120, "the edge jumped \(Int(jumps.max() ?? 0))pt in one sample: \(edges.map { Int($0.x) })")
        let final = try #require(cardRect(window, panes[0])).maxX
        #expect(abs(final - (gutter.midX + 600)) < 12, "settled at the pointer: \(final) vs \(gutter.midX + 600)")
        #expect(all(PaneCardView.self, in: window.contentView!).allSatisfy { !$0.isFrozen }, "and nothing held")
    }

    /// Four panes; the last divider dragged right until the last pane tucks
    /// away: the bar stays with the gutter that snapped to the edge, not
    /// the one beside it that the pointer had come closer to.
    @Test func theBarStaysWithTheGutterThatSnappedToTheEdge() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 4, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        #expect(controller.paneStackState.pin(for: key) == nil && strips(window).isEmpty, "side by side")
        let divider = try #require(handles(window).last)
        let gutter = divider.convert(divider.bounds, to: nil)
        let start = NSPoint(x: gutter.midX, y: gutter.midY)
        let path = Array(stride(from: CGFloat(10), through: 200, by: 10)) + Array(repeating: 200, count: 25)
        let frames = try await recordedDrag(window, from: start, through: path)
        #expect(strips(window) == [panes[3].id], "the last pane tucked away")
        let edge = try #require(handles(window).max { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX })
        let edgeX = edge.convert(edge.bounds, to: nil).midX
        try expectOneBar(frames, window, y: start.y) { pointer, bar in
            pointer.lowerBound >= 200 ? abs(bar - edgeX) < 8 : true
        }
    }

    /// Pulling the grip at the run's edge when more than one pane is tucked
    /// that way: the nearest comes out at the width pulled, the row still
    /// stacked, the other strip where it was.
    @Test func aStripPulledOutOfAStackComesOutAtTheWidthPulled() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 3, width: 1300)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        // Tuck the first two away to the left: the last divider, dragged on
        // through the row.
        let divider = try #require(handles(window).last)
        divider.onDragBegan?()
        let start = divider.currentSplit?() ?? 0.5
        for step in 1...40 {
            divider.onDragDelta?(CGFloat(step) * -30, start)
            await settle(0.01)
        }
        divider.onDragEnded?()
        await settle(0.8)
        #expect(controller.paneStackState.pin(for: key) == .init(start: 2, count: 1), "two strips")

        // The grip where the run meets them, pulled 400pt into the run.
        let grip = try #require(handles(window).first)
        let pointer = grip.convert(grip.bounds, to: nil).midX + 400
        drag(grip, by: 400)
        await settle(0.8)
        #expect(controller.paneStackState.pin(for: key) == .init(start: 1, count: 2), "one out, one still a strip")
        // Its edge where the pointer let go: the grip between it and the
        // card beside it is there.
        let between = try #require(handles(window).first { $0.convert($0.bounds, to: nil).midX > pointer - 100 })
        let at = between.convert(between.bounds, to: nil).midX
        #expect(abs(at - pointer) <= 12, "the grip at \(at), the pointer at \(pointer); cards \(cardRects(window))")
    }

    /// What can be dragged says so: a bar down the middle of a divider's
    /// gutter while the pointer is over it, and under the pointer while it
    /// drags.
    @Test func aDividerShowsABarOnHoverThatFollowsTheDrag() async throws {
        let (controller, window, _) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        let handle = try #require(handles(window).first)
        #expect(!handle.showsBar)
        handle.mouseEntered(with: try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        let hovered = try #require(handle.barInWindow)
        let gutter = handle.convert(handle.bounds, to: nil)
        #expect(hovered.width == DividerHandle.DividerHandleView.barThickness)
        #expect(abs(hovered.midX - gutter.midX) < 0.5, "down the middle")

        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // Driven step by step: the handle's own event loop would wait on
        // the window for them.
        handle.tracksModally = false
        handle.mouseDown(with: try event(.leftMouseDown, start.x))
        handle.mouseDragged(with: try event(.leftMouseDragged, start.x + 80))
        await settle(0.3)
        handle.mouseDragged(with: try event(.leftMouseDragged, start.x + 80))
        // In the gutter, which the divider moved with the pointer.
        let bar = try #require(handle.barInWindow)
        #expect(abs(bar.midX - (start.x + 80)) < 2, "in the gutter: \(bar.midX) vs \(start.x + 80)")
        // The pointer has left the gutter; the bar goes with it all the same.
        handle.mouseExited(with: try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        #expect(handle.showsBar, "still dragging")
        GutterBar.pointerOverride = CGPoint(x: start.x + 300, y: start.y)
        defer { GutterBar.pointerOverride = nil }
        handle.mouseUp(with: try event(.leftMouseUp, start.x + 300))
        #expect(!handle.showsBar, "the pointer is elsewhere once the drag ends")

        // Let go where the gutter WAS, before the layout has moved it: at
        // that moment the pointer is over it, and then the gutter moves out
        // from under a pointer that does not — AppKit sends no mouse-exited
        // for that. It stayed lit, looking mid-drag, until the pointer
        // crossed it again.
        await settle(0.4)
        let here = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        GutterBar.pointerOverride = here
        handle.mouseEntered(with: try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        handle.tracksModally = false
        handle.mouseDown(with: try event(.leftMouseDown, here.x))
        handle.mouseDragged(with: try event(.leftMouseDragged, here.x - 120))
        handle.mouseUp(with: try event(.leftMouseUp, here.x))
        await settle(0.4)
        #expect(abs(handle.convert(handle.bounds, to: nil).midX - (here.x - 120)) < 2, "the divider moved")
        #expect(!handle.showsBar, "the bar stayed lit after the gutter moved out from under the pointer")
    }

    /// Let go ON the gutter, then move away: the bar goes out. The drag's end
    /// finds the pointer on the gutter as AppKit sends that gutter a late
    /// mouse-exited, and the hover found from geometry turned the bar back on
    /// after it — with AppKit taking the pointer to be outside, so it never
    /// sent the exit that would put the bar out. It stayed lit until the
    /// pointer crossed the gutter again. AppKit's tracking cannot be driven
    /// by synthetic events, so this replays what it sent (recorded from a
    /// real drag) and checks the area is re-armed to send that exit.
    @Test func aGutterLetGoUnderThePointerGoesOutWhenThePointerLeaves() async throws {
        let (controller, window, _) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        let handle = try #require(handles(window).first)
        func enterExit(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        handle.mouseEntered(with: try enterExit(.mouseEntered))
        handle.tracksModally = false
        handle.mouseDown(with: try event(.leftMouseDown, start.x))
        handle.mouseDragged(with: try event(.leftMouseDragged, start.x + 80))
        await settle(0.3)
        handle.mouseDragged(with: try event(.leftMouseDragged, start.x + 80))
        await settle(0.3)
        // The gutter followed the pointer, which lets go on it.
        let here = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        #expect(abs(here.x - (start.x + 80)) < 2, "the divider moved with the drag")
        GutterBar.pointerOverride = here
        defer { GutterBar.pointerOverride = nil }
        handle.mouseUp(with: try event(.leftMouseUp, here.x))
        handle.mouseExited(with: try enterExit(.mouseExited))
        await settle(0.2)
        #expect(handle.showsBar, "the pointer is on the gutter")
        #expect(handle.trackingAssumesInside, "AppKit takes the pointer to be outside and would never send the exit")
        #expect(handle.trackingAreas.count == 1, "re-arming replaces the area")

        // The exit that area sends when the pointer leaves puts the bar out.
        GutterBar.pointerOverride = CGPoint(x: here.x + 300, y: here.y)
        handle.mouseExited(with: try enterExit(.mouseExited))
        #expect(!handle.showsBar, "the bar stayed lit after the pointer left")
    }

    // MARK: - Resizers live in the gutters

    /// Where every card shows, in window coordinates: a card on show is its
    /// pane; a strip is its tab.
    /// Where `pane`'s card is, in window coordinates: its strip when it is
    /// one.
    private func cardRect(_ window: NSWindow, _ pane: PaneView) -> CGRect? {
        guard let card = all(PaneCardView.self, in: window.contentView!).first(where: { $0.paneID == pane.id })
        else { return nil }
        if let tab = all(PaneStackTabView.self, in: card).first(where: { $0.isStrip }) {
            return tab.convert(tab.bounds, to: nil)
        }
        let o = PaneCardView.outset
        return card.convert(card.bounds.insetBy(dx: o, dy: o), to: nil)
    }

    private func cardRects(_ window: NSWindow) -> [CGRect] {
        all(PaneCardView.self, in: window.contentView!).compactMap { card -> CGRect? in
            if let tab = all(PaneStackTabView.self, in: card).first(where: { $0.isStrip }) {
                return tab.convert(tab.bounds, to: nil)
            }
            guard !card.isContentHidden else { return nil }
            let o = PaneCardView.outset
            return card.convert(card.bounds.insetBy(dx: o, dy: o), to: nil)
        }
    }

    /// Every resize target in the window: split dividers, stack grips (between
    /// cards and at a run's edge) and the pane sidebar's edge.
    private func resizerRects(_ window: NSWindow) -> [(String, CGRect)] {
        let grips = all(DividerHandle.DividerHandleView.self, in: window.contentView!)
            .map { ("grip", $0.convert($0.bounds, to: nil)) }
        let sidebar = all(SidePanelResizeHandle.self, in: window.contentView!)
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map { ("sidebar edge", $0.convert($0.bounds, to: nil)) }
        return grips + sidebar
    }

    /// No resizer overlaps any card, and a click just inside any card's edge
    /// is the card's, not a resize: the resizers live in the gutters alone,
    /// so dragging a pane (its grab handle, a strip) and resizing each have
    /// their own target.
    private func expectResizersInGutters(_ window: NSWindow, _ name: String) throws {
        let cards = cardRects(window), resizers = resizerRects(window)
        #expect(!resizers.isEmpty, "\(name): no resizers found")
        // The sidebar's card, open over the grid, covers what is under it: a
        // grip on that card is on the sidebar, not on the pane beneath.
        let sidebar = all(PaneSidebarHostView.self, in: window.contentView!).first
            .map { $0.convert($0.cardRect, to: nil) }
        for (kind, r) in resizers {
            if let sidebar, sidebar.contains(r) { continue }
            for c in cards {
                let overlap = r.intersection(c)
                #expect(overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01,
                        "\(name): a \(kind) \(r) overlaps a card \(c) by \(overlap)")
            }
        }
        let root = try #require(window.contentView?.superview)
        for c in cards {
            for p in [CGPoint(x: c.minX + 1, y: c.midY), CGPoint(x: c.maxX - 1, y: c.midY),
                      CGPoint(x: c.midX, y: c.minY + 1), CGPoint(x: c.midX, y: c.maxY - 1)] {
                let hit = root.hitTest(p)
                #expect(!(hit is DividerHandle.DividerHandleView) && !(hit is SidePanelResizeHandle),
                        "\(name): a click at \(p), just inside a card's edge, starts a resize")
            }
        }
    }

    @Test func everyResizerSitsInAGutter() async throws {
        // Side by side, with a column (a horizontal divider runs along the
        // top of the lower pane, where its grab handle is).
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let panes = (0..<3).map { _ in PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)) }
        var tree = SplitTree<PaneView>(view: panes[0])
        tree = try tree.inserting(view: panes[1], at: panes[0], direction: .right)
        tree = try tree.inserting(view: panes[2], at: panes[1], direction: .down)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1300, height: 900))
        await settle(1.0)
        try expectResizersInGutters(window, "side by side")

        // The sidebar expanded beside them.
        controller.paneSidebarState.isHidden = false
        controller.setPaneSidebarExpanded(true)
        await settle(1.0)
        try expectResizersInGutters(window, "expanded sidebar")
        controller.setPaneSidebarExpanded(false)
        await settle(1.0)
        try expectResizersInGutters(window, "sidebar rail")
    }

    /// The pinned sidebar is resized from the gutter between it and the
    /// panes — all of that gutter, and not from inside the sidebar, whose
    /// edge is a click on the list. It used to straddle the edge: half
    /// inside the sidebar, and only part of the gutter.
    @Test func theExpandedSidebarResizesFromTheGutterBesideIt() async throws {
        let (controller, window, _) = try await stackedWindow(count: 2, width: 1300)
        defer { controller.close() }
        try #require(controller.ghostty.config.macosPaneStyle == .elevated)
        controller.paneSidebarState.isHidden = false
        controller.setPaneSidebarExpanded(true)
        await settle(1.0)
        let host = try #require(all(PaneSidebarHostView.self, in: window.contentView!).first)
        let edge = host.convert(host.cardRect, to: nil).maxX
        let firstCard = try #require(cardRects(window).map(\.minX).min())
        let handle = try #require(all(SidePanelResizeHandle.self, in: window.contentView!)
            .first { !$0.isHiddenOrHasHiddenAncestor })
        let grab = handle.convert(handle.bounds, to: nil)
        #expect(abs(grab.minX - edge) <= 0.5 && abs(grab.maxX - firstCard) <= 0.5,
                "the handle \(grab.minX)...\(grab.maxX), the gutter \(edge)...\(firstCard)")
        let root = try #require(window.contentView?.superview)
        let y = grab.midY
        #expect(root.hitTest(CGPoint(x: (edge + firstCard) / 2, y: y)) === handle, "the gutter's middle")
        #expect(!(root.hitTest(CGPoint(x: edge - 2, y: y)) is SidePanelResizeHandle), "just inside the sidebar")
        // And it says so, as a divider does: a bar down the gutter's middle.
        handle.mouseEntered(with: try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        let bar = try #require(handle.barInWindow)
        #expect(abs(bar.midX - (edge + firstCard) / 2) < 0.5 && bar.width == GutterBar.thickness)

        // Dragged far past the panel's widest, the bar stops in the gutter
        // where the panel stopped, lit — not out at the pointer.
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let from = (edge + firstCard) / 2
        handle.mouseDown(with: try event(.leftMouseDown, from))
        handle.mouseDragged(with: try event(.leftMouseDragged, from + 900))
        await settle(0.4)
        handle.mouseDragged(with: try event(.leftMouseDragged, from + 900))
        let widest = host.convert(host.cardRect, to: nil).maxX
        let held = try #require(handle.barInWindow)
        #expect(controller.paneSidebarState.width < 900, "the panel stopped at its widest")
        #expect(abs(held.midX - (widest + (firstCard - edge) / 2)) < 2,
                "the bar at \(held.midX), the panel's edge at \(widest)")
        GutterBar.pointerOverride = CGPoint(x: from + 900, y: y)
        defer { GutterBar.pointerOverride = nil }
        handle.mouseUp(with: try event(.leftMouseUp, from + 900))
        // Let go out there, away from the gutter: it is not left lit.
        await settle(0.3)
        #expect(!handle.showsBar, "the bar stayed lit after the drag")
    }

    @Test func everyResizerOfAStackSitsInAGutter() async throws {
        // A collapsed row: grips between the cards on show and at the run's
        // edges, beside the strips.
        let (controller, window, _) = try await collapsedRow(.right)
        defer { controller.close() }
        window.setContentSize(NSSize(width: 1800, height: 600))
        await settle(1.0)
        #expect(handles(window).count == 3, "between c and d, and at both edges of the run")
        try expectResizersInGutters(window, "collapsed row")

        // A row stacked for want of room.
        let (narrow, narrowWindow, _) = try await stackedWindow(count: 4, width: 1100)
        defer { narrow.close() }
        try expectResizersInGutters(narrowWindow, "stacked row")
    }

    // MARK: - Dragging a strip

    /// A view's frame in screen coordinates.
    private func onScreen(_ view: NSView) -> CGRect {
        view.window!.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func tab(_ window: NSWindow, _ pane: PaneView) throws -> PaneStackTabView {
        try #require(all(PaneStackTabView.self, in: window.contentView!).first { $0.pane === pane && $0.isStrip })
    }

    /// `a b [c d] e f`: b's strip dragged into the gutter between c and d
    /// comes on show there, between them, and takes focus; the row stays
    /// collapsed. Over the middle of a card there is no target at all — a
    /// strip has no swap or split there — and the caret shows only over a
    /// slot.
    @Test func aStripDroppedBetweenTwoCardsComesOnShowThere() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        let session = PaneDragSession.shared
        session.begin(pane: panes[1], from: controller, isBlade: true)
        defer { session.end(commit: false) }

        let c = onScreen(panes[2].contentView), d = onScreen(panes[3].contentView)
        session.update(screenPoint: CGPoint(x: c.midX, y: c.midY))
        #expect(session.target == nil, "a strip over a card has no target")

        session.update(screenPoint: CGPoint(x: (c.maxX + d.minX) / 2, y: c.midY))
        guard case .reorder(_, let beside, let side, _) = session.target else {
            Issue.record("expected a slot, got \(String(describing: session.target))")
            return
        }
        #expect(beside == [panes[2].id] && side == .right)
        await settle(0.3)
        try await capture(window, "blade-slot")
        session.end(commit: true)
        await settle(1.0)
        try await capture(window, "blade-dropped-between-cards")

        #expect(controller.surfaceTree.root?.leaves().map(\.id) == [0, 2, 1, 3, 4, 5].map { panes[$0].id })
        #expect(strips(window) == [panes[0], panes[4], panes[5]].map(\.id))
        #expect(panes[1].isFocusedPane)
        #expect(panes[1].surfaceView?.surface != nil, "the pane lives on")
    }

    /// Dropped between two strips, a strip stays one there, and the panes on
    /// show stay as they were.
    @Test func aStripDroppedBetweenTwoStripsStaysAStrip() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        let session = PaneDragSession.shared
        session.begin(pane: panes[1], from: controller, isBlade: true)
        let e = onScreen(try tab(window, panes[4])), f = onScreen(try tab(window, panes[5]))
        session.update(screenPoint: CGPoint(x: (e.maxX + f.minX) / 2, y: e.midY))
        guard case .reorder(_, let beside, let side, _) = session.target else {
            session.end(commit: false)
            Issue.record("expected a slot, got \(String(describing: session.target))")
            return
        }
        #expect(beside == [panes[4].id] && side == .right)
        session.end(commit: true)
        await settle(1.0)
        #expect(controller.surfaceTree.root?.leaves().map(\.id) == [0, 2, 3, 4, 1, 5].map { panes[$0].id })
        #expect(strips(window) == [panes[0], panes[4], panes[1], panes[5]].map(\.id))
        #expect(panes[3].isFocusedPane, "the caret stays where it was")
    }

    /// A strip brought back on show is a pane like any other to a pane drag:
    /// dropped on the middle of it, the drag swaps with it. (Its strip, hidden
    /// once it came out, was still taken for where the pane is, so the drop
    /// missed it.)
    @Test func aPaneThatWasAStripIsADropTargetOnceOnShow() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        window.makeFirstResponder(panes[1].surfaceView)
        await settle(1.0)
        #expect(!strips(window).contains(panes[1].id))
        let session = PaneDragSession.shared
        session.begin(pane: panes[3], from: controller)
        defer { session.end(commit: false) }
        let b = onScreen(panes[1].contentView)
        session.update(screenPoint: CGPoint(x: b.midX, y: b.midY))
        #expect(session.target == .swap(window: controller.rearrangeWindowRef, pane: panes[1].id))
    }

    /// At a screen's edge a strip tiles: a preview of that half of the
    /// screen, then a window of its own covering it — and its session is
    /// not ended by the move.
    @Test func aStripAtTheScreensEdgeTilesIntoAWindowOfItsOwn() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        let screen = try #require(window.screen?.visibleFrame)
        let session = PaneDragSession.shared
        session.begin(pane: panes[1], from: controller, isBlade: true)
        session.update(screenPoint: CGPoint(x: screen.maxX - 4, y: screen.midY))
        let half = CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
        #expect(session.target == .tile(frame: half))
        #expect(TileDropPreview.shared.shownFrame == half.insetBy(dx: 6, dy: 6), "the half is previewed")
        session.end(commit: true)
        #expect(TileDropPreview.shared.shownFrame == nil, "and the preview goes with the drag")
        await settle(1.2)

        let tiled = try #require(TerminalController.all.first { $0.surfaceTree.root?.leaves().map(\.id) == [panes[1].id] })
        defer { tiled.close() }
        let frame = try #require(tiled.window?.frame)
        #expect(abs(frame.minX - half.minX) < 2 && abs(frame.width - half.width) < 2, "\(frame) vs \(half)")
        #expect(!controller.surfaceTree.contains { $0 === panes[1] })
        #expect(panes[1].surfaceView?.surface != nil, "the pane lives on in its new window")
        #expect(strips(window) == [panes[0], panes[4], panes[5]].map(\.id), "the row it left stays collapsed")
    }

    /// The user's repro: seven panes in a row with room for four, stacked for
    /// want of room. Clicking the far card ON SHOW must change nothing — it
    /// used to re-centre the run on it from the focus history, sliding three
    /// cards out and three strips in.
    @Test func clickingACardOnShowNeverMovesTheRow() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 7, width: 4 * Self.m.width + 300)
        defer { controller.close() }
        // The run shows the last four (the last pane has focus); bring the
        // first one forward with a click on its strip: 0...3 on show.
        let first = try tab(window, panes[0])
        let point = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        let root = try #require(window.contentView?.superview)
        func click(_ at: NSPoint) throws {
            let hit = try #require(root.hitTest(at))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? hit.mouseDown(with: event) : hit.mouseUp(with: event)
            }
        }
        try click(point)
        await settle(1.0)
        let before = strips(window)
        #expect(before == [4, 5, 6].map { panes[$0].id }, "a b c d on show")

        // Click the far card on show: the click is the pane's, and focuses it.
        let far = try #require(panes[3].surfaceView)
        let frame = far.convert(far.bounds, to: nil)
        #expect(root.hitTest(NSPoint(x: frame.midX, y: frame.midY))?.isDescendant(of: far) == true)
        window.makeFirstResponder(far)
        await settle(1.0)
        try await capture(window, "click-far-card-on-show")
        #expect(panes[3].isFocusedPane)
        #expect(strips(window) == before, "focusing a pane on show moved the row")
    }

    // MARK: - Focus never lands on a strip

    /// `a b [c d] e f`, c focused: stashing c must hand the caret to d, the
    /// pane still on show — not to b, the neighbour a close would pick, which
    /// is a strip, and focusing it would bring it back out.
    @Test func stashingTheFocusedPaneNeverFocusesAStrip() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        window.makeFirstResponder(panes[2].surfaceView)
        await settle(0.4)
        #expect(controller.stashPane(panes[2]))
        await settle(1.0)
        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id), "a strip came out")
        #expect(panes[3].isFocusedPane)
    }

    /// The same, for a close from the sidebar (its row's ×), past any
    /// confirmation (`closeSurface` is what the × reaches).
    @Test func closingTheFocusedPaneNeverFocusesAStrip() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        window.makeFirstResponder(panes[2].surfaceView)
        await settle(0.4)
        let node = try #require(controller.surfaceTree.root?.node(view: panes[2]))
        controller.closeSurface(node, withConfirmation: false)
        await settle(1.0)
        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id), "a strip came out")
        #expect(panes[3].isFocusedPane)
    }

    /// Cmd-W in a focused VIEWER pane on show (`close(_:)`): the caret goes
    /// to the pane still on show, not to the strip beside it.
    @Test func closingAFocusedViewerNeverFocusesAStrip() async throws {
        let (controller, window, panes) = try await collapsedRow(.right, viewerAt: 2)
        defer { controller.close() }
        window.makeFirstResponder(try #require(panes[2].viewerView))
        await settle(0.4)
        #expect(panes[2].isFocusedPane)
        controller.close(self)
        await settle(1.0)
        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id), "a strip came out")
        #expect(panes[3].isFocusedPane)
    }

    /// Three panes, the middle one a viewer with focus. The terminal last
    /// focused (a) is minimized by a drag. `focusedSurface` still names it,
    /// so when the caret leaves the viewer for something that is no pane
    /// (the window itself, after a re-parent) the window must not read a as
    /// focused again and bring it out — nor must the window becoming key,
    /// which restores its focused surface.
    @Test func aTerminalMinimizedWhileAViewerHasFocusStaysMinimized() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let a = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let v = PaneView(viewer: ViewerView(location: "about:blank"))
        let c = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        var tree = SplitTree<PaneView>(view: a)
        tree = try tree.inserting(view: v, at: a, direction: .right)
        tree = try tree.inserting(view: c, at: v, direction: .right)
        tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1300, height: 600))
        window.makeFirstResponder(a.surfaceView)
        await settle(0.6)
        window.makeFirstResponder(try #require(v.viewerView))
        await settle(0.6)
        #expect(v.isFocusedPane)
        #expect(controller.focusedSurface === a.surfaceView)

        controller.performSplitAction(.restack(.init(items: [[a.id], [v.id], [c.id]], run: 0...2), .collapse(.leading)))
        await settle(0.8)
        #expect(strips(window) == [a.id])
        #expect(v.isFocusedPane, "the viewer keeps the caret")

        // The caret leaves the viewer for the window itself.
        window.makeFirstResponder(nil)
        await settle(0.6)
        #expect(strips(window) == [a.id], "the stale focused surface brought its strip out")

        // The window becomes key with nothing focused: it restores focus,
        // into a pane on show.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        await settle(0.6)
        #expect(strips(window) == [a.id], "becoming key brought a strip out")
        #expect(!a.isFocusedPane)
    }

    /// A pane on show dragged onto a strip trades places with it: it takes
    /// the strip's place, minimized, and the caret goes to the pane that came
    /// out of the strip — focusing the dragged pane would bring it straight
    /// back out and undo the drop.
    @Test func aPaneDroppedOnAStripTakesItsPlace() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        PaneMoveCoordinator.apply(.swap(window: controller.rearrangeWindowRef, pane: panes[1].id),
                                  pane: panes[3], from: controller)
        await settle(1.0)
        #expect(strips(window) == [panes[0], panes[3], panes[4], panes[5]].map(\.id))
        #expect(panes[1].isFocusedPane)
    }

    /// Closing a pane on show and undoing the close brings the row back
    /// exactly as it was.
    @Test func undoingACloseBringsTheRowBack() async throws {
        let (controller, window, panes) = try await collapsedRow(.right)
        defer { controller.close() }
        let key = Set(panes.map(\.id))
        window.makeFirstResponder(panes[2].surfaceView)
        await settle(0.4)
        controller.closeSurface(try #require(panes[2].surfaceView), withConfirmation: false)
        await settle(1.0)
        #expect(controller.paneStackState.pin(for: key) == nil, "a row not on screen has no collapse")
        try #require(window.undoManager?.canUndo == true)
        window.undoManager?.undo()
        await settle(1.0)
        #expect(controller.paneStackState.pin(for: key) == .init(start: 2, count: 2))
        #expect(strips(window) == [panes[0], panes[1], panes[4], panes[5]].map(\.id))
    }

    /// A strip is named by its pane's banner title when the banner has one,
    /// live: setting the banner relabels the strip, a banner with no title
    /// leaves the pane's own title, and clearing it brings that back. Read
    /// off the composited window, so it is the drawn label, not a model.
    @Test func aStripIsLabeledByItsBannerTitleLive() async throws {
        let (controller, window, panes) = try await stackedWindow()
        defer { controller.close() }
        let pane = panes[0]
        let surface = try #require(pane.surfaceView)
        let strip = try tab(window, pane)
        let ownName = strip.accessibilityLabel()

        // The strip's pixels, from a capture of the whole window.
        func stripPixels(_ name: String) async throws -> [UInt8] {
            let content = try await SCShareableContent.currentProcess
            let scWindow = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let cfg = SCStreamConfiguration()
            cfg.width = Int(scWindow.frame.width * 2)
            cfg.height = Int(scWindow.frame.height * 2)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: cfg)
            let dir = "/tmp/pane-stack-snapshots"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/strip-label-\(name).png"))
            // Window points, top-left origin, to the capture's pixels.
            let r = strip.convert(strip.bounds, to: nil)
            let frame = window.frame
            let scale = CGFloat(image.width) / frame.width
            let crop = CGRect(x: r.minX * scale, y: (frame.height - r.maxY) * scale,
                              width: r.width * scale, height: r.height * scale).integral
            let cropped = try #require(image.cropping(to: crop))
            let rep = NSBitmapImageRep(cgImage: cropped)
            var out: [UInt8] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    out.append(UInt8(((c?.brightnessComponent ?? 0) * 255).rounded()))
                }
            }
            return out
        }
        func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            a.count != b.count || zip(a, b).contains { abs(Int($0) - Int($1)) > 24 }
        }

        let plain = try await stripPixels("0-pane-title")

        surface.paneBanner = PaneSidebarTextTests.hookBanner
        await settle(0.4)
        #expect(strip.accessibilityLabel() == "Tucked pane: Strip label from banner title")
        let titled = try await stripPixels("1-banner-title")
        #expect(differs(plain, titled), "the banner title replaced the pane title on the strip")

        surface.paneBanner = "## Another task\n|  |  |\n|---|---|\n| **Status** | Working |"
        await settle(0.4)
        #expect(strip.accessibilityLabel() == "Tucked pane: Another task")
        #expect(differs(titled, try await stripPixels("2-new-banner-title")), "a new banner title relabels it")

        // A banner with no title names nothing: the pane's own title is back.
        surface.paneBanner = "|  |  |\n|---|---|\n| **Prompt** | do the thing |\n| **Status** | Idle |"
        await settle(0.4)
        #expect(strip.accessibilityLabel() == ownName)
        #expect(!differs(plain, try await stripPixels("3-untitled-banner")), "an untitled banner keeps the pane title")

        surface.paneBanner = PaneSidebarTextTests.hookBanner
        await settle(0.4)
        surface.paneBanner = nil
        await settle(0.4)
        #expect(strip.accessibilityLabel() == ownName)
        #expect(!differs(plain, try await stripPixels("4-cleared")), "clearing the banner brings the pane title back")
    }

    @Test func aWobbleDuringAClickOnAStripIsStillAClick() async throws {
        let (controller, window, panes) = try await stackedWindow()
        defer { controller.close() }
        let tab = try #require(all(PaneStackTabView.self, in: window.contentView!).first { $0.pane === panes[0] })
        let point = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
        let source = try #require(window.contentView!.superview!.hitTest(point))
        func event(_ type: NSEvent.EventType, _ at: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        source.mouseDown(with: try event(.leftMouseDown, point))
        source.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: point.x + 2, y: point.y - 2)))
        #expect(!PaneDragSession.shared.isDragging, "a 3pt wobble starts no drag")
        source.mouseUp(with: try event(.leftMouseUp, NSPoint(x: point.x + 2, y: point.y - 2)))
        await settle(0.6)
        #expect(panes[0].isFocusedPane, "the click brought the pane forward")
    }
}

/// Records a window at its display's frame rate (ScreenCaptureKit, own window:
/// no screen-recording grant) — what the slide actually looks like, frame by
/// frame, as the window server composited it.
final class WindowFrameRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(CFTimeInterval, CGImage)] = []
    private var stream: SCStream?
    private let context = CIContext()

    func start(_ window: NSWindow, scale: CGFloat = 1) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(scWindow.frame.width * scale)
        cfg.height = Int(scWindow.frame.height * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        cfg.queueDepth = 8
        cfg.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: cfg, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "recorder"))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async -> [(CFTimeInterval, CGImage)] {
        try? await stream?.stopCapture()
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        lock.lock(); frames.append((CACurrentMediaTime(), cg)); lock.unlock()
    }
}
