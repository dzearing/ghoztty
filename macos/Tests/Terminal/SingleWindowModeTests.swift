import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

/// `macos-window-mode = single`: one `NSWindow`, every window a workspace in
/// it (`WorkspaceHost`). Real controllers in the test host, the mode forced
/// with `WindowMode.overrideForTesting`. See docs/reference/window-modes.md.
@MainActor
@Suite(.serialized)
final class SingleWindowModeTests {
    private var opened: [TerminalController] = []

    init() {
        WindowMode.overrideForTesting = .single
        WorkspaceHost.shared.resetForTesting()
    }

    deinit {
        MainActor.assumeIsolated {
            for controller in opened.reversed() where !controller.windowHasClosed {
                if controller.isParked {
                    controller.forceCloseWindow()
                } else {
                    controller.heldWindow?.close()
                }
            }
            for controller in opened {
                for pane in controller.surfaceTree { pane.surfaceView?.releaseClosedSurface() }
            }
            WorkspaceHost.shared.resetForTesting()
            WindowMode.overrideForTesting = nil
        }
    }

    // MARK: Helpers

    private var ghostty: Ghostty.App {
        get throws { try #require((NSApp.delegate as? AppDelegate)?.ghostty) }
    }

    private func terminal(_ command: String = "/bin/cat") throws -> PaneView {
        let app = try #require(try ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        return PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
    }

    /// A workspace with one terminal, opened as a script opens a window (in
    /// the background) unless `activate`. The first one loads the window.
    private func workspace(activate: Bool = false) async throws -> (TerminalController, PaneView) {
        let pane = try terminal()
        let controller = TerminalController.newWindow(
            try ghostty, tree: SplitTree<PaneView>(view: pane), activate: activate)
        opened.append(controller)
        if controller.isParked {
            // Laid out at the window's size before it is asked about.
            _ = await poll(timeout: 5) { controller.contentContainer != nil }
        } else {
            _ = await poll(timeout: 10) { controller.window?.isVisible == true }
            let window = try #require(controller.window)
            window.setContentSize(NSSize(width: 1000, height: 600))
            WindowInUse.setInUseForTesting(window, true)
        }
        return (controller, pane)
    }

    private var host: WorkspaceHost { WorkspaceHost.shared }

    private func terminalWindows() -> [NSWindow] {
        NSApp.windows.filter {
            ($0.windowController as? TerminalController).map { host.manages($0) } == true && $0.isVisible
        }
    }

    private func run(_ action: String, _ arguments: [String]) async throws -> IPCResponse {
        let server = try #require((NSApp.delegate as? AppDelegate)?.ipcServer)
        let request = IPCRequest(action: action, arguments: arguments, callerPane: nil)
        return await Task.detached { server.dispatch(request) }.value
    }

    private func screen(_ pane: PaneView) async throws -> String {
        let response = try await run("read", ["--name=\(pane.id.uuidString)", "--lines=20"])
        guard case .readResult(let result)? = response.data else { return "" }
        return result.text
    }

    private func listed() async throws -> [IPCData.WindowData] {
        let response = try await run("list", [])
        guard case .listState(let state)? = response.data else { return [] }
        return state.windows
    }

    /// Wait for `text` on `pane`'s screen (`+read`).
    private func waitForScreen(_ pane: PaneView, _ text: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await screen(pane).contains(text) { return true }
            await settle(0.1)
        }
        return false
    }

