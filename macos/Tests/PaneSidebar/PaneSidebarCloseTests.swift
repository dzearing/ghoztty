import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

/// What the sidebar's closes decide: a window's last pane closes the window.
struct PaneSidebarClosePolicyTests {
    @Test func aPaneWithSiblingsLeavesItsWindow() {
        #expect(PaneSidebarClosePolicy.paneClose(leafCount: 2) == .removePane)
        #expect(PaneSidebarClosePolicy.paneClose(leafCount: 5) == .removePane)
    }

    @Test func aWindowsLastPaneClosesTheWindow() {
        // Through `closeSurface` the root would go to closeTab/closeWindow,
        // which confirm — so the sidebar closes the window itself.
        #expect(PaneSidebarClosePolicy.paneClose(leafCount: 1) == .closeWindow)
        #expect(PaneSidebarClosePolicy.paneClose(leafCount: 0) == .closeWindow)
    }
}

/// Every close from the sidebar — a pane's ×, a window row's ×, a project
/// group's × — in REAL windows: the target closes, is never made key, shows no
/// alert, and its panes' sessions are marked to END (CLOSE-on-free), not
/// detach. Terminals run `/bin/cat`, a running process a normal close would
/// confirm.
@MainActor
@Suite(.serialized)
struct PaneSidebarCloseWindowTests {
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

