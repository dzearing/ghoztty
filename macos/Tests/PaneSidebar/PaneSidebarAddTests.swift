import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

/// A project group's +: the placeholder name it gives its new window.
struct PaneSidebarNewWindowNameTests {
    @Test func theFirstIsPlainNew() {
        #expect(PaneSidebarNewWindowName.title(project: "ghoztty", existing: []) == "ghoztty: new")
        #expect(PaneSidebarNewWindowName.title(
            project: "ghoztty", existing: ["ghoztty: main", "other: new"]) == "ghoztty: new")
    }

    @Test func aTakenNameCountsUpToTheFirstFreeOne() {
        #expect(PaneSidebarNewWindowName.title(
            project: "ghoztty", existing: ["ghoztty: new"]) == "ghoztty: new-2")
        #expect(PaneSidebarNewWindowName.title(
            project: "ghoztty", existing: ["ghoztty: new", "ghoztty: new-2", "ghoztty: new-3"]) == "ghoztty: new-4")
        // A gap is reused.
        #expect(PaneSidebarNewWindowName.title(
            project: "ghoztty", existing: ["ghoztty: new", "ghoztty: new-3"]) == "ghoztty: new-2")
    }

    @Test func itLandsInTheGroup() throws {
        let title = PaneSidebarNewWindowName.title(project: "my proj", existing: ["my proj: new"])
        let parts = try #require(PaneSidebarWindowGrouping.split(title))
        #expect(parts.project == "my proj")
        #expect(parts.worktree == "new-2")
    }
}

/// The three + buttons in REAL windows, and the last-split-direction memory
/// the window row's + repeats: set by a split made by hand, never by
/// `ghoztty +split`.
@MainActor
@Suite(.serialized)
struct PaneSidebarAddWindowTests {
    private func settle(_ seconds: TimeInterval = 0.3) async {
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

    private var ghostty: Ghostty.App {
        get throws { try #require((NSApp.delegate as? AppDelegate)?.ghostty) }
    }

    private func window(
        title: String, config: Ghostty.SurfaceConfiguration? = nil
    ) async throws -> (TerminalController, PaneView) {
        let ghostty = try self.ghostty
        let app = try #require(ghostty.app)
        var config = config ?? Ghostty.SurfaceConfiguration()
        if config.command == nil { config.command = "/bin/cat" }
        let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        controller.windowTitleOverride = title
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        await settle(0.5)
        return (controller, pane)
    }

    private func terminalWindows() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.filter { $0.windowController is TerminalController && $0.isVisible }
            .map(ObjectIdentifier.init))
    }

    /// The window that appeared since `before`.
    private func newWindow(since before: Set<ObjectIdentifier>) async -> TerminalController? {
        var found: TerminalController?
        _ = await poll(timeout: 10) {
            found = NSApp.windows.first {
                $0.isVisible && !before.contains(ObjectIdentifier($0)) && $0.windowController is TerminalController
            }?.windowController as? TerminalController
            return found != nil
        }
        return found
    }

    /// Brought forward and focused, as Cmd-N / Cmd-D do — key when the app
    /// is active, else (a test host in the background can't take key) the
    /// front window, never ordered in behind the others.
    private func isFocused(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isKeyWindow
            || (!NSApp.isActive && NSApp.orderedWindows.first { $0.isVisible } === window)
    }

