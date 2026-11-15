import AppKit
import Testing
@testable import Ghostty

/// Work only the eye needs stops where no one is looking: endless animations
/// outside the window in use, titles of a window no one can see.
@MainActor
@Suite(.serialized)
struct WindowInUseTests {
    /// A window that says it is key and on screen when told to, so the gate
    /// is exercised without fighting the test host for real focus.
    final class StubWindow: NSWindow {
        var key = true
        var onScreen = true
        override var isKeyWindow: Bool { key }
        override var occlusionState: NSWindow.OcclusionState { onScreen ? [.visible] : [] }

        init() {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                       styleMask: [.titled], backing: .buffered, defer: true)
            isReleasedWhenClosed = false
        }

        func set(key: Bool, onScreen: Bool) {
            let wasKey = self.key
            self.key = key
            self.onScreen = onScreen
            if key != wasKey {
                NotificationCenter.default.post(
                    name: key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
                    object: self)
            }
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
        }
    }

    // MARK: The busy border and the sidebar sheen

    @Test func theBusyBorderCirclesOnlyInTheWindowInUse() {
        let window = StubWindow()
        let border = BusyBorderView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(border)
        #expect(border.isSpinning)

        window.set(key: false, onScreen: true)
        #expect(!border.isSpinning, "a window behind the key one holds still")

        window.set(key: true, onScreen: true)
        #expect(border.isSpinning, "and moves again the moment it is in use")

        window.set(key: true, onScreen: false)
        #expect(!border.isSpinning, "a key window no one can see (minimized) holds still")

        border.removeFromSuperview()
        #expect(!border.isSpinning)
    }

    @Test func theSidebarSheenMovesOnlyInTheWindowInUse() {
        let window = StubWindow()
        let sheen = PaneSidebarTileSheenLayer.View(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        window.contentView?.addSubview(sheen)
        sheen.layout()
        #expect(sheen.isAnimating)

        window.set(key: false, onScreen: true)
        #expect(!sheen.isAnimating)

        window.set(key: true, onScreen: true)
        #expect(sheen.isAnimating)
    }

    // MARK: Coverage

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    /// AppKit calls a window behind another of exactly its frame visible —
    /// its corners peek out — which is every window behind the front one when
    /// they all fill the screen.
    @Test func aWindowBehindOneOfItsOwnSizeIsCovered() {
        let frame = CGRect(x: 0, y: 33, width: 1728, height: 1025)
        #expect(WindowCoverage.isCovered(frame, by: [frame], on: [screen], corner: 24))
    }

    @Test func aWindowWithAStripShowingIsNotCovered() {
        let frame = CGRect(x: 0, y: 33, width: 1728, height: 1025)
        let front = CGRect(x: 0, y: 33, width: 1694, height: 1024)
        #expect(!WindowCoverage.isCovered(frame, by: [front], on: [screen], corner: 24))
    }

    @Test func coveringMayTakeSeveralWindows() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let left = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let right = CGRect(x: 500, y: 0, width: 600, height: 1000)
        #expect(WindowCoverage.isCovered(frame, by: [left, right], on: [screen], corner: 24))
        #expect(!WindowCoverage.isCovered(frame, by: [left], on: [screen], corner: 24))
    }

    @Test func whatShowsOnlyOffScreenDoesNotCount() {
        // Nudged right past the screen's edge: the strip that is not covered
        // is off every screen.
        let frame = CGRect(x: 8, y: 33, width: 1728, height: 1025)
        let front = CGRect(x: 0, y: 33, width: 1728, height: 1025)
        #expect(WindowCoverage.isCovered(frame, by: [front], on: [screen], corner: 24))
        #expect(!WindowCoverage.isCovered(frame, by: [front], on: [screen.insetBy(dx: -100, dy: 0)], corner: 24))
    }

    // MARK: Titles

    private func settle(_ seconds: TimeInterval = 0.2) async {
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

    private func run(_ action: String, _ arguments: [String]) async throws -> IPCResponse {
        let server = try #require((NSApp.delegate as? AppDelegate)?.ipcServer)
        let request = IPCRequest(action: action, arguments: arguments, callerPane: nil)
        return await Task.detached { server.dispatch(request) }.value
    }

    /// A hidden window's title waits for it to show, yet scripts asking for
    /// it (`+list`, AppleScript) get the new one at once.
    @Test func aHiddenWindowsTitleLandsWhenItShows() async throws {
        let target = "window-in-use-title-test"
        let opened = try await run("new-window", ["--target=\(target)", "--title=before"])
        #expect(opened.success, "\(opened.error ?? "")")
        var found: TerminalController?
        #expect(await poll(timeout: 5) {
            found = TerminalController.all.first { $0.windowTitleOverride == "before" }
            return found != nil
        })
        let c = try #require(found)
        let window = try #require(c.window)
        // In front of everything, so no other window covers it.
        window.orderFrontRegardless()
        #expect(await poll(timeout: 7) { window.title == "before" })

        window.orderOut(nil)
        #expect(await poll(timeout: 5) { !WindowInUse.isOnScreen(window) })

        let renamed = try await run("rename", ["--target=\(target)", "--title=after"])
        #expect(renamed.success)
        await settle()
        #expect(window.title == "before", "held back while no one can see it")
        #expect(c.currentWindowTitle == "after")
        let listed = try await run("list", ["--json"])
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try #require(listed.data))) as? [String: Any]
        let entry = (json?["windows"] as? [[String: Any]])?.first { $0["target"] as? String == target }
        #expect(entry?["title"] as? String == "after", "+list has it at once")

        window.orderFrontRegardless()
        #expect(await poll(timeout: 5) { window.title == "after" }, "lands as it shows")

        c.close()
        await settle(0.3)
    }
}