    private func terminalPane(_ app: ghostty_app_t) -> PaneView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        return PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
    }

    private func window(
        _ ghostty: Ghostty.App, title: String, panes count: Int
    ) throws -> (TerminalController, [PaneView]) {
        let app = try #require(ghostty.app)
        let panes = (0..<count).map { _ in terminalPane(app) }
        var tree = SplitTree<PaneView>(view: panes[0])
        for pane in panes.dropFirst() {
            tree = try tree.inserting(view: pane, at: panes[0], direction: .right)
        }
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        controller.windowTitleOverride = title
        return (controller, panes)
    }

    /// The window the sidebar is in: all-windows scope, expanded, key.
    private func sidebarWindow(_ ghostty: Ghostty.App) async throws -> TerminalController {
        let (main, _) = try window(ghostty, title: "Main", panes: 1)
        main.paneSidebarState.isHidden = false
        main.paneSidebarState.isExpanded = true
        main.paneSidebarState.showsAllWindows = true
        _ = await poll(timeout: 10) { main.window?.isVisible == true }
        main.window?.setContentSize(NSSize(width: 1000, height: 600))
        main.window?.makeKeyAndOrderFront(nil)
        return main
    }

    /// Counts every time one of `windows` becomes key, and every sheet any
    /// window gets, while `body` runs.
    private final class Watch: @unchecked Sendable {
        var becameKey = 0
        var sheets = 0
        private var observers: [NSObjectProtocol] = []

        init(_ windows: [NSWindow]) {
            let center = NotificationCenter.default
            for window in windows {
                observers.append(center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil
                ) { [weak self] _ in self?.becameKey += 1 })
            }
            observers.append(center.addObserver(
                forName: NSWindow.willBeginSheetNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.sheets += 1 })
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    private func noAlertAnywhere() -> Bool {
        NSApp.modalWindow == nil && NSApp.windows.allSatisfy { $0.attachedSheet == nil }
    }

    @Test func closingAnotherWindowFromTheSidebarAsksNothingAndEndsItsSessions() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let main = try await sidebarWindow(ghostty)
        let (other, panes) = try window(ghostty, title: "Other", panes: 2)
        _ = await poll(timeout: 10) { other.window?.isVisible == true }
        main.window?.makeKeyAndOrderFront(nil)
        await settle(0.8)
        let otherWindow = try #require(other.window)
        #expect(panes.contains { $0.surfaceView?.needsConfirmQuit == true },
                "a running process: an ordinary close would have asked")
        let mainWasKey = main.window?.isKeyWindow ?? false

        let watch = Watch([otherWindow])
        other.closeWindowFromSidebar()
        #expect(await poll(timeout: 5) { !otherWindow.isVisible })
        await settle(0.3)

        #expect(watch.becameKey == 0, "the closed window was never made key")
        #expect(watch.sheets == 0, "no confirmation or Disconnect alert")
        #expect(noAlertAnywhere())
        #expect(main.window?.isKeyWindow == mainWasKey, "focus stayed where it was")
        for pane in panes {
            #expect(pane.surfaceView?.sessionClosesOnFree == true, "its session ends, not detaches")
        }
        main.close()
        await settle(0.3)
    }

    @Test func closingAnotherWindowsPaneAsksNothingAndTakesNoFocus() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let main = try await sidebarWindow(ghostty)
        let (other, panes) = try window(ghostty, title: "Other", panes: 2)
        _ = await poll(timeout: 10) { other.window?.isVisible == true }
        main.window?.makeKeyAndOrderFront(nil)
        await settle(0.8)
        let otherWindow = try #require(other.window)

        let watch = Watch([otherWindow])
        other.closePaneFromSidebar(panes[0])
        await settle(0.5)
        #expect(!other.surfaceTree.contains(panes[0]))
        #expect(other.surfaceTree.contains(panes[1]))
        #expect(otherWindow.isVisible)
        #expect(watch.becameKey == 0)
        #expect(watch.sheets == 0)
        #expect(panes[0].surfaceView?.sessionClosesOnFree == true)
        #expect(panes[1].surfaceView?.sessionClosesOnFree == false)

        // Its last pane: the window closes, still without asking.
        other.closePaneFromSidebar(panes[1])
        #expect(await poll(timeout: 5) { !otherWindow.isVisible })
        await settle(0.3)
        #expect(watch.becameKey == 0)
        #expect(watch.sheets == 0)
        #expect(noAlertAnywhere())
        #expect(panes[1].surfaceView?.sessionClosesOnFree == true)
        main.close()
        await settle(0.3)
    }

    @Test func aGroupsCloseClosesEveryWindowInIt() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let main = try await sidebarWindow(ghostty)
        let (a, aPanes) = try window(ghostty, title: "proj: one", panes: 1)
        let (b, bPanes) = try window(ghostty, title: "proj: two", panes: 2)
        _ = await poll(timeout: 10) { a.window?.isVisible == true && b.window?.isVisible == true }
        main.window?.makeKeyAndOrderFront(nil)
        await settle(0.8)
        let windows = try [#require(a.window), #require(b.window)]

        let watch = Watch(windows)
        BaseTerminalController.closeWindowsFromSidebar([a, b])
        #expect(await poll(timeout: 5) { windows.allSatisfy { !$0.isVisible } })
        await settle(0.3)
        #expect(watch.becameKey == 0)
        #expect(watch.sheets == 0)
        #expect(noAlertAnywhere())
        for pane in aPanes + bPanes {
            #expect(pane.surfaceView?.sessionClosesOnFree == true)
        }
        main.close()
        await settle(0.3)
    }

    @Test func aWindowClosesItselfFromItsOwnSidebar() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let main = try await sidebarWindow(ghostty)
        await settle(0.8)
        let window = try #require(main.window)
        let panes = Array(main.surfaceTree)

        let watch = Watch([])
        main.closeWindowFromSidebar()
        #expect(await poll(timeout: 5) { !window.isVisible })
        await settle(0.3)
        #expect(watch.sheets == 0)
        #expect(noAlertAnywhere())
        for pane in panes {
            #expect(pane.surfaceView?.sessionClosesOnFree == true)
        }
    }

    /// A real click on a window row's ×, through the sidebar's own event
    /// routing: the row's tap (which raises its window) must not also fire.
    @Test func clickingAWindowRowsCloseDoesNotRaiseIt() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let main = try await sidebarWindow(ghostty)
        let (other, _) = try window(ghostty, title: "Other", panes: 1)
        _ = await poll(timeout: 10) { other.window?.isVisible == true }
        let mainWindow = try #require(main.window)
        mainWindow.makeKeyAndOrderFront(nil)
        await settle(1.0)
        let otherWindow = try #require(other.window)

        func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { all(type, in: $0) }
        }
        // "Main" sorts first and is unfolded; "Other" is folded below it, so
        // the lowest hover area is Other's header.
        let content = try #require(mainWindow.contentView)
        let header = try #require(all(HoverTrackingArea.View.self, in: content)
            .filter { $0.window != nil && $0.bounds.width > 150 }
            .min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY })
        header.onHoverChanged?(true)
        await settle(0.4)
        let frame = header.convert(header.bounds, to: nil)
        let point = NSPoint(
            x: frame.maxX - SidePanelRow.fillInset - PaneSidebarRow.trailingButtonInset
                - PaneSidebarItemButton.size / 2,
            y: frame.midY)

        let watch = Watch([otherWindow])
        var raisedOrder: [Int] = []
        let order = { NSApp.orderedWindows.firstIndex(of: otherWindow) ?? -1 }
        raisedOrder.append(order())
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: mainWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
            mainWindow.sendEvent(event)
            raisedOrder.append(order())
            await settle(0.05)
        }
        #expect(await poll(timeout: 5) { !otherWindow.isVisible }, "the click reached the ×")
        #expect(watch.becameKey == 0, "the closed window was raised and made key first")
        #expect(raisedOrder.allSatisfy { $0 == raisedOrder[0] }, "it was ordered front: \(raisedOrder)")
        #expect(mainWindow.isKeyWindow || !NSApp.isActive)
        main.close()
        await settle(0.3)
    }
}
