import AppKit
import SwiftUI
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
            // Forced: no undo, sessions ended now, session-layout entries
            // (a `+new-window` here is agent-backed) removed — and written
            // before the host can exit, or the debug app restores them.
            for controller in opened.reversed() where !controller.windowHasClosed {
                controller.forceCloseWindow()
            }
            for controller in opened {
                for pane in controller.surfaceTree { pane.surfaceView?.releaseClosedSurface() }
            }
            SessionLayoutManifest.shared.flushWrites()
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

        // A parked workspace keeps its title for `+list` and AppleScript.
        a.setWindowTitle("parked title")
        #expect(a.currentWindowTitle == "parked title")
        b.setWindowTitle("shown title")
        host.show(a)
        #expect(b.currentWindowTitle == "shown title", "the title it showed as it parked")
        host.show(b)

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

    /// Cmd-N pressed fast, as the key does it: the core's `new_window`
    /// from whichever terminal is on show at each press. Every press opens a
    /// workspace, they come on show in the order pressed, and the last one
    /// pressed ends on show — however the agent's replies interleave.
    @Test func rapidNewWindowKeepsUpInOrder() async throws {
        let ghostty = try self.ghostty
        // As a window opened by hand is: on the local agent (session
        // persistence), so a new window inherits its working directory
        // through an agent round trip.
        let first = TerminalController.newWindow(ghostty, withBaseConfig: nil, activate: true)
        opened.append(first)
        _ = await poll(timeout: 10) { first.window?.isVisible == true }
        _ = await poll(timeout: 10) { first.focusedSurface?.surface != nil }
        // Its agent session is up, as in a window someone has been using:
        // a new window from it asks the agent for its directory.
        let attached = await poll(timeout: 15) {
            first.focusedSurface.map { BaseTerminalController.remoteInheritance(of: $0).sessionId != nil } ?? false
        }
        try #require(attached, "the first window never got an agent session")
        let before = Set(host.workspaces.map(ObjectIdentifier.init))

        var shown: [ObjectIdentifier] = []
        var shownNames: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: WorkspaceHost.didSwitchNotification, object: nil, queue: nil
        ) { note in
            if let c = note.object as? TerminalController {
                shown.append(ObjectIdentifier(c))
                shownNames.append(c.windowName)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let presses = 8
        let started = Date()
        for _ in 0..<presses {
            let surface = try #require(host.active?.focusedSurface?.surface)
            ghostty.newWindow(surface: surface)
            await settle(0.04)
        }
        let made = await poll(timeout: 15) { self.host.workspaces.count - before.count == presses }
        let created = host.workspaces.filter { !before.contains(ObjectIdentifier($0)) }
        self.opened.append(contentsOf: created)
        #expect(made, "\(created.count) of \(presses) presses opened a workspace")
        await settle(0.5)
        let elapsed = Date().timeIntervalSince(started)

        // Created order: by window name (minted in creation order).
        let byName = created.sorted {
            (Int($0.windowName.dropFirst("window-".count)) ?? 0) < (Int($1.windowName.dropFirst("window-".count)) ?? 0)
        }
        let switches = shown.filter { id in created.contains { ObjectIdentifier($0) == id } }
        print("RAPID: \(created.count) workspaces in \(String(format: "%.2f", elapsed))s; created \(byName.map(\.windowName)); shown \(shownNames); active \(host.active?.windowName ?? "nil")")
        #expect(switches == byName.map(ObjectIdentifier.init), "workspaces came on show out of order")
        #expect(host.active === byName.last, "the last one pressed is not the one on show")
    }

    /// Workspaces with the same name (every new shell is `~`) stay in the
    /// order they were opened in the all-windows list, so a new one lands
    /// at the end of its namesakes and the selection follows it there —
    /// not at a random place among them.
    @Test func sameNamedWorkspacesKeepTheOrderTheyOpenedIn() async throws {
        var made: [TerminalController] = []
        for _ in 0..<6 {
            let (c, _) = try await workspace()
            c.setWindowTitle("same")
            made.append(c)
        }
        let listed = TerminalController.sidebarOrder(host.workspaces)
        #expect(listed.map(\.windowName) == made.map(\.windowName))
        // Showing one never reorders them.
        host.show(made[3])
        #expect(TerminalController.sidebarOrder(host.workspaces).map(\.windowName) == made.map(\.windowName))
    }

    /// Cmd-N puts the new workspace on show in the key's own turn — no
    /// agent round trip for a local window, no deferred presentation — so
    /// the next frame already shows it selected. Prints the time to drawn.
    @Test func newWindowIsOnShowInTheKeysTurn() async throws {
        let ghostty = try self.ghostty
        let first = TerminalController.newWindow(ghostty, withBaseConfig: nil, activate: true)
        opened.append(first)
        _ = await poll(timeout: 10) { first.window?.isVisible == true }
        let window = try #require(first.window)
        window.setContentSize(NSSize(width: 1400, height: 900))
        WindowInUse.setInUseForTesting(window, true)
        first.paneSidebarState.isHidden = false
        _ = await poll(timeout: 15) {
            first.focusedSurface.map { BaseTerminalController.remoteInheritance(of: $0).sessionId != nil } ?? false
        }
        // Its shell has reported its directory: what lets a new window
        // inherit it with no agent round trip.
        _ = await poll(timeout: 15) { first.focusedSurface?.pwd != nil }
        await settle(1)

        for round in 0..<4 {
            var marks: [(String, TimeInterval)] = []
            let t0 = CACurrentMediaTime()
            let mark = { (name: String) in marks.append((name, (CACurrentMediaTime() - t0) * 1000)) }
            let n1 = NotificationCenter.default.addObserver(
                forName: Ghostty.Notification.ghosttyNewWindow, object: nil, queue: nil) { _ in mark("action") }
            let n2 = NotificationCenter.default.addObserver(
                forName: WorkspaceHost.didSwitchNotification, object: nil, queue: nil) { _ in mark("switched") }
            let count = host.workspaces.count
            let surface = try #require(host.active?.focusedSurface?.surface)
            let previous = host.active
            ghostty.newWindow(surface: surface)
            #expect(host.workspaces.count == count + 1, "the workspace was not made in the key's turn")
            #expect(host.active !== previous, "the new workspace was not on show in the key's turn")
            var created = false
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && !marks.contains(where: { $0.0 == "switched" }) {
                if !created && host.workspaces.count > count { created = true; mark("created") }
                try? await Task.sleep(nanoseconds: 500_000)
            }
            window.displayIfNeeded()
            mark("drawn")
            NotificationCenter.default.removeObserver(n1)
            NotificationCenter.default.removeObserver(n2)
            print("LATENCY round \(round): " + marks.map { "\($0.0) \(String(format: "%.1f", $0.1))ms" }.joined(separator: ", "))
            if let made = host.active { opened.append(made) }
            await settle(0.5)
        }
    }

    /// Cmd-N then Cmd-W at once, before the new shell has drawn its first
    /// prompt: it closes with no "are you sure?" — nothing the user started
    /// can be running in a shell they have sent nothing to. Once they run
    /// something in it, closing asks again; an explicit command always asks.
    @Test func aShellClosedBeforeAnyInputDoesNotAsk() async throws {
        let ghostty = try self.ghostty
        let first = TerminalController.newWindow(ghostty, withBaseConfig: nil, activate: true)
        opened.append(first)
        _ = await poll(timeout: 10) { first.window?.isVisible == true }
        let window = try #require(first.window)
        _ = await poll(timeout: 15) {
            first.focusedSurface.map { BaseTerminalController.remoteInheritance(of: $0).sessionId != nil } ?? false
        }

        // Cmd-N, and Cmd-W as soon as the new workspace is on show.
        ghostty.newWindow(surface: try #require(first.focusedSurface?.surface))
        #expect(await poll(timeout: 5) { self.host.active !== first })
        let fresh = try #require(host.active)
        opened.append(fresh)
        let pane = try #require(fresh.surfaceTree.first)
        #expect(!pane.needsConfirmQuit, "a shell that has had no input asks to be confirmed")
        fresh.closeWindow(nil)
        #expect(window.attachedSheet == nil, "closing it put up a confirmation")
        #expect(fresh.windowHasClosed)
        #expect(host.active === first)

        // Run something in a shell: now its close is confirmed.
        ghostty.newWindow(surface: try #require(first.focusedSurface?.surface))
        #expect(await poll(timeout: 5) { self.host.active !== first })
        let used = try #require(host.active)
        opened.append(used)
        let usedPane = try #require(used.surfaceTree.first)
        _ = await poll(timeout: 10) { usedPane.surfaceView?.surface != nil }
        await settle(1.5)
        let typed = try await run("send-keys", ["--target=\(usedPane.id.uuidString)", "--keys=sleep 30\n"])
        #expect(typed.success, "\(typed.error ?? "")")
        #expect(await poll(timeout: 10) { usedPane.needsConfirmQuit }, "a shell running a command closed without asking")

        // An explicit command asks from the start.
        let commanded = try await run("new-window", ["--target=explicit-cmd", "--command=/bin/cat"])
        #expect(commanded.success)
        var withCommand: TerminalController?
        _ = await poll(timeout: 5) {
            withCommand = TerminalController.all.first { $0.windowName == "explicit-cmd" }
            return withCommand?.surfaceTree.first?.surfaceView?.surface != nil
        }
        let explicit = try #require(withCommand)
        opened.append(explicit)
        #expect(await poll(timeout: 5) { explicit.surfaceTree.first?.needsConfirmQuit == true })
    }

    /// A workspace whose row has stacked panes (blades) comes back on show
    /// exactly as it was left: no glide, the same panes on show.
    @Test func switchingBackDoesNotReplayTheStack() async throws {
        let (a, first) = try await workspace(activate: true)
        var tree = a.surfaceTree
        var last = first
        for _ in 0..<5 {
            let pane = try terminal()
            tree = try tree.inserting(view: pane, at: last, direction: .right)
            last = pane
        }
        a.surfaceTree = tree
        let window = try #require(a.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        await settle(1.5)

        func stage(_ c: TerminalController) -> PaneStageView? {
            func find(_ v: NSView) -> PaneStageView? {
                if let s = v as? PaneStageView { return s }
                for sub in v.subviews { if let s = find(sub) { return s } }
                return nil
            }
            return c.contentContainer.flatMap(find)
        }
        let stageA = try #require(stage(a))
        #expect(await poll(timeout: 5) { !stageA.isGlidingForTesting })
        let before = stageA.runsForTesting
        try #require(before?.count ?? 0 > 0)

        let (b, _) = try await workspace()
        host.show(b)
        await settle(0.5)
        var glided = false
        var runs: [String] = []
        host.show(a)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if stageA.isGlidingForTesting { glided = true }
            let r = String(describing: stageA.runsForTesting)
            if runs.last != r { runs.append(r) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(runs.count == 1, "the stack changed on the way back: \(runs)")
        #expect(!glided, "coming back on show replayed a glide")
        #expect(stageA.runsForTesting == before)
    }

    /// A pane's banner keeps the terminal below it across a switch away and
    /// back: the card never comes back floating over the text.
    @Test func aBannerStillHoldsTheTerminalBelowItAfterASwitch() async throws {
        let (a, paneA) = try await workspace(activate: true)
        let view = try #require(paneA.surfaceView)
        view.paneBanner = "**Title**\nGoal: one\nStatus: two"
        await settle(1)
        // How far down the pane the terminal starts.
        // How far down its pane the terminal starts: the SwiftUI host of the
        // surface, in the pane's own hosting view.
        func inset() -> CGFloat {
            var host: NSView? = view
            while let h = host, !String(describing: type(of: h)).contains("SurfaceRepresentable") {
                host = h.superview
            }
            guard let host, let pane = host.superview else { return -1 }
            return pane.isFlipped ? host.frame.minY : pane.bounds.height - host.frame.maxY
        }
        let before = inset()
        try #require(before > 20, "the banner did not push the terminal down: \(before)")

        let (b, _) = try await workspace()
        host.show(b)
        await settle(0.5)
        host.show(a)
        await settle(1)
        #expect(abs(inset() - before) < 1, "after a switch the terminal starts at \(inset()), not \(before)")

        // Cleared while parked: back on show with no banner, the terminal
        // starts at the top; a banner set again pushes it down again.
        host.show(b)
        await settle(0.5)
        view.paneBanner = nil
        await settle(0.3)
        host.show(a)
        await settle(1)
        #expect(inset() < 1, "a banner cleared while parked still holds the terminal down: \(inset())")
        view.paneBanner = "**Title**\nGoal: one\nStatus: two"
        await settle(1)
        #expect(abs(inset() - before) < 1, "a banner set again starts the terminal at \(inset()), not \(before)")
    }

    /// Hero mode over one pane, with the pane sidebar out of the window
    /// meanwhile (that window only; the shared flag is untouched).
    @Test func heroModeTurnsOnOverOnePaneWithoutTheSidebar() async throws {
        let (a, pane) = try await workspace(activate: true)
        a.paneSidebarState.isHidden = false
        let surface = try #require(pane.surfaceView)
        let wide = (width: CGFloat(1400), ())
        #expect(a.paneSidebarState.mode(windowWidth: wide.width) != .hidden)

        NotificationCenter.default.post(name: Ghostty.Notification.didToggleHeroMode, object: surface)
        #expect(await poll(timeout: 2) { a.heroModeState.isActive }, "hero mode refused a single pane")
        #expect(a.paneSidebarState.mode(windowWidth: wide.width) == .hidden)
        #expect(!a.paneSidebarState.isHidden, "hero mode hid every window's sidebar")
        #expect(a.heroModeState.carouselWidth(in: wide.width) == 130)

        NotificationCenter.default.post(name: Ghostty.Notification.didToggleHeroMode, object: surface)
        #expect(await poll(timeout: 2) { !a.heroModeState.isActive })
        #expect(a.paneSidebarState.mode(windowWidth: wide.width) != .hidden, "the sidebar did not come back")
    }

    /// In hero mode Cmd-Shift-Up/Down steps through the panes of the
    /// workspace on show — only its panes, never another workspace — with
    /// the stepped-to pane drawn, including after a switch away and back.
    @Test func heroModeCyclesTheWorkspacesPanes() async throws {
        let text = "/bin/sh -c 'i=0; while [ $i -lt 60 ]; do echo line $i of the pane; i=$((i+1)); done; cat'"
        let first = try terminal(text)
        let a = TerminalController.newWindow(try ghostty, tree: SplitTree<PaneView>(view: first), activate: true)
        opened.append(a)
        _ = await poll(timeout: 10) { a.window?.isVisible == true }
        let window = try #require(a.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        WindowInUse.setInUseForTesting(window, true)
        var tree = a.surfaceTree
        var last = first
        for _ in 0..<2 {
            let pane = try terminal(text)
            tree = try tree.inserting(view: pane, at: last, direction: .right)
            last = pane
        }
        a.surfaceTree = tree
        // A second workspace from the start: a keystroke that leaks to the
        // pane's own `goto_window` binding then shows as a switch.
        let (b, _) = try await workspace()
        #expect(host.active === a)
        await settle(1)
        window.makeFirstResponder(first.surfaceView)
        NotificationCenter.default.post(name: Ghostty.Notification.didToggleHeroMode, object: first.surfaceView)
        #expect(await poll(timeout: 2) { a.heroModeState.isActive })
        await settle(1)

        func press(_ key: NSEvent.SpecialKey) {
            let characters = String(key.unicodeScalar)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift, .function, .numericPad],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: key == .upArrow ? 126 : 125)
            else { Issue.record("no key event"); return }
            NSApp.sendEvent(event)
        }

        // Text on screen where the hero pane is: the left 60% of the window,
        // below the titlebar (the carousel is on the right).
        func heroShowsText() async throws -> Bool {
            let recorder = WindowFrameRecorder()
            try await recorder.start(window, scale: 1)
            await settle(0.4)
            let image = try #require(await recorder.stop().last?.1)
            let rep = NSBitmapImageRep(cgImage: image)
            var levels: [CGFloat] = []
            for y in stride(from: image.height / 5, to: image.height * 4 / 5, by: 3) {
                for x in stride(from: image.width / 10, to: image.width * 5 / 10, by: 3) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    levels.append((c.redComponent + c.greenComponent + c.blueComponent) / 3)
                }
            }
            guard let low = levels.min(), let high = levels.max() else { return false }
            return high - low > 0.3
        }

        // The hero is up once it draws: the keys go to its monitor only from
        // then on.
        var drawn = false
        for _ in 0..<10 where !drawn {
            drawn = try await heroShowsText()
        }
        if !drawn {
            let homes = a.surfaceTree.map { String(describing: $0.contentView.superview.map { type(of: $0) }) }
            Issue.record("hero panes' superviews: \(homes)")
        }
        #expect(drawn, "the hero pane is blank on entry")
        for (step, key) in [NSEvent.SpecialKey.downArrow, .downArrow, .upArrow, .upArrow].enumerated() {
            let before = a.heroModeState.selectedIndex
            let expected = key == .downArrow ? before + 1 : before - 1
            press(key)
            await settle(0.6)
            #expect(a.heroModeState.selectedIndex == expected, "step \(step): Cmd-Shift-\(key == .downArrow ? "Down" : "Up") did not move the hero")
            #expect(host.active === a, "step \(step): the chord in hero mode switched workspaces")
            #expect(try await heroShowsText(), "step \(step): pane \(a.heroModeState.selectedIndex) is blank in the hero")
        }

        // Away and back.
        host.show(b)
        await settle(4) // past the idle release
        host.show(a)
        await settle(1)
        #expect(try await heroShowsText(), "after a switch, the hero pane is blank")
        for (step, key) in [NSEvent.SpecialKey.downArrow, .downArrow, .upArrow, .upArrow].enumerated() {
            let before = a.heroModeState.selectedIndex
            let expected = key == .downArrow ? before + 1 : before - 1
            press(key)
            await settle(0.6)
            #expect(a.heroModeState.selectedIndex == expected, "after a switch, step \(step): Cmd-Shift-\(key == .downArrow ? "Down" : "Up") did not move the hero")
            #expect(host.active === a, "after a switch, step \(step): the chord in hero mode switched workspaces")
            #expect(try await heroShowsText(), "after a switch, step \(step): pane \(a.heroModeState.selectedIndex) is blank in the hero")
        }

        // Hero off: every terminal is back in the window's grid.
        NotificationCenter.default.post(name: Ghostty.Notification.didToggleHeroMode, object: a.focusedSurface ?? first.surfaceView)
        #expect(await poll(timeout: 2) { !a.heroModeState.isActive })
        #expect(await poll(timeout: 3) { a.surfaceTree.allSatisfy { $0.contentView.window === window } },
                "a terminal did not come back from hero mode: \(a.surfaceTree.map { String(describing: $0.contentView.superview.map { type(of: $0) }) })")
    }

    /// In hero mode Cmd-Shift-Up/Down never leaves the window: past the first
    /// or last pane, and over a single pane, the chord does nothing.
    @Test(arguments: [1, 3]) func heroModeKeepsTheChordInItsWindow(panes: Int) async throws {
        let first = try terminal()
        let a = TerminalController.newWindow(try ghostty, tree: SplitTree<PaneView>(view: first), activate: true)
        opened.append(a)
        _ = await poll(timeout: 10) { a.window?.isVisible == true }
        let window = try #require(a.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        var tree = a.surfaceTree
        var last = first
        for _ in 1..<panes {
            let pane = try terminal()
            tree = try tree.inserting(view: pane, at: last, direction: .right)
            last = pane
        }
        a.surfaceTree = tree
        _ = try await workspace()
        _ = try await workspace()
        #expect(host.active === a)
        await settle(1)
        window.makeFirstResponder(first.surfaceView)
        NotificationCenter.default.post(name: Ghostty.Notification.didToggleHeroMode, object: first.surfaceView)
        #expect(await poll(timeout: 2) { a.heroModeState.isActive })
        await settle(1)

        func press(_ key: NSEvent.SpecialKey) {
            let characters = String(key.unicodeScalar)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift, .function, .numericPad],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: key == .upArrow ? 126 : 125)
            else { Issue.record("no key event"); return }
            NSApp.sendEvent(event)
        }

        // Up from the first pane, down to and past the last, up past the first.
        let keys: [NSEvent.SpecialKey] = [.upArrow] + Array(repeating: .downArrow, count: panes + 1)
            + Array(repeating: .upArrow, count: panes + 1)
        for (step, key) in keys.enumerated() {
            press(key)
            await settle(0.4)
            #expect(host.active === a, "\(panes) pane(s), step \(step) (\(key == .upArrow ? "Up" : "Down")): the chord left the window")
            #expect(a.heroModeState.isActive)
        }
        #expect(a.heroModeState.selectedIndex == 0)
    }

    /// Cmd-Shift-Up/Down is `goto_window`, which walks the windows in the
    /// sidebar's all-windows order, wrapping.
    @Test func cmdShiftArrowsWalkTheSidebarsWindows() async throws {
        let ghostty = try self.ghostty
        let up = try #require(ghostty.config.keyboardShortcut(for: "goto_window:previous"))
        let down = try #require(ghostty.config.keyboardShortcut(for: "goto_window:next"))
        let upKey: KeyEquivalent = .upArrow, downKey: KeyEquivalent = .downArrow
        #expect(up.modifiers == [.command, .shift])
        #expect(up.key.character == upKey.character)
        #expect(down.modifiers == [.command, .shift])
        #expect(down.key.character == downKey.character)

        _ = try await workspace()
        _ = try await workspace()
        _ = try await workspace()
        let order = TerminalController.sidebarOrder(host.workspaces)
        host.show(order[0])
        BaseTerminalController.gotoWindow(offset: 1)
        #expect(host.active === order[1])
        BaseTerminalController.gotoWindow(offset: -1)
        BaseTerminalController.gotoWindow(offset: -1)
        #expect(host.active === order[2], "it does not wrap")
    }

    /// A parked workspace's row × in the sidebar closes it, with no window
    /// of its own to close; the workspace on show is left alone.
    @Test func theSidebarsCloseButtonClosesAParkedWorkspace() async throws {
        let (a, _) = try await workspace()
        let (b, _) = try await workspace()
        #expect(b.isParked)
        b.closeWindowFromSidebar()
        #expect(await poll(timeout: 2) { b.windowHasClosed })
        #expect(!host.manages(b))
        #expect(host.active === a)
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
        // The workspace on show is listed ahead of the parked one, which is
        // not the focused window. (Other suites' windows can be in this
        // process too, so not "a is focused".)
        let aIndex = try #require(windows.firstIndex { $0.target == a.windowName })
        let beeIndex = try #require(windows.firstIndex { $0.target == "parked-bee" })
        #expect(aIndex < beeIndex)
        #expect(windows[beeIndex].focused == false)
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