    private func released(_ pane: PaneView) throws -> Bool {
        ghostty_surface_frame_memory(try #require(pane.surface)).released
    }

    // MARK: Switching

    /// One window, whichever workspace is on show: switching hands the same
    /// `NSWindow` (and only it) from one controller to the other, with each
    /// one's content view whole and its panes untouched.
    @Test func aSwitchHandsTheOneWindowOver() async throws {
        let (a, paneA) = try await workspace()
        let (b, paneB) = try await workspace()
        let window = try #require(a.window)

        #expect(!a.isParked)
        #expect(b.isParked)
        #expect(b.window == nil, "a parked workspace has no window")
        #expect(host.active === a)
        #expect(terminalWindows().count == 1)
        #expect(paneB.contentView.window == nil)
        #expect(paneB.contentView.frame.width > 100, "a parked pane is laid out at the window's size")

        let containerA = try #require(a.contentContainer)
        let containerB = try #require(b.contentContainer)
        #expect(host.show(b))

        #expect(window.windowController === b)
        #expect(window.delegate === b)
        #expect(window.contentView === containerB)
        #expect(b.window === window)
        #expect(a.isParked && a.window == nil)
        #expect(a.contentContainer === containerA, "the parked workspace keeps its content")
        #expect(paneB.contentView.window === window)
        #expect(paneA.contentView.window == nil)
        #expect(a.surfaceTree.contains(where: { $0 === paneA }))
        #expect(terminalWindows().count == 1, "still one window")
        #expect(host.active === b)
        #expect(host.workspaces.first === b, "most recently shown first")

        // And back.
        #expect(host.show(a))
        #expect(window.windowController === a)
        #expect(paneA.contentView.window === window)
        #expect(b.isParked)
    }

    /// A switch fades the old workspace's gradient out over the new one's.
    @Test func aSwitchFadesTheShade() async throws {
        let (a, _) = try await workspace()
        let (b, _) = try await workspace()
        a.deskVariant = PaneDeskVariant(seed: 1)
        b.deskVariant = PaneDeskVariant(seed: 2)
        host.show(b)
        #expect(b.deskEntrance?.from == PaneDeskVariant(seed: 1))
        #expect(await poll(timeout: 2) { b.deskEntrance == nil }, "the fade is cleared when done")
    }

    /// Tab navigation walks the workspaces in the sidebar's order.
    @Test func nextAndPreviousTabWalkTheWorkspaces() async throws {
        let (a, _) = try await workspace()
        let (b, _) = try await workspace()
        let (c, _) = try await workspace()
        let order = TerminalController.sidebarOrder(host.workspaces)
        #expect(order.count == 3)
        let start = try #require(order.firstIndex { $0 === a })
        a.gotoWorkspace(GHOSTTY_GOTO_TAB_NEXT.rawValue, host: host)
        #expect(host.active === order[(start + 1) % 3])
        host.active?.gotoWorkspace(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue, host: host)
        #expect(host.active === a)
        _ = (b, c)
    }

    // MARK: Parking

    /// A parked workspace's terminals give back their frames and draw
    /// nothing while their programs print; on show again they draw.
    @Test func parkedTerminalsDoNotDraw() async throws {
        let (a, paneA) = try await workspace()
        let (b, _) = try await workspace()
        let window = try #require(a.window)
        #expect(await poll(timeout: 5) { WindowInUse.isOnScreen(window) })
        #expect(await poll(timeout: 5) { (try? self.released(paneA)) == false }, "the pane on show never drew")

        host.show(b)
        #expect(await poll(timeout: 1.5) { (try? self.released(paneA)) == true }, "a parked terminal kept its frames")
        paneA.surfaceView?.surfaceModel?.sendText("printed while parked\r")
        await settle(1)
        #expect(try released(paneA), "a parked terminal drew")

        host.show(a)
        #expect(await poll(timeout: 5) { (try? self.released(paneA)) == false }, "a terminal back on show did not draw")
        #expect(try await waitForScreen(paneA, "printed while parked"))
    }

    /// A workspace parked from birth never draws, and a split added to it
    /// while parked is laid out (not left at zero size).
    @Test func aWorkspaceParkedFromBirthStaysQuiet() async throws {
        _ = try await workspace()
        let (b, paneB) = try await workspace()
        await settle(0.5)
        #expect(try released(paneB) || ghostty_surface_frame_memory(try #require(paneB.surface)).target_bytes == 0)

        let split = try await run("split", ["--target=\(paneB.id.uuidString)", "--name=side", "--command=/bin/cat"])
        #expect(split.success, "\(split.error ?? "")")
        #expect(await poll(timeout: 5) { b.surfaceTree.count == 2 })
        let side = try #require(b.surfaceTree.first { $0 !== paneB })
        #expect(await poll(timeout: 5) { side.contentView.frame.width > 100 })
        #expect(b.isParked, "a split never puts a workspace on show")
    }

    // MARK: CLI

    /// From the CLI nothing changed: a parked workspace is a window to
    /// `+list`, `--target`, `+split`, `+send-keys`, `+read`, `+stash`,
    /// `+restore` and `+close` — and none of them puts it on show.
    @Test func theCLIAddressesAParkedWorkspace() async throws {
        let (a, _) = try await workspace()
        let opened = try await run("new-window", ["--target=parked-bee", "--command=/bin/cat"])
        #expect(opened.success)
        var bee: TerminalController?
        #expect(await poll(timeout: 5) {
            bee = TerminalController.all.first { $0.windowName == "parked-bee" }
            return bee != nil
        })
        let b = try #require(bee)
        self.opened.append(b)
        #expect(b.isParked)
        #expect(host.active === a, "a background +new-window does not switch")

        let windows = try await listed()
        let targets = windows.compactMap(\.target)
        #expect(targets.contains("parked-bee"))
        #expect(targets.contains(a.windowName))
        #expect(windows.filter(\.focused).count == 1)
        #expect(windows.first { $0.target == a.windowName }?.focused == true)
        let beeRow = try #require(windows.first { $0.target == "parked-bee" })
        // The same id on show or parked.
        #expect(beeRow.id == ScriptWindow.stableID(primaryController: b))

