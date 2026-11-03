//! The keyboard shortcut guide's catalog, the pure half (T2591) - the win32
//! counterpart of Mac's `KeybindCatalog.swift`, `ShortcutDescriptors.swift`
//! and `KeyTrigger.swift` (docs/reference/keyboard-shortcuts.md).
//!
//! Nothing here is a static list of shortcuts. The rows are built from the
//! live config's effective bindings (`src/config/keybind_list.zig`, the same
//! listing Mac decodes from `ghostty_config_keybinds_json`), compared against
//! a freshly built default config to say what the user customized, and
//! described by a curation table keyed on the action tag.
//!
//! The curation table is an EXHAUSTIVE switch over `Binding.Action.Key`, so
//! an action added to `Binding.zig` without a plain-language entry here is a
//! compile error in every lane - the same guarantee Mac's
//! `everyLibraryActionHasACuratedDescriptor` test gives, one step earlier.
//! `order` is checked by a test to name every tag exactly once.
//!
//! Where the Windows build differs from Mac it is named in place: chords are
//! drawn Windows' way (`Ctrl+Shift+D`, modifiers Win/Ctrl/Alt/Shift, the
//! order `menu_label.formatTrigger` already prints), the built-in viewer keys
//! are the Windows ones (docs/claude/viewers.md), and descriptors whose Mac
//! text says "Linux only" or "points" say what is true here.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const keybind_list = @import("../../config/keybind_list.zig");

pub const Entry = keybind_list.Entry;
const Key = input.Binding.Action.Key;

// ---------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------

/// The guide's categories, in display order (Mac's `ShortcutCategory`).
pub const Category = enum {
    windows,
    panes,
    hero,
    sidebar,
    viewer,
    text,
    scrolling,
    font,
    app,
    advanced,
    other,

    pub const count = @typeInfo(Category).@"enum".fields.len;

    pub fn title(self: Category) []const u8 {
        return switch (self) {
            .windows => "Windows & Tabs",
            .panes => "Panes & Splits",
            .hero => "Hero & Rearrange",
            .sidebar => "Pane Sidebar & Stash",
            .viewer => "Viewer Panes",
            .text => "Text & Clipboard",
            .scrolling => "Scrolling & Search",
            .font => "Font & Appearance",
            .app => "App",
            .advanced => "Key Tables & Advanced",
            .other => "Other",
        };
    }

    /// A short note under the section title, when the section needs one.
    pub fn subtitle(self: Category) ?[]const u8 {
        return switch (self) {
            .viewer => "while a viewer pane has focus",
            .other => "actions this guide has no description for yet",
            else => null,
        };
    }
};

// ---------------------------------------------------------------------
// The curation layer
// ---------------------------------------------------------------------

/// The curated, human-facing description of one action.
pub const Descriptor = struct {
    category: Category,
    title: []const u8,
    detail: []const u8,
    /// Safe to run from the guide with one click: no data loss, no prompt
    /// that cannot be dismissed, nothing typed into a shell.
    runnable: bool = false,
    /// The action string to list (as "Not bound") when nothing binds this
    /// action. Null for actions that make no sense without an argument the
    /// user picks (`text:...`) or that do not apply on Windows.
    unbound: ?[]const u8 = null,
};

fn d(
    category: Category,
    title: []const u8,
    detail: []const u8,
    runnable: bool,
    unbound: ?[]const u8,
) Descriptor {
    return .{ .category = category, .title = title, .detail = detail, .runnable = runnable, .unbound = unbound };
}

