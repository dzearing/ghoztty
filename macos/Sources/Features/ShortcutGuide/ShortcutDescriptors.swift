import Foundation

/// The guide's categories, in display order.
enum ShortcutCategory: String, CaseIterable, Identifiable, Hashable {
    case windows, panes, hero, sidebar, viewer, text, scrolling, font, app, advanced, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: return "Windows & Tabs"
        case .panes: return "Panes & Splits"
        case .hero: return "Hero & Rearrange"
        case .sidebar: return "Pane Sidebar & Stash"
        case .viewer: return "Viewer Panes"
        case .text: return "Text & Clipboard"
        case .scrolling: return "Scrolling & Search"
        case .font: return "Font & Appearance"
        case .app: return "App"
        case .advanced: return "Key Tables & Advanced"
        case .other: return "Other"
        }
    }

    /// SF Symbol for the sidebar.
    var symbol: String {
        switch self {
        case .windows: return "macwindow.on.rectangle"
        case .panes: return "rectangle.split.2x1"
        case .hero: return "rectangle.leadinghalf.inset.filled"
        case .sidebar: return "sidebar.left"
        case .viewer: return "doc.richtext"
        case .text: return "doc.on.clipboard"
        case .scrolling: return "magnifyingglass"
        case .font: return "textformat.size"
        case .app: return "app.badge"
        case .advanced: return "slider.horizontal.3"
        case .other: return "questionmark.square.dashed"
        }
    }

    /// A short note under the section title, when the section needs one.
    var subtitle: String? {
        switch self {
        case .viewer: return "while a viewer pane has focus"
        case .other: return "actions this guide has no description for yet"
        default: return nil
        }
    }
}

/// The curated, human-facing description of one keybind action.
///
/// This is a mapping layer over the real data: bindings always come from the
/// live config. An action with no descriptor still appears (under Other, with
/// its raw name), and `KeybindCatalogTests` fails when an action is added to
/// `Binding.zig` without one here.
struct ShortcutDescriptor {
    let category: ShortcutCategory
    /// Title for an action string's argument (empty when it has none).
    let title: (String) -> String
    let detail: (String) -> String
    /// Safe to run from the guide with one click: no data loss, no prompt
    /// that can't be dismissed, nothing typed into a shell.
    let runnable: Bool
    /// The action string to list (as "Not bound") when nothing binds this
    /// action. Nil for actions that make no sense without an argument the
    /// user picks (`text:…`) or don't apply on macOS.
    let unboundAction: String?

    init(
        _ category: ShortcutCategory,
        _ title: @escaping (String) -> String,
        _ detail: @escaping (String) -> String,
        runnable: Bool = false,
        unbound: String? = nil
    ) {
        self.category = category
        self.title = title
        self.detail = detail
        self.runnable = runnable
        self.unboundAction = unbound
    }

    init(
        _ category: ShortcutCategory,
        _ title: String,
        _ detail: String,
        runnable: Bool = false,
        unbound: String? = nil
    ) {
        self.init(category, { _ in title }, { _ in detail }, runnable: runnable, unbound: unbound)
    }
}