        let split = try await run("split", ["--target=parked-bee", "--name=helper", "--command=/bin/cat"])
        #expect(split.success, "\(split.error ?? "")")
        #expect(await poll(timeout: 5) { b.surfaceTree.count == 2 })

        let keys = try await run("send-keys", ["--target=helper", "--keys=hello-parked\n"])
        #expect(keys.success, "\(keys.error ?? "")")
        let helper = try #require(b.surfaceTree.first { $0.surfaceView != nil && $0 !== b.surfaceTree.first })
        #expect(try await waitForScreen(helper, "hello-parked"))

        let stash = try await run("stash", ["--target=helper"])
        #expect(stash.success, "\(stash.error ?? "")")
        #expect(b.surfaceTree.isStashed(helper))
        let restore = try await run("restore", ["--target=helper"])
        #expect(restore.success, "\(restore.error ?? "")")
        #expect(!b.surfaceTree.isStashed(helper))

        #expect(host.active === a, "no command put the parked workspace on show")
        #expect(b.isParked)

        let close = try await run("close", ["--target=parked-bee"])
        #expect(close.success, "\(close.error ?? "")")
        #expect(await poll(timeout: 5) { b.windowHasClosed })
        #expect(!host.manages(b))
        #expect(host.active === a)
        #expect(a.window?.isVisible == true)
    }

    /// `+close --force` on a parked workspace ends it at once, its terminals
    /// freed, and leaves the one on show alone.
    @Test func forceClosingAParkedWorkspace() async throws {
        let (a, _) = try await workspace()
        let (b, paneB) = try await workspace()
        let close = try await run("close", ["--target=\(b.windowName)", "--force"])
        #expect(close.success, "\(close.error ?? "")")
        #expect(b.windowHasClosed)
        #expect(paneB.surface == nil, "a forced close frees the terminal at once")
        #expect(host.active === a && a.window?.isVisible == true)
    }

    // MARK: Focus policy

    /// `--focus` puts a workspace on show — a new one, or an existing one
    /// found by name (the idempotent hit). Without it, nothing switches.
    @Test func focusPolicy() async throws {
        let (a, _) = try await workspace()
        let (b, _) = try await workspace()

        let hit = try await run("new-window", ["--target=\(b.windowName)"])
        #expect(hit.success)
        await settle(0.2)
        #expect(host.active === a, "an idempotent hit without --focus does nothing")

        let focused = try await run("new-window", ["--target=\(b.windowName)", "--focus"])
        #expect(focused.success)
        #expect(await poll(timeout: 2) { self.host.active === b })

        let fresh = try await run("new-window", ["--target=focused-new", "--command=/bin/cat", "--focus"])
        #expect(fresh.success)
        #expect(await poll(timeout: 5) { self.host.active?.windowName == "focused-new" })
        if let made = host.active { self.opened.append(made) }
        #expect(terminalWindows().count == 1)
    }

    // MARK: Closing

    /// Closing the workspace on show hands the window to the one shown
    /// before it; the last workspace's close closes the window.
    @Test func closingTheWorkspaceOnShowShowsTheLastOne() async throws {
        let (a, _) = try await workspace()
        let (b, _) = try await workspace()
        let (c, _) = try await workspace()
        let window = try #require(a.window)
        host.show(c)
        host.show(b)
        b.closeWindowImmediately()
        #expect(b.windowHasClosed)
        #expect(host.active === c, "the one shown before it")
        #expect(window.windowController === c)
        #expect(window.isVisible)

        c.closeWindowImmediately()
        #expect(host.active === a)
        a.closeWindowImmediately()
        #expect(await poll(timeout: 2) { !window.isVisible })
        #expect(host.workspaces.isEmpty)
    }

    /// The window's activity is every workspace's: a parked one waiting on
    /// a question is this window waiting on one. The title keeps only the
    /// workspace on show's own.
    @Test func theWindowReportsEveryWorkspacesActivity() async throws {
        let (a, _) = try await workspace()
        let (_, paneB) = try await workspace()
        let window = try #require(a.window as? TerminalWindow)
        let set = try await run("set-state", ["--target=\(paneB.id.uuidString)", "--state=needs_input"])
        #expect(set.success, "\(set.error ?? "")")
        #expect(await poll(timeout: 2) { window.activityState == .needsInput })
        #expect(a.activityState == .idle)
        #expect(!window.title.contains("question"))
    }

    // MARK: Restore

    /// AppKit restoration in single-window mode saves every workspace with
    /// the one window, and restores them as workspaces — or, read in
    /// `separate` mode, as windows of their own.
    @Test func appKitRestorationRoundTripsInBothModes() async throws {
        let (a, paneA) = try await workspace()
        let (b, paneB) = try await workspace()
        a.setWindowTitle("first")
        b.setWindowTitle("second")
        let window = try #require(a.window)

        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        a.window(window, willEncodeRestorableState: coder)
        coder.finishEncoding()
        let archive = coder.encodedData

        func restore() async throws -> [TerminalController] {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: archive)
            decoder.requiresSecureCoding = true
            var restored: [TerminalController] = []
            let before = Set(TerminalController.all.map(ObjectIdentifier.init))
            TerminalWindowRestoration.restoreWindow(
                withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
                state: decoder
            ) { _, _ in }
            await settle(0.3)
            restored = TerminalController.all.filter { !before.contains(ObjectIdentifier($0)) }
            self.opened.append(contentsOf: restored)
            return restored
        }

        // Read back in single-window mode, beside the two still open: both
        // come back, as parked workspaces.
        let single = try await restore()
        #expect(single.count == 2)
        let titles = Set(single.compactMap { $0.windowTitleOverride })
        #expect(titles == ["first", "second"])
        let allParked = single.allSatisfy { $0.isParked }
        #expect(allParked)
        let paneIDs = Set(single.flatMap { $0.surfaceTree.map(\.id) })
        #expect(paneIDs == [paneA.id, paneB.id])
        #expect(terminalWindows().count == 1)

        // Read back in separate mode: a window each.
        WindowMode.overrideForTesting = .separate
        defer { WindowMode.overrideForTesting = .single }
        let separate = try await restore()
        #expect(separate.count == 2)
        #expect(separate.allSatisfy { !$0.isParked && $0.window != nil })
        for controller in separate { controller.heldWindow?.close() }
    }

    /// A separate-mode archive (one window, no workspaces key) restores into
    /// single-window mode as a workspace.
    @Test func aSeparateModeArchiveRestoresAsAWorkspace() async throws {
        WindowMode.overrideForTesting = .separate
        let pane = try terminal()
        let own = TerminalController.newWindow(try ghostty, tree: SplitTree<PaneView>(view: pane))
        _ = await poll(timeout: 10) { own.window?.isVisible == true }
        let ownWindow = try #require(own.window)
        own.setWindowTitle("standalone")
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        own.window(ownWindow, willEncodeRestorableState: coder)
        coder.finishEncoding()
        ownWindow.close()

        WindowMode.overrideForTesting = .single
        let (a, _) = try await workspace()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
        decoder.requiresSecureCoding = true
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: decoder
        ) { _, _ in }
        await settle(0.3)
        let restored = try #require(host.workspaces.first { $0.windowTitleOverride == "standalone" })
        opened.append(restored)
        #expect(restored.isParked)
        #expect(host.active === a)
        #expect(terminalWindows().count == 1)
    }

    /// The session layout manifest records which window is in front — the
    /// workspace on show — and restore brings it back last, in either mode.
    @Test func theManifestRemembersTheWorkspaceOnShow() async throws {
        let (a, _) = try await workspace()
        let (b, _) = try await workspace()
        #expect(SessionLayoutManifest.isFrontmost(a))
        #expect(!SessionLayoutManifest.isFrontmost(b))
        host.show(b)
        #expect(SessionLayoutManifest.isFrontmost(b))
        #expect(!SessionLayoutManifest.isFrontmost(a))
    }
}