/// The descriptor for one action tag and its argument (the part after `:`).
/// Argument-dependent titles are formatted into `arena`.
pub fn describe(arena: Allocator, key: Key, arg: []const u8) Allocator.Error!Descriptor {
    const p = std.fmt.allocPrint;
    return switch (key) {
        // Windows & Tabs
        .new_window => d(.windows, "New Window", "Open a new terminal window.", true, "new_window"),
        .new_tab => d(.windows, "New Tab", "Open a new tab in this window.", true, "new_tab"),
        .close_tab => if (eql(arg, "other"))
            d(.windows, "Close Other Tabs", "Close every tab in this window except this one.", false, "close_tab:this")
        else if (eql(arg, "right"))
            d(.windows, "Close Tabs to the Right", "Close every tab to the right of this one.", false, "close_tab:this")
        else
            d(.windows, "Close Tab", "Close this tab and every pane in it.", false, "close_tab:this"),
        .close_window => d(.windows, "Close Window", "Close this window and all of its tabs.", false, "close_window"),
        .close_all_windows => d(.windows, "Close All Windows", "Close every Ghoztty window.", false, "close_all_windows"),
        .previous_tab => d(.windows, "Previous Tab", "Switch to the tab on the left.", true, "previous_tab"),
        .next_tab => d(.windows, "Next Tab", "Switch to the tab on the right.", true, "next_tab"),
        .last_tab => d(.windows, "Last Tab", "Switch to the rightmost tab.", true, "last_tab"),
        .goto_tab => d(.windows, try p(arena, "Go to Tab {s}", .{arg}), try p(arena, "Switch to tab {s}.", .{arg}), true, null),
        .move_tab => d(.windows, if (negative(arg)) "Move Tab Left" else "Move Tab Right", "Move this tab along the tab bar.", true, null),
        // Mac says "(Linux only)"; the win32 frontend performs it.
        .toggle_tab_overview => d(.windows, "Tab Overview", "Show all tabs as thumbnails.", true, "toggle_tab_overview"),
        .prompt_window_title => d(.windows, "Rename Window\u{2026}", "Give this window a title, shown in the title bar and the pane sidebar.", true, "prompt_window_title"),
        .prompt_tab_title => d(.windows, "Rename Tab\u{2026}", "Give this tab a title.", true, "prompt_tab_title"),
        .set_tab_title => d(.windows, try p(arena, "Set Tab Title to \u{201C}{s}\u{201D}", .{arg}), "Set this tab's title to a fixed string.", false, null),
        .toggle_fullscreen => d(.windows, "Toggle Full Screen", "Enter or leave full screen.", true, "toggle_fullscreen"),
        .toggle_maximize => d(.windows, "Toggle Maximize", "Maximize or restore this window.", true, "toggle_maximize"),
        .toggle_window_decorations => d(.windows, "Toggle Window Decorations", "Show or hide the title bar and window border.", true, "toggle_window_decorations"),
        .toggle_window_float_on_top => d(.windows, "Float on Top", "Keep this window above other apps' windows.", true, "toggle_window_float_on_top"),
        .reset_window_size => d(.windows, "Reset Window Size", "Return this window to its configured default size.", true, "reset_window_size"),
        .goto_window => d(.windows, if (eql(arg, "previous")) "Previous Window" else "Next Window", "Focus the next or previous Ghoztty window.", true, "goto_window:next"),
        .undo => d(.windows, "Undo", "Undo the last window, tab or pane change \u{2014} reopens what you just closed.", false, "undo"),
        .redo => d(.windows, "Redo", "Redo the change you just undid.", false, "redo"),

        // Panes & Splits
        .new_split => d(.panes, try p(arena, "Split {s}", .{direction(arg)}), if (eql(arg, "right") or eql(arg, "left"))
            try p(arena, "Open a new pane beside this one, on the {s}.", .{arg})
        else if (eql(arg, "down"))
            "Open a new pane below this one."
        else if (eql(arg, "up"))
            "Open a new pane above this one."
        else
            "Open a new pane, on the longer side of this one.", true, "new_split:right"),
        .goto_split => d(.panes, try p(arena, "Focus {s} Pane", .{direction(arg)}), if (eql(arg, "previous") or eql(arg, "next"))
            try p(arena, "Move focus to the {s} pane.", .{arg})
        else
            try p(arena, "Move focus to the pane {s}.", .{relative(arg)}), true, "goto_split:next"),
        .swap_split => d(.panes, try p(arena, "Swap Pane {s}", .{direction(arg)}), try p(arena, "Trade places with the pane {s}.", .{relative(arg)}), true, null),
        .resize_split => blk: {
            var it = std.mem.splitScalar(u8, arg, ',');
            const dir = it.next() orelse arg;
            const amount = it.next() orelse "10";
            // Mac says "points"; resize_split moves by pixels here.
            break :blk d(.panes, try p(arena, "Resize Pane {s}", .{direction(dir)}), try p(arena, "Move the divider {s} by {s} pixels.", .{ dir, amount }), true, null);
        },
        .equalize_splits => d(.panes, "Equalize Panes", "Make every pane in this tab the same size.", true, "equalize_splits"),
        .toggle_split_zoom => d(.panes, "Zoom Pane", "Fill the window with this pane; press again to bring the layout back.", true, "toggle_split_zoom"),
        .close_surface => d(.panes, "Close Pane", "Close the focused pane or viewer.", false, "close_surface"),
        .prompt_surface_title => d(.panes, "Rename Pane\u{2026}", "Give the focused pane a title.", true, "prompt_surface_title"),
        .set_surface_title => d(.panes, try p(arena, "Set Pane Title to \u{201C}{s}\u{201D}", .{arg}), "Set the focused pane's title to a fixed string.", false, null),
        .prompt_surface_banner => d(.panes, "Set Pane Banner\u{2026}", "Edit the sticky markdown banner shown above this pane.", true, "prompt_surface_banner"),
        .toggle_readonly => d(.panes, "Toggle Read-Only", "Stop (or resume) sending your keystrokes to this pane.", true, "toggle_readonly"),

        // Hero & Rearrange
        .toggle_hero_mode => d(.hero, "Hero Mode", "Show the focused pane large, with every pane in a scrollable carousel beside it.", true, "toggle_hero_mode"),
        .toggle_rearrange_mode => d(.hero, "Rearrange Mode", "Give every pane a drag header to move, swap, or pop it out into its own window. Esc exits.", true, "toggle_rearrange_mode"),

        // Pane Sidebar & Stash
        .toggle_pane_sidebar => d(.sidebar, "Toggle Pane Sidebar", "Show or hide the sidebar of windows, panes and stashed panes.", true, "toggle_pane_sidebar"),
        .stash_pane => d(.sidebar, "Stash Pane", "Put the focused pane away in the sidebar; it keeps running.", true, "stash_pane"),
        .restore_stashed_pane => d(.sidebar, "Restore Stashed Pane", "Bring the most recently stashed pane back into the layout.", true, "restore_stashed_pane"),

        // Text & Clipboard
        .copy_to_clipboard => if (eql(arg, "plain"))
            d(.text, "Copy as Plain Text", "Copy the selection without any styling.", false, "copy_to_clipboard")
        else if (eql(arg, "vt"))
            d(.text, "Copy as ANSI", "Copy the selection with its ANSI escape sequences.", false, "copy_to_clipboard")
        else if (eql(arg, "html"))
            d(.text, "Copy as HTML", "Copy the selection as HTML.", false, "copy_to_clipboard")
        else
            d(.text, "Copy", "Copy the selection, as plain text plus styling.", false, "copy_to_clipboard"),
        .paste_from_clipboard => d(.text, "Paste", "Paste the clipboard into the terminal.", false, "paste_from_clipboard"),
        .paste_from_selection => d(.text, "Paste Selection", "Paste the selection clipboard.", false, "paste_from_selection"),
        .copy_url_to_clipboard => d(.text, "Copy Link", "Copy the link under the mouse pointer.", false, "copy_url_to_clipboard"),
        .copy_title_to_clipboard => d(.text, "Copy Pane Title", "Copy the terminal's title.", false, "copy_title_to_clipboard"),
        .select_all => d(.text, "Select All", "Select all text on the screen.", true, "select_all"),
        .adjust_selection => d(.text, try p(arena, "Extend Selection {s}", .{selectionName(arg)}), "Grow or shrink the current selection.", false, null),
        .clear_screen => d(.text, "Clear Screen", "Clear the screen and the scrollback.", false, "clear_screen"),
        .reset => d(.text, "Reset Terminal", "Reset the terminal to a clean state.", false, "reset"),
        .write_screen_file => d(.text, try p(arena, "Save Screen to File, {s}", .{writeVerb(arg)}), "Write the visible screen to a temporary file.", false, null),
        .write_scrollback_file => d(.text, try p(arena, "Save Scrollback to File, {s}", .{writeVerb(arg)}), "Write the whole scrollback to a temporary file.", false, null),
        .write_selection_file => d(.text, try p(arena, "Save Selection to File, {s}", .{writeVerb(arg)}), "Write the selection to a temporary file.", false, null),
        .text => if (textName(arg)) |n|
            d(.text, n[0], n[1], false, null)
        else
            d(.text, try p(arena, "Type \u{201C}{s}\u{201D}", .{arg}), "Send this text to the terminal.", false, null),
        .esc => d(.text, if (eql(arg, "b"))
            "Move Back One Word"
        else if (eql(arg, "f"))
            "Move Forward One Word"
        else if (eql(arg, "d"))
            "Delete Next Word"
        else
            try p(arena, "Send Esc {s}", .{arg}), try p(arena, "Send Esc-{s} to the shell.", .{arg}), false, null),
        .csi => d(.text, try p(arena, "Send CSI {s}", .{arg}), "Send a control sequence to the terminal.", false, null),
        .cursor_key => d(.text, "Send Cursor Key", "Send a cursor key in the terminal's current mode.", false, null),

        // Scrolling & Search
        .scroll_to_top => d(.scrolling, "Scroll to Top", "Jump to the start of the scrollback.", true, "scroll_to_top"),
        .scroll_to_bottom => d(.scrolling, "Scroll to Bottom", "Jump back down to the live prompt.", true, "scroll_to_bottom"),
        .scroll_page_up => d(.scrolling, "Page Up", "Scroll up one screen.", true, "scroll_page_up"),
        .scroll_page_down => d(.scrolling, "Page Down", "Scroll down one screen.", true, "scroll_page_down"),
        .scroll_page_fractional => d(.scrolling, try p(arena, "Scroll {s} Page", .{arg}), "Scroll by part of a page.", true, null),
        .scroll_page_lines => d(.scrolling, try p(arena, "Scroll {s} Lines", .{arg}), "Scroll a fixed number of lines.", true, null),
        .scroll_to_selection => d(.scrolling, "Scroll to Selection", "Bring the selected text into view.", true, "scroll_to_selection"),
        .scroll_to_row => d(.scrolling, try p(arena, "Scroll to Row {s}", .{arg}), "Scroll to a specific row.", true, null),
        .jump_to_prompt => if (negative(arg))
            d(.scrolling, "Previous Prompt", "Jump to the previous shell prompt.", true, null)
        else
            d(.scrolling, "Next Prompt", "Jump to the next shell prompt.", true, null),
        .start_search => d(.scrolling, "Find\u{2026}", "Search the scrollback.", true, "start_search"),
        .search_selection => d(.scrolling, "Find Selection", "Search for the selected text.", true, "search_selection"),
        .search => d(.scrolling, try p(arena, "Find \u{201C}{s}\u{201D}", .{arg}), "Search for a fixed string.", true, null),
        .navigate_search => if (eql(arg, "previous"))
            d(.scrolling, "Find Previous", "Go to the previous match.", true, null)
        else
            d(.scrolling, "Find Next", "Go to the next match.", true, null),
        .end_search => d(.scrolling, "Close Find", "Hide the find bar and clear its highlights.", true, "end_search"),

        // Font & Appearance
        .increase_font_size => d(.font, "Bigger Text", "Increase the font size.", true, "increase_font_size:1"),
        .decrease_font_size => d(.font, "Smaller Text", "Decrease the font size.", true, "decrease_font_size:1"),
        .reset_font_size => d(.font, "Actual Size", "Reset the font size to your configured default.", true, "reset_font_size"),
        .set_font_size => d(.font, try p(arena, "Font Size {s}", .{arg}), "Set the font size to a fixed value.", true, null),
        .toggle_background_opacity => d(.font, "Toggle Background Opacity", "Switch between an opaque background and your translucent one.", true, "toggle_background_opacity"),

        // App
        .show_keyboard_shortcuts => d(.app, "Keyboard Shortcuts", "Open this guide.", false, "show_keyboard_shortcuts"),
        .toggle_command_palette => d(.app, "Command Palette", "Search for and run any command.", true, "toggle_command_palette"),
        .open_config => d(.app, "Open Settings", "Open your Ghoztty settings.", true, "open_config"),
        .reload_config => d(.app, "Reload Config", "Re-read your config without restarting.", true, "reload_config"),
        // The terminal inspector is not built on win32 (`commands.unsupported_actions`).
        .inspector => d(.app, "Terminal Inspector", "Show or hide the inspector for debugging terminal state (not on Windows yet).", false, null),
        .toggle_quick_terminal => d(.app, "Quick Terminal", "Slide the quick terminal in or out.", true, "toggle_quick_terminal"),
        .toggle_visibility => d(.app, "Show/Hide Ghoztty", "Hide or reveal every Ghoztty window.", false, "toggle_visibility"),
        .toggle_secure_input => d(.app, "Secure Keyboard Entry", "Stop other apps from observing what you type (macOS only).", false, null),
        .toggle_mouse_reporting => d(.app, "Toggle Mouse Reporting", "Let (or stop) terminal programs see the mouse.", true, "toggle_mouse_reporting"),
        .check_for_updates => d(.app, "Check for Updates\u{2026}", "Look for a newer version of Ghoztty.", true, "check_for_updates"),
        // Windows' word for it (File > Exit); Mac says Quit.
        .quit => d(.app, "Exit Ghoztty", "Close every window and exit the app.", false, "quit"),
        .show_gtk_inspector => d(.app, "GTK Inspector", "Open the GTK inspector (Linux only).", false, null),
        .show_on_screen_keyboard => d(.app, "On-Screen Keyboard", "Show the on-screen keyboard (Linux only).", false, null),

        // Key tables & advanced
        .activate_key_table => d(.advanced, try p(arena, "Enter \u{201C}{s}\u{201D} Key Table", .{arg}), "Switch to a key table until it's deactivated.", false, null),
        .activate_key_table_once => d(.advanced, try p(arena, "Enter \u{201C}{s}\u{201D} Key Table for One Key", .{arg}), "Use a key table for the next key press only.", false, null),
        .deactivate_key_table => d(.advanced, "Leave Key Table", "Return to the previous key table.", false, null),
        .deactivate_all_key_tables => d(.advanced, "Leave All Key Tables", "Return to the normal keybindings.", false, null),
        .end_key_sequence => d(.advanced, "Cancel Key Sequence", "Abandon a half-typed key sequence.", false, null),
        .ignore => d(.advanced, "Ignore Key", "Swallow this key: neither Ghoztty nor the program sees it.", false, null),
        .unbind => d(.advanced, "Unbind", "Remove a binding.", false, null),
        .crash => d(.advanced, try p(arena, "Crash ({s} thread)", .{arg}), "Deliberately crash, for testing crash reporting.", false, null),
    };
}

