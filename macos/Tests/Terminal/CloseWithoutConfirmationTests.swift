import AppKit
import Testing
@testable import Ghostty

/// A close that asks for no confirmation gets none — including when the pane
/// is its window's last, where the close becomes a window close. `ghoztty
/// +close`, App Intents and AppleScript all close this way, and nobody is
/// there to answer a "Close Window?" sheet.
@MainActor
@Suite(.serialized)
struct CloseWithoutConfirmationTests {
    private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    @Test func closingAWindowsLastPaneWithoutConfirmationClosesTheWindow() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        // A running program: exactly what a close would stop to ask about.
        config.command = "/bin/cat"
        let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        defer { controller.window?.close() }
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        let surface = try #require(pane.surfaceView)
        // The program has started, so the pane is one a close asks about.
        _ = await poll(timeout: 5) { surface.needsConfirmQuit }

        controller.closeSurface(surface, withConfirmation: false)

        #expect(window.attachedSheet == nil, "the close stopped to ask")
        #expect(await poll(timeout: 3) { !window.isVisible }, "the window did not close")
    }

    /// A closed window that something still holds (here, the test) is gone
    /// all the same: it is not among the windows, and its terminal is freed
    /// once the close can no longer be undone rather than running for as
    /// long as the object lives.
    @Test func aClosedWindowThatIsStillHeldIsNotAWindowAndFreesItsTerminal() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let held = try #require(pane.surfaceView)
        #expect(held.surface != nil)
        #expect(TerminalController.all.contains { $0 === controller })

        controller.closeWindowImmediately()

        #expect(controller.windowHasClosed)
        #expect(!TerminalController.all.contains { $0 === controller }, "a closed window is still listed")
        // Inside the undo window the terminal lives: an undo brings it back.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(held.surface != nil, "freed before its close could no longer be undone")
        let freed = await poll(timeout: controller.undoExpiration.timeInterval + 3) { held.surface == nil }
        #expect(freed, "the closed window's terminal is still running")
    }
}
