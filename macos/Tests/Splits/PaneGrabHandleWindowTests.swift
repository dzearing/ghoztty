import AppKit
import Combine
import GhosttyKit
import SwiftUI
import Testing
@testable import Ghostty

/// The hover grab handle and the drag it starts, in a REAL terminal window
/// with rearrange mode off.
///
/// `NSDraggingSession` waits on the physical mouse button, so these never
/// start one: a synthetic drag hangs in `CoreDragStartDragging`. They cover
/// what is either side of it — the grip answering the pointer, the ghost, and
/// the session the drag feeds. Set `PANE_SIDEBAR_SNAPSHOTS=<dir>` to also
/// write each ghost as a PNG.
@MainActor
@Suite(.serialized)
struct PaneGrabHandleWindowTests {
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

    private func open(_ tree: SplitTree<PaneView>, _ ghostty: Ghostty.App) async throws -> TerminalController {
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1100, height: 700))
        await settle(0.8)
        return controller
    }

    /// a | b in the first tab of a window, and a lone pane in its second.
    private func openTabs() async throws -> (first: TerminalController, second: TerminalController, a: PaneView, b: PaneView) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let first = try await open(try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right), ghostty)
        let second = try await open(SplitTree<PaneView>(view: terminalPane(app)), ghostty)
        let window = try #require(first.window)
        let secondWindow = try #require(second.window)
        window.addTabbedWindow(secondWindow, ordered: .above)
        await settle(0.8)
        window.tabGroup?.selectedWindow = window
        await settle(0.8)
        return (first, second, a, b)
    }

    private func sources(in view: NSView) -> [PaneDragSourceView] {
        ((view as? PaneDragSourceView).map { [$0] } ?? []) + view.subviews.flatMap { sources(in: $0) }
    }

    private func grip(of pane: PaneView, in window: NSWindow) throws -> PaneDragSourceView {
        let root = try #require(window.contentView?.superview)
        return try #require(sources(in: root).first { $0.pane === pane && !$0.isHiddenOrHasHiddenAncestor })
    }

    /// Where the visible capsule is drawn, in window coordinates.
    private func capsulePoints(of pane: PaneView) -> [NSPoint] {
        let frame = pane.contentView.convert(pane.contentView.bounds, to: nil)
        return [1.0, 5.0, 10.0].flatMap { dy in
            [-22.0, 0, 22].map { dx in NSPoint(x: frame.midX + dx, y: frame.maxY - dy) }
        }
    }

    private func raster(_ image: NSImage) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The share of the card's own area that is solid, and how many colors
    /// are in it.
    private func measure(_ rep: NSBitmapImageRep) -> (solid: Double, colors: Int) {
        let inset = Int(PaneDragGhost.margin * 2) + 8
        var solid = 0, total = 0
        var colors = Set<UInt32>()
        for y in stride(from: inset, to: rep.pixelsHigh - inset, by: 2) {
            for x in stride(from: inset, to: rep.pixelsWide - inset, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                if color.alphaComponent > 0.9 { solid += 1 }
                colors.insert(UInt32(color.redComponent * 255) << 16
                    | UInt32(color.greenComponent * 255) << 8
                    | UInt32(color.blueComponent * 255))
            }
        }
        return (Double(solid) / Double(Swift.max(total, 1)), colors.count)
    }

    private func save(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PANE_SIDEBAR_SNAPSHOTS"] else { return }
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func screenPoint(in view: NSView, _ window: NSWindow, at point: NSPoint) -> CGPoint {
        window.convertPoint(toScreen: view.convert(point, to: nil))
    }

    // MARK: The grip

    /// The capsule is over the drag source wherever it is drawn: on panes the
    /// window opened with and on a split made afterwards, with tabs showing.
    @Test func theCapsuleIsOverTheDragSource() async throws {
        let tabs = try await openTabs()
        let window = try #require(tabs.first.window)
        let bView = try #require(tabs.b.surfaceView)
        let surface = try #require(tabs.first.newSplit(at: bView, direction: .down, focus: false))
        await settle(0.8)
        let added = try #require(tabs.first.surfaceTree.pane(for: surface))
        let root = try #require(window.contentView?.superview)
        for pane in [tabs.a, tabs.b, added] {
            for point in capsulePoints(of: pane) {
                let hit = root.hitTest(root.convert(point, from: nil))
                #expect((hit as? PaneDragSourceView)?.pane === pane, "at \(point): \(String(describing: hit))")
            }
        }
        tabs.second.close()
        tabs.first.close()
        await settle(0.3)
    }

    /// The grip holds the cursor against the terminal's own rect under it,
    /// and gives the terminal's back on the way out.
    @Test func theGripTakesTheCursorAndGivesItBack() async throws {
        let tabs = try await openTabs()
        let window = try #require(tabs.first.window)
        let source = try grip(of: tabs.b, in: window)
        #expect(source.hoverTrackingOptions.contains(.cursorUpdate))
        #expect(source.hoverTrackingOptions.contains(.mouseMoved))

        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        NSCursor.iBeam.set()
        source.mouseMoved(with: event)
        #expect(NSCursor.current == NSCursor.openHand)
        NSCursor.iBeam.set()
        source.cursorUpdate(with: event)
        #expect(NSCursor.current == NSCursor.openHand)
        source.mouseExited(with: event)
        #expect(NSCursor.current == tabs.b.surfaceView?.pointerStyle.cursor)

        tabs.second.close()
        tabs.first.close()
        await settle(0.3)
    }

    /// A list row is a row first: it keeps the arrow.
    @Test func aRowLeavesTheCursorAlone() {
        let row = PaneDragSourceView()
        row.showsGrabCursor = false
        #expect(!row.hoverTrackingOptions.contains(.cursorUpdate))
        #expect(!row.hoverTrackingOptions.contains(.mouseMoved))
    }

    // MARK: The ghost

    @Test func theCardKeepsThePaneShapeWithinItsLimits() {
        #expect(PaneDragGhost.cardSize(for: CGSize(width: 1000, height: 500)) == CGSize(width: 220, height: 110))
        #expect(PaneDragGhost.cardSize(for: CGSize(width: 500, height: 1000)) == CGSize(width: 120, height: 150))
        #expect(PaneDragGhost.cardSize(for: CGSize(width: 40, height: 30)) == PaneDragGhost.minSize)
        #expect(PaneDragGhost.cardSize(for: .zero) == PaneDragGhost.minSize)
    }

    @Test func thePointerHoldsTheCardByItsTitle() {
        let size = CGSize(width: 240, height: 130)
        let frame = PaneDragGhost.frame(imageSize: size, pointer: CGPoint(x: 500, y: 300))
        #expect(frame.midX == 500)
        // Inside the title strip, which runs along the top of the card.
        let cardTop = frame.maxY - PaneDragGhost.margin
        #expect(300 < cardTop)
        #expect(300 > cardTop - PaneDragGhost.titleHeight)
    }

    /// A fresh terminal has one line of glyphs on nothing: its snapshot alone
    /// is almost entirely transparent. The ghost must still be a solid card.
    @Test func aFreshTerminalGetsASolidCard() async throws {
        let tabs = try await openTabs()
        let snapshot = try raster(try #require(tabs.b.dragSnapshot))
        let bare = measure(snapshot)
        #expect(bare.solid < 0.5, "the premise: a bare snapshot is mostly transparent")

        let image = try #require(PaneDragGhost.image(for: tabs.b))
        #expect(image.size.width <= PaneDragGhost.maxSize.width + PaneDragGhost.margin * 2)
        #expect(image.size.height <= PaneDragGhost.maxSize.height + PaneDragGhost.margin * 2)
        let rep = try raster(image)
        save(rep, "ghost-terminal")
        let card = measure(rep)
        #expect(card.solid > 0.95)
        #expect(card.colors > 2, "a background, a title strip and its text")
        tabs.second.close()
        tabs.first.close()
        await settle(0.3)
    }

    @Test func aViewerGetsACard() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let doc = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-\(UUID().uuidString).md")
        try "# Heading\n\nSome body text for the ghost.\n".write(to: doc, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: doc) }
        let viewer = PaneView(viewer: ViewerView(location: doc.path))
        let a = terminalPane(app)
        let controller = try await open(try SplitTree<PaneView>(view: a).inserting(view: viewer, at: a, direction: .right), ghostty)
        await settle(1.5)
        let rep = try raster(try #require(PaneDragGhost.image(for: viewer)))
        save(rep, "ghost-viewer")
        #expect(measure(rep).solid > 0.95)
        controller.close()
        await settle(0.3)
    }

    /// Nothing mounted, nothing to show: the row stands in.
    @Test func anUnmountedPaneHasNoGhost() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        #expect(PaneDragGhost.image(for: terminalPane(app)) == nil)
    }

    // MARK: The drag, with rearrange mode off

    @Test func aDropOnTheTabBarMakesATab() async throws {
        let tabs = try await openTabs()
        let window = try #require(tabs.first.window)
        #expect(!tabs.first.rearrangeModeState.isActive)
        let bar = try #require(window.tabBarView)
        let groupSize = try #require(window.tabGroup).windows.count

        let session = PaneDragSession.shared
        session.begin(pane: tabs.b, from: tabs.first)
        session.update(screenPoint: screenPoint(in: bar, window, at: NSPoint(x: bar.bounds.midX, y: bar.bounds.midY)))
        guard case .newTab = session.target else {
            Issue.record("over the tab bar: \(String(describing: session.target))")
            session.end(commit: false)
            return
        }
        session.end(commit: true)
        await settle(0.8)

        #expect(try #require(window.tabGroup).windows.count == groupSize + 1)
        #expect(!tabs.first.surfaceTree.contains { $0 === tabs.b })
        for w in try #require(window.tabGroup).windows where w !== window && w !== tabs.second.window {
            (w.windowController as? TerminalController)?.close()
        }
        tabs.second.close()
        tabs.first.close()
        await settle(0.3)
    }

    /// Every pane and sidebar of every window hangs off the session, so a
    /// move must publish nothing to them: a publish per move is what held a
    /// drag to a few frames a second. A new target reaches only the overlays.
    @Test func aMoveRedrawsOnlyTheOverlays() async throws {
        let tabs = try await openTabs()
        let window = try #require(tabs.first.window)
        let a = try #require(tabs.first.surfaceTree.visibleLeaves.first { $0 !== tabs.b })
        let session = PaneDragSession.shared
        session.begin(pane: tabs.b, from: tabs.first)

        var sessionFires = 0, overlayFires = 0, sidebarFires = 0
        let subscriptions = [
            session.objectWillChange.sink { sessionFires += 1 },
            session.dropFeedback.objectWillChange.sink { overlayFires += 1 },
            tabs.first.paneSidebarState.objectWillChange.sink { sidebarFires += 1 },
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        let view = a.contentView
        let centre = screenPoint(in: view, window, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        session.update(screenPoint: centre)
        #expect(overlayFires == 1)
        for step in 1...50 {
            session.update(screenPoint: CGPoint(x: centre.x + CGFloat(step % 5), y: centre.y))
        }
        #expect(overlayFires == 1)
        #expect(sessionFires == 0)
        #expect(sidebarFires == 0)

        session.end(commit: false)
        tabs.second.close()
        tabs.first.close()
        await settle(0.3)
    }

    /// A sidebar redraws a whole list, so only the one the target is in hears
    /// of it, and it is told when the target leaves.
    @Test func aSidebarTargetReachesOnlyItsSidebar() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let source = try await open(try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right), ghostty)
        let c = terminalPane(app), d = terminalPane(app)
        let other = try await open(try SplitTree<PaneView>(view: c).inserting(view: d, at: c, direction: .right), ghostty)
        let window = try #require(other.window)
        let rail = try #require(other.paneSidebarHost?.dropGeometry()).rect

        let session = PaneDragSession.shared
        session.begin(pane: b, from: source)
        session.update(screenPoint: CGPoint(x: rail.midX, y: rail.midY))
        #expect(session.target?.window == PaneDropWindowRef(other))
        #expect(other.paneSidebarState.dropTarget == session.target)
        #expect(source.paneSidebarState.dropTarget == nil)

        let view = c.contentView
        session.update(screenPoint: screenPoint(in: view, window, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
        #expect(other.paneSidebarState.dropTarget == nil)

        session.end(commit: false)
        other.close()
        source.close()
        await settle(0.3)
    }

    private func centre(of view: NSView, _ window: NSWindow) -> CGPoint {
        screenPoint(in: view, window, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    /// A pane dragged to where it already is has nowhere to go: the spots that
    /// would put it back don't react, and the ones beside them do.
    @Test func aSpotThatChangesNothingDoesNotReact() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let controller = try await open(try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right), ghostty)
        let window = try #require(controller.window)
        let view = b.contentView
        let session = PaneDragSession.shared
        session.begin(pane: a, from: controller)

        func target(atFraction x: CGFloat, _ y: CGFloat) -> PaneDropTarget? {
            session.update(screenPoint: screenPoint(
                in: view, window, at: NSPoint(x: view.bounds.width * x, y: view.bounds.height * y)))
            return session.target
        }
        // b's triangle facing a: a is already on b's left.
        #expect(target(atFraction: 0.2, 0.5) == nil)
        #expect(target(atFraction: 0.8, 0.5) == .split(window: PaneDropWindowRef(controller), pane: b.id, direction: .right))
        #expect(target(atFraction: 0.5, 0.5) == .swap(window: PaneDropWindowRef(controller), pane: b.id))

        // The divider between them.
        let divider = try #require(controllerDivider(controller, window))
        session.update(screenPoint: CGPoint(x: divider.line.midX, y: divider.line.midY))
        #expect(session.target == nil)

        // The window's left edge, which a is against.
        let leftEdge = centre(of: a.contentView, window)
        session.update(screenPoint: CGPoint(x: a.contentView.window!.convertToScreen(a.contentView.convert(a.contentView.bounds, to: nil)).minX + 4, y: leftEdge.y))
        #expect(session.target == nil)

        session.end(commit: false)
        controller.close()
        await settle(0.3)
    }

    private func controllerDivider(_ controller: TerminalController, _ window: NSWindow) -> PaneDropCandidate.Divider? {
        let rects = controller.surfaceTree.visibleLeaves.map { pane in
            (pane.id, window.convertToScreen(pane.contentView.convert(pane.contentView.bounds, to: nil)))
        }
        return PaneDropCandidate.Divider.all(
            in: controller.surfaceTree.visibleTree.root,
            rects: Dictionary(uniqueKeysWithValues: rects)).first
    }

    /// A pane from another window dropped on a divider lands between its two
    /// sides, and the window it left keeps the rest.
    @Test func aDropOnADividerInsertsBetweenItsPanes() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app)
        let destination = try await open(try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right), ghostty)
        let c = terminalPane(app), d = terminalPane(app)
        let source = try await open(try SplitTree<PaneView>(view: c).inserting(view: d, at: c, direction: .right), ghostty)
        let window = try #require(destination.window)
        window.orderFrontRegardless()
        await settle(0.3)

        let session = PaneDragSession.shared
        session.begin(pane: d, from: source)
        let divider = try #require(controllerDivider(destination, window))
        session.update(screenPoint: CGPoint(x: divider.line.midX, y: divider.line.midY))
        guard case .insert = session.target else {
            Issue.record("over the divider: \(String(describing: session.target))")
            session.end(commit: false)
            return
        }
        session.end(commit: true)
        await settle(0.8)

        #expect(destination.surfaceTree.visibleLeaves.map(\.id) == [a.id, d.id, b.id])
        #expect(source.surfaceTree.visibleLeaves.map(\.id) == [c.id])
        source.close()
        destination.close()
        await settle(0.3)
    }

    /// A banner is part of its pane. The card floats over the top of the pane,
    /// above where the terminal starts, and a drop there means what it means
    /// anywhere else on a pane: its triangles, its box and the dividers beside
    /// it are the whole pane's.
    @Test func aBannerIsPartOfItsPaneToADrop() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app), b = terminalPane(app), c = terminalPane(app)
        let controller = try await open(
            try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right)
                .inserting(view: c, at: b, direction: .down), ghostty)
        let window = try #require(controller.window)
        let banner = "## A task\n|  |  |\n|---|---|\n| **Goal** | one |\n| **Status** | two |\n| **Prompt** | three |"
        a.surfaceView?.paneBanner = banner
        b.surfaceView?.paneBanner = banner
        await settle(0.8)

        func rect(_ view: NSView) -> CGRect {
            window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        let ref = PaneDropWindowRef(controller)
        let terminal = rect(b.contentView), whole = rect(b.footprintView)
        #expect(whole.maxY - terminal.maxY > 40, "the banner should push the terminal down")
        #expect(whole.minY == terminal.minY && whole.width == terminal.width)
        // On the banner card, below the window's edge band.
        let onBanner = whole.maxY - PaneDropResolver.windowEdgeBand - 8

        let session = PaneDragSession.shared
        session.begin(pane: c, from: controller)
        session.update(screenPoint: CGPoint(x: whole.midX, y: onBanner))
        #expect(session.target == .split(window: ref, pane: b.id, direction: .up))
        session.end(commit: false)

        // From another window, as a pane that is not next to it.
        let d = terminalPane(app)
        let other = try await open(SplitTree<PaneView>(view: d), ghostty)
        window.orderFrontRegardless()
        await settle(0.3)
        session.begin(pane: d, from: other)
        session.update(screenPoint: CGPoint(x: whole.midX, y: onBanner))
        #expect(session.target == .split(window: ref, pane: b.id, direction: .up))

        // The middle of the pane as drawn is its swap box.
        session.update(screenPoint: CGPoint(x: whole.midX, y: whole.midY))
        #expect(session.target == .swap(window: ref, pane: b.id))

        // The divider beside it runs the length of the banner too.
        session.update(screenPoint: CGPoint(x: (rect(a.footprintView).maxX + whole.minX) / 2, y: onBanner))
        guard case .insert = session.target else {
            Issue.record("between the banners: \(String(describing: session.target))")
            session.end(commit: false)
            return
        }

        // The top of the window is still its edge band.
        session.update(screenPoint: CGPoint(x: whole.midX, y: whole.maxY - 4))
        #expect(session.target == .topLevel(window: ref, side: .up))

        session.end(commit: false)
        other.close()
        controller.close()
        await settle(0.3)
    }

    /// The window order is read once, not per move, but a window that opens
    /// mid-drag is still somewhere to drop.
    @Test func aWindowOpenedMidDragIsATarget() async throws {
        let tabs = try await openTabs()
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let session = PaneDragSession.shared
        session.begin(pane: tabs.b, from: tabs.first)

        let late = terminalPane(app)
        let opened = try await open(SplitTree<PaneView>(view: late), ghostty)
        let window = try #require(opened.window)
        let view = late.contentView
        session.update(screenPoint: screenPoint(in: view, window, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
        #expect(session.target?.window == PaneDropWindowRef(opened))

        session.end(commit: false)
        opened.close()
        tabs.second.close()
        tabs.first.close()
        await settle(0.3)
    }

    /// Rest on a tab and it comes forward, and the drop lands in its layout.
    @Test func aDwellOnATabDropsIntoThatTab() async throws {
        let tabs = try await openTabs()
        let window = try #require(tabs.first.window)
        let secondWindow = try #require(tabs.second.window)
        let bar = try #require(window.tabBarView)
        let group = try #require(window.tabGroup)
        let index = try #require(group.windows.firstIndex(of: secondWindow))
        let button = window.tabButtonsInVisualOrder()[index]

        let session = PaneDragSession.shared
        session.begin(pane: tabs.b, from: tabs.first)
        let onTab = screenPoint(in: button, window, at: NSPoint(x: button.bounds.midX, y: button.bounds.midY))
        session.update(screenPoint: onTab)
        #expect(session.hoveredTab?.index == index)
        #expect(bar.window != nil)
        let revealed = await poll(timeout: 2) { group.selectedWindow === secondWindow }
        #expect(revealed)
        await settle(0.5)

        let host = try #require(tabs.second.surfaceTree.first)
        let frame = host.contentView.convert(host.contentView.bounds, to: nil)
        session.update(screenPoint: secondWindow.convertPoint(
            toScreen: NSPoint(x: frame.maxX - 60, y: frame.midY)))
        guard case .split(_, let target, _) = session.target else {
            Issue.record("over the revealed tab's pane: \(String(describing: session.target))")
            session.end(commit: false)
            return
        }
        #expect(target == host.id)
        session.end(commit: true)
        await settle(0.8)

        #expect(tabs.second.surfaceTree.contains { $0 === tabs.b })
        #expect(!tabs.first.surfaceTree.contains { $0 === tabs.b })
        tabs.second.close()
        tabs.first.close()
        await settle(0.3)
    }
}
