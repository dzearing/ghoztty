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
        let tabs = all(PaneStackTabView.self, in: window.contentView!).filter { !$0.isHidden }
        let leftmost = try #require(tabs.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        #expect(leftmost.pane === panes[0])
        let point = leftmost.convert(NSPoint(x: leftmost.bounds.midX, y: leftmost.bounds.midY), to: nil)
        let hit = try #require(window.contentView!.superview!.hitTest(point))
        #expect(hit.isDescendant(of: leftmost), "the tab wins the click")
        hit.mouseUp(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))

        // Mid-slide, the card is on its way — on the render server, not
        // already there — and nothing has been resized.
        var sawMidway = false
        var shot = 0
        for _ in 0..<40 {
            await settle(0.01)
            // While the cards are still on their way, nothing has been resized
            // (the pane coming forward takes its slot's size once it is there).
            if card(panes[1])?.layer?.animationKeys()?.isEmpty == false {
                #expect(sizes() == before, "a slide never resizes a terminal mid-slide")
            }
            let target = try #require(card(panes[1])).frame.minX
            if let shown = card(panes[1])?.layer?.presentation()?.frame.minX,
               shown > x0 + 4, shown < target - 4 {
                sawMidway = true
                if shot < 2 { try await capture(window, "mid-\(shot)"); shot += 1 }
            }
            // A card hanging past the stack's end never shows past it.
            for c in cards {
                guard let cardLayer = c.layer?.presentation(), let clip = c.clipLayer?.presentation() else { continue }
                let right = cardLayer.frame.minX + clip.frame.maxX
                let paneRight = cardLayer.frame.maxX - PaneCardView.outset
                if paneRight > stage.bounds.maxX {
                    #expect(right <= stage.bounds.maxX + 0.5, "cut at the stack's edge mid-slide")
                }
            }
        }
        #expect(sawMidway, "the cards slide")

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

    private func drag(_ handle: DividerHandle.DividerHandleView, by delta: CGFloat) {
        handle.onDragBegan?()
        let start = handle.currentSplit?() ?? 0.5
        for step in 1...10 { handle.onDragDelta?(delta * CGFloat(step) / 10, start) }
        handle.onDragEnded?()
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
        let tabs = all(PaneStackTabView.self, in: window.contentView!).filter { !$0.isHidden }
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
        #expect(all(PaneStackTabView.self, in: window.contentView!).allSatisfy { $0.isHidden })

        // Collapse again, from the other side this time, and widen it back
        // with the grip where the run meets the minimized card.
        drag(try #require(handles(window).first), by: -500)
        await settle(0.8)
        #expect(state.pin(for: key) == .init(start: 1, count: 2))
        // The grip where the run meets the tucked card widens the row again.
        drag(try #require(handles(window).first), by: -200)
        await settle(0.8)
        #expect(state.pin(for: key) == nil)
        let left = all(PaneStackTabView.self, in: window.contentView!).filter { !$0.isHidden }
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
        let tabs = all(PaneStackTabView.self, in: window.contentView!).filter { !$0.isHidden }
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
        while CACurrentMediaTime() - start < 1.0 {
            let g = grid()
            if g != changes.last?.1 { changes.append((CACurrentMediaTime() - start, g)) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let frames = await recorder.stop()
        let log = changes.map { String(format: "t=%.3f ", $0.0) + $0.1.joined(separator: " ") }.joined(separator: "\n")
        try? log.write(toFile: "/tmp/pane-stack-snapshots/resize-log.txt", atomically: true, encoding: .utf8)

        #expect(controller.paneStackState.pin(for: key) == .init(start: 0, count: 3))
        #expect(changes.count == 2, "each terminal is resized once, all together:\n\(log)")
        if changes.count == 2 {
            #expect(changes[1].0 >= PaneStageView.slideDuration - 0.02, "resized mid-slide:\n\(log)")
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
        let during = frames.filter { $0.0 - start >= 0 && $0.0 - start <= PaneStageView.slideDuration + 0.15 }
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
        let tabs = all(PaneStackTabView.self, in: window.contentView!).filter { !$0.isHidden }
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
        // Four panes in 1200pt: three cards on show, one tucked.
        let (controller, window, panes) = try await stackedWindow(count: 4, width: 1200)
        defer { controller.close() }
        let width = { (p: PaneView) in p.contentView.frame.width }
        let grips = handles(window)
        #expect(grips.count == 2, "a grip between each pair of cards on show")
        let before = panes.map(width)

        // Widen the first card on show by 40.
        drag(try #require(grips.first), by: 40)
        await settle(0.8)
        let after = panes.map(width)
        #expect(after != before, "the cards on show resized: \(before) -> \(after) shares \(controller.paneStackState.shares)")
        #expect(after.max()! - after.min()! >= 70, "one slot grew at another's expense: \(before) -> \(after) shares \(controller.paneStackState.shares)")

        // Squeeze the next card well past its minimum: the far card tucks.
        drag(try #require(handles(window).first), by: 600)
        await settle(0.8)
        let key = Set(panes.map(\.id))
        #expect(controller.paneStackState.pin(for: key)?.count == 2)
    }

    @Test func aGripBetweenCardsFollowsThePointer() async throws {
        let (controller, window, panes) = try await stackedWindow(count: 4, width: 1200)
        defer { controller.close() }
        // The card on show just before the grip.
        let grip = try #require(handles(window).first)
        let gripX = grip.convert(grip.bounds, to: nil).midX
        let frame = { (p: PaneView) in p.contentView.convert(p.contentView.bounds, to: nil) }
        let first = try #require(panes.filter { frame($0).maxX <= gripX }.max { frame($0).maxX < frame($1).maxX })
        let edge = { frame(first).maxX }
        let before = edge()

        // A real drag: the layout catches up between mouse events.
        grip.onDragBegan?()
        for step in 1...6 {
            grip.onDragDelta?(CGFloat(step) * -10, 0.5)
            await settle(0.1)
        }
        let held = edge()
        grip.onDragEnded?()
        #expect(abs(held - (before - 60)) <= 1, "60pt left moved the edge 60pt: \(before) -> \(held)")
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
        _ direction: SplitTree<PaneView>.NewDirection
    ) async throws -> (TerminalController, NSWindow, [PaneView]) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let panes = (0..<6).map { _ in PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)) }
        var tree = SplitTree<PaneView>(view: panes[0])
        for i in 1..<6 { tree = try tree.inserting(view: panes[i], at: panes[i - 1], direction: direction) }
        tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        window.setContentSize(direction == .right ? NSSize(width: 1600, height: 600) : NSSize(width: 900, height: 1000))
        window.makeFirstResponder(panes[3].surfaceView)
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
        all(PaneStackTabView.self, in: window.contentView!).filter { !$0.isHidden }
            .sorted {
                let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
                return a.minX == b.minX ? a.minY > b.minY : a.minX < b.minX
            }
            .map { $0.pane?.id }
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
        // four strips.
        let extent = direction == .right ? panes[3].contentView.frame.width : panes[3].contentView.frame.height
        let stage = try #require(all(PaneCardView.self, in: window.contentView!).first?.superview)
        let total = direction == .right ? stage.bounds.width : stage.bounds.height
        #expect(extent > total - 4 * PaneLayout.Metrics.peek - 40, "\(extent) of \(total)")
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
        window.setContentSize(vertical ? NSSize(width: 900, height: 700) : NSSize(width: 950, height: 600))
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
