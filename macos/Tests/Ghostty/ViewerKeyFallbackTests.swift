import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

/// A chord a focused viewer pane does not claim must reach Ghoztty's binding
/// dispatch, as it would from a focused terminal — except bindings that only
/// mean something with a terminal focused, and chords a focused text field
/// uses itself. See `ViewerKeyFallback`.

private func keyEvent(
    _ chars: String,
    _ flags: NSEvent.ModifierFlags,
    keyCode: UInt16 = 0,
    window: NSWindow? = nil
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window?.windowNumber ?? 0, context: nil,
        characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: keyCode)!
}

/// Cmd+Shift+. — `toggle_rearrange_mode` by default, on the PHYSICAL period
/// key, which is why its menu item carries no key equivalent.
private func cmdShiftPeriod(window: NSWindow? = nil) -> NSEvent {
    keyEvent(">", [.command, .shift], keyCode: 47, window: window)
}

private func leftArrow(_ flags: NSEvent.ModifierFlags) -> NSEvent {
    keyEvent(String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), flags.union(.function), keyCode: 123)
}

// MARK: - Routing policy (pure)

struct ViewerKeyFallbackRouteTests {
    typealias B = ViewerKeyFallback.Binding

    private func route(
        _ binding: B?,
        event: NSEvent = cmdShiftPeriod(),
        text: Bool = false,
        menu: Bool = false,
        host: Bool = true
    ) -> ViewerKeyFallback.Route {
        ViewerKeyFallback.route(
            for: binding, event: event, textInputFocused: text,
            hasMenuItem: menu, hasHostSurface: host)
    }

    private func binding(
        _ requires: ViewerKeyFallback.Requires,
        _ flags: Ghostty.Input.BindingFlags = [.consumed],
        action: String? = "some_action"
    ) -> B {
        B(flags: flags, requires: requires, action: action)
    }

    @Test func notABindingPasses() {
        #expect(route(nil) == .pass)
    }

    @Test func terminalBindingsAreNeverForwarded() {
        // Performing these through another terminal in the window would type
        // into, copy from, or scroll a pane the user is not looking at.
        #expect(route(binding(.terminal)) == .pass)
        #expect(route(binding(.terminal), menu: true) == .pass)
    }

    @Test func appBindingsGoToTheCoreWithOrWithoutATerminal() {
        #expect(route(binding(.app), host: true) == .core)
        #expect(route(binding(.app), host: false) == .core)
    }

    @Test func windowBindingsNeedATerminalToNameTheWindow() {
        #expect(route(binding(.window), host: true) == .core)
        #expect(route(binding(.window), host: false) == .pass)
        // ...unless the menu can perform it, which needs no terminal.
        #expect(route(binding(.window), menu: true, host: false) == .menuItem)
    }

    @Test func paneBindingsOnlyThroughTheViewerAwareMenu() {
        #expect(route(binding(.pane), menu: true) == .menuItem)
        // A terminal standing in would act on ITS pane, not the viewer.
        #expect(route(binding(.pane), menu: false, host: true) == .pass)
    }

    @Test func performableBindingsStayOffTheMenu() {
        // Performable must be able to decline; the menu always performs.
        #expect(route(binding(.window, [.consumed, .performable]), menu: true) == .core)
        #expect(route(binding(.pane, [.consumed, .performable]), menu: true) == .pass)
        // Unconsumed has no terminal program to pass the key on to here, so
        // it takes the menu like any other binding.
        #expect(route(binding(.pane, []), menu: true) == .menuItem)
    }

    @Test func globalAndAllBindingsActEverywhere() {
        #expect(route(binding(.terminal, [.consumed, .all])) == .core)
        #expect(route(binding(.window, [.consumed, .global]), host: false) == .core)
    }

    @Test func textFieldKeepsTypingAndTextNavigation() {
        let window = binding(.window)
        // Command chords the text system does not use are forwarded.
        #expect(route(window, event: cmdShiftPeriod(), text: true) == .core)
        #expect(route(window, event: keyEvent("1", [.command], keyCode: 18), text: true) == .core)
        // Typing, emacs keys, option-word-motion: the field's.
        #expect(route(window, event: keyEvent("a", []), text: true) == .pass)
        #expect(route(window, event: keyEvent("A", [.shift]), text: true) == .pass)
        #expect(route(window, event: keyEvent("a", [.control]), text: true) == .pass)
        #expect(route(window, event: leftArrow([.option]), text: true) == .pass)
        // Command text navigation / deletion: the field's.
        #expect(route(window, event: leftArrow([.command]), text: true) == .pass)
        #expect(route(window, event: leftArrow([.command, .shift]), text: true) == .pass)
        #expect(route(window, event: keyEvent("\u{7f}", [.command], keyCode: 51), text: true) == .pass)
        // The same chords without a text field are forwarded.
        #expect(route(window, event: keyEvent("a", [.control]), text: false) == .core)
    }
}