// swiftlint:disable function_body_length cyclomatic_complexity
enum ShortcutDescriptors {
    /// Descriptor per action tag (the part before `:`). Must cover every tag
    /// in `ghostty_input_action_keys()`.
    static let all: [String: ShortcutDescriptor] = {
        var d: [String: ShortcutDescriptor] = [:]

        // MARK: Windows & Tabs
        d["new_window"] = .init(.windows, "New Window", "Open a new terminal window.", runnable: true, unbound: "new_window")
        d["new_tab"] = .init(.windows, "New Tab", "Open a new tab in this window.", runnable: true, unbound: "new_tab")
        d["close_tab"] = .init(.windows, { arg in
            switch arg {
            case "other": return "Close Other Tabs"
            case "right": return "Close Tabs to the Right"
            default: return "Close Tab"
            }
        }, { arg in
            switch arg {
            case "other": return "Close every tab in this window except this one."
            case "right": return "Close every tab to the right of this one."
            default: return "Close this tab and every pane in it."
            }
        }, unbound: "close_tab:this")
        d["close_window"] = .init(.windows, "Close Window", "Close this window and all of its tabs.", unbound: "close_window")
        d["close_all_windows"] = .init(.windows, "Close All Windows", "Close every Ghoztty window.", unbound: "close_all_windows")
        d["previous_tab"] = .init(.windows, "Previous Tab", "Switch to the tab on the left.", runnable: true, unbound: "previous_tab")
        d["next_tab"] = .init(.windows, "Next Tab", "Switch to the tab on the right.", runnable: true, unbound: "next_tab")
        d["last_tab"] = .init(.windows, "Last Tab", "Switch to the rightmost tab.", runnable: true, unbound: "last_tab")
        d["goto_tab"] = .init(.windows, { "Go to Tab \($0)" }, { "Switch to tab \($0)." }, runnable: true)
        d["move_tab"] = .init(.windows, { (Int($0) ?? 0) < 0 ? "Move Tab Left" : "Move Tab Right" },
                              { _ in "Move this tab along the tab bar." }, runnable: true)
        d["toggle_tab_overview"] = .init(.windows, "Tab Overview", "Show all tabs as thumbnails (Linux only).")
        d["prompt_window_title"] = .init(.windows, "Rename Window…", "Give this window a title, shown in the title bar and the pane sidebar.",
                                         runnable: true, unbound: "prompt_window_title")
        d["prompt_tab_title"] = .init(.windows, "Rename Tab…", "Give this tab a title.", runnable: true, unbound: "prompt_tab_title")
        d["set_tab_title"] = .init(.windows, { "Set Tab Title to “\($0)”" }, { _ in "Set this tab's title to a fixed string." })
        d["toggle_fullscreen"] = .init(.windows, "Toggle Full Screen", "Enter or leave full screen.", runnable: true, unbound: "toggle_fullscreen")
        d["toggle_maximize"] = .init(.windows, "Toggle Maximize", "Maximize or restore this window.", runnable: true, unbound: "toggle_maximize")
        d["toggle_window_decorations"] = .init(.windows, "Toggle Window Decorations", "Show or hide the title bar and window border.",
                                               runnable: true, unbound: "toggle_window_decorations")
        d["toggle_window_float_on_top"] = .init(.windows, "Float on Top", "Keep this window above other apps' windows.",
                                                runnable: true, unbound: "toggle_window_float_on_top")
        d["reset_window_size"] = .init(.windows, "Reset Window Size", "Return this window to its configured default size.",
                                       runnable: true, unbound: "reset_window_size")
        d["goto_window"] = .init(.windows, { $0 == "previous" ? "Previous Window" : "Next Window" },
                                 { _ in "Focus the next or previous Ghoztty window." }, runnable: true, unbound: "goto_window:next")
        d["undo"] = .init(.windows, "Undo", "Undo the last window, tab or pane change — reopens what you just closed.", unbound: "undo")
        d["redo"] = .init(.windows, "Redo", "Redo the change you just undid.", unbound: "redo")

        // MARK: Panes & Splits
        d["new_split"] = .init(.panes, { "Split \(direction($0))" }, { arg in
            switch arg {
            case "right", "left": return "Open a new pane beside this one, on the \(arg)."
            case "down": return "Open a new pane below this one."
            case "up": return "Open a new pane above this one."
            default: return "Open a new pane, on the longer side of this one."
            }
        }, runnable: true, unbound: "new_split:right")
        d["goto_split"] = .init(.panes, { "Focus \(direction($0)) Pane" }, { arg in
            switch arg {
            case "previous", "next": return "Move focus to the \(arg) pane."
            default: return "Move focus to the pane \(relative(arg))."
            }
        }, runnable: true, unbound: "goto_split:next")
        d["swap_split"] = .init(.panes, { "Swap Pane \(direction($0))" }, { "Trade places with the pane \(relative($0))." },
                                runnable: true)
        d["resize_split"] = .init(.panes, { arg in
            "Resize Pane \(direction(arg.split(separator: ",").first.map(String.init) ?? arg))"
        }, { arg in
            let parts = arg.split(separator: ",").map(String.init)
            let amount = parts.count > 1 ? parts[1] : "10"
            return "Move the divider \(parts.first ?? "") by \(amount) points."
        }, runnable: true)
        d["equalize_splits"] = .init(.panes, "Equalize Panes", "Make every pane in this tab the same size.", runnable: true, unbound: "equalize_splits")
        d["toggle_split_zoom"] = .init(.panes, "Zoom Pane", "Fill the window with this pane; press again to bring the layout back.",
                                      runnable: true, unbound: "toggle_split_zoom")
        d["close_surface"] = .init(.panes, "Close Pane", "Close the focused pane or viewer.", unbound: "close_surface")
        d["prompt_surface_title"] = .init(.panes, "Rename Pane…", "Give the focused pane a title.", runnable: true, unbound: "prompt_surface_title")
        d["set_surface_title"] = .init(.panes, { "Set Pane Title to “\($0)”" }, { _ in "Set the focused pane's title to a fixed string." })
        d["prompt_surface_banner"] = .init(.panes, "Set Pane Banner…", "Edit the sticky markdown banner shown above this pane.",
                                          runnable: true, unbound: "prompt_surface_banner")
        d["toggle_readonly"] = .init(.panes, "Toggle Read-Only", "Stop (or resume) sending your keystrokes to this pane.",
                                    runnable: true, unbound: "toggle_readonly")

        // MARK: Hero & Rearrange
        d["toggle_hero_mode"] = .init(.hero, "Hero Mode", "Show the focused pane large, with every pane in a scrollable carousel beside it.",
                                     runnable: true, unbound: "toggle_hero_mode")
        d["toggle_rearrange_mode"] = .init(.hero, "Rearrange Mode",
                                          "Give every pane a drag header to move, swap, or pop it out into its own window. Esc exits.",
                                          runnable: true, unbound: "toggle_rearrange_mode")

        // MARK: Pane Sidebar & Stash
        d["toggle_pane_sidebar"] = .init(.sidebar, "Toggle Pane Sidebar", "Show or hide the sidebar of windows, panes and stashed panes.",
                                        runnable: true, unbound: "toggle_pane_sidebar")
        d["stash_pane"] = .init(.sidebar, "Stash Pane", "Put the focused pane away in the sidebar; it keeps running.",
                               runnable: true, unbound: "stash_pane")
        d["restore_stashed_pane"] = .init(.sidebar, "Restore Stashed Pane", "Bring the most recently stashed pane back into the layout.",
                                         runnable: true, unbound: "restore_stashed_pane")

        // MARK: Text & Clipboard
        d["copy_to_clipboard"] = .init(.text, { arg in
            switch arg {
            case "plain": return "Copy as Plain Text"
            case "vt": return "Copy as ANSI"
            case "html": return "Copy as HTML"
            default: return "Copy"
            }
        }, { arg in
            switch arg {
            case "plain": return "Copy the selection without any styling."
            case "vt": return "Copy the selection with its ANSI escape sequences."
            case "html": return "Copy the selection as HTML."
            default: return "Copy the selection, as plain text plus styling."
            }
        }, unbound: "copy_to_clipboard")
        d["paste_from_clipboard"] = .init(.text, "Paste", "Paste the clipboard into the terminal.", unbound: "paste_from_clipboard")
        d["paste_from_selection"] = .init(.text, "Paste Selection", "Paste the selection clipboard.", unbound: "paste_from_selection")
        d["copy_url_to_clipboard"] = .init(.text, "Copy Link", "Copy the link under the mouse pointer.", unbound: "copy_url_to_clipboard")
        d["copy_title_to_clipboard"] = .init(.text, "Copy Pane Title", "Copy the terminal's title.", unbound: "copy_title_to_clipboard")
        d["select_all"] = .init(.text, "Select All", "Select all text on the screen.", runnable: true, unbound: "select_all")
        d["adjust_selection"] = .init(.text, { arg in
            let names = ["page_up": "a Page Up", "page_down": "a Page Down", "home": "to the Top", "end": "to the Bottom",
                         "beginning_of_line": "to Line Start", "end_of_line": "to Line End"]
            return "Extend Selection \(names[arg] ?? direction(arg))"
        }, { _ in "Grow or shrink the current selection." })
        d["clear_screen"] = .init(.text, "Clear Screen", "Clear the screen and the scrollback.", unbound: "clear_screen")
        d["reset"] = .init(.text, "Reset Terminal", "Reset the terminal to a clean state.", unbound: "reset")
        d["write_screen_file"] = .init(.text, { "Save Screen to File, \(writeVerb($0))" },
                                       { _ in "Write the visible screen to a temporary file." })
        d["write_scrollback_file"] = .init(.text, { "Save Scrollback to File, \(writeVerb($0))" },
                                           { _ in "Write the whole scrollback to a temporary file." })
        d["write_selection_file"] = .init(.text, { "Save Selection to File, \(writeVerb($0))" },
                                          { _ in "Write the selection to a temporary file." })
        d["text"] = .init(.text, { arg in
            textNames[textKey(arg)]?.0 ?? "Type “\(arg)”"
        }, { arg in
            textNames[textKey(arg)]?.1 ?? "Send this text to the terminal."
        })
        d["esc"] = .init(.text, { arg in
            ["b": "Move Back One Word", "f": "Move Forward One Word", "d": "Delete Next Word"][arg] ?? "Send Esc \(arg)"
        }, { "Send Esc-\($0) to the shell." })
        d["csi"] = .init(.text, { "Send CSI \($0)" }, { _ in "Send a control sequence to the terminal." })
        d["cursor_key"] = .init(.text, "Send Cursor Key", "Send a cursor key in the terminal's current mode.")

        // MARK: Scrolling & Search
        d["scroll_to_top"] = .init(.scrolling, "Scroll to Top", "Jump to the start of the scrollback.", runnable: true, unbound: "scroll_to_top")
        d["scroll_to_bottom"] = .init(.scrolling, "Scroll to Bottom", "Jump back down to the live prompt.", runnable: true, unbound: "scroll_to_bottom")
        d["scroll_page_up"] = .init(.scrolling, "Page Up", "Scroll up one screen.", runnable: true, unbound: "scroll_page_up")
        d["scroll_page_down"] = .init(.scrolling, "Page Down", "Scroll down one screen.", runnable: true, unbound: "scroll_page_down")
        d["scroll_page_fractional"] = .init(.scrolling, { "Scroll \($0) Page" }, { _ in "Scroll by part of a page." }, runnable: true)
        d["scroll_page_lines"] = .init(.scrolling, { "Scroll \($0) Lines" }, { _ in "Scroll a fixed number of lines." }, runnable: true)
        d["scroll_to_selection"] = .init(.scrolling, "Scroll to Selection", "Bring the selected text into view.", runnable: true,
                                        unbound: "scroll_to_selection")
        d["scroll_to_row"] = .init(.scrolling, { "Scroll to Row \($0)" }, { _ in "Scroll to a specific row." }, runnable: true)
        d["jump_to_prompt"] = .init(.scrolling, { (Int($0) ?? 0) < 0 ? "Previous Prompt" : "Next Prompt" },
                                    { (Int($0) ?? 0) < 0 ? "Jump to the previous shell prompt." : "Jump to the next shell prompt." },
                                    runnable: true)
        d["start_search"] = .init(.scrolling, "Find…", "Search the scrollback.", runnable: true, unbound: "start_search")
        d["search_selection"] = .init(.scrolling, "Find Selection", "Search for the selected text.", runnable: true, unbound: "search_selection")
        d["search"] = .init(.scrolling, { "Find “\($0)”" }, { _ in "Search for a fixed string." }, runnable: true)
        d["navigate_search"] = .init(.scrolling, { $0 == "previous" ? "Find Previous" : "Find Next" },
                                     { $0 == "previous" ? "Go to the previous match." : "Go to the next match." }, runnable: true)
        d["end_search"] = .init(.scrolling, "Close Find", "Hide the find bar and clear its highlights.", runnable: true, unbound: "end_search")

        // MARK: Font & Appearance
        d["increase_font_size"] = .init(.font, "Bigger Text", "Increase the font size.", runnable: true, unbound: "increase_font_size:1")
        d["decrease_font_size"] = .init(.font, "Smaller Text", "Decrease the font size.", runnable: true, unbound: "decrease_font_size:1")
        d["reset_font_size"] = .init(.font, "Actual Size", "Reset the font size to your configured default.", runnable: true,
                                    unbound: "reset_font_size")
        d["set_font_size"] = .init(.font, { "Font Size \($0)" }, { _ in "Set the font size to a fixed value." }, runnable: true)
        d["toggle_background_opacity"] = .init(.font, "Toggle Background Opacity",
                                              "Switch between an opaque background and your translucent one.",
                                              runnable: true, unbound: "toggle_background_opacity")

        // MARK: App
        d["show_keyboard_shortcuts"] = .init(.app, "Keyboard Shortcuts", "Open this guide.", unbound: "show_keyboard_shortcuts")
        d["toggle_command_palette"] = .init(.app, "Command Palette", "Search for and run any command.", runnable: true,
                                           unbound: "toggle_command_palette")
        d["open_config"] = .init(.app, "Open Settings", "Open the Settings window (it can also open your config file).", runnable: true, unbound: "open_config")
        d["reload_config"] = .init(.app, "Reload Config", "Re-read your config without restarting.", runnable: true, unbound: "reload_config")
        d["inspector"] = .init(.app, "Terminal Inspector", "Show or hide the inspector for debugging terminal state.", runnable: true,
                              unbound: "inspector:toggle")
        d["toggle_quick_terminal"] = .init(.app, "Quick Terminal", "Slide the quick terminal in or out.", runnable: true,
                                          unbound: "toggle_quick_terminal")
        d["toggle_visibility"] = .init(.app, "Show/Hide Ghoztty", "Hide or reveal every Ghoztty window.", unbound: "toggle_visibility")
        d["toggle_secure_input"] = .init(.app, "Secure Keyboard Entry", "Stop other apps from observing what you type.", runnable: true,
                                        unbound: "toggle_secure_input")
        d["toggle_mouse_reporting"] = .init(.app, "Toggle Mouse Reporting", "Let (or stop) terminal programs see the mouse.", runnable: true,
                                           unbound: "toggle_mouse_reporting")
        d["check_for_updates"] = .init(.app, "Check for Updates…", "Look for a newer version of Ghoztty.", runnable: true,
                                      unbound: "check_for_updates")
        d["quit"] = .init(.app, "Quit Ghoztty", "Quit the app.", unbound: "quit")
        d["show_gtk_inspector"] = .init(.app, "GTK Inspector", "Open the GTK inspector (Linux only).")
        d["show_on_screen_keyboard"] = .init(.app, "On-Screen Keyboard", "Show the on-screen keyboard (Linux only).")

        // MARK: Key tables & advanced
        d["activate_key_table"] = .init(.advanced, { "Enter “\($0)” Key Table" },
                                        { _ in "Switch to a key table until it's deactivated." })
        d["activate_key_table_once"] = .init(.advanced, { "Enter “\($0)” Key Table for One Key" },
                                             { _ in "Use a key table for the next key press only." })
        d["deactivate_key_table"] = .init(.advanced, "Leave Key Table", "Return to the previous key table.")
        d["deactivate_all_key_tables"] = .init(.advanced, "Leave All Key Tables", "Return to the normal keybindings.")
        d["end_key_sequence"] = .init(.advanced, "Cancel Key Sequence", "Abandon a half-typed key sequence.")
        d["ignore"] = .init(.advanced, "Ignore Key", "Swallow this key: neither Ghoztty nor the program sees it.")
        d["unbind"] = .init(.advanced, "Unbind", "Remove a binding.")
        d["crash"] = .init(.advanced, { "Crash (\($0) thread)" }, { _ in "Deliberately crash, for testing crash reporting." })

        return d
    }()