/// Display order within a category: Mac's `ShortcutDescriptors.order`,
/// verbatim. A test asserts it names every action tag exactly once.
pub const order = [_]Key{
    .new_window,                .new_tab,                .close_tab,                 .close_window,
    .close_all_windows,         .previous_tab,           .next_tab,                  .last_tab,
    .goto_tab,                  .move_tab,               .toggle_tab_overview,       .prompt_window_title,
    .prompt_tab_title,          .set_tab_title,          .toggle_fullscreen,         .toggle_maximize,
    .toggle_window_decorations, .toggle_window_float_on_top, .reset_window_size,     .goto_window,
    .undo,                      .redo,                   .new_split,                 .goto_split,
    .swap_split,                .resize_split,           .equalize_splits,           .toggle_split_zoom,
    .close_surface,             .prompt_surface_title,   .set_surface_title,         .prompt_surface_banner,
    .toggle_readonly,           .toggle_hero_mode,       .toggle_rearrange_mode,     .toggle_pane_sidebar,
    .stash_pane,                .restore_stashed_pane,   .copy_to_clipboard,         .paste_from_clipboard,
    .paste_from_selection,      .copy_url_to_clipboard,  .copy_title_to_clipboard,   .select_all,
    .adjust_selection,          .clear_screen,           .reset,                     .write_screen_file,
    .write_scrollback_file,     .write_selection_file,   .text,                      .esc,
    .csi,                       .cursor_key,             .scroll_to_top,             .scroll_to_bottom,
    .scroll_page_up,            .scroll_page_down,       .scroll_page_fractional,    .scroll_page_lines,
    .scroll_to_selection,       .scroll_to_row,          .jump_to_prompt,            .start_search,
    .search_selection,          .search,                 .navigate_search,           .end_search,
    .increase_font_size,        .decrease_font_size,     .reset_font_size,           .set_font_size,
    .toggle_background_opacity, .show_keyboard_shortcuts, .toggle_command_palette,   .open_config,
    .reload_config,             .inspector,              .toggle_quick_terminal,     .toggle_visibility,
    .toggle_secure_input,       .toggle_mouse_reporting, .check_for_updates,         .quit,
    .show_gtk_inspector,        .show_on_screen_keyboard, .activate_key_table,       .activate_key_table_once,
    .deactivate_key_table,      .deactivate_all_key_tables, .end_key_sequence,       .ignore,
    .unbind,                    .crash,
};

fn orderIndex(key: ?Key) usize {
    const k = key orelse return std.math.maxInt(usize);
    for (order, 0..) |o, i| if (o == k) return i;
    return std.math.maxInt(usize);
}

/// A key that is not a configurable keybind: it belongs to a pane type or a
/// mode. Windows' own chords (docs/claude/viewers.md, pane-rearrange).
pub const BuiltIn = struct {
    category: Category,
    title: []const u8,
    detail: []const u8,
    triggers: []const []const u8,
};

pub const built_ins = [_]BuiltIn{
    .{ .category = .viewer, .title = "Reload Viewer", .detail = "Re-fetch the page, re-render the file, or re-decode the image.", .triggers = &.{"ctrl+r"} },
    .{ .category = .viewer, .title = "Edit Address", .detail = "Put the caret in the address field, with the address selected.", .triggers = &.{ "ctrl+l", "alt+d" } },
    .{ .category = .viewer, .title = "Find in Page", .detail = "Open the viewer's find bar.", .triggers = &.{"ctrl+f"} },
    .{ .category = .viewer, .title = "Find Next", .detail = "Step to the next match.", .triggers = &.{ "ctrl+g", "f3" } },
    .{ .category = .viewer, .title = "Find Previous", .detail = "Step to the previous match.", .triggers = &.{ "ctrl+shift+g", "shift+f3" } },
    .{ .category = .viewer, .title = "Zoom In", .detail = "Zoom the page (or the image) in.", .triggers = &.{"ctrl+="} },
    .{ .category = .viewer, .title = "Zoom Out", .detail = "Zoom the page (or the image) out.", .triggers = &.{"ctrl+-"} },
    .{ .category = .viewer, .title = "Actual Size", .detail = "Reset page zoom; in an image pane, show it at 100%.", .triggers = &.{"ctrl+0"} },
    .{ .category = .hero, .title = "Leave Rearrange Mode", .detail = "Exit rearrange mode.", .triggers = &.{"escape"} },
};