/// The manifest side of window modes, pure.
struct WindowModeManifestTests {
    private func entry(front: Bool?) -> SessionLayoutManifest.Entry {
        var entry = SessionLayoutManifest.Entry(id: UUID())
        entry.frontmost = front
        return entry
    }

    @Test func theFrontmostWindowIsRestoredLast() {
        let one = entry(front: nil), two = entry(front: true), three = entry(front: nil)
        let order = SessionLayoutManifest.frontmostLast([[one], [two], [three]]).map { $0[0].id }
        #expect(order == [one.id, three.id, two.id])
    }

    @Test func withNoFrontmostTheOrderIsAsWritten() {
        let one = entry(front: nil), two = entry(front: nil)
        let order = SessionLayoutManifest.frontmostLast([[one], [two]]).map { $0[0].id }
        #expect(order == [one.id, two.id])
    }

    /// Additive: a manifest written before the field decodes with nil, and
    /// one written with it round-trips.
    @Test func frontmostIsAdditive() throws {
        let old = #"{"id":"\#(UUID().uuidString)","tabIndex":0}"#
        let decoded = try JSONDecoder().decode(SessionLayoutManifest.Entry.self, from: Data(old.utf8))
        #expect(decoded.frontmost == nil)

        let written = entry(front: true)
        let data = try JSONEncoder().encode(written)
        #expect(try JSONDecoder().decode(SessionLayoutManifest.Entry.self, from: data).frontmost == true)
    }
}