    /// Display order within a category: the order of the table above.
    static let order: [String] = [
        "new_window", "new_tab", "close_tab", "close_window", "close_all_windows", "previous_tab", "next_tab",
        "last_tab", "goto_tab", "move_tab", "toggle_tab_overview", "prompt_window_title", "prompt_tab_title",
        "set_tab_title", "toggle_fullscreen", "toggle_maximize", "toggle_window_decorations",
        "toggle_window_float_on_top", "reset_window_size", "goto_window", "undo", "redo", "new_split", "goto_split",
        "swap_split", "resize_split", "equalize_splits", "toggle_split_zoom", "close_surface", "prompt_surface_title",
        "set_surface_title", "prompt_surface_banner", "toggle_readonly", "toggle_hero_mode", "toggle_rearrange_mode",
        "toggle_pane_sidebar", "stash_pane", "restore_stashed_pane", "copy_to_clipboard", "paste_from_clipboard",
        "paste_from_selection", "copy_url_to_clipboard", "copy_title_to_clipboard", "select_all", "adjust_selection",
        "clear_screen", "reset", "write_screen_file", "write_scrollback_file", "write_selection_file", "text", "esc",
        "csi", "cursor_key", "scroll_to_top", "scroll_to_bottom", "scroll_page_up", "scroll_page_down",
        "scroll_page_fractional", "scroll_page_lines", "scroll_to_selection", "scroll_to_row", "jump_to_prompt",
        "start_search", "search_selection", "search", "navigate_search", "end_search", "increase_font_size",
        "decrease_font_size", "reset_font_size", "set_font_size", "toggle_background_opacity",
        "show_keyboard_shortcuts", "toggle_command_palette", "open_config", "reload_config", "inspector",
        "toggle_quick_terminal", "toggle_visibility", "toggle_secure_input", "toggle_mouse_reporting",
        "check_for_updates", "quit", "show_gtk_inspector", "show_on_screen_keyboard", "activate_key_table",
        "activate_key_table_once", "deactivate_key_table", "deactivate_all_key_tables", "end_key_sequence", "ignore",
        "unbind", "crash",
    ]