/// Action tags that collapse into one row when three or more bindings share
/// modifiers and differ only in the key (Ctrl+1...8, Ctrl+Alt+arrows).
pub fn familyOf(key: ?Key) ?struct { title: []const u8, detail: []const u8 } {
    const k = key orelse return null;
    return switch (k) {
        .goto_tab => .{ .title = "Go to Tab", .detail = "Switch to a tab by its number." },
        .goto_split => .{ .title = "Focus Pane", .detail = "Move focus to the pane in that direction." },
        .swap_split => .{ .title = "Swap Pane", .detail = "Trade places with the neighbouring pane in that direction." },
        .resize_split => .{ .title = "Resize Pane", .detail = "Move the divider in that direction." },
        .adjust_selection => .{ .title = "Extend Selection", .detail = "Grow or shrink the selection by character, line or page." },
        else => null,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn negative(arg: []const u8) bool {
    const n = std.fmt.parseInt(i64, arg, 10) catch return false;
    return n < 0;
}

pub fn direction(arg: []const u8) []const u8 {
    const pairs = .{
        .{ "right", "Right" },  .{ "left", "Left" }, .{ "up", "Up" },     .{ "down", "Down" },
        .{ "previous", "Previous" }, .{ "next", "Next" }, .{ "auto", "Auto" },
    };
    inline for (pairs) |pr| if (eql(arg, pr[0])) return pr[1];
    return arg;
}

fn relative(arg: []const u8) []const u8 {
    if (eql(arg, "up")) return "above";
    if (eql(arg, "down")) return "below";
    if (eql(arg, "left")) return "to the left";
    if (eql(arg, "right")) return "to the right";
    return arg;
}

fn selectionName(arg: []const u8) []const u8 {
    const pairs = .{
        .{ "page_up", "a Page Up" },                .{ "page_down", "a Page Down" },
        .{ "home", "to the Top" },                  .{ "end", "to the Bottom" },
        .{ "beginning_of_line", "to Line Start" }, .{ "end_of_line", "to Line End" },
    };
    inline for (pairs) |pr| if (eql(arg, pr[0])) return pr[1];
    return direction(arg);
}

fn writeVerb(arg: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, arg, ',');
    const first = it.next() orelse "";
    if (eql(first, "copy")) return "Copy Path";
    if (eql(first, "paste")) return "Paste Path";
    if (eql(first, "open")) return "Open";
    return arg;
}

/// Plain names for the common `text:` shell bindings. Config's formatter may
/// double the backslash (`\\x05`), so both spellings are looked up as one.
fn textName(raw: []const u8) ?[2][]const u8 {
    const arg = if (std.mem.startsWith(u8, raw, "\\\\")) raw[1..] else raw;
    const pairs = .{
        .{ "\\x05", "Move to End of Line", "Send Ctrl-E to the shell." },
        .{ "\\x01", "Move to Start of Line", "Send Ctrl-A to the shell." },
        .{ "\\x15", "Delete to Start of Line", "Send Ctrl-U to the shell." },
        .{ "\\x0b", "Delete to End of Line", "Send Ctrl-K to the shell." },
        .{ "\\x17", "Delete Previous Word", "Send Ctrl-W to the shell." },
    };
    inline for (pairs) |pr| if (eql(arg, pr[0])) return .{ pr[1], pr[2] };
    return null;
}

// ---------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------

/// Modifiers, compared as a set.
pub const Mods = packed struct(u4) {
    super: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn isEmpty(self: Mods) bool {
        return @as(u4, @bitCast(self)) == 0;
    }

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u4, @bitCast(a)) == @as(u4, @bitCast(b));
    }

    /// Every spelling config (and people) use for a modifier. `win` and
    /// `windows` are the Windows names for config's `super`.
    pub fn parse(raw: []const u8) ?Mods {
        const names = .{
            .{ "ctrl", Mods{ .ctrl = true } },    .{ "control", Mods{ .ctrl = true } },
            .{ "alt", Mods{ .alt = true } },      .{ "opt", Mods{ .alt = true } },
            .{ "option", Mods{ .alt = true } },   .{ "shift", Mods{ .shift = true } },
            .{ "super", Mods{ .super = true } },  .{ "cmd", Mods{ .super = true } },
            .{ "command", Mods{ .super = true } }, .{ "win", Mods{ .super = true } },
            .{ "windows", Mods{ .super = true } },
            .{ "\u{2303}", Mods{ .ctrl = true } }, .{ "\u{2325}", Mods{ .alt = true } },
            .{ "\u{21E7}", Mods{ .shift = true } }, .{ "\u{2318}", Mods{ .super = true } },
        };
        inline for (names) |n| if (std.ascii.eqlIgnoreCase(raw, n[0])) return n[1];
        return null;
    }

    pub fn merge(a: Mods, b: Mods) Mods {
        return @bitCast(@as(u4, @bitCast(a)) | @as(u4, @bitCast(b)));
    }

    /// Windows' own order (Win, Ctrl, Alt, Shift) - `menu_label.formatTrigger`
    /// prints the same, and it is also config's canonical order.
    pub fn labels(self: Mods, out: *[4][]const u8) []const []const u8 {
        var n: usize = 0;
        if (self.super) {
            out[n] = "Win";
            n += 1;
        }
        if (self.ctrl) {
            out[n] = "Ctrl";
            n += 1;
        }
        if (self.alt) {
            out[n] = "Alt";
            n += 1;
        }
        if (self.shift) {
            out[n] = "Shift";
            n += 1;
        }
        return out[0..n];
    }

    fn canonicalNames(self: Mods, out: *[4][]const u8) []const []const u8 {
        var n: usize = 0;
        if (self.super) {
            out[n] = "super";
            n += 1;
        }
        if (self.ctrl) {
            out[n] = "ctrl";
            n += 1;
        }
        if (self.alt) {
            out[n] = "alt";
            n += 1;
        }
        if (self.shift) {
            out[n] = "shift";
            n += 1;
        }
        return out[0..n];
    }
};

/// One step of a trigger: modifiers plus a canonical key.
pub const Step = struct {
    mods: Mods,
    key: []const u8,
};

/// A parsed trigger: one step, or several for a sequence (`ctrl+a>n`).
pub const Trigger = struct {
    steps: []const Step,

    /// Parse config's trigger syntax. Null for an empty trigger. A `>` or `+`
    /// that IS the key (`ctrl++`, `ctrl+>`) is kept as the key.
    pub fn parse(arena: Allocator, raw: []const u8) Allocator.Error!?Trigger {
        var steps: std.ArrayList(Step) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '>' and i > start and raw[i - 1] != '+') {
                if (try parseStep(arena, raw[start..i])) |s| try steps.append(arena, s);
                start = i + 1;
            }
        }
        if (start < raw.len) if (try parseStep(arena, raw[start..])) |s| try steps.append(arena, s);
        if (steps.items.len == 0) return null;
        return .{ .steps = steps.items };
    }

    /// `ctrl+shift+d`, `ctrl+a>n`: modifiers in config's order.
    pub fn canonical(self: Trigger, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.steps, 0..) |s, i| {
            if (i > 0) try out.append(arena, '>');
            var buf: [4][]const u8 = undefined;
            for (s.mods.canonicalNames(&buf)) |m| {
                try out.appendSlice(arena, m);
                try out.append(arena, '+');
            }
            try out.appendSlice(arena, s.key);
        }
        return out.items;
    }

    /// `Ctrl+Shift+D`, `Ctrl+A then N` - the Windows way to write a chord.
    pub fn display(self: Trigger, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.steps, 0..) |s, i| {
            if (i > 0) try out.appendSlice(arena, " then ");
            var buf: [4][]const u8 = undefined;
            for (s.mods.labels(&buf)) |m| {
                try out.appendSlice(arena, m);
                try out.append(arena, '+');
            }
            try out.appendSlice(arena, try keyLabel(arena, s.key));
        }
        return out.items;
    }

    /// Whether this trigger is what a key-combo query names: the same
    /// modifiers on some step, and the key (if typed) matching it.
    pub fn matches(self: Trigger, mods: Mods, key: []const u8) bool {
        for (self.steps) |s| {
            if (!s.mods.eql(mods)) continue;
            if (key.len == 0 or keyMatches(s.key, key)) return true;
        }
        return false;
    }
};

fn parseStep(arena: Allocator, raw: []const u8) Allocator.Error!?Step {
    var tokens: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '+' and i > start) {
            try tokens.append(arena, raw[start..i]);
            start = i + 1;
        }
    }
    if (start < raw.len) try tokens.append(arena, raw[start..]);
    if (tokens.items.len == 0) return null;
    var mods: Mods = .{};
    for (tokens.items[0 .. tokens.items.len - 1]) |t| {
        // An unknown "modifier" means this is not a chord we understand;
        // keep it visible rather than dropping it.
        const m = Mods.parse(t) orelse return .{ .mods = .{}, .key = try std.ascii.allocLowerString(arena, raw) };
        mods = mods.merge(m);
    }
    return .{ .mods = mods, .key = try canonicalKey(arena, tokens.items[tokens.items.len - 1]) };
}

/// One spelling per key: config writes `digit_1` for the physical key and
/// `1` for the character, `period` vs `.`, and so on. They draw the same
/// keycap, so they compare equal.
pub fn canonicalKey(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const lower = try std.ascii.allocLowerString(arena, raw);
    if (std.mem.startsWith(u8, lower, "digit_") and lower.len == 7) return lower[6..];
    if (std.mem.startsWith(u8, lower, "numpad_")) return lower;
    const aliases = .{
        .{ "period", "." },         .{ "comma", "," },          .{ "slash", "/" },
        .{ "backslash", "\\" },     .{ "minus", "-" },          .{ "equal", "=" },
        .{ "semicolon", ";" },      .{ "quote", "'" },          .{ "backquote", "`" },
        .{ "grave_accent", "`" },   .{ "bracket_left", "[" },   .{ "bracket_right", "]" },
        .{ "plus", "+" },           .{ "return", "enter" },     .{ "esc", "escape" },
        .{ "up", "arrow_up" },      .{ "down", "arrow_down" },  .{ "left", "arrow_left" },
        .{ "right", "arrow_right" }, .{ "pageup", "page_up" },  .{ "pagedown", "page_down" },
        .{ "del", "delete" },       .{ "ins", "insert" },       .{ "pgup", "page_up" },
        .{ "pgdn", "page_down" },
    };
    inline for (aliases) |a| if (eql(lower, a[0])) return a[1];
    return lower;
}

/// The keycap label for a canonical key: `D`, `Enter`, `PgUp`, `F5`, `\u{2190}`.
/// Words match the Windows menu labels (`menu_label.keyName`); arrows are
/// drawn as glyphs so a family's keycaps stay narrow.
pub fn keyLabel(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    const names = .{
        .{ "arrow_left", "\u{2190}" }, .{ "arrow_right", "\u{2192}" }, .{ "arrow_up", "\u{2191}" },
        .{ "arrow_down", "\u{2193}" }, .{ "enter", "Enter" },          .{ "backspace", "Backspace" },
        .{ "delete", "Delete" },       .{ "escape", "Esc" },           .{ "tab", "Tab" },
        .{ "space", "Space" },         .{ "page_up", "PgUp" },         .{ "page_down", "PgDn" },
        .{ "home", "Home" },           .{ "end", "End" },              .{ "insert", "Insert" },
        .{ "caps_lock", "Caps Lock" }, .{ "context_menu", "Menu" },    .{ "numpad_enter", "Num Enter" },
    };
    inline for (names) |n| if (eql(key, n[0])) return n[1];
    if ((std.unicode.utf8CountCodepoints(key) catch 0) == 1) return std.ascii.allocUpperString(arena, key);
    if (key.len >= 2 and key[0] == 'f' and isDigits(key[1..])) return std.ascii.allocUpperString(arena, key);
    if (std.mem.startsWith(u8, key, "numpad_")) return std.fmt.allocPrint(arena, "Num {s}", .{try keyLabel(arena, key[7..])});
    // `media_play_pause` -> `Media Play Pause`.
    const out = try arena.dupe(u8, key);
    var up = true;
    for (out) |*c| {
        if (c.* == '_') {
            c.* = ' ';
            up = true;
        } else if (up) {
            c.* = std.ascii.toUpper(c.*);
            up = false;
        }
    }
    return out;
}

fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Whether a typed key name (`d`, `esc`, `PgUp`, `f5`) names canonical `key`.
fn keyMatches(key: []const u8, typed: []const u8) bool {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = fba.allocator();
    const want = canonicalKey(a, typed) catch return false;
    if (eql(key, want)) return true;
    const label = keyLabel(a, key) catch return false;
    return std.ascii.eqlIgnoreCase(label, typed);
}

// ---------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------

/// A binding as the guide shows it.
pub const Binding = struct {
    trigger: Trigger,
    global: bool = false,
    all: bool = false,
    /// Key table name; empty for the root set.
    table: []const u8 = "",
    chain: []const []const u8 = &.{},
    /// A collapsed family's keys (canonical), drawn as `mods + k1 k2 ...`.
    family_keys: ?[]const []const u8 = null,
};

pub const RowKind = enum { keybind, family, built_in };

/// One row of the guide.
pub const Row = struct {
    id: []const u8,
    kind: RowKind,
    /// Canonical action strings this row stands for (one, except families).
    actions: []const []const u8,
    action_key: []const u8,
    category: Category,
    title: []const u8,
    detail: []const u8,
    bindings: []const Binding,
    /// Bindings differ from the defaults (added, changed or removed).
    customized: bool = false,
    /// A default binding the user's config removed, leaving none.
    unbound_by_user: bool = false,
    /// No curated descriptor: shown with its raw action name.
    uncurated: bool = false,
    runnable: bool = false,

    pub fn action(self: Row) []const u8 {
        return if (self.actions.len > 0) self.actions[0] else "";
    }

    pub fn isBound(self: Row) bool {
        return self.bindings.len > 0;
    }

    pub fn isGlobal(self: Row) bool {
        for (self.bindings) |b| if (b.global) return true;
        return false;
    }

    /// The first key table any binding lives in, for the TABLE badge.
    pub fn table(self: Row) ?[]const u8 {
        for (self.bindings) |b| if (b.table.len > 0) return b.table;
        return null;
    }
};

fn argumentOf(action: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, action, ':') orelse return "";
    return action[i + 1 ..];
}

fn tagOf(action: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, action, ':') orelse return action;
    return action[0..i];
}

fn signature(arena: Allocator, e: Entry) Allocator.Error![]const u8 {
    const trig = if (try Trigger.parse(arena, e.trigger)) |t| try t.canonical(arena) else e.trigger;
    const chain = try std.mem.join(arena, ",", e.chain);
    return std.fmt.allocPrint(arena, "{s}|{s}|{s}|{s}{s}{s}{s}", .{
        e.table,
        trig,
        chain,
        if (e.global) "g" else "",
        if (e.all) "a" else "",
        if (e.consumed) "" else "u",
        if (e.performable) "p" else "",
    });
}

fn sameSignatureSet(arena: Allocator, a: []const Entry, b: []const Entry) Allocator.Error!bool {
    var sa: std.StringHashMapUnmanaged(void) = .empty;
    var sb: std.StringHashMapUnmanaged(void) = .empty;
    for (a) |e| try sa.put(arena, try signature(arena, e), {});
    for (b) |e| try sb.put(arena, try signature(arena, e), {});
    if (sa.count() != sb.count()) return false;
    var it = sa.keyIterator();
    while (it.next()) |k| if (!sb.contains(k.*)) return false;
    return true;
}

/// Every keyboard shortcut the guide knows: the live config's effective
/// bindings compared against the defaults, described by `describe`.
pub const Catalog = struct {
    /// Every row: bound actions, unbound-but-listable actions, built-ins.
    /// Families expanded; `visible` collapses them.
    rows: []const Row,

    pub const Options = struct {
        query: []const u8 = "",
        /// Null is "All Shortcuts".
        category: ?Category = null,
        include_unbound: bool = false,
        group_families: bool = true,
    };

    /// Build from entry lists. All memory lives in `arena`.
    pub fn build(arena: Allocator, effective: []const Entry, defaults: []const Entry) Allocator.Error!Catalog {
        var order_list: std.ArrayList([]const u8) = .empty;
        var by_action: std.StringArrayHashMapUnmanaged(std.ArrayList(Entry)) = .empty;
        for (effective) |e| {
            const gop = try by_action.getOrPut(arena, e.action);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                try order_list.append(arena, e.action);
            }
            try gop.value_ptr.append(arena, e);
        }
        var defaults_by: std.StringArrayHashMapUnmanaged(std.ArrayList(Entry)) = .empty;
        for (defaults) |e| {
            const gop = try defaults_by.getOrPut(arena, e.action);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, e);
        }

        var rows: std.ArrayList(Row) = .empty;
        var seen_keys: std.StringHashMapUnmanaged(void) = .empty;

        for (order_list.items) |action| {
            const entries = by_action.get(action).?.items;
            try rows.append(arena, try makeRow(arena, action, entries, &defaults_by));
            try seen_keys.put(arena, tagOf(action), {});
        }
        // Defaults the user's config unbound entirely.
        for (defaults_by.keys()) |action| {
            if (by_action.contains(action)) continue;
            try rows.append(arena, try makeRow(arena, action, &.{}, &defaults_by));
            try seen_keys.put(arena, tagOf(action), {});
        }
        // Every other action, as "Not bound" when it has a sensible
        // argument-free form.
        for (std.enums.values(Key)) |key| {
            if (seen_keys.contains(@tagName(key))) continue;
            const desc = try describe(arena, key, "");
            const action = desc.unbound orelse continue;
            try rows.append(arena, try makeRow(arena, action, &.{}, &defaults_by));
        }
        // Built-in, non-configurable keys.
        for (built_ins, 0..) |b, i| {
            var bindings: std.ArrayList(Binding) = .empty;
            for (b.triggers) |t| if (try Trigger.parse(arena, t)) |trig| try bindings.append(arena, .{ .trigger = trig });
            try rows.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "builtin:{d}", .{i}),
                .kind = .built_in,
                .actions = &.{},
                .action_key = "",
                .category = b.category,
                .title = b.title,
                .detail = b.detail,
                .bindings = bindings.items,
            });
        }
        return .{ .rows = rows.items };
    }

    /// Rows for display: filtered by the unbound toggle, the category and
    /// the search, families collapsed, sorted. A search always searches every
    /// category, the way Mac's does.
    pub fn visible(self: Catalog, arena: Allocator, opts: Options) Allocator.Error![]const Row {
        var kept: std.ArrayList(Row) = .empty;
        for (self.rows) |r| {
            if (!opts.include_unbound and !r.isBound() and !r.unbound_by_user) continue;
            try kept.append(arena, r);
        }
        const grouped = if (opts.group_families) try collapseFamilies(arena, kept.items) else kept.items;
        const query = std.mem.trim(u8, opts.query, " \t");
        var out: std.ArrayList(Row) = .empty;
        for (grouped) |r| {
            if (query.len == 0) {
                if (opts.category) |c| if (r.category != c) continue;
            } else if (!try matches(arena, r, query)) continue;
            try out.append(arena, r);
        }
        sortRows(out.items);
        return out.items;
    }

    /// Rows per category under the same filters, for the sidebar counts.
    pub fn counts(self: Catalog, arena: Allocator, opts: Options) Allocator.Error![Category.count]usize {
        var o = opts;
        o.category = null;
        var out: [Category.count]usize = @splat(0);
        for (try self.visible(arena, o)) |r| out[@intFromEnum(r.category)] += 1;
        return out;
    }

    /// Bound, non-built-in rows (families collapsed) and customized actions:
    /// the footer's "N shortcuts - M customized".
    pub fn summary(self: Catalog, arena: Allocator) Allocator.Error!struct { bound: usize, customized: usize } {
        var bound: usize = 0;
        for (try self.visible(arena, .{})) |r| {
            if (r.kind != .built_in and r.isBound()) bound += 1;
        }
        var customized: usize = 0;
        for (self.rows) |r| if (r.customized) {
            customized += 1;
        };
        return .{ .bound = bound, .customized = customized };
    }
};

