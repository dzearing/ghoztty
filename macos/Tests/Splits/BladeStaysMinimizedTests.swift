import AppKit
import WebKit
import GhosttyKit
import Testing
@testable import Ghostty

/// A pane the user minimized into a blade stays minimized until the user
/// brings it out. Each case minimizes an HTML viewer pane into a blade, does
/// one thing that happens to a pane behind the user's back, and checks the
/// blade is still a blade.
@MainActor
@Suite(.serialized)
struct BladeStaysMinimizedTests {
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// The panes drawn as strips.
    private func strips(_ window: NSWindow) -> Set<UUID> {
        Set(all(PaneStackTabView.self, in: window.contentView!).filter { $0.isStrip }.compactMap { $0.pane?.id })
    }

    private static func htmlFile(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blade-stays-minimized-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("page.html")
        try "<!doctype html><html><body>\(body)</body></html>".write(to: url, atomically: true, encoding: .utf8)
        try "<!doctype html><html><body><input autofocus><p>other</p></body></html>"
            .write(to: dir.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><html><body><p>plain</p></body></html>"
            .write(to: dir.appendingPathComponent("plain.html"), atomically: true, encoding: .utf8)
        return url
    }

    /// Two terminals and an HTML viewer, side by side in a window with room
    /// for all three; the user collapses the viewer into a blade at the
    /// trailing edge, with the caret in the first terminal.
    private func minimizedViewer(
        body: String = "<h1>page</h1>"
    ) async throws -> (TerminalController, NSWindow, [PaneView], URL) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let file = try Self.htmlFile(body)
        let panes = [
            PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)),
            PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)),
            PaneView(viewer: ViewerView(location: file.path)),
        ]
        var tree = SplitTree<PaneView>(view: panes[0])
        for i in 1..<panes.count { tree = try tree.inserting(view: panes[i], at: panes[i - 1], direction: .right) }
        tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        WindowInUse.setInUseForTesting(window, true)
        window.setContentSize(NSSize(width: 1400, height: 600))
        window.makeFirstResponder(panes[0].surfaceView)
        await settle(1.5)
        let items = panes.map { [$0.id] }
        controller.performSplitAction(.restack(.init(items: items, run: 0...2), .collapse(.trailing)))
        await settle(0.8)
        #expect(strips(window) == [panes[2].id], "the viewer is a blade")
        return (controller, window, panes, file)
    }

    enum Trigger: String, CaseIterable, CustomTestStringConvertible {
        case fileSaved, reloadContent, reloadPage, jsNavigate, contentProcessDied,
             windowResignsAndBecomesKey, windowGrows, windowShrinksAndGrows,
             siblingSplit, siblingClosed, siblingStashedAndRestored, focusOtherTerminal,
             jsNavigatePlain, jsFocusInput, savedWithAutofocus, jsFocusWindow,
             siblingPoppedOutToANewWindow
        var testDescription: String { rawValue }
    }

    @Test(arguments: Trigger.allCases)
    func aBladeStaysMinimized(_ trigger: Trigger) async throws {
        let (controller, window, panes, file) = try await minimizedViewer()
        defer { controller.close() }
        let viewer = try #require(panes[2].viewerView)
        switch trigger {
        case .fileSaved:
            try "<!doctype html><html><body><h1>edited</h1></body></html>"
                .write(to: file, atomically: true, encoding: .utf8)
            await settle(2.0)
        case .reloadContent:
            viewer.reloadContent()
            await settle(1.5)
        case .reloadPage:
            viewer.reloadPage()
            await settle(1.5)
        case .jsNavigate:
            _ = try? await viewer.webView.evaluateJavaScript("location.href = 'other.html'; 0")
            await settle(1.5)
        case .siblingPoppedOutToANewWindow:
            PaneMoveCoordinator.popOut(pane: panes[1], from: controller)
            await settle(1.5)
            for other in NSApp.windows where other !== window {
                if let c = other.windowController as? BaseTerminalController,
                   c.surfaceTree.contains(where: { $0 === panes[1] }) { c.close() }
            }
            window.makeKeyAndOrderFront(nil)
            await settle(0.8)
        case .jsNavigatePlain:
            _ = try? await viewer.webView.evaluateJavaScript("location.href = 'plain.html'; 0")
            await settle(1.5)
        case .jsFocusInput:
            _ = try? await viewer.webView.evaluateJavaScript(
                "const i = document.createElement('input'); document.body.appendChild(i); i.focus(); 0")
            await settle(1.5)
        case .jsFocusWindow:
            _ = try? await viewer.webView.evaluateJavaScript("window.focus(); 0")
            await settle(1.5)
        case .savedWithAutofocus:
            try "<!doctype html><html><body><input autofocus></body></html>"
                .write(to: file, atomically: true, encoding: .utf8)
            await settle(2.0)
        case .contentProcessDied:
            viewer.webViewWebContentProcessDidTerminate(viewer.webView)
            await settle(1.5)
        case .windowResignsAndBecomesKey:
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            other.makeKeyAndOrderFront(nil)
            await settle(0.5)
            window.makeKeyAndOrderFront(nil)
            other.close()
            await settle(1.0)
        case .windowGrows:
            window.setContentSize(NSSize(width: 2200, height: 700))
            await settle(1.0)
        case .windowShrinksAndGrows:
            window.setContentSize(NSSize(width: 500, height: 600))
            await settle(1.0)
            window.setContentSize(NSSize(width: 1400, height: 600))
            await settle(1.0)
        case .siblingSplit:
            let at = try #require(panes[0].surfaceView)
            _ = controller.newSplit(at: at, direction: .down, focus: true)
            await settle(1.0)
        case .siblingClosed:
            controller.closeSurface(try #require(panes[1].surfaceView), withConfirmation: false)
            await settle(1.0)
        case .siblingStashedAndRestored:
            controller.stashPane(panes[1])
            await settle(1.0)
            controller.restorePane(panes[1], focus: false)
            await settle(1.0)
        case .focusOtherTerminal:
            window.makeFirstResponder(panes[1].surfaceView)
            await settle(0.5)
            window.makeFirstResponder(panes[0].surfaceView)
            await settle(1.0)
        }
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        #expect(strips(window).contains(panes[2].id),
                "\(trigger): the viewer is still a blade (first responder \(responder), pin \(String(describing: controller.paneStackState.pin(for: Set(panes.map(\.id))))))")
    }

    /// Two HTML viewers in a row, the LEFT one minimized into a blade on the
    /// leading edge, the caret in the right one's page (the user's report:
    /// a link clicked in the right pane brought the left one out).
    private func leadingBladeBesideAViewer() async throws -> (TerminalController, NSWindow, [PaneView]) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let left = try Self.htmlFile("<h1>left</h1><a id=same href='plain.html'>same</a>")
        let right = try Self.htmlFile("""
            <h1>right</h1>
            <p><a id=same href='plain.html' style='font-size:40px'>a same-folder link</a></p>
            <p><a id=hash href='#below' style='font-size:40px'>an in-page link</a></p>
            <p><a id=other href='other.html' style='font-size:40px'>a page that autofocuses</a></p>
            <p id=below-middle style='margin-left:600px;font-size:40px'>plain text far from the blade</p>
            <div style='height:2000px'></div><p id=below>below</p>
            """)
        let panes = [PaneView(viewer: ViewerView(location: left.path)), PaneView(viewer: ViewerView(location: right.path))]
        var tree = SplitTree<PaneView>(view: panes[0])
        tree = try tree.inserting(view: panes[1], at: panes[0], direction: .right)
        tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        let window = try #require(controller.window)
        WindowInUse.setInUseForTesting(window, true)
        window.setContentSize(NSSize(width: 1400, height: 700))
        await settle(1.5)
        controller.performSplitAction(.restack(.init(items: panes.map { [$0.id] }, run: 0...1), .collapse(.leading)))
        await settle(0.8)
        let rightViewer = try #require(panes[1].viewerView)
        window.makeFirstResponder(rightViewer.webView)
        await settle(0.5)
        #expect(strips(window) == [panes[0].id], "the left viewer is a blade")
        return (controller, window, panes)
    }

    enum RightPaneAction: String, CaseIterable, CustomTestStringConvertible {
        case mouseClickMiddleOfPage, mouseClickSameFolderLink, mouseClickInPageLink, mouseClickAutofocusPage,
             jsClickSameFolderLink, cmdClickSameFolderLink, windowResignsAndBecomesKey,
             appResignsAndBecomesActive
        var testDescription: String { rawValue }
    }

    @Test(arguments: RightPaneAction.allCases)
    func aLeadingBladeStaysMinimized(_ action: RightPaneAction) async throws {
        let (controller, window, panes) = try await leadingBladeBesideAViewer()
        defer { controller.close() }
        let viewer = try #require(panes[1].viewerView)

        // A real click (in-process events) on the link with this id.
        func click(_ id: String, modifiers: NSEvent.ModifierFlags = []) async throws {
            let rect = try await viewer.webView.evaluateJavaScript(
                "(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.left + 10, r.top + r.height / 2]; })()") as? [Double]
            let point = try #require(rect)
            // Page coordinates are top-down from the web view's top-left.
            let inWeb = NSPoint(x: point[0], y: viewer.webView.isFlipped ? point[1] : viewer.webView.bounds.height - point[1])
            let inWindow = viewer.webView.convert(inWeb, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: inWindow, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.sendEvent(event)
                await settle(0.05)
            }
        }

        let pinBefore = String(describing: controller.paneStackState.pin(for: Set(panes.map(\.id))))
        switch action {
        case .mouseClickMiddleOfPage: try await click("below-middle")
        case .mouseClickSameFolderLink: try await click("same")
        case .mouseClickInPageLink: try await click("hash")
        case .mouseClickAutofocusPage: try await click("other")
        case .jsClickSameFolderLink:
            _ = try? await viewer.webView.evaluateJavaScript("document.getElementById('same').click(); 0")
        case .cmdClickSameFolderLink: try await click("same", modifiers: .command)
        case .windowResignsAndBecomesKey:
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            other.makeKeyAndOrderFront(nil)
            await settle(0.5)
            window.makeKeyAndOrderFront(nil)
            other.close()
        case .appResignsAndBecomesActive:
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            window.resignKey()
            await settle(0.5)
            window.becomeKey()
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        }
        await settle(2.0)
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        #expect(strips(window).contains(panes[0].id),
                "\(action): the left viewer came out of its blade (first responder \(responder), url \(viewer.webView.url?.lastPathComponent ?? "nil"), pin before \(pinBefore) after \(String(describing: controller.paneStackState.pin(for: Set(panes.map(\.id))))))")
    }

    /// A page that focuses an element in a blade leaves the caret where the
    /// user had it — not on the window, not in the blade.
    @Test func aPageFocusingAnElementInABladeLeavesTheCaretWhereItWas() async throws {
        let (controller, window, panes, _) = try await minimizedViewer()
        defer { controller.close() }
        let viewer = try #require(panes[2].viewerView)
        _ = try? await viewer.webView.evaluateJavaScript(
            "const i = document.createElement('input'); document.body.appendChild(i); i.focus(); 0")
        await settle(1.0)
        #expect(window.firstResponder === panes[0].surfaceView, "the caret stays in the terminal")
        #expect(strips(window) == [panes[2].id])
    }

    /// The user still brings the blade out (a strip click, the sidebar,
    /// `goto_split` all focus the pane), and its page has the caret.
    @Test func theUserStillBringsABladeOut() async throws {
        let (controller, window, panes, _) = try await minimizedViewer()
        defer { controller.close() }
        let viewer = try #require(panes[2].viewerView)
        Ghostty.moveFocus(to: panes[2])
        await settle(1.2)
        #expect(strips(window).isEmpty, "the viewer came out")
        #expect(window.firstResponder === viewer.webView, "its page has the caret")
        // On show, a page may focus its own elements again.
        window.makeFirstResponder(panes[0].surfaceView)
        await settle(0.3)
        _ = try? await viewer.webView.evaluateJavaScript(
            "const i = document.createElement('input'); document.body.appendChild(i); i.focus(); 0")
        await settle(0.8)
        #expect(window.firstResponder === viewer.webView, "a page on show is not held back")
    }

    // MARK: - Relaunch

    /// The window's blades are saved with its layout and come back with it:
    /// a relaunch used to lay every row out side by side again. The saved
    /// entry goes through JSON as the manifest file does, and the restored
    /// window's viewer has a fresh id, as it does on a real restore.
    @Test func aRestoredWindowKeepsItsBlades() async throws {
        let (controller, window, panes, file) = try await minimizedViewer()
        let saved = try #require(controller.persistedPaneStack, "a collapsed row is saved")
        #expect(saved.rows.count == 1)
        controller.close()
        _ = window

        var entry = SessionLayoutManifest.Entry(id: UUID())
        entry.paneStack = saved
        let decoded = try JSONDecoder().decode(
            SessionLayoutManifest.Entry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.paneStack == saved)

        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'cat'"
        let restored = [
            PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)),
            PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)),
            PaneView(viewer: ViewerView(location: file.path)),
        ]
        #expect(restored[2].id != panes[2].id, "a restored viewer has a new id")
        var tree = SplitTree<PaneView>(view: restored[0])
        for i in 1..<restored.count {
            tree = try tree.inserting(view: restored[i], at: restored[i - 1], direction: .right)
        }
        tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
        let again = TerminalController.newWindow(ghostty, tree: tree)
        defer { again.close() }
        again.paneSidebarState.isHidden = true
        again.adoptPersistedPaneStack(decoded.paneStack)
        for _ in 0..<100 where again.window?.isVisible != true { await settle(0.1) }
        let newWindow = try #require(again.window)
        WindowInUse.setInUseForTesting(newWindow, true)
        newWindow.setContentSize(NSSize(width: 1400, height: 600))
        // The caret goes to a pane on show, even when the blade is asked for.
        let target = try #require(again.restoredFocusTarget(preferring: restored[2]))
        #expect(target !== restored[2], "the caret never goes into a blade")
        Ghostty.moveFocus(to: target)
        await settle(1.5)
        #expect(strips(newWindow) == [restored[2].id], "the viewer is still a blade")
    }

    /// A manifest written before blades were saved has no `paneStack`, and
    /// still loads.
    @Test func aManifestWithoutBladesStillLoads() throws {
        let json = #"[{"id":"6B1C1F0E-8E77-4C29-A8F1-1D4B7E0A9C11","tabIndex":0}]"#
        let entries = try JSONDecoder().decode([SessionLayoutManifest.Entry].self, from: Data(json.utf8))
        #expect(entries.first?.paneStack == nil)
    }

    /// Saved and taken back, a window's collapses name the same panes by
    /// position, whatever their ids are now.
    @Test func theStackStateRoundTripsByLeafPosition() {
        let old = (0..<4).map { _ in UUID() }, new = (0..<4).map { _ in UUID() }
        let state = PaneStackState()
        state.restack(.init(items: old.map { [$0] }, run: 0...3), .collapse(.trailing))
        state.noteFocus(old[1])
        state.noteFocus(old[0])
        let saved = try? #require(state.persisted(leaves: old))
        #expect(saved?.rows == [.init(leaves: [0, 1, 2, 3], start: 0, count: 3, shares: saved?.rows.first?.shares)])
        #expect(saved?.recency == [0, 1])

        let restored = PaneStackState()
        if let saved { restored.adopt(saved, leaves: new) }
        #expect(restored.pin(for: Set(new)) == PaneLayout.Pin(start: 0, count: 3))
        #expect(restored.recency == [new[0], new[1]])
        #expect(restored.isMinimized(new[3], in: [new.map { [$0] }]))

        // A row naming a leaf the restored tree does not have is dropped.
        let fewer = PaneStackState()
        if let saved { fewer.adopt(saved, leaves: Array(new.prefix(2))) }
        #expect(fewer.pin(for: Set(new)) == nil)
    }
}