    /// Built-in keys that are not configurable keybinds: they belong to a
    /// pane type or mode (docs/reference/viewer-panes.md, pane-rearrange.md).
    static let builtIns: [(ShortcutCategory, String, String, [String])] = [
        (.viewer, "Reload Viewer", "Re-fetch the page, re-render the file, or re-decode the image.", ["super+r"]),
        (.viewer, "Edit Address", "Put the caret in the address field, with the address selected.", ["super+l"]),
        (.viewer, "Find in Page", "Open the viewer's find bar.", ["super+f"]),
        (.viewer, "Find Next", "Step to the next match.", ["super+g"]),
        (.viewer, "Find Previous", "Step to the previous match.", ["super+shift+g"]),
        (.viewer, "Zoom In", "Zoom the page (or the image) in.", ["super+="]),
        (.viewer, "Zoom Out", "Zoom the page (or the image) out.", ["super+-"]),
        (.viewer, "Actual Size", "Reset page zoom; in an image pane, show it at 100%.", ["super+0"]),
        (.hero, "Leave Rearrange Mode", "Exit rearrange mode.", ["escape"]),
    ]

    /// Action tags that collapse into one row when several bindings share
    /// modifiers and differ only in the key (⌘1…⌘8, ⌥⌘ + arrows).
    static let families: [String: (title: String, detail: String)] = [
        "goto_tab": ("Go to Tab", "Switch to a tab by its number."),
        "goto_split": ("Focus Pane", "Move focus to the pane in that direction."),
        "swap_split": ("Swap Pane", "Trade places with the neighbouring pane in that direction."),
        "resize_split": ("Resize Pane", "Move the divider in that direction."),
        "adjust_selection": ("Extend Selection", "Grow or shrink the selection by character, line or page."),
    ]