fn makeRow(
    arena: Allocator,
    action: []const u8,
    entries: []const Entry,
    defaults_by: *const std.StringArrayHashMapUnmanaged(std.ArrayList(Entry)),
) Allocator.Error!Row {
    const action_key = if (entries.len > 0) entries[0].action_key else tagOf(action);
    const arg = argumentOf(action);
    const key = std.meta.stringToEnum(Key, action_key);
    const desc: ?Descriptor = if (key) |k| try describe(arena, k, arg) else null;
    const default_entries: []const Entry = if (defaults_by.get(action)) |l| l.items else &.{};

    // Collapse spellings that draw the same keycaps (ctrl+digit_1 vs ctrl+1).
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var bindings: std.ArrayList(Binding) = .empty;
    var all_root = true;
    for (entries) |e| {
        if (e.table.len > 0) all_root = false;
        const trig = (try Trigger.parse(arena, e.trigger)) orelse continue;
        const k = try std.fmt.allocPrint(arena, "{s}/{s}/{any}", .{ e.table, try trig.canonical(arena), e.global });
        const gop = try seen.getOrPut(arena, k);
        if (gop.found_existing) continue;
        try bindings.append(arena, .{
            .trigger = trig,
            .global = e.global,
            .all = e.all,
            .table = e.table,
            .chain = e.chain,
        });
    }
    return .{
        .id = action,
        .kind = .keybind,
        .actions = try arena.dupe([]const u8, &.{action}),
        .action_key = action_key,
        .category = if (desc) |x| x.category else .other,
        .title = if (desc) |x| x.title else action_key,
        .detail = if (desc) |x| x.detail else "No description yet \u{2014} listed by its raw action name.",
        .bindings = bindings.items,
        .customized = !try sameSignatureSet(arena, entries, default_entries),
        .unbound_by_user = entries.len == 0 and default_entries.len > 0,
        .uncurated = desc == null,
        .runnable = (if (desc) |x| x.runnable else false) and all_root,
    };
}

/// A row's family signature: the modifiers of each of its bindings, in
/// order, when every one is single-step, root-table and non-global (at most
/// four). Windows binds tabs twice (Ctrl+N and Alt+N), so rows that share
/// the whole list collapse together, one family binding per position.
fn modsSignature(row: Row) ?u32 {
    if (row.bindings.len == 0 or row.bindings.len > 4) return null;
    var sig: u32 = @intCast(row.bindings.len);
    for (row.bindings, 0..) |b, k| {
        if (b.table.len > 0 or b.global or b.trigger.steps.len != 1) return null;
        const m: u32 = @as(u4, @bitCast(b.trigger.steps[0].mods));
        sig |= m << @intCast(4 + 4 * k);
    }
    return sig;
}

/// Collapse rows of one family (same action tag) whose bindings share
/// modifiers and differ only by key, when three or more do.
pub fn collapseFamilies(arena: Allocator, rows: []const Row) Allocator.Error![]const Row {
    var out: std.ArrayList(Row) = .empty;
    const consumed = try arena.alloc(bool, rows.len);
    @memset(consumed, false);
    for (rows, 0..) |row, i| {
        if (consumed[i]) continue;
        const fam = familyOf(std.meta.stringToEnum(Key, row.action_key));
        const sig = modsSignature(row);
        if (row.kind != .keybind or fam == null or sig == null) {
            try out.append(arena, row);
            continue;
        }
        var members: std.ArrayList(usize) = .empty;
        for (rows, 0..) |r, j| {
            if (r.kind != .keybind or !eql(r.action_key, row.action_key)) continue;
            if (modsSignature(r) == sig) try members.append(arena, j);
        }
        if (members.items.len < 3) {
            try out.append(arena, row);
            continue;
        }
        // Members in the order the row sort would draw them, so the keys
        // read 1 2 3 ... and right down left up.
        const sorted_members = try arena.alloc(Row, members.items.len);
        for (members.items, sorted_members) |j, *dst| dst.* = rows[j];
        sortRows(sorted_members);
        var actions: std.ArrayList([]const u8) = .empty;
        var customized = false;
        for (members.items) |j| consumed[j] = true;
        for (sorted_members) |m| {
            try actions.appendSlice(arena, m.actions);
            customized = customized or m.customized;
        }
        const width = row.bindings.len;
        const bindings = try arena.alloc(Binding, width);
        for (bindings, 0..) |*fb, k| {
            const keys = try arena.alloc([]const u8, sorted_members.len);
            for (sorted_members, keys) |m, *dst| dst.* = m.bindings[k].trigger.steps[0].key;
            const step = try arena.dupe(Step, &.{.{ .mods = row.bindings[k].trigger.steps[0].mods, .key = keys[0] }});
            fb.* = .{ .trigger = .{ .steps = step }, .family_keys = keys };
        }
        try out.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "family:{s}:{d}", .{ row.action_key, sig.? }),
            .kind = .family,
            .actions = actions.items,
            .action_key = row.action_key,
            .category = row.category,
            .title = fam.?.title,
            .detail = fam.?.detail,
            .bindings = bindings,
            .customized = customized,
        });
    }
    return out.items;
}

/// Within one action tag: directions in reading order, numbers ascending.
fn argRank(action: []const u8) struct { group: u8, num: f64, rest: []const u8 } {
    const arg = argumentOf(action);
    const rank = [_][]const u8{ "right", "down", "left", "up", "next", "previous", "auto", "this", "other", "mixed", "plain" };
    for (rank, 0..) |r, i| if (std.mem.startsWith(u8, arg, r)) return .{ .group = 0, .num = @floatFromInt(i), .rest = "" };
    if (std.fmt.parseFloat(f64, arg)) |n| return .{ .group = 1, .num = n, .rest = "" } else |_| {}
    return .{ .group = 2, .num = 0, .rest = arg };
}

fn rowLess(_: void, l: Row, r: Row) bool {
    if (l.category != r.category) return @intFromEnum(l.category) < @intFromEnum(r.category);
    const lb = l.kind == .built_in;
    const rb = r.kind == .built_in;
    if (lb != rb) return rb;
    if (l.isBound() != r.isBound()) return l.isBound();
    const lo = orderIndex(std.meta.stringToEnum(Key, l.action_key));
    const ro = orderIndex(std.meta.stringToEnum(Key, r.action_key));
    if (lo != ro) return lo < ro;
    const la = argRank(l.action());
    const ra = argRank(r.action());
    if (la.group != ra.group) return la.group < ra.group;
    if (la.num != ra.num) return la.num < ra.num;
    return std.mem.lessThan(u8, la.rest, ra.rest);
}

/// Category order, then the curated order, then arguments in reading order;
/// unbound rows after bound ones, built-ins last. Stable, so equal rows keep
/// config order.
pub fn sortRows(rows: []Row) void {
    std.sort.insertion(Row, rows, {}, rowLess);
}

// ---------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------

/// A search query that names a key combo ("ctrl shift p", "Shift+Ctrl+P",
/// "win+e"): its modifiers and the rest. Null when it names no modifier.
pub fn parseQuery(arena: Allocator, query: []const u8) Allocator.Error!?struct { mods: Mods, key: []const u8 } {
    var mods: Mods = .{};
    var rest: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, query, " +");
    while (it.next()) |word| {
        if (Mods.parse(word)) |m| {
            mods = mods.merge(m);
            continue;
        }
        // Mac glyph runs ("\u{21E7}\u{2318}p") still search.
        var view = std.unicode.Utf8View.init(word) catch {
            try rest.appendSlice(arena, word);
            continue;
        };
        var cps = view.iterator();
        while (cps.nextCodepointSlice()) |cp| {
            if (Mods.parse(cp)) |m| mods = mods.merge(m) else try rest.appendSlice(arena, cp);
        }
    }
    if (mods.isEmpty()) return null;
    return .{ .mods = mods, .key = rest.items };
}

