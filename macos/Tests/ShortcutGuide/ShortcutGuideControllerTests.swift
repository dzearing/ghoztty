import Testing
import AppKit
@testable import Ghostty
@testable import GhosttyKit

/// The shortcut guide window, driven through the real app: the Help menu
/// item, the core `show_keyboard_shortcuts` action, and the window's keys.
@MainActor
@Suite(.serialized)
struct ShortcutGuideControllerTests {
    private var ghostty: Ghostty.App {
        get throws { try #require((NSApp.delegate as? AppDelegate)?.ghostty) }
    }

    private func spin(_ seconds: TimeInterval = 0.3, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private var helpItem: NSMenuItem? {
        NSApp.mainMenu?.items.first { $0.title == "Help" }?.submenu?.items.first { $0.title == "Keyboard Shortcuts" }
    }

    @Test func helpMenuItemCarriesTheConfiguredShortcut() throws {
        let item = try #require(helpItem)
        #expect(item.action == #selector(AppDelegate.showKeyboardShortcuts(_:)))
        // syncMenuShortcuts runs once the app is ready.
        spin(2) { (try? ghostty.readiness) == .ready && item.keyEquivalent == "/" }
        #expect(item.keyEquivalent == "/")
        #expect(item.keyEquivalentModifierMask == [.command])
    }

    @Test func theCoreActionOpensTheGuide() throws {
        let app = try #require(try ghostty.app)
        ShortcutGuideController.shared.window?.orderOut(nil)
        let ran = "show_keyboard_shortcuts".withCString { ghostty_app_binding_action(app, nil, $0, UInt(strlen($0))) }
        #expect(ran)
        let window = try #require(ShortcutGuideController.shared.window)
        spin(2) { window.isVisible }
        #expect(window.isVisible)
        #expect(window.title == "Keyboard Shortcuts")
        window.orderOut(nil)
    }

    @Test func theSelectorOpensTheGuideFromAnywhereInTheResponderChain() throws {
        ShortcutGuideController.shared.window?.orderOut(nil)
        #expect(NSApp.sendAction(#selector(AppDelegate.showKeyboardShortcuts(_:)), to: nil, from: nil))
        let window = try #require(ShortcutGuideController.shared.window)
        spin(1) { window.isVisible }
        #expect(window.isVisible)
        window.orderOut(nil)
    }
}