    // MARK: Helpers

    private static let textNames: [String: (String, String)] = [
        "\\x05": ("Move to End of Line", "Send Ctrl-E to the shell."),
        "\\x01": ("Move to Start of Line", "Send Ctrl-A to the shell."),
        "\\x15": ("Delete to Start of Line", "Send Ctrl-U to the shell."),
        "\\x0b": ("Delete to End of Line", "Send Ctrl-K to the shell."),
        "\\x17": ("Delete Previous Word", "Send Ctrl-W to the shell."),
    ]

    /// Config's formatter may double the backslash in `text:\\x05`; look
    /// both spellings up as one.
    private static func textKey(_ arg: String) -> String {
        arg.replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func direction(_ arg: String) -> String {
        switch arg {
        case "right": return "Right"
        case "left": return "Left"
        case "up": return "Up"
        case "down": return "Down"
        case "previous": return "Previous"
        case "next": return "Next"
        case "auto": return "Auto"
        default: return arg.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func relative(_ arg: String) -> String {
        switch arg {
        case "up": return "above"
        case "down": return "below"
        case "left", "right": return "to the \(arg)"
        default: return arg
        }
    }

    private static func writeVerb(_ arg: String) -> String {
        switch arg.split(separator: ",").first.map(String.init) ?? "" {
        case "copy": return "Copy Path"
        case "paste": return "Paste Path"
        case "open": return "Open"
        default: return arg
        }
    }
}
// swiftlint:enable function_body_length cyclomatic_complexity