/// Whether `row` matches a search: its title, description, category or raw
/// action name, or - for a key-combo query - its keys, in any modifier order.
pub fn matches(arena: Allocator, row: Row, query: []const u8) Allocator.Error!bool {
    const q = std.mem.trim(u8, query, " \t");
    if (q.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(row.title, q) != null) return true;
    if (std.ascii.indexOfIgnoreCase(row.detail, q) != null) return true;
    if (std.ascii.indexOfIgnoreCase(row.category.title(), q) != null) return true;
    for (row.actions) |a| if (std.ascii.indexOfIgnoreCase(a, q) != null) return true;

    if (try parseQuery(arena, q)) |combo| {
        for (row.bindings) |b| {
            if (b.family_keys) |keys| {
                if (!b.trigger.steps[0].mods.eql(combo.mods)) continue;
                if (combo.key.len == 0) return true;
                for (keys) |k| if (keyMatches(k, combo.key)) return true;
                continue;
            }
            if (b.trigger.matches(combo.mods, combo.key)) return true;
        }
        return false;
    }
    // A bare key name ("f5", "esc") with no modifier.
    for (row.bindings) |b| {
        for (b.trigger.steps) |s| {
            if (s.mods.isEmpty() and keyMatches(s.key, q)) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------
// Keycaps
// ---------------------------------------------------------------------

/// What a binding draws: keycap labels, with `then` between sequence steps
/// and a family's keys after its modifiers. Digits that run 1..8 contiguously
/// collapse to `1-8` so a family row stays one line.
pub const Cap = struct {
    label: []const u8,
    /// A word drawn between caps ("then"), not a keycap.
    is_joiner: bool = false,
};

pub fn caps(arena: Allocator, b: Binding) Allocator.Error![]const Cap {
    var out: std.ArrayList(Cap) = .empty;
    if (b.family_keys) |keys| {
        var buf: [4][]const u8 = undefined;
        for (b.trigger.steps[0].mods.labels(&buf)) |m| try out.append(arena, .{ .label = m });
        if (digitRun(keys)) |run| {
            try out.append(arena, .{ .label = try std.fmt.allocPrint(arena, "{s}\u{2013}{s}", .{ run[0], run[1] }) });
        } else {
            for (keys) |k| try out.append(arena, .{ .label = try keyLabel(arena, k) });
        }
        return out.items;
    }
    for (b.trigger.steps, 0..) |s, i| {
        if (i > 0) try out.append(arena, .{ .label = "then", .is_joiner = true });
        var buf: [4][]const u8 = undefined;
        for (s.mods.labels(&buf)) |m| try out.append(arena, .{ .label = m });
        try out.append(arena, .{ .label = try keyLabel(arena, s.key) });
    }
    return out.items;
}

fn digitRun(keys: []const []const u8) ?[2][]const u8 {
    if (keys.len < 3) return null;
    var prev: ?u8 = null;
    for (keys) |k| {
        if (k.len != 1 or !std.ascii.isDigit(k[0])) return null;
        if (prev) |p| if (k[0] != p + 1) return null;
        prev = k[0];
    }
    return .{ keys[0], keys[keys.len - 1] };
}

/// The compact text of a binding: `Ctrl+Shift+D`, `Ctrl+1\u{2013}8`.
pub fn bindingText(arena: Allocator, b: Binding) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    // A family reads `Ctrl + 1\u{2013}8`, `Ctrl+Alt + \u{2192} \u{2193} \u{2190} \u{2191}`
    // (Mac: `\u{2318} + 1 \u{2026} 8`): the shared modifiers, then the keys.
    if (b.family_keys) |keys| {
        var buf: [4][]const u8 = undefined;
        for (b.trigger.steps[0].mods.labels(&buf), 0..) |m, i| {
            if (i > 0) try out.append(arena, '+');
            try out.appendSlice(arena, m);
        }
        if (out.items.len > 0) try out.appendSlice(arena, " + ");
        if (digitRun(keys)) |run| {
            try out.print(arena, "{s}\u{2013}{s}", .{ run[0], run[1] });
        } else for (keys, 0..) |k, i| {
            if (i > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, try keyLabel(arena, k));
        }
        return out.items;
    }
    const cs = try caps(arena, b);
    for (cs, 0..) |c, i| {
        if (c.is_joiner) {
            try out.appendSlice(arena, " then ");
            continue;
        }
        if (i > 0 and !cs[i - 1].is_joiner) try out.append(arena, '+');
        try out.appendSlice(arena, c.label);
    }
    return out.items;
}

// ---------------------------------------------------------------------
// Cheat sheet
// ---------------------------------------------------------------------

/// A printable cheat sheet of every bound shortcut by category, as a small
/// self-contained HTML page that opens its own print dialog (Mac's "Print
/// Cheat Sheet\u{2026}" opens the print panel; Save as PDF is in both).
pub fn cheatSheetHtml(arena: Allocator, rows: []const Row) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\<!doctype html><html><head><meta charset="utf-8"><title>Ghoztty Keyboard Shortcuts</title>
        \\<style>body{font:13px "Segoe UI",sans-serif;margin:24px;color:#111}h1{font-size:20px;margin:0 0 16px}
        \\.cols{columns:2;column-gap:32px}section{break-inside:avoid;margin:0 0 16px}
        \\h2{font-size:14px;margin:0 0 8px;border-bottom:1px solid #ccc;padding-bottom:4px}
        \\table{width:100%;border-collapse:collapse}td{padding:2px 0;vertical-align:top}
        \\td.k{text-align:right;white-space:nowrap;font-family:Consolas,monospace;padding-left:12px}
        \\@media print{body{margin:0}}</style></head>
        \\<body onload="window.print()"><h1>Ghoztty Keyboard Shortcuts</h1><div class="cols">
    );
    var current: ?Category = null;
    for (rows) |r| {
        if (!r.isBound()) continue;
        if (current != r.category) {
            if (current != null) try out.appendSlice(arena, "</table></section>");
            try out.appendSlice(arena, "<section><h2>");
            try escapeHtml(arena, &out, r.category.title());
            try out.appendSlice(arena, "</h2><table>");
            current = r.category;
        }
        try out.appendSlice(arena, "<tr><td>");
        try escapeHtml(arena, &out, r.title);
        try out.appendSlice(arena, "</td><td class=\"k\">");
        for (r.bindings, 0..) |b, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            try escapeHtml(arena, &out, try bindingText(arena, b));
        }
        try out.appendSlice(arena, "</td></tr>");
    }
    if (current != null) try out.appendSlice(arena, "</table></section>");
    try out.appendSlice(arena, "</div></body></html>\n");
    return out.items;
}

fn escapeHtml(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '<' => try out.appendSlice(arena, "&lt;"),
        '>' => try out.appendSlice(arena, "&gt;"),
        '&' => try out.appendSlice(arena, "&amp;"),
        '"' => try out.appendSlice(arena, "&quot;"),
        else => try out.append(arena, c),
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn ent(trigger: []const u8, action: []const u8) Entry {
    return .{
        .trigger = trigger,
        .action = action,
        .action_key = tagOf(action),
        .chain = &.{},
        .table = "",
        .global = false,
        .all = false,
        .consumed = true,
        .performable = false,
    };
}

test "order names every action tag exactly once" {
    var seen = std.EnumSet(Key).initEmpty();
    for (order) |k| {
        try testing.expect(!seen.contains(k));
        seen.insert(k);
    }
    try testing.expectEqual(std.enums.values(Key).len, order.len);
}

test "every action has a plain-language descriptor with a non-empty title" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (std.enums.values(Key)) |k| {
        const desc = try describe(arena, k, "x");
        try testing.expect(desc.title.len > 0);
        try testing.expect(desc.detail.len > 0);
        // An unbound form must itself parse as the same action tag.
        if (desc.unbound) |u| try testing.expectEqualStrings(@tagName(k), tagOf(u));
    }
}

test "arguments produce their own titles" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("Split Right", (try describe(arena, .new_split, "right")).title);
    try testing.expectEqualStrings("Go to Tab 3", (try describe(arena, .goto_tab, "3")).title);
    try testing.expectEqualStrings("Previous Prompt", (try describe(arena, .jump_to_prompt, "-1")).title);
    try testing.expectEqualStrings("Move to End of Line", (try describe(arena, .text, "\\x05")).title);
    try testing.expectEqualStrings("Move to End of Line", (try describe(arena, .text, "\\\\x05")).title);
}

test "triggers parse every spelling to one canonical form" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = (try Trigger.parse(arena, "shift+ctrl+D")).?;
    const b = (try Trigger.parse(arena, "control+shift+d")).?;
    try testing.expectEqualStrings("ctrl+shift+d", try a.canonical(arena));
    try testing.expectEqualStrings(try a.canonical(arena), try b.canonical(arena));
    try testing.expectEqualStrings("ctrl+1", try (try Trigger.parse(arena, "ctrl+digit_1")).?.canonical(arena));
    try testing.expectEqualStrings("ctrl++", try (try Trigger.parse(arena, "ctrl++")).?.canonical(arena));
    const seq = (try Trigger.parse(arena, "ctrl+a>n")).?;
    try testing.expectEqual(@as(usize, 2), seq.steps.len);
    try testing.expectEqualStrings("Ctrl+A then N", try seq.display(arena));
    try testing.expectEqualStrings("Win+Ctrl+Alt+Shift+\u{2190}", try (try Trigger.parse(arena, "shift+alt+ctrl+super+left")).?.display(arena));
    try testing.expectEqualStrings("Ctrl+>", try (try Trigger.parse(arena, "ctrl+>")).?.display(arena));
}

