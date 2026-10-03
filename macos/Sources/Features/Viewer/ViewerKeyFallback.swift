import AppKit
import GhosttyKit

/// Ghoztty's keybindings for a focused viewer pane.
///
/// Config-driven keybindings are dispatched by the focused terminal
/// (`SurfaceView.performKeyEquivalent`, which hands the key to libghostty).
/// A focused viewer pane has no terminal, so before this existed a chord the
/// viewer did not claim itself reached Ghoztty only if it happened to ALSO be
/// a menu item's key equivalent — and even that only after WebKit, which
/// claims every Command chord in the key-equivalent walk to offer it to the
/// page, re-sent it unhandled. Everything else in the keybind table silently
/// did nothing: Cmd+1…9, Cmd+Shift+[ / ], and Cmd+Shift+. (rearrange mode),
/// whose menu item has no key equivalent at all because its trigger is the
/// physical `period` key, which `KeyboardShortcut` cannot express.
///
/// The rule: **a chord nothing in the pane claims reaches Ghoztty's
/// bindings, exactly as it would from a focused terminal** — minus the
/// bindings that only make sense with a terminal focused. `ViewerView` asks
/// here only AFTER its own chords (zoom, Cmd-R/D/F/G, the editing chords)
/// and everything inside the pane (the web page, a text field, the feedback
/// composer) have declined, so the pane keeps first claim on every key.
///
/// What is never forwarded is decided by the core, exhaustively
/// (`Binding.Action.requires`): an action that acts on terminal state —
/// `text:`/`csi:`/`esc:`, copy/paste, font size, scrolling, search — would
/// otherwise be performed through some OTHER terminal in the window, i.e.
/// typed into a shell the user is not looking at. Those stay dead here, as
/// they must.
enum ViewerKeyFallback {
    /// What a chord is bound to, as the core reports it.
    struct Binding: Equatable {
        var flags: Ghostty.Input.BindingFlags
        var requires: Requires
        /// The canonical action, for a single-action binding. Nil for a chain.
        var action: String?
    }

    /// Mirrors `ghostty_binding_requires_e` (`Binding.Action.Requires`).
    enum Requires: Equatable {
        /// App-scoped: performed with no surface at all.
        case app
        /// Acts on the window; any terminal in it can name it.
        case window
        /// Acts on the focused pane — only a handler that knows viewer panes
        /// (the menu's) may perform it, never a terminal standing in.
        case pane
        /// Terminal state. Never forwarded.
        case terminal

        init(_ c: ghostty_binding_requires_e) {
            switch c {
            case GHOSTTY_BINDING_REQUIRES_APP: self = .app
            case GHOSTTY_BINDING_REQUIRES_WINDOW: self = .window
            case GHOSTTY_BINDING_REQUIRES_PANE: self = .pane
            default: self = .terminal
            }
        }
    }

    /// Where an unclaimed chord goes.
    enum Route: Equatable {
        /// Not ours to forward: the event continues exactly as it always did.
        case pass
        /// Perform the binding's menu item. Preferred, as a terminal prefers
        /// it: the menu flashes, and the menu's handlers are the ones that
        /// know a viewer pane can be the focused pane (split, close, zoom,
        /// hero, focus movement all act on the VIEWER from here).
        case menuItem
        /// Perform the binding through libghostty, never as terminal input.
        case core
    }

    /// Decide where an unclaimed chord goes. Pure, so the policy is testable
    /// without a pane, a menu, or a running app.
    ///
    /// - `textInputFocused`: a text field in the pane has the caret (the
    ///   address bar, a diff filter, the find field, the feedback composer).
    ///   Typing there must stay typing, so only Command chords the text system
    ///   does not itself use are forwarded (see `textInputOwns`).
    /// - `hasHostSurface`: the window has a terminal to perform window-scoped
    ///   actions through. The core performs those by naming a surface; a
    ///   window of nothing but viewers has none, so only app actions and menu
    ///   items reach Ghoztty from it.
    static func route(
        for binding: Binding?,
        event: NSEvent,
        textInputFocused: Bool,
        hasMenuItem: Bool,
        hasHostSurface: Bool
    ) -> Route {
        guard let binding else { return .pass }
        if textInputFocused && textInputOwns(event) { return .pass }

        // Global and all-surface bindings are explicitly not about the focused
        // pane: they act on every surface, and the core performs them exactly
        // as it would from a focused terminal.
        if !binding.flags.isDisjoint(with: [.global, .all]) { return .core }
        if binding.requires == .terminal { return .pass }

        // A performable binding must be able to decline, and the menu always
        // performs — the same reason `SurfaceView.performKeyEquivalent` keeps
        // performable bindings off the menu. (It also keeps `unconsumed:` ones
        // off it, so the key still reaches the terminal program; a viewer has
        // no program to pass the key to, so that half does not apply.)
        if hasMenuItem, !binding.flags.contains(.performable) {
            return .menuItem
        }

        switch binding.requires {
        case .app: return .core
        case .window: return hasHostSurface ? .core : .pass
        // Performing a pane action through a terminal would act on that
        // terminal's pane, not the viewer the user is looking at.
        case .pane, .terminal: return .pass
        }
    }