// MARK: - What the core reports a chord is bound to

struct ViewerKeyFallbackBindingTests {
    private func lookup(_ config: Ghostty.Config, _ event: NSEvent) -> ViewerKeyFallback.Binding? {
        guard let cfg = config.config else { return nil }
        return ViewerKeyFallback.binding(for: event, config: cfg)
    }

    @Test func defaultChordsAreClassified() throws {
        let config = try TemporaryConfig("")
        let rearrange = lookup(config, cmdShiftPeriod())
        #expect(rearrange?.requires == .window)
        #expect(rearrange?.action == "toggle_rearrange_mode")
        #expect(rearrange?.flags.contains(.consumed) == true)

        #expect(lookup(config, keyEvent("c", [.command], keyCode: 8))?.requires == .terminal)
        #expect(lookup(config, keyEvent("t", [.command], keyCode: 17))?.action == "new_tab")
        #expect(lookup(config, keyEvent("d", [.command], keyCode: 2))?.requires == .pane)
        #expect(lookup(config, keyEvent("z", [.command], keyCode: 6))?.requires == .app)
        #expect(lookup(config, keyEvent("1", [.command], keyCode: 18))?.action == "goto_tab:1")
    }

    @Test func unboundChordIsNotABinding() throws {
        let config = try TemporaryConfig("")
        #expect(lookup(config, keyEvent("j", [.command, .control, .option], keyCode: 38)) == nil)
    }

    @Test func flagsAndChainsAreReported() throws {
        let config = try TemporaryConfig("""
            keybind = unconsumed:super+shift+j=new_tab
            keybind = super+shift+k=text:hi
            keybind = super+shift+l=new_tab
            keybind = chain=text:oops
            """)
        let unconsumed = lookup(config, keyEvent("J", [.command, .shift], keyCode: 38))
        #expect(unconsumed?.flags.contains(.consumed) == false)
        #expect(unconsumed?.requires == .window)

        #expect(lookup(config, keyEvent("K", [.command, .shift], keyCode: 40))?.requires == .terminal)

        // A chain is as demanding as its most demanding action, and has no
        // single action to find a menu item for.
        let chain = lookup(config, keyEvent("L", [.command, .shift], keyCode: 37))
        #expect(chain?.requires == .terminal)
        #expect(chain?.action == nil)
    }
}

// MARK: - Menu items by action

@MainActor
struct ViewerKeyFallbackMenuIndexTests {
    final class Target: NSObject {
        var fired = 0
        @objc func fire(_ sender: Any?) { fired += 1 }
    }

    @Test func itemWithoutAKeyEquivalentIsStillFoundByAction() throws {
        let config = try TemporaryConfig("")
        let target = Target()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Toggle Rearrange Mode", action: #selector(Target.fire(_:)), keyEquivalent: "")
        item.target = target
        menu.addItem(item)

        let manager = Ghostty.MenuShortcutManager()
        manager.reset()
        manager.syncMenuShortcut(config, action: "toggle_rearrange_mode", menuItem: item)

        // The physical-period trigger cannot be a key equivalent...
        #expect(item.keyEquivalent.isEmpty)
        // ...but the binding still finds its item.
        #expect(manager.hasMenuItem(forAction: "toggle_rearrange_mode"))
        #expect(manager.performGhosttyBindingMenuItem(forAction: "toggle_rearrange_mode"))
        #expect(target.fired == 1)
    }

    @Test func itemsAreIndexedByCanonicalSpelling() throws {
        let config = try TemporaryConfig("")
        let item = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "")
        let manager = Ghostty.MenuShortcutManager()
        manager.reset()
        manager.syncMenuShortcut(config, action: "close_tab", menuItem: item)
        // A lookup reports `close_tab:this`, so that is the key.
        #expect(manager.hasMenuItem(forAction: "close_tab:this"))
        #expect(Ghostty.MenuShortcutManager.canonicalAction("close_tab") == "close_tab:this")
        #expect(Ghostty.MenuShortcutManager.canonicalAction("not_an_action") == nil)
    }
}

