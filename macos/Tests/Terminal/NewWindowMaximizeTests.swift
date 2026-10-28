import AppKit
import Testing
@testable import Ghostty

/// `maximize` (on by default in Ghoztty): every new window fills its
/// screen's visible frame — not placed at the last window's position, not
/// cascaded down from the one before it, which left a gap above it and cut
/// it short.
@MainActor
@Suite(.serialized)
struct NewWindowMaximizeTests {
    private func settle(_ seconds: TimeInterval = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @Test func newWindowsFillTheScreen() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        try #require(ghostty.config.maximize)
        // The last window the user had was smaller and lower down.
        let key = "NSWindowLastPosition"
        let saved = UserDefaults.ghostty.object(forKey: key)
        defer { UserDefaults.ghostty.set(saved, forKey: key) }
        UserDefaults.ghostty.set([120.0, 140.0, 900.0, 600.0], forKey: key)

        var controllers: [TerminalController] = []
        for _ in 0..<3 {
            // A script-opened window (background) and Cmd-N's path share
            // `applyInitialFrame` and the cascade.
            controllers.append(TerminalController.newWindow(ghostty, activate: false))
            await settle(0.6)
        }
        for (index, c) in controllers.enumerated() {
            let window = try #require(c.window)
            let screen = try #require(window.screen ?? NSScreen.main)
            #expect(window.frame == screen.visibleFrame, "window \(index + 1): \(window.frame) vs \(screen.visibleFrame)")
        }
        for c in controllers { c.close() }
        await settle(0.4)
    }
}