    /// True for a chord a focused text field uses itself: anything without
    /// Command (typing, Option-arrows, the Control emacs bindings), and the
    /// Command chords of text navigation and deletion (Cmd-arrows,
    /// Cmd-Home/End/PageUp/PageDown, Cmd-Backspace, Cmd-Delete). The editing
    /// chords (Cmd-C/V/X/A) never get this far — `ViewerView` routes them to
    /// the field first — and Cmd-Z/Shift-Z go through the Undo/Redo menu
    /// items, whose `undo:`/`redo:` reach the field's own undo stack.
    static func textInputOwns(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return true }
        switch event.specialKey {
        case .upArrow, .downArrow, .leftArrow, .rightArrow,
             .home, .end, .pageUp, .pageDown,
             .delete, .deleteForward, .backspace:
            return true
        default:
            break
        }
        // Backspace (51) and forward delete (117) by key code, for events
        // whose characters do not carry the special key.
        return event.keyCode == 51 || event.keyCode == 117
    }

    // MARK: - Dispatch

    /// Forward `event` to Ghoztty's binding dispatch on behalf of the focused
    /// viewer pane in `controller`'s window. Returns true when the event was
    /// consumed. A `performable:` binding that could not perform acts as if it
    /// did not exist, as in a terminal. An `unconsumed:` one that performed
    /// still consumes: in a terminal "unconsumed" means the key ALSO goes to
    /// the program running there, and a viewer has none — letting the key go
    /// on would only hand it to the menu, which could perform the same
    /// binding a second time.
    @MainActor
    static func perform(
        _ event: NSEvent,
        in controller: BaseTerminalController?,
        textInputFocused: Bool
    ) -> Bool {
        guard event.type == .keyDown,
              let delegate = NSApp.delegate as? AppDelegate,
              let app = delegate.ghostty.app,
              let config = delegate.ghostty.config.config,
              let binding = binding(for: event, config: config)
        else { return false }

        let host = controller.flatMap(hostSurface(in:))
        let hasMenuItem = binding.action.map { delegate.hasGhosttyBindingMenuItem(forAction: $0) } ?? false
        var route = Self.route(
            for: binding, event: event, textInputFocused: textInputFocused,
            hasMenuItem: hasMenuItem, hasHostSurface: host != nil)

        if route == .menuItem {
            if let action = binding.action, delegate.performGhosttyBindingMenuItem(forAction: action) {
                return true
            }
            // A disabled item: decide again as if there were none, which is
            // what a terminal falls back to (its keyDown) when the menu
            // declines.
            route = Self.route(
                for: binding, event: event, textInputFocused: textInputFocused,
                hasMenuItem: false, hasHostSurface: host != nil)
        }

        guard route == .core else { return false }
        let performed = withCEvent(event) { ghostty_app_key_binding_perform(app, host, $0) }
        if performed { return true }
        // Not performed: a performable binding passes the key on as if
        // unbound; any other consumed binding swallows it, as a terminal does.
        if binding.flags.contains(.performable) { return false }
        return !binding.flags.isDisjoint(with: [.consumed, .global, .all])
    }

    /// The terminal window-scoped actions are performed through: the one that
    /// last had focus, else any terminal in the window.
    @MainActor
    static func hostSurface(in controller: BaseTerminalController) -> ghostty_surface_t? {
        if let surface = controller.focusedSurface?.surface { return surface }
        return controller.surfaceTree.first(where: { $0.surfaceView?.surface != nil })?
            .surfaceView?.surface
    }

    /// What the core says `event` is bound to under `config`, or nil if it is
    /// not a binding. The app's config — the same one `AppDelegate`'s
    /// no-window key fallback checks bindings against.
    static func binding(for event: NSEvent, config: ghostty_config_t) -> Binding? {
        var info = ghostty_binding_info_s()
        let found = withCEvent(event) { ghostty_config_key_binding(config, $0, &info) }
        guard found else { return nil }
        let action = Ghostty.AllocatedString(info.action).string
        return Binding(
            flags: Ghostty.Input.BindingFlags(rawValue: UInt32(info.flags)),
            requires: Requires(info.requires),
            action: action.isEmpty ? nil : action)
    }

    /// The C key event for `event`, built the way every other binding check
    /// in the app builds it (text from `characters`).
    private static func withCEvent<T>(_ event: NSEvent, _ body: (ghostty_input_key_s) -> T) -> T {
        var cEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        return (event.characters ?? "").withCString { ptr in
            cEvent.text = ptr
            return body(cEvent)
        }
    }
}