// MARK: - In a real window

/// A real `TerminalController` window: a terminal pane (running `cat`, so no
/// shell and no session agent) beside a viewer pane, keys pushed through the
/// window's own key-equivalent walk the way AppKit does.
@MainActor
@Suite(.serialized)
struct ViewerKeyFallbackWindowTests {
    private struct Harness {
        let controller: TerminalController
        let window: NSWindow
        let viewer: ViewerView
        let surface: Ghostty.SurfaceView?
    }

    private func fixture(_ name: String, _ write: (URL) throws -> Void) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-key-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try write(url)
        return url
    }

    private func markdownFile() throws -> URL {
        try fixture("doc.md") { try "# Title\n\nBody.".write(to: $0, atomically: true, encoding: .utf8) }
    }

    private func imageFile() throws -> URL {
        try fixture("image.png") { url in
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try rep.representation(using: .png, properties: [:])!.write(to: url)
        }
    }

    private func open(_ location: String, withTerminal: Bool = true) async throws -> Harness {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let viewer = ViewerView(location: location)
        let viewerPane = PaneView(viewer: viewer)
        var surface: Ghostty.SurfaceView?
        var tree = SplitTree<PaneView>(view: viewerPane)
        if withTerminal {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "/bin/cat"
            let terminal = Ghostty.SurfaceView(app, baseConfig: config)
            surface = terminal
            let terminalPane = PaneView(surface: terminal)
            tree = try SplitTree<PaneView>(view: terminalPane)
                .inserting(view: viewerPane, at: terminalPane, direction: .right)
        }
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        let window = try #require(await windowOf(controller))
        await settle(1.5)
        return Harness(controller: controller, window: window, viewer: viewer, surface: surface)
    }

    private func windowOf(_ controller: TerminalController) async -> NSWindow? {
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        return controller.window
    }

    /// Run `body` against a fresh window, closing it whatever happens.
    private func withWindow(
        _ location: String,
        withTerminal: Bool = true,
        _ body: (Harness) async throws -> Void
    ) async throws {
        let h = try await open(location, withTerminal: withTerminal)
        do {
            try await body(h)
        } catch {
            await close(h)
            throw error
        }
        await close(h)
    }

    private func close(_ h: Harness) async {
        if h.controller.rearrangeModeState.isActive { h.controller.toggleRearrangeMode() }
        h.controller.close()
        await settle(0.3)
    }

    /// The precondition every case here leans on: the running app's config
    /// binds Cmd+Shift+. to rearrange mode (the default).
    private func requireDefaultRearrangeBinding() throws {
        let config = try #require((NSApp.delegate as? AppDelegate)?.ghostty.config.config)
        let binding = ViewerKeyFallback.binding(for: cmdShiftPeriod(), config: config)
        try #require(binding?.action == "toggle_rearrange_mode",
                     "the app's config does not bind Cmd+Shift+. to toggle_rearrange_mode")
    }

    @Test func unclaimedChordFromAnImagePaneReachesGhoztty() async throws {
        try requireDefaultRearrangeBinding()
        try await withWindow(try imageFile().path) { h in
            h.window.makeFirstResponder(h.viewer)
            await settle(0.3)
            #expect(!h.controller.rearrangeModeState.isActive)

            #expect(h.window.performKeyEquivalent(with: cmdShiftPeriod(window: h.window)))
            #expect(h.controller.rearrangeModeState.isActive)

            #expect(h.window.performKeyEquivalent(with: cmdShiftPeriod(window: h.window)))
            #expect(!h.controller.rearrangeModeState.isActive)
        }
    }

    @Test func aWindowOfOnlyViewersStillReachesMenuBackedBindings() async throws {
        try requireDefaultRearrangeBinding()
        try await withWindow(try imageFile().path, withTerminal: false) { h in
            h.window.makeFirstResponder(h.viewer)
            await settle(0.3)
            let delegate = try #require(NSApp.delegate as? AppDelegate)
            let config = try #require(delegate.ghostty.config.config)
            let binding = ViewerKeyFallback.binding(for: cmdShiftPeriod(), config: config)

            // No terminal to name the window, so the core cannot perform it;
            // the menu item can.
            #expect(ViewerKeyFallback.hostSurface(in: h.controller) == nil)
            #expect(delegate.hasGhosttyBindingMenuItem(forAction: "toggle_rearrange_mode"))
            #expect(ViewerKeyFallback.route(
                for: binding, event: cmdShiftPeriod(), textInputFocused: false,
                hasMenuItem: true, hasHostSurface: false) == .menuItem)

            // The menu item's action, sent from the focused viewer, lands on
            // this window's controller. (Performing the item itself needs a
            // KEY window for AppKit's menu validation, which a test host
            // cannot have: it is never the active app.)
            #expect(h.window.firstResponder?.tryToPerform(
                #selector(BaseTerminalController.toggleRearrangeMode(_:)), with: nil) == true)
            #expect(h.controller.rearrangeModeState.isActive)
        }
    }

    @Test func addressFieldForwardsChordsButKeepsTyping() async throws {
        try requireDefaultRearrangeBinding()
        try await withWindow(try markdownFile().path) { h in
            h.viewer.focusAddressBar()
            _ = await poll(timeout: 5) {
                h.viewer.layoutSubtreeIfNeeded()
                guard let field = ViewerView.firstTextField(in: h.viewer) else { return false }
                h.window.makeFirstResponder(field)
                return field.currentEditor() != nil
            }
            try #require(h.window.firstResponder is NSText, "address field never took the caret")

            // Plain typing and text navigation are never forwarded.
            #expect(!h.window.performKeyEquivalent(with: keyEvent("a", [], keyCode: 0, window: h.window)))
            #expect(!h.viewer.performKeyEquivalent(with: leftArrow([.command])))
            #expect(!h.controller.rearrangeModeState.isActive)

            // A chord the field has no use for reaches Ghoztty.
            #expect(h.window.performKeyEquivalent(with: cmdShiftPeriod(window: h.window)))
            #expect(h.controller.rearrangeModeState.isActive)
            #expect(h.window.firstResponder is NSText, "forwarding moved the caret out of the field")
        }
    }

    @Test func aFocusedTerminalIsUntouched() async throws {
        try await withWindow(try markdownFile().path) { h in
            let surface = try #require(h.surface)
            h.window.makeFirstResponder(surface)
            await settle(0.3)
            // performKeyEquivalent is offered to every view; the viewer must not
            // forward on a terminal's behalf, nor take its Cmd-C.
            #expect(!h.viewer.performKeyEquivalent(with: cmdShiftPeriod(window: h.window)))
            #expect(!h.viewer.performKeyEquivalent(with: keyEvent("c", [.command], keyCode: 8, window: h.window)))
            #expect(!h.controller.rearrangeModeState.isActive)
        }
    }

    /// The page gets first claim: WebKit takes every Command chord in the walk
    /// to offer it to the page, and only a chord the page leaves alone comes
    /// back (re-sent) to be forwarded. So the first pass must NOT forward.
    @Test func aFocusedPageGetsFirstClaim() async throws {
        try await withWindow(try markdownFile().path) { h in
            h.window.makeFirstResponder(h.viewer)
            await settle(0.3)
            try #require(h.window.firstResponder === h.viewer.webView)
            #expect(h.window.performKeyEquivalent(with: cmdShiftPeriod(window: h.window)))
            #expect(!h.controller.rearrangeModeState.isActive)
        }
    }

    /// The core half on its own: a window action performed through the
    /// window's terminal, with no terminal focused, and no key sent to it.
    @Test func coreDispatchPerformsWindowActionsThroughTheWindowsTerminal() async throws {
        try requireDefaultRearrangeBinding()
        try await withWindow(try imageFile().path) { h in
            let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
            let host = try #require(ViewerKeyFallback.hostSurface(in: h.controller))
            var cEvent = cmdShiftPeriod(window: h.window).ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            let performed = ">".withCString { ptr in
                cEvent.text = ptr
                return ghostty_app_key_binding_perform(app, host, cEvent)
            }
            #expect(performed)
            _ = await poll(timeout: 2) { h.controller.rearrangeModeState.isActive }
            #expect(h.controller.rearrangeModeState.isActive)
        }
    }

    /// Cmd-C in an image pane copies the picture — it used to reach no
    /// `copy:` handler at all.
    @Test func copyInAnImagePaneCopiesTheImage() async throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let file = try imageFile()
        try await withWindow(file.path) { h in
            h.window.makeFirstResponder(h.viewer)
            await settle(0.3)

            pasteboard.clearContents()
            #expect(h.window.performKeyEquivalent(with: keyEvent("c", [.command], keyCode: 8, window: h.window)))
            #expect(pasteboard.canReadObject(forClasses: [NSImage.self], options: nil))
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
            #expect(urls?.first?.standardizedFileURL == file.standardizedFileURL)
        }
    }
}