test "customized: added, changed and removed bindings, and an unbound default" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const defaults = [_]Entry{ ent("ctrl+n", "new_window"), ent("ctrl+t", "new_tab"), ent("ctrl+d", "new_split:right") };
    const effective = [_]Entry{ ent("ctrl+n", "new_window"), ent("ctrl+shift+t", "new_tab"), ent("ctrl+alt+p", "toggle_command_palette") };
    const cat = try Catalog.build(arena, &effective, &defaults);
    var found: u8 = 0;
    for (cat.rows) |r| {
        if (eql(r.id, "new_window")) {
            try testing.expect(!r.customized);
            found += 1;
        } else if (eql(r.id, "new_tab")) {
            try testing.expect(r.customized);
            found += 1;
        } else if (eql(r.id, "toggle_command_palette")) {
            try testing.expect(r.customized);
            try testing.expect(r.runnable);
            found += 1;
        } else if (eql(r.id, "new_split:right")) {
            try testing.expect(r.customized);
            try testing.expect(r.unbound_by_user);
            try testing.expect(!r.isBound());
            found += 1;
        }
    }
    try testing.expectEqual(@as(u8, 4), found);
    // The unbound default stays visible without "Show unbound actions".
    const vis = try cat.visible(arena, .{});
    var listed = false;
    for (vis) |r| if (eql(r.id, "new_split:right")) {
        listed = true;
    };
    try testing.expect(listed);
}

test "every action appears when unbound actions are included, uncurated ones under Other" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const effective = [_]Entry{ent("ctrl+q", "some_future_action")};
    const cat = try Catalog.build(arena, &effective, &.{});
    const vis = try cat.visible(arena, .{ .include_unbound = true });
    var other = false;
    for (vis) |r| if (eql(r.id, "some_future_action")) {
        other = r.category == .other and r.uncurated and eql(r.title, "some_future_action");
    };
    try testing.expect(other);
    // Unbound rows only with the toggle on.
    const off = try cat.visible(arena, .{});
    for (off) |r| try testing.expect(r.isBound() or r.unbound_by_user);
    try testing.expect(vis.len > off.len);
}

test "families collapse three or more same-modifier bindings into one row" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const effective = [_]Entry{
        ent("ctrl+3", "goto_tab:3"),          ent("ctrl+1", "goto_tab:1"), ent("ctrl+2", "goto_tab:2"),
        ent("ctrl+alt+up", "goto_split:up"),  ent("ctrl+alt+down", "goto_split:down"),
    };
    const cat = try Catalog.build(arena, &effective, &.{});
    const vis = try cat.visible(arena, .{});
    var family: ?Row = null;
    var split_rows: usize = 0;
    for (vis) |r| {
        if (r.kind == .family) family = r;
        if (eql(r.action_key, "goto_split")) split_rows += 1;
    }
    try testing.expect(family != null);
    try testing.expectEqualStrings("Go to Tab", family.?.title);
    try testing.expectEqualStrings("Ctrl + 1\u{2013}3", try bindingText(arena, family.?.bindings[0]));
    // Two goto_split bindings are not a family.
    try testing.expectEqual(@as(usize, 2), split_rows);

    // Windows binds each tab twice (Ctrl+N and Alt+N): rows that share the
    // whole modifier list still collapse, one family binding per position.
    const twice = [_]Entry{
        ent("ctrl+1", "goto_tab:1"), ent("alt+1", "goto_tab:1"),
        ent("ctrl+2", "goto_tab:2"), ent("alt+2", "goto_tab:2"),
        ent("ctrl+3", "goto_tab:3"), ent("alt+3", "goto_tab:3"),
    };
    const cat2 = try Catalog.build(arena, &twice, &.{});
    var fam2: ?Row = null;
    var tab_rows: usize = 0;
    for (try cat2.visible(arena, .{})) |r| {
        if (eql(r.action_key, "goto_tab")) tab_rows += 1;
        if (r.kind == .family) fam2 = r;
    }
    try testing.expectEqual(@as(usize, 1), tab_rows);
    try testing.expectEqual(@as(usize, 2), fam2.?.bindings.len);
    try testing.expectEqualStrings("Alt + 1\u{2013}3", try bindingText(arena, fam2.?.bindings[1]));
    // Editing keeps them apart.
    const flat = try cat.visible(arena, .{ .group_families = false });
    for (flat) |r| try testing.expect(r.kind != .family);
}

test "ordering: category, curated order, then arguments in reading order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const effective = [_]Entry{
        ent("ctrl+shift+e", "new_split:down"), ent("ctrl+d", "new_split:right"), ent("ctrl+n", "new_window"),
        ent("ctrl+c", "copy_to_clipboard:mixed"),
    };
    const cat = try Catalog.build(arena, &effective, &.{});
    const vis = try cat.visible(arena, .{});
    try testing.expectEqualStrings("new_window", vis[0].id);
    try testing.expectEqualStrings("new_split:right", vis[1].id);
    try testing.expectEqualStrings("new_split:down", vis[2].id);
    // The built-in rearrange exit (Hero) sorts between panes and text.
    try testing.expectEqual(Category.hero, vis[3].category);
    try testing.expectEqual(RowKind.built_in, vis[3].kind);
    // Categories never go backwards, and the copy row lands in Text.
    for (vis[1..], vis[0 .. vis.len - 1]) |r, prev| {
        try testing.expect(@intFromEnum(r.category) >= @intFromEnum(prev.category));
        if (eql(r.id, "copy_to_clipboard:mixed")) try testing.expectEqual(Category.text, r.category);
    }
    // Built-ins sort last within their category.
    var last_viewer: ?Row = null;
    for (vis) |r| if (r.category == .viewer) {
        last_viewer = r;
    };
    try testing.expectEqual(RowKind.built_in, last_viewer.?.kind);
}

test "search: words, key combos in any modifier order, and bare keys" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const effective = [_]Entry{
        ent("ctrl+shift+p", "toggle_command_palette"), ent("ctrl+d", "new_split:right"), ent("f11", "toggle_fullscreen"),
    };
    const cat = try Catalog.build(arena, &effective, &.{});
    const one = struct {
        fn ids(a: Allocator, c: Catalog, q: []const u8) ![]const Row {
            return c.visible(a, .{ .query = q, .category = .viewer });
        }
    };
    // Searching ignores the selected category.
    try testing.expect((try one.ids(arena, cat, "split")).len >= 1);
    for ([_][]const u8{ "ctrl shift p", "Shift+Ctrl+P", "ctrl+shift+p" }) |q| {
        const rows = try one.ids(arena, cat, q);
        var hit = false;
        for (rows) |r| if (eql(r.id, "toggle_command_palette")) {
            hit = true;
        };
        try testing.expect(hit);
    }
    const f11 = try one.ids(arena, cat, "f11");
    try testing.expectEqual(@as(usize, 1), f11.len);
    try testing.expectEqualStrings("toggle_fullscreen", f11[0].id);
    // "esc" finds the built-in rearrange exit.
    var esc_hit = false;
    for (try one.ids(arena, cat, "esc")) |r| if (eql(r.title, "Leave Rearrange Mode")) {
        esc_hit = true;
    };
    try testing.expect(esc_hit);
    // Ctrl alone lists every Ctrl chord and nothing with more modifiers.
    for (try one.ids(arena, cat, "ctrl")) |r| {
        if (eql(r.id, "toggle_command_palette")) {
            // matched only by text? its detail has no "ctrl" - so it must not be here
            return error.TestUnexpectedResult;
        }
    }
}

test "the effective config's real bindings build a catalog with no uncurated rows" {
    const alloc = testing.allocator;
    var cfg = try @import("../../config/Config.zig").default(alloc);
    defer cfg.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try keybind_list.entries(arena, &cfg.keybind);
    const cat = try Catalog.build(arena, list, list);
    try testing.expect(cat.rows.len > 20);
    for (cat.rows) |r| {
        try testing.expect(!r.uncurated);
        try testing.expect(!r.customized);
    }
    const s = try cat.summary(arena);
    try testing.expect(s.bound > 10);
    try testing.expectEqual(@as(usize, 0), s.customized);
}

test "cheat sheet lists bound rows by category and escapes text" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const effective = [_]Entry{ ent("ctrl+n", "new_window"), ent("ctrl+shift+,", "set_tab_title:<b>") };
    const cat = try Catalog.build(arena, &effective, &.{});
    const html = try cheatSheetHtml(arena, try cat.visible(arena, .{}));
    try testing.expect(std.mem.indexOf(u8, html, "<h2>Windows &amp; Tabs</h2>") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Ctrl+N") != null);
    try testing.expect(std.mem.indexOf(u8, html, "&lt;b&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, html, "window.print()") != null);
}
