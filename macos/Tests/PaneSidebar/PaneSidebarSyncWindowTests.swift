import AppKit
import GhosttyKit
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import Ghostty

/// The pane sidebar shared across REAL windows (`PaneSidebarSharedState`):
/// a change in one window's sidebar appears in another's, and windows and
/// project groups drag into an order every window's list shows
/// (`PaneSidebarItemDrag`). Terminals run `/bin/cat`, as in
/// `PaneSidebarWindowTests`.
@MainActor
@Suite(.serialized)
struct PaneSidebarSyncWindowTests {
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

    /// One window per title, each `size`, the sidebar shown and expanded.
    private func open(_ titles: [String], size: NSSize = NSSize(width: 1000, height: 600)) async throws -> [TerminalController] {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var controllers: [TerminalController] = []
        for title in titles {
            let c = TerminalController.newWindow(ghostty, tree: SplitTree(view: terminalPane(app)))
            c.windowTitleOverride = title
            controllers.append(c)
        }
        let shared = PaneSidebarSharedState.shared
        shared.isHidden = false
        shared.isExpanded = true
        shared.width = 260
        shared.windowOrder = []
        shared.foldedProjects = []
        shared.showsAllWindows = false
        _ = await poll(timeout: 10) { controllers.allSatisfy { $0.window?.isVisible == true } }
        for c in controllers { c.window?.setContentSize(size) }
        // The first is the window in use. (Set, not by making it key: the
        // test host is a background app, and must not take focus.)
        use(controllers[0], among: controllers)
        await settle(0.8)
        return controllers
    }

    /// Put the shared state back as a user would have it, and close.
    private func close(_ controllers: [TerminalController], restoring saved: Saved) async {
        PaneSidebarItemDrag.shared.end(commit: false)
        let shared = PaneSidebarSharedState.shared
        shared.showsAllWindows = false
        shared.isExpanded = saved.isExpanded
        shared.isHidden = saved.isHidden
        shared.width = saved.width
        shared.windowOrder = saved.order
        shared.foldedProjects = saved.folds
        for c in controllers { c.close() }
        await settle(0.4)
    }