    private func samePath(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return URL(fileURLWithPath: a).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    /// Where `pane` sits in its window's grid (top-left origin).
    private func slot(_ pane: PaneView, in controller: BaseTerminalController) -> CGRect? {
        controller.surfaceTree.root?.spatial(within: CGSize(width: 100, height: 100)).slots.first {
            if case .leaf(let view) = $0.node { return view === pane }
            return false
        }?.bounds
    }

    private func run(_ action: String, _ arguments: [String]) async throws -> IPCResponse {
        let server = try #require((NSApp.delegate as? AppDelegate)?.ipcServer)
        let request = IPCRequest(action: action, arguments: arguments, callerPane: nil)
        return await Task.detached { server.dispatch(request) }.value
    }

    /// Click the rail's topmost + (its only item button: an 18pt circle)
    /// in `main`'s collapsed sidebar, in the given scope.
    private func clickRailsPlus(_ main: BaseTerminalController, allWindows: Bool) async throws {
        main.paneSidebarState.isHidden = false
        main.setPaneSidebarExpanded(false)
        main.paneSidebarState.showsAllWindows = allWindows
        await settle(0.8)
        let window = try #require(main.window)
        let content = try #require(window.contentView)
        func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
        }
        let plus = try #require(all(HoverTrackingArea.View.self, in: content)
            .filter { $0.window != nil && abs($0.bounds.width - PaneSidebarItemButton.size) < 1 }
            .max { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY },
            "no + in the rail")
        let frame = plus.convert(plus.bounds, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
            await settle(0.05)
        }
    }

    /// This window's rail: its + is the window header's (where it is when
    /// expanded) — a pane in this window, not a new window.
    @Test func theRailsPlusAddsAPaneInThisWindow() async throws {
        let (main, _) = try await window(title: "Rail Plus Pane")
        let before = terminalWindows()
        try await clickRailsPlus(main, allWindows: false)
        #expect(await poll(timeout: 5) { main.surfaceTree.count == 2 }, "the rail's + added no pane")
        await settle(0.5)
        #expect(terminalWindows() == before, "no window was opened")
        main.close()
        await settle(0.3)
    }

    /// All windows' rail: its + is the panel header's — a new window, as
    /// Cmd-N — not a pane in this one.
    @Test func theAllWindowsRailsPlusOpensAWindow() async throws {
        let (main, _) = try await window(title: "Rail Plus Window")
        let before = terminalWindows()
        try await clickRailsPlus(main, allWindows: true)
        let created = try #require(await newWindow(since: before), "the rail's + opened no window")
        #expect(main.surfaceTree.count == 1, "no pane was added to this window")
        #expect(created.surfaceTree.count == 1)
        main.paneSidebarState.showsAllWindows = false
        created.close()
        main.close()
        await settle(0.3)
    }

    @Test func theHeadersPlusOpensAFocusedWindowAsCmdNDoes() async throws {
        let ghostty = try self.ghostty
        let (main, _) = try await window(title: "Plus Main")
        let before = terminalWindows()

        BaseTerminalController.newWindowFromSidebar(ghostty, from: main)
        let created = try #require(await newWindow(since: before))
        #expect(await poll(timeout: 5) { isFocused(created.window) }, "focused, as Cmd-N")
        #expect(created.surfaceTree.count == 1)
        #expect(created.windowTitleOverride == nil, "no pinned title")
        created.close()
        main.close()
        await settle(0.3)
    }

    @Test func aGroupsPlusOpensATitledWindowInTheGroupInItsFirstWindowsDirectory() async throws {
        let ghostty = try self.ghostty
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-plus-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The group's first window reports its directory (OSC 7), as a shell
        // with integration does.
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = dir.path
        config.command = "/bin/sh -c 'printf \"\\033]7;file://localhost\(dir.path)\\007\"; exec cat'"
        let (one, onePane) = try await window(title: "plusproj: one", config: config)
        let (taken, _) = try await window(title: "plusproj: new")
        #expect(await poll(timeout: 5) { samePath(onePane.surfaceView?.pwd, dir.path) }, "\(onePane.surfaceView?.pwd ?? "nil")")
        let before = terminalWindows()

        BaseTerminalController.newWindowInGroupFromSidebar(ghostty, project: "plusproj", from: one)
        let created = try #require(await newWindow(since: before))
        #expect(created.windowTitleOverride == "plusproj: new-2", "a free placeholder in the group")
        #expect(PaneSidebarWindowGrouping.split(PaneSidebarText.windowTitle(of: created))?.project == "plusproj")
        #expect(await poll(timeout: 5) { isFocused(created.window) }, "focused, as Cmd-N")
        let pane = try #require(created.surfaceTree.first)
        #expect(await poll(timeout: 10) { samePath(pane.surfaceView?.pwd, dir.path) },
                "started in the group's first window's directory: \(pane.surfaceView?.pwd ?? "nil")")
        created.close()
        one.close()
        taken.close()
        await settle(0.3)
    }

    @Test func aWindowRowsPlusSplitsTheWayTheLastManualSplitWent() async throws {
        PaneSplitMemory.reset()
        defer { PaneSplitMemory.reset() }
        let (main, first) = try await window(title: "Plus Split")
        let (other, _) = try await window(title: "Plus Other")
        other.window?.makeKeyAndOrderFront(nil)
        await settle(0.3)

        // Default: right — and the window comes forward with the new pane focused.
        #expect(PaneSplitMemory.lastManual == .right)
        main.addPaneFromSidebar()
        #expect(await poll(timeout: 5) { main.surfaceTree.count == 2 })
        let second = try #require(main.surfaceTree.first { $0 !== first })
        #expect(await poll(timeout: 5) { isFocused(main.window) }, "its window raised")
        #expect(await poll(timeout: 5) { main.focusedSurface === second.surfaceView }, "the new pane focused")
        var a = try #require(slot(first, in: main)), b = try #require(slot(second, in: main))
        #expect(b.minX >= a.maxX - 0.5 && b.minY == a.minY, "to the right: \(a) \(b)")

        // A split by hand (the Split Down menu item / Cmd-Shift-D) is remembered...
        main.splitDown(self)
        #expect(await poll(timeout: 5) { main.surfaceTree.count == 3 })
        #expect(PaneSplitMemory.lastManual == .down)

        // ...and a script's `ghoztty +split` is not.
        let response = try await run("split", ["--target=\(first.id.uuidString)", "--direction=left", "--command=/bin/cat"])
        #expect(response.success, "\(response.error ?? "")")
        #expect(await poll(timeout: 5) { main.surfaceTree.count == 4 })
        #expect(PaneSplitMemory.lastManual == .down, "a programmatic split leaves it alone")

        // So the + now splits the focused pane down.
        let focused = try #require(main.surfaceTree.first { $0.surfaceView === main.focusedSurface })
        let existing = Set(main.surfaceTree.map(ObjectIdentifier.init))
        main.addPaneFromSidebar()
        #expect(await poll(timeout: 5) { main.surfaceTree.count == 5 })
        let added = try #require(main.surfaceTree.first { !existing.contains(ObjectIdentifier($0)) })
        a = try #require(slot(focused, in: main))
        b = try #require(slot(added, in: main))
        #expect(b.minY >= a.maxY - 0.5 && b.minX == a.minX, "below: \(a) \(b)")
        #expect(await poll(timeout: 5) { main.focusedSurface === added.surfaceView })

        main.close()
        other.close()
        await settle(0.3)
    }
}
