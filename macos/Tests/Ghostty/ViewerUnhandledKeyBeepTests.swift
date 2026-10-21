import AppKit
import Testing
import WebKit
@testable import Ghostty

/// A plain key a page does not consume must not beep.
///
/// WKWebView hands a keyDown the page left alone back to AppKit: it climbs the
/// responder chain from the web view, nothing on it handles a bare Return /
/// letter / arrow, and the chain's last responder calls
/// `noResponder(for: #selector(keyDown(with:)))` — which is `NSBeep()`. Pressing
/// Enter in an HTML page beeped. `ViewerView.keyDown` ends that walk for keys
/// its content handed back.
///
/// Serialized: the web-backed cases are timing-flaky when two runners share
/// the machine (a key sent before the window is key never reaches WebKit).
@MainActor
@Suite(.serialized)
struct ViewerUnhandledKeyBeepTests {
    /// Records the beep instead of playing it, and what reached the window.
    /// With no controller the window is the chain's last responder, so it is
    /// where `noResponder(for:)` lands.
    final class BeepWindow: NSWindow {
        var beeps: [Selector] = []
        var windowKeyDowns: [UInt16] = []
        override func noResponder(for eventSelector: Selector) {
            beeps.append(eventSelector)
        }
        override func keyDown(with event: NSEvent) {
            windowKeyDowns.append(event.keyCode)
            super.keyDown(with: event)
        }
    }

    private func makePane(_ html: String) async throws -> (BeepWindow, ViewerView) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-beep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("page.html")
        try "<!doctype html><html><body>\(html)</body></html>"
            .write(to: file, atomically: true, encoding: .utf8)

        let window = BeepWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        let viewer = ViewerView(location: file.path)
        viewer.frame = window.contentView!.bounds
        viewer.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let ready = try? await viewer.webView.evaluateJavaScript(
                "document.readyState === 'complete' && !!document.getElementById('ready')")
            if (ready as? Bool) == true { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        window.makeFirstResponder(viewer.webView)
        return (window, viewer)
    }

    private static func key(
        _ chars: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode)!
    }

    /// Press a key at the focused web view and give the web process time to
    /// decide it did not want it (the hand-back is asynchronous).
    private func press(
        _ chars: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
        in window: BeepWindow, viewer: ViewerView
    ) async {
        window.sendEvent(Self.key(chars, keyCode: keyCode, flags, windowNumber: window.windowNumber))
        _ = try? await viewer.webView.evaluateJavaScript("1")
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private static let downArrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    private static let tab = String(Character(UnicodeScalar(NSTabCharacter)!))

    // MARK: - Policy (pure)

    @Test func plainKeysEndTheWalk() {
        #expect(ViewerView.endsUnhandledKeyWalk(Self.key("\r", keyCode: 36)))
        #expect(ViewerView.endsUnhandledKeyWalk(Self.key("a", keyCode: 0)))
        #expect(ViewerView.endsUnhandledKeyWalk(Self.key("\u{1b}", keyCode: 53)))
        #expect(ViewerView.endsUnhandledKeyWalk(Self.key(" ", keyCode: 49)))
        #expect(ViewerView.endsUnhandledKeyWalk(
            Self.key(Self.downArrow, keyCode: 125, [.function, .numericPad])))
        // Control and Shift chords are plain keys too.
        #expect(ViewerView.endsUnhandledKeyWalk(Self.key("a", keyCode: 0, [.control])))
        #expect(ViewerView.endsUnhandledKeyWalk(Self.key("A", keyCode: 0, [.shift])))
    }

    @Test func commandChordsAndTabGoOn() {
        #expect(!ViewerView.endsUnhandledKeyWalk(Self.key("k", keyCode: 40, [.command])))
        #expect(!ViewerView.endsUnhandledKeyWalk(Self.key("\r", keyCode: 36, [.command])))
        #expect(!ViewerView.endsUnhandledKeyWalk(Self.key(Self.tab, keyCode: 48)))
        #expect(!ViewerView.endsUnhandledKeyWalk(
            Self.key(String(Character(UnicodeScalar(NSBackTabCharacter)!)), keyCode: 48, [.shift])))
    }

    // MARK: - In a page

    @Test(arguments: [
        ("\r", UInt16(36)), ("a", UInt16(0)), ("\u{1b}", UInt16(53)), (" ", UInt16(49)),
    ])
    func anUnhandledKeyInAPageDoesNotBeep(_ k: (String, UInt16)) async throws {
        let (window, viewer) = try await makePane("<p id=ready>Hello</p>")
        defer { window.orderOut(nil) }
        await press(k.0, keyCode: k.1, in: window, viewer: viewer)
        #expect(window.beeps.isEmpty, "key \(k.1) beeped")
        #expect(window.windowKeyDowns.isEmpty, "key \(k.1) climbed past the pane")
    }

    @Test func anArrowWithNothingToScrollDoesNotBeep() async throws {
        let (window, viewer) = try await makePane("<p id=ready>Hello</p>")
        defer { window.orderOut(nil) }
        await press(Self.downArrow, keyCode: 125, [.function, .numericPad], in: window, viewer: viewer)
        #expect(window.beeps.isEmpty)
    }

    /// The page still gets the key first: ending the walk must not mean
    /// swallowing the key before WebKit sees it.
    @Test func thePageStillReceivesEnter() async throws {
        let (window, viewer) = try await makePane("""
            <p id=ready>Hello</p>
            <script>window.__keys = [];
            addEventListener('keydown', e => __keys.push(e.key));</script>
            """)
        defer { window.orderOut(nil) }
        await press("\r", keyCode: 36, in: window, viewer: viewer)
        let keys = try await viewer.webView.evaluateJavaScript("__keys.join(',')") as? String
        #expect(keys == "Enter")
        #expect(window.beeps.isEmpty)
    }

    /// Typing into a page's form field still types.
    @Test func typingInAFormFieldStillTypes() async throws {
        let (window, viewer) = try await makePane("<input id=ready>")
        defer { window.orderOut(nil) }
        _ = try await viewer.webView.evaluateJavaScript("document.getElementById('ready').focus()")
        await press("a", keyCode: 0, in: window, viewer: viewer)
        await press("\r", keyCode: 36, in: window, viewer: viewer)
        let value = try await viewer.webView.evaluateJavaScript(
            "document.getElementById('ready').value") as? String
        #expect(value == "a")
        #expect(window.beeps.isEmpty)
    }

    /// A Command chord nothing claims still reaches the window, exactly as
    /// before — this change is about plain keys.
    @Test func anUnclaimedCommandChordStillClimbs() async throws {
        let (window, viewer) = try await makePane("<p id=ready>Hello</p>")
        defer { window.orderOut(nil) }
        // Straight at keyDown: this is the hand-back WebKit does after the
        // chord's performKeyEquivalent pass found no taker.
        viewer.keyDown(with: Self.key("j", keyCode: 38, [.command], windowNumber: window.windowNumber))
        #expect(window.windowKeyDowns == [38])
    }
}