    /// `c` becomes the window in use, as when it becomes key: the others'
    /// sidebars stop redrawing live, and `c`'s catches up.
    private func use(_ c: TerminalController, among controllers: [TerminalController]) {
        for other in controllers { other.paneSidebarState.isLive = { [weak c, weak other] in c === other } }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: c.window)
    }

    private struct Saved {
        let isExpanded: Bool, isHidden: Bool, width: CGFloat, order: [String], folds: Set<String>
    }

    private func save() -> Saved {
        let s = PaneSidebarSharedState.shared
        return Saved(isExpanded: s.isExpanded, isHidden: s.isHidden, width: s.width,
                     order: s.windowOrder, folds: s.foldedProjects)
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    // MARK: Shared state

    /// A window opened while the shared scope is all windows comes up with
    /// the search field in its sidebar: as AppKit orders it in, it hands the
    /// caret to the window's first key view, which must not be the search —
    /// the window's terminal gets it as it becomes key. A click (a
    /// `makeFirstResponder`) still focuses the field, and typing filters.
    @Test func aNewWindowDoesNotPutTheCaretInTheSearch() async throws {
        let saved = save()
        let shared = PaneSidebarSharedState.shared
        shared.isHidden = false
        shared.isExpanded = true
        shared.width = 260
        shared.showsAllWindows = true
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let c = TerminalController.newWindow(ghostty, tree: SplitTree(view: terminalPane(app)))
        c.windowTitleOverride = "focus: new window"
        _ = await poll(timeout: 10) { c.window?.isVisible == true }
        c.window?.setContentSize(NSSize(width: 1000, height: 600))
        await settle(0.8)
        let window = try #require(c.window)
        let content = try #require(window.contentView)
        let field = try #require(all(NSTextField.self, in: content).first { $0.placeholderString == "Search" },
                                 "the all-windows list shows its search field")

        let responder = window.firstResponder
        let caretInSearch = responder === field || (responder as? NSText)?.delegate === field
        #expect(!caretInSearch, "the new window's first responder is the search field (\(String(describing: responder)))")

        #expect(window.makeFirstResponder(field), "a click still focuses the search field")
        let editor = try #require(field.currentEditor())
        editor.insertText("focus")
        await settle(0.2)
        #expect(c.paneSidebarState.filter == "focus", "typing filters: \(c.paneSidebarState.filter)")
        window.makeFirstResponder(nil)

        c.close()
        await close([], restoring: saved)
    }

    /// Collapse, hide, width, the all-windows scope, a fold: each changed in
    /// one window shows in the other — while a narrow window keeps its rail.
    @Test func aChangeInOneWindowShowsInTheOther() async throws {
        let saved = save()
        let windows = try await open(["sync: one", "sync: two"])
        let (a, b) = (windows[0], windows[1])
        let bHost = try #require(b.paneSidebarHost)
        #expect(bHost.mode == .expanded)

        // A collapse is a's alone until b is next key: then b has it too.
        a.setPaneSidebarExpanded(false, cause: "test")
        await settle(0.5)
        #expect(a.paneSidebarHost?.mode == .collapsed)
        #expect(b.paneSidebarHost?.mode == .expanded, "b, in the background, is not re-laid out")
        use(b, among: windows)
        await settle(0.5)
        #expect(b.paneSidebarHost?.mode == .collapsed, "b collapsed as it became key")
        b.setPaneSidebarExpanded(true, cause: "test")
        await settle(0.5)
        use(a, among: windows)
        await settle(0.5)
        #expect(a.paneSidebarHost?.mode == .expanded)

        // A width change redraws only the window in use; b catches up as
        // it becomes key.
        a.paneSidebarState.width = 320
        await settle(0.4)
        #expect(b.paneSidebarState.isStale, "b, in the background, did not redraw")
        use(b, among: windows)
        await settle(0.4)
        #expect(!b.paneSidebarState.isStale, "b caught up when it became key")
        let bCard = try #require(b.paneSidebarHost?.cardRect)
        #expect(bCard.width == 320, "b's panel is a's width: \(bCard.width)")
        use(a, among: windows)
        await settle(0.3)

        a.togglePaneSidebar()
        await settle(0.5)
        use(b, among: windows)
        await settle(0.5)
        #expect(b.paneSidebarHost == nil, "b's sidebar hid with a's")
        b.togglePaneSidebar()
        await settle(0.5)
        use(a, among: windows)
        await settle(0.5)
        #expect(a.paneSidebarHost?.mode == .expanded)

        // All windows, turned on in a: in b too, with the same folds.
        a.paneSidebarState.showsAllWindows = true
        await settle(0.5)
        #expect(b.paneSidebarState.showsAllWindows)
        for viewer in [a, b] {
            #expect(!viewer.paneSidebarState.isWindowFolded(a.paneSidebarState.windowID, isSearching: false))
            #expect(viewer.paneSidebarState.isWindowFolded(b.paneSidebarState.windowID, isSearching: false))
        }
        b.paneSidebarState.foldedProjects = ["sync"]
        #expect(a.paneSidebarState.foldedProjects == ["sync"])

        // A narrow window shows the rail, expanded or not, and wide windows
        // stay expanded: the rail is each window's own rule.
        b.window?.setContentSize(NSSize(width: 600, height: 600))
        await settle(0.6)
        #expect(b.paneSidebarHost?.mode == .collapsed, "too narrow for the panel")
        #expect(a.paneSidebarHost?.mode == .expanded, "a stays expanded")
        #expect(a.paneSidebarState.isExpanded)
        await close(windows, restoring: saved)
    }

    /// The all-windows list scrolls as one: scrolled in one window, the
    /// other's list follows — and one appearing starts where they are.
    @Test func theAllWindowsListScrollsAsOne() async throws {
        let saved = save()
        let titles = (1...10).map { "scroll: wt-\($0)" }
        let windows = try await open(titles, size: NSSize(width: 1000, height: 420))
        let (a, b) = (windows[0], windows[1])
        a.paneSidebarState.showsAllWindows = true
        // Every window open, so the list is longer than the bar.
        for c in windows { PaneSidebarSharedState.shared.unfoldedWindows.insert(c.paneSidebarState.windowID) }
        await settle(0.8)

        func syncView(_ c: TerminalController) throws -> PaneSidebarScrollSyncView {
            let content = try #require(c.window?.contentView)
            return try #require(all(PaneSidebarScrollSyncView.self, in: content).first, """
                host \(String(describing: c.paneSidebarHost?.mode)) all \(c.paneSidebarState.showsAllWindows) \
                scrolls \(all(NSScrollView.self, in: content).count) stale \(c.paneSidebarState.isStale) \
                live \(c.paneSidebarState.isLive())
                """)
        }
        let aSync = try syncView(a)
        let aScroll = try #require(aSync.enclosingScrollView)
        let document = try #require(aScroll.documentView)
        #expect(document.frame.height > aScroll.contentView.bounds.height + 100,
                "the list overflows: \(document.frame.height) in \(aScroll.contentView.bounds.height)")

        aScroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        aScroll.reflectScrolledClipView(aScroll.contentView)
        await settle(0.2)
        #expect(abs((aSync.scrollOffset ?? 0) - 80) < 1, "a is where it was scrolled")
        #expect(b.paneSidebarState.isStale, "b, in the background, has not redrawn for any of it")

        // b becomes key: its list is the all-windows list, scrolled to 80.
        use(b, among: windows)
        await settle(0.8)
        let bSync = try syncView(b)
        #expect(abs((bSync.scrollOffset ?? 0) - 80) < 1, "b starts where a was: \(bSync.scrollOffset ?? -1)")

        // b scrolls on; a, back in use, catches up.
        let bScroll = try #require(bSync.enclosingScrollView)
        bScroll.contentView.scroll(to: NSPoint(x: 0, y: 140))
        bScroll.reflectScrolledClipView(bScroll.contentView)
        await settle(0.2)
        #expect(abs((aSync.scrollOffset ?? 0) - 80) < 1, "a does not scroll along")
        use(a, among: windows)
        await settle(0.4)
        #expect(abs((aSync.scrollOffset ?? 0) - 140) < 1, "a took b's place as it became key: \(aSync.scrollOffset ?? -1)")
        await close(windows, restoring: saved)
    }

    // MARK: Drag to reorder

    /// The center of `key`'s item in `c`'s list, on screen.
    private func screenY(of key: String, in c: TerminalController, fraction: CGFloat = 0.5) throws -> CGFloat {
        let host = try #require(c.paneSidebarHost)
        let frame = try #require(host.geometry.itemFrames[key], "no frame for \(key)")
        return try #require(host.screenY(sidebarY: frame.minY + frame.height * fraction))
    }

    /// A window row dragged up its group, and a group dragged above another
    /// — folding every group while it is held and putting the folds back
    /// after. Each window's list shows the new order; no window moves.
    @Test func dragReordersAWindowAndAGroup() async throws {
        let saved = save()
        let windows = try await open(["alpha: one", "alpha: two", "beta: main", "gamma: main"])
        let a = windows[0], other = windows[2]
        a.paneSidebarState.showsAllWindows = true
        await settle(0.8)
        let frames = windows.map { $0.window?.frame }
        let drag = PaneSidebarItemDrag.shared
        let host = try #require(a.paneSidebarHost)
        #expect(all(PaneSidebarItemDragView.self, in: host).count >= 5, "every window row and group header drags")

        // `alpha: two` up above `alpha: one`, among alpha's windows.
        let alpha = try #require(a.paneSidebarSections.first { $0.project == "alpha" })
        #expect(alpha.windows.map(\.label) == ["one", "two"], "by name to start")
        let siblings = alpha.windows.map(\.key)
        let two = siblings[1], one = siblings[0]
        // The list reports its frames once a drag is on; begin at the row
        // as it lies before any of them is known. An open window folds to
        // its row while one is held, and opens again after.
        let shared = PaneSidebarSharedState.shared
        shared.unfoldedWindows = [a.paneSidebarState.windowID]
        await settle(0.4)
        drag.begin(two, siblings: siblings, in: a, screenY: 0)
        await settle(0.4)
        #expect(shared.unfoldedWindows.isEmpty, "every window folds while one is dragged")
        drag.end(commit: false)
        await settle(0.5)
        #expect(a.paneSidebarSections.first { $0.project == "alpha" }?.windows.map(\.label) == ["one", "two"],
                "cancelled: nothing moved")
        #expect(shared.unfoldedWindows == [a.paneSidebarState.windowID], "the open window opens again")
        shared.unfoldedWindows = []
        await settle(0.4)

        // For real: grab the row at its middle (frames from the cancelled
        // look), and move it up past `one`'s middle.
        drag.begin(two, siblings: siblings, in: a, screenY: 0)
        await settle(0.3)
        let twoY = try screenY(of: two, in: a, fraction: 0.15)
        drag.end(commit: false)
        await settle(0.5)
        drag.begin(two, siblings: siblings, in: a, screenY: twoY)
        await settle(0.4)
        #expect(drag.liftOffset(two).map { abs($0) < 1 } == true, "grabbed in place: \(String(describing: drag.liftOffset(two)))")
        let oneTop = try screenY(of: one, in: a, fraction: 0.1)
        drag.move(screenY: oneTop)
        await settle(0.4)
        #expect(drag.destination == .group("alpha", index: 0), "above one: \(String(describing: drag.destination))")
        #expect(drag.shift(one) > 0, "one slides down to make room")
        #expect((drag.liftOffset(two) ?? 0) < -10, "two follows the pointer up")
        drag.end(commit: true)
        await settle(0.6)
        #expect(!drag.isDragging, "settled")
        for viewer in [a, other] {
            #expect(viewer.paneSidebarSections.first { $0.project == "alpha" }?.windows.map(\.label) == ["two", "one"],
                    "every window's list has the new order")
        }
        #expect(windows.map { $0.window?.frame } == frames, "no window moved")

        // `gamma` (a group) above `alpha`: every group folds while held.
        PaneSidebarSharedState.shared.foldedProjects = ["beta"]
        await settle(0.4)
        let tops = a.paneSidebarSections.map(\.id)
        #expect(tops == ["project:alpha", "project:beta", "project:gamma"])
        let gamma = "project:gamma"
        // A cancelled group drag folds and puts the folds back.
        drag.begin(gamma, siblings: tops, in: a, screenY: 0)
        await settle(0.4)
        #expect(PaneSidebarSharedState.shared.foldedProjects == ["alpha", "beta", "gamma"])
        drag.end(commit: false)
        await settle(0.6)
        #expect(PaneSidebarSharedState.shared.foldedProjects == ["beta"], "a cancelled drag puts the folds back")
        // Where gamma's header is, unfolded, from a look that folds nothing
        // (a window's drag reports every item's frame): its top part.
        drag.begin(siblings[0], siblings: siblings, in: a, screenY: 0)
        await settle(0.3)
        let gammaY = try screenY(of: gamma, in: a, fraction: 0.15)
        drag.end(commit: false)
        await settle(0.5)
        drag.begin(gamma, siblings: tops, in: a, screenY: gammaY)
        await settle(0.5)
        #expect(PaneSidebarSharedState.shared.foldedProjects == ["alpha", "beta", "gamma"], "every group folds")
        // The folded headers have moved up; gamma stays under the pointer.
        let lifted = try #require(a.paneSidebarHost?.geometry.itemFrames[gamma])
        let drawnTop = lifted.minY + (drag.liftOffset(gamma) ?? 0)
        let pointer = try #require(a.paneSidebarHost?.sidebarY(screenY: gammaY))
        #expect(pointer >= drawnTop && pointer <= drawnTop + lifted.height + 1,
                "gamma's header is under the pointer: \(drawnTop)…\(drawnTop + lifted.height) vs \(pointer)")
        let alphaY = try screenY(of: "project:alpha", in: a, fraction: 0.1)
        drag.move(screenY: alphaY)
        await settle(0.4)
        #expect(drag.target == 0, """
            above alpha: target \(String(describing: drag.target)), top \(drag.top), \
            pointer \(String(describing: a.paneSidebarHost?.sidebarY(screenY: alphaY))), \
            frames \(a.paneSidebarHost?.geometry.itemFrames.filter { $0.key.hasPrefix("project:") } ?? [:])
            """)
        drag.end(commit: true)
        await settle(0.8)
        #expect(a.paneSidebarSections.map(\.id) == ["project:gamma", "project:alpha", "project:beta"])
        #expect(other.paneSidebarSections.map(\.id) == ["project:gamma", "project:alpha", "project:beta"])
        #expect(PaneSidebarSharedState.shared.foldedProjects == ["beta"], "the folds are back")
        #expect(windows.map { $0.window?.frame } == frames, "no window moved")
        // Persisted: the shared order is what a relaunch reads.
        let stored = PaneSidebarSharedState.shared.defaults.stringArray(forKey: PaneSidebarSharedState.windowOrderKey) ?? []
        #expect(stored.filter { $0.hasPrefix("project:") } == ["project:gamma", "project:alpha", "project:beta"])
        await close(windows, restoring: saved)
    }

    /// A window dragged into another group takes its name, `<project>: `;
    /// one dragged out to the top level loses it. Every window's list agrees.
    @Test func dragMovesAWindowIntoAndOutOfAGroup() async throws {
        let saved = save()
        let windows = try await open(["alpha: one", "alpha: two", "beta: main", "solo"])
        let a = windows[0], other = windows[3]
        a.paneSidebarState.showsAllWindows = true
        await settle(0.8)
        let drag = PaneSidebarItemDrag.shared
        let key = { (c: TerminalController) in PaneSidebarWindowGrouping.key(window: c.paneSidebarState.windowID) }
        let one = key(windows[0]), main = key(windows[2])
        // `main` open: grabbed at its middle, it folds to its row under the
        // pointer, not above it.
        PaneSidebarSharedState.shared.unfoldedWindows = [windows[2].paneSidebarState.windowID]
        await settle(0.4)

        // Frames come only with a drag on: a look first, then the real one,
        // grabbed at its middle.
        drag.begin(main, siblings: [main], in: a, screenY: 0)
        await settle(0.4)
        // Half a row below its folded row: inside its open pane list.
        let mainY = try screenY(of: main, in: a, fraction: 1.5)
        drag.end(commit: false)
        await settle(0.5)
        drag.begin(main, siblings: [main], in: a, screenY: mainY)
        await settle(0.5)
        let held = try #require(a.paneSidebarHost?.geometry.itemFrames[main])
        let drawnTop = held.minY + (drag.liftOffset(main) ?? 0)
        let pointer = try #require(a.paneSidebarHost?.sidebarY(screenY: mainY))
        #expect(pointer >= drawnTop && pointer <= drawnTop + held.height + 1,
                "folded under the pointer: \(drawnTop)…\(drawnTop + held.height) vs \(pointer)")
        // Its middle at `one`'s bottom: between `one` and `two`.
        drag.move(screenY: try screenY(of: one, in: a, fraction: 1))
        await settle(0.4)
        #expect(drag.destination == .group("alpha", index: 1), "\(String(describing: drag.destination))")
        drag.end(commit: true)
        await settle(0.8)
        #expect(windows[2].windowTitleOverride == "alpha: main")
        for viewer in [a, other] {
            #expect(viewer.paneSidebarSections.first { $0.project == "alpha" }?.windows.map(\.label)
                    == ["one", "main", "two"], "every window's list has it in alpha")
            #expect(!viewer.paneSidebarSections.contains { $0.project == "beta" }, "beta is gone")
        }

        // `one` out, past `solo` at the end of the list.
        drag.begin(one, siblings: [one], in: a, screenY: 0)
        await settle(0.4)
        let oneY = try screenY(of: one, in: a)
        let end = try screenY(of: key(other), in: a, fraction: 1)
        drag.end(commit: false)
        await settle(0.5)
        drag.begin(one, siblings: [one], in: a, screenY: oneY)
        await settle(0.4)
        drag.move(screenY: end)
        await settle(0.4)
        #expect(drag.destination == .topLevel(index: 2), "\(String(describing: drag.destination))")
        drag.end(commit: true)
        await settle(0.8)
        #expect(windows[0].windowTitleOverride == "one")
        #expect(a.paneSidebarSections.map(\.id) == ["project:alpha", key(other), one])
        #expect(other.paneSidebarSections.map(\.id) == ["project:alpha", key(other), one])
        await close(windows, restoring: saved)
    }

    // MARK: Captures (a check by eye: /tmp/pane-sidebar-snapshots/reorder-*.png)

    private func capture(_ window: NSWindow, _ name: String) async throws {
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
            .write(to: URL(fileURLWithPath: "\(dir)/reorder-\(name).png"))
    }

    @Test func reorderCaptures() async throws {
        let saved = save()
        let windows = try await open(["Notes", "Build", "alpha: one", "alpha: two", "beta: main", "gamma: main"],
                                     size: NSSize(width: 900, height: 620))
        let a = windows[0]
        let window = try #require(a.window)
        a.paneSidebarState.showsAllWindows = true
        PaneSidebarSharedState.shared.foldedProjects = ["alpha", "beta", "gamma"]
        await settle(0.8)
        try await capture(window, "0-folded")
        let drag = PaneSidebarItemDrag.shared
        let tops = a.paneSidebarSections.map(\.id)
        // Frames from a look that folds nothing.
        let notes = G.key(window: a.paneSidebarState.windowID)
        drag.begin(notes, siblings: tops, in: a, screenY: 0)
        await settle(0.3)
        let gammaY = try screenY(of: "project:gamma", in: a)
        let topY = try screenY(of: tops[0], in: a, fraction: 0.1)
        drag.end(commit: false)
        await settle(0.5)
        drag.begin("project:gamma", siblings: tops, in: a, screenY: gammaY)
        for (i, t) in [0.03, 0.08, 0.15, 0.3].enumerated() {
            await settle(t)
            try await capture(window, "1-group-begin-\(i)")
        }
        for step in 1...4 {
            drag.move(screenY: gammaY + (topY - gammaY) * CGFloat(step) / 4)
            await settle(0.06)
            try await capture(window, "2-group-move-\(step)")
            await settle(0.4)
            try await capture(window, "2-group-rest-\(step)")
        }
        drag.end(commit: true)
        await settle(0.05)
        try await capture(window, "3-group-drop")
        await settle(0.8)
        try await capture(window, "4-group-settled")

        // A window in an open group, dragged a step at a time.
        PaneSidebarSharedState.shared.foldedProjects = []
        await settle(0.6)
        let alpha = try #require(a.paneSidebarSections.first { $0.project == "alpha" }).windows.map(\.key)
        drag.begin(alpha[1], siblings: alpha, in: a, screenY: 0)
        await settle(0.3)
        let twoY = try screenY(of: alpha[1], in: a, fraction: 0.3)
        let oneY = try screenY(of: alpha[0], in: a, fraction: 0.1)
        drag.end(commit: false)
        await settle(0.5)
        drag.begin(alpha[1], siblings: alpha, in: a, screenY: twoY)
        await settle(0.3)
        var trace: [String] = []
        for step in 1...8 {
            drag.move(screenY: twoY + (oneY - twoY) * CGFloat(step) / 8)
            await settle(0.03)
            trace.append("\(step): top \(drag.top) lift \(drag.liftOffset(alpha[1]) ?? .nan) target \(drag.target ?? -1)")
            if step % 2 == 0 { try await capture(window, "5-window-move-\(step)") }
        }
        print("WINDOW-DRAG-TRACE\n" + trace.joined(separator: "\n"))
        drag.end(commit: true)
        await settle(0.05)
        try await capture(window, "6-window-drop")
        await settle(0.6)
        try await capture(window, "7-window-settled")
        await close(windows, restoring: saved)
    }

    private typealias G = PaneSidebarWindowGrouping
}
