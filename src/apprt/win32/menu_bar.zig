//! Pure model for the Windows menu system (T143/T189): the menu tree, its
//! titles and mnemonics, and the per-item enabled/checked state.
//!
//! The user's report was blunt — *"on the mac version, there is a way to
//! access the menu bar. On windows, there's none."* Windows had only the
//! right-click context menu (T102) and the command palette, so every labeled
//! command was undiscoverable unless you already knew its chord. T129 was a
//! symptom of the same hole.
//!
//! ## The host is a button, not a classic menu bar
//!
//! The tree here is rendered as a nested `HMENU` opened from a `≡` button at
//! the right end of the tab strip (T190), NOT installed with `SetMenu`. Three
//! reasons, in order of weight:
//!
//! 1. **Dark mode.** The classic menu BAR is drawn by the system frame and
//!    ignores the uxtheme dark-mode ordinals; only popup menus honor them
//!    (that is the whole T79 mechanism). A `SetMenu` bar would be a light
//!    gray strip pinned above a dark terminal on every dark theme.
//! 2. **Layout.** A `SetMenu` bar lives outside the client area, and every
//!    layout path in `Window.zig` is written against "client top == tab
//!    strip". Moving that origin touches split geometry, banner insets, and
//!    the hero carousel for no user-visible gain.
//! 3. **Convention.** Windows' own modern terminals put this menu behind a
//!    caption/tab-strip button — Windows Terminal's `⌄`, VS Code's and Edge's
//!    hamburger. A menu bar would look older than the app, not more native.
//!
//! Mnemonics (`&`) and accelerator hints (`\t`) both work in a popup menu, so
//! the keyboard affordances of a real menu bar survive the move.
//!
//! ## One command list, two surfaces
//!
//! Items do not carry actions. They carry a `commands.Id`, and `commands.zig`
//! owns what that performs — the same registry the command palette renders.
//! A menu row therefore cannot drift from its palette twin or dispatch
//! through a second code path, and `everyCommandIsPlacedOrOmitted` below
//! fails the build if a new command lands in neither surface.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.

const std = @import("std");
const commands = @import("commands.zig");

fn u16lit(comptime s: []const u8) [:0]const u16 {
    // The tree is ~60 UTF-16 literals; each one costs comptime branches in
    // std's transcoder, and the default 1000-branch quota runs out partway
    // through building it.
    @setEvalBranchQuota(20_000);
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

pub const Item = struct {
    cmd: commands.Id,
    /// UTF-16 title ready for `AppendMenuW`, including its `&` mnemonic.
    /// The host appends `\t<chord>` from the LIVE keybind set (T129), so a
    /// rebind relabels the menu and an unbound command shows no hint.
    title: [:0]const u16,
};

pub const Submenu = struct {
    title: [:0]const u16,
    items: []const Node,
};

pub const Node = union(enum) {
    separator,
    item: Item,
    submenu: Submenu,
};

/// Surface/window state the menu reflects. Everything here is cheap to read
/// on the GUI thread at open time — the menu is built fresh per open, so
/// there is no stale-state class of bug to guard against.
pub const State = struct {
    has_selection: bool = false,
    readonly: bool = false,
    /// The find bar is open, so navigating/hiding it can do something.
    search_active: bool = false,
    /// Tabs in the window. `close_tab` and tab cycling need >1 to mean
    /// anything.
    tab_count: usize = 1,
    /// Panes in the active tab. Split navigation/resize needs >1.
    pane_count: usize = 1,
    /// `session-persistence` is on, so quitting DETACHES sessions for
    /// re-attach rather than ending them — and the menu must say so (T89e).
    session_persistence: bool = false,
    /// The window currently carries `WS_EX_TOPMOST` (T191), so the Float on
    /// Top row shows a checkmark. Read from the live ex-style at open time,
    /// never tracked separately — the OS owns this bit and another process
    /// can change it.
    float_on_top: bool = false,
    /// This is the quick terminal, which topmosts itself as part of how it
    /// works. Float on Top would fight it, so the row is grayed — matching
    /// Mac, where `validateMenuItem` disables it for anything that is not a
    /// primary terminal window (`AppDelegate.swift`).
    is_quick_terminal: bool = false,
    /// This window has a pane or tab close it can still undo, or an undo it
    /// can still redo (T1825).
    can_undo: bool = false,
    can_redo: bool = false,
    /// This window has a pane sidebar at all (T1848) — every window but the
    /// quick terminal (Mac `hasPaneSidebar`).
    has_pane_sidebar: bool = false,
    /// The sidebar is hidden outright, so its row offers to SHOW it.
    pane_sidebar_hidden: bool = false,
    /// Panes ON SCREEN in the active tab: `pane_count` minus the stashed
    /// ones. Stashing the last of them is refused, so the row grays.
    visible_pane_count: usize = 1,
    /// Panes in the active tab's stash.
    stashed_count: usize = 0,
};

pub const Flags = struct {
    enabled: bool = true,
    checked: bool = false,
};

// --- The tree -------------------------------------------------------------
//
// Mirrors macOS `MainMenu.xib` (File / Edit / View / Window / Help) item for
// item wherever the command exists on Windows. Deviations are deliberate and
// each is named in a comment; commands that stay palette-only are in
// `omitted` with a reason.

const file_menu = [_]Node{
    .{ .item = .{ .cmd = .new_window, .title = u16lit("&New Window") } },
    .{ .item = .{ .cmd = .new_remote_window, .title = u16lit("New &Remote Window") } },
    .{ .item = .{ .cmd = .new_tab, .title = u16lit("New &Tab") } },
    .separator,
    .{ .item = .{ .cmd = .split_right, .title = u16lit("Split R&ight") } },
    .{ .item = .{ .cmd = .split_left, .title = u16lit("Split &Left") } },
    .{ .item = .{ .cmd = .split_down, .title = u16lit("Split &Down") } },
    .{ .item = .{ .cmd = .split_up, .title = u16lit("Split &Up") } },
    .separator,
    // Mac's "Close" is the pane; Windows names the noun so the three Close
    // rows read unambiguously in a flat list.
    .{ .item = .{ .cmd = .close_surface, .title = u16lit("&Close Pane") } },
    .{ .item = .{ .cmd = .close_tab, .title = u16lit("Close Ta&b") } },
    .{ .item = .{ .cmd = .close_window, .title = u16lit("Close &Window") } },
    .{ .item = .{ .cmd = .close_all_windows, .title = u16lit("Close &All Windows") } },
    .separator,
    // T1804: beside Exit, because they are Exit's siblings — the app going
    // away, and coming back. Mac adds the same pair to its application menu
    // (T1805), which is where its Quit lives. `R` and `S` are taken at this
    // level (Remote, Split), hence `e` and `g`.
    .{ .item = .{ .cmd = .restart_app, .title = u16lit("R&estart Ghoztty") } },
    .{ .item = .{ .cmd = .restart_app_and_agent, .title = u16lit("Restart Ghoztty and Back&ground Sessions…") } },
    // Windows convention puts Exit at the foot of File; Mac's lives in the
    // application menu, which Windows does not have.
    .{ .item = .{ .cmd = .quit, .title = u16lit("E&xit") } },
};

const edit_menu = [_]Node{
    // Mac's Edit menu opens with Undo/Redo too. Here they bring back a closed
    // pane or tab (T1825); grayed when there is none.
    .{ .item = .{ .cmd = .undo, .title = u16lit("Und&o Close") } },
    .{ .item = .{ .cmd = .redo, .title = u16lit("&Redo Close") } },
    .separator,
    .{ .item = .{ .cmd = .copy_to_clipboard, .title = u16lit("&Copy") } },
    .{ .item = .{ .cmd = .paste_from_clipboard, .title = u16lit("&Paste") } },
    .{ .item = .{ .cmd = .select_all, .title = u16lit("Select &All") } },
    .separator,
    .{ .item = .{ .cmd = .find, .title = u16lit("&Find…") } },
    .{ .item = .{ .cmd = .find_next, .title = u16lit("Find &Next") } },
    .{ .item = .{ .cmd = .find_previous, .title = u16lit("Find Pre&vious") } },
    .{ .item = .{ .cmd = .hide_find_bar, .title = u16lit("&Hide Find Bar") } },
    .separator,
    .{ .item = .{ .cmd = .search_selection, .title = u16lit("&Use Selection for Find") } },
    .{ .item = .{ .cmd = .jump_to_selection, .title = u16lit("&Jump to Selection") } },
};

const view_menu = [_]Node{
    .{ .item = .{ .cmd = .reset_font_size, .title = u16lit("&Reset Font Size") } },
    .{ .item = .{ .cmd = .increase_font_size, .title = u16lit("&Increase Font Size") } },
    .{ .item = .{ .cmd = .decrease_font_size, .title = u16lit("&Decrease Font Size") } },
    .separator,
    .{ .item = .{ .cmd = .command_palette, .title = u16lit("Command &Palette") } },
    .separator,
    .{ .item = .{ .cmd = .prompt_window_title, .title = u16lit("Change &Window Title…") } },
    .{ .item = .{ .cmd = .prompt_tab_title, .title = u16lit("Change &Tab Title…") } },
    .{ .item = .{ .cmd = .prompt_surface_title, .title = u16lit("Change Pan&e Title…") } },
    // Windows-only row. Mac reaches the banner editor with cmd+r; the
    // Windows chord had to differ (plain ctrl+r is the shell's reverse
    // search), and naming it nowhere is what made a working feature read as
    // broken (T129).
    .{ .item = .{ .cmd = .prompt_surface_banner, .title = u16lit("Set Pane &Banner…") } },
    .separator,
    .{ .item = .{ .cmd = .toggle_readonly, .title = u16lit("Terminal Read-&only") } },
    .separator,
    .{ .item = .{ .cmd = .toggle_quick_terminal, .title = u16lit("&Quick Terminal") } },
};

const select_split_menu = [_]Node{
    .{ .item = .{ .cmd = .focus_split_up, .title = u16lit("Select Split &Above") } },
    .{ .item = .{ .cmd = .focus_split_down, .title = u16lit("Select Split &Below") } },
    .{ .item = .{ .cmd = .focus_split_left, .title = u16lit("Select Split &Left") } },
    .{ .item = .{ .cmd = .focus_split_right, .title = u16lit("Select Split &Right") } },
};

// Windows addition: the swap commands are real here (T18/T61) and their only
// home was the palette. They belong beside Select Split, not in a menu of
// their own.
const swap_split_menu = [_]Node{
    .{ .item = .{ .cmd = .swap_split_up, .title = u16lit("Swap Split &Up") } },
    .{ .item = .{ .cmd = .swap_split_down, .title = u16lit("Swap Split &Down") } },
    .{ .item = .{ .cmd = .swap_split_left, .title = u16lit("Swap Split &Left") } },
    .{ .item = .{ .cmd = .swap_split_right, .title = u16lit("Swap Split &Right") } },
};

const resize_split_menu = [_]Node{
    .{ .item = .{ .cmd = .equalize_splits, .title = u16lit("&Equalize Splits") } },
    .separator,
    .{ .item = .{ .cmd = .move_divider_up, .title = u16lit("Move Divider &Up") } },
    .{ .item = .{ .cmd = .move_divider_down, .title = u16lit("Move Divider &Down") } },
    .{ .item = .{ .cmd = .move_divider_left, .title = u16lit("Move Divider &Left") } },
    .{ .item = .{ .cmd = .move_divider_right, .title = u16lit("Move Divider &Right") } },
};

const window_menu = [_]Node{
    .{ .item = .{ .cmd = .toggle_fullscreen, .title = u16lit("Toggle &Full Screen") } },
    // Mac's "Zoom" is Windows' maximize; use the Windows word.
    .{ .item = .{ .cmd = .toggle_maximize, .title = u16lit("Ma&ximize") } },
    .{ .item = .{ .cmd = .toggle_visibility, .title = u16lit("Show/&Hide All Terminals") } },
    .separator,
    .{ .item = .{ .cmd = .toggle_split_zoom, .title = u16lit("&Zoom Split") } },
    .{ .item = .{ .cmd = .toggle_hero_mode, .title = u16lit("Toggle Hero &Mode") } },
    .{ .item = .{ .cmd = .toggle_rearrange_mode, .title = u16lit("Toggle Re&arrange Mode") } },
    // T1848: Mac's three pane-sidebar rows, in Mac's place — a separator
    // after Toggle Rearrange Mode, then straight into Select Previous Split
    // (`MainMenu.xib`). The sidebar row's title flips Show/Hide (`title`).
    .separator,
    .{ .item = .{ .cmd = .toggle_pane_sidebar, .title = u16lit("Show Pane S&idebar") } },
    .{ .item = .{ .cmd = .stash_pane, .title = u16lit("Stash Pan&e") } },
    .{ .item = .{ .cmd = .restore_stashed_pane, .title = u16lit("Restore Stashe&d Pane") } },
    .{ .item = .{ .cmd = .focus_split_previous, .title = u16lit("Select &Previous Split") } },
    .{ .item = .{ .cmd = .focus_split_next, .title = u16lit("Select &Next Split") } },
    .{ .submenu = .{ .title = u16lit("&Select Split"), .items = &select_split_menu } },
    .{ .submenu = .{ .title = u16lit("S&wap Split"), .items = &swap_split_menu } },
    .{ .submenu = .{ .title = u16lit("&Resize Split"), .items = &resize_split_menu } },
    .separator,
    // Windows addition: tab cycling has chords and no other labeled home
    // (macOS gets tab cycling from the system's own Window menu).
    .{ .item = .{ .cmd = .previous_tab, .title = u16lit("Previous &Tab") } },
    .{ .item = .{ .cmd = .next_tab, .title = u16lit("Next Ta&b") } },
    .{ .item = .{ .cmd = .last_tab, .title = u16lit("&Last Tab") } },
    .separator,
    // `D` went to Restore Stashed Pane (T1848), whose title has no other
    // free letter at this level.
    .{ .item = .{ .cmd = .reset_window_size, .title = u16lit("Return To Defa&ult Size") } },
    // Mac's Window menu puts Float on Top directly after Return To Default
    // Size (`MainMenu.xib`), and it is a checkable row there — so it is one
    // here. `F` and `T` are already spoken for at this level, hence `o`.
    .{ .item = .{ .cmd = .toggle_float_on_top, .title = u16lit("Fl&oat on Top") } },
};

const help_menu = [_]Node{
    .{ .item = .{ .cmd = .help, .title = u16lit("Ghoztty &Help") } },
    .separator,
    .{ .item = .{ .cmd = .check_for_updates, .title = u16lit("Check for &Updates…") } },
    .{ .item = .{ .cmd = .claude_integration, .title = u16lit("Set Up Agent &Integrations…") } },
    .separator,
    .{ .item = .{ .cmd = .about, .title = u16lit("&About Ghoztty") } },
    // Mac puts this directly under About in the application menu
    // (MainMenu.xib). Windows has no application menu, so About's neighbour
    // in Help is the same neighbour here. `W` is free at this level.
    .{ .item = .{ .cmd = .whats_new, .title = u16lit("&What’s New in Ghoztty…") } },
};

/// The root popup, opened from the tab-strip menu button.
///
/// The five submenus are Mac's menu bar. The two rows below them are the
/// Windows home for macOS's application-menu config items (Preferences… /
/// Reload Configuration): Windows has no application menu, and "Settings at
/// the foot of the button menu" is where Windows Terminal, VS Code and Edge
/// all put it.
pub const root = [_]Node{
    .{ .submenu = .{ .title = u16lit("&File"), .items = &file_menu } },
    .{ .submenu = .{ .title = u16lit("&Edit"), .items = &edit_menu } },
    .{ .submenu = .{ .title = u16lit("&View"), .items = &view_menu } },
    .{ .submenu = .{ .title = u16lit("&Window"), .items = &window_menu } },
    .{ .submenu = .{ .title = u16lit("&Help"), .items = &help_menu } },
    .separator,
    .{ .item = .{ .cmd = .open_config, .title = u16lit("&Settings") } },
    .{ .item = .{ .cmd = .reload_config, .title = u16lit("&Reload Configuration") } },
};

/// A command that is deliberately NOT in the menu, and why. Everything in
/// the registry must be in the tree or in here — see the coverage test.
pub const Omitted = struct {
    cmd: commands.Id,
    why: []const u8,
};

pub const omitted = [_]Omitted{
    .{
        .cmd = .activity_monitor,
        .why = "palette-only on macOS too: TerminalCommandPalette.swift:179-188 " ++
            "registers it as a palette entry and MainMenu.xib has no row for it",
    },
    .{
        .cmd = .copy_url_to_clipboard,
        .why = "hover/selection-scoped; macOS has no menu row and a menu " ++
            "cannot know which URL was meant",
    },
    .{
        .cmd = .copy_title_to_clipboard,
        .why = "utility command with no macOS menu row; palette-only",
    },
    .{
        .cmd = .toggle_mouse_reporting,
        .why = "debugging toggle with no macOS menu row; palette-only",
    },
    .{
        .cmd = .toggle_window_decorations,
        .why = "config-shaped toggle with no macOS menu row; palette-only",
    },
    .{
        .cmd = .toggle_background_opacity,
        .why = "config-shaped toggle with no macOS menu row; palette-only",
    },
    .{
        .cmd = .scroll_page_up,
        .why = "scrolling is a keyboard/wheel gesture; no macOS menu row",
    },
    .{
        .cmd = .scroll_page_down,
        .why = "scrolling is a keyboard/wheel gesture; no macOS menu row",
    },
    .{
        .cmd = .scroll_to_top,
        .why = "scrolling is a keyboard/wheel gesture; no macOS menu row",
    },
    .{
        .cmd = .scroll_to_bottom,
        .why = "scrolling is a keyboard/wheel gesture; no macOS menu row",
    },
    .{
        .cmd = .viewer_open_file,
        .why = "palette-only on macOS too: TerminalCommandPalette.swift:195-219 " ++
            "registers the viewer entries and MainMenu.xib has no rows for them",
    },
    .{
        .cmd = .viewer_open_url,
        .why = "palette-only on macOS too: TerminalCommandPalette.swift:195-219 " ++
            "registers the viewer entries and MainMenu.xib has no rows for them",
    },
    .{
        .cmd = .viewer_open_browser,
        .why = "palette-only on macOS too: TerminalCommandPalette.swift:195-219 " ++
            "registers the viewer entries and MainMenu.xib has no rows for them",
    },
    .{
        .cmd = .clear_screen,
        .why = "pane-scoped; lives in the right-click context menu (T102)",
    },
    .{
        .cmd = .reset_terminal,
        .why = "pane-scoped; lives in the right-click context menu (T102)",
    },
    .{
        .cmd = .install_update,
        .why = "not in the static tree because its row is CONDITIONAL and its " ++
            "label carries a version (T1673): `Window.openMenu` prepends " ++
            "`Install Update <ver>` to the root popup while an offer is " ++
            "pending, and nothing at all when there is none — a permanently " ++
            "present row would be a row that is grayed out 364 days a year",
    },
    .{
        .cmd = .dismiss_update,
        .why = "palette-only on macOS too (T1754): Mac's `Cancel or Skip " ++
            "Update` lives in TerminalCommandPalette.swift `updateOptions` and " ++
            "nowhere in MainMenu.xib; the menu's own way out of an offer is the " ++
            "dialog's Later button",
    },
};

// --- Lookup / dispatch ----------------------------------------------------

/// `TrackPopupMenuEx` with `TPM_RETURNCMD` returns 0 for "dismissed without
/// choosing", so command ids start at 1.
pub fn menuCommandId(cmd: commands.Id) usize {
    return @intFromEnum(cmd) + 1;
}

/// The command a `TPM_RETURNCMD` result names, or null when the menu was
/// dismissed (0) or the value is not one of ours.
pub fn fromMenuCommandId(value: usize) ?commands.Id {
    if (value == 0) return null;
    return std.meta.intToEnum(commands.Id, value - 1) catch null;
}

/// Enabled/checked state for a row. A command whose target does not exist
/// (no selection, one pane, no find bar) is GRAYED rather than hidden —
/// grayed-but-present is the Windows idiom, and it keeps the menu's shape
/// stable enough to learn.
pub fn flags(cmd: commands.Id, state: State) Flags {
    return switch (cmd) {
        // Needs a selection.
        .copy_to_clipboard,
        .search_selection,
        .jump_to_selection,
        => .{ .enabled = state.has_selection },

        // Needs a live find bar.
        .find_next, .find_previous, .hide_find_bar => .{ .enabled = state.search_active },

        // Needs more than one tab.
        .close_tab, .previous_tab, .next_tab, .last_tab => .{ .enabled = state.tab_count > 1 },

        // Rearrange mode needs somewhere to move a pane TO, which is a second
        // pane in this tab or a second tab to drop onto (T1524). A lone pane
        // in a lone tab can still be dragged into another WINDOW, but the
        // menu has no count of those, so the honest gate is the one it can
        // see; the chord is unaffected either way.
        .toggle_rearrange_mode => .{ .enabled = state.pane_count > 1 or state.tab_count > 1 },

        // Needs more than one pane in the tab.
        .close_surface,
        .toggle_split_zoom,
        .toggle_hero_mode,
        .equalize_splits,
        .focus_split_up,
        .focus_split_down,
        .focus_split_left,
        .focus_split_right,
        .focus_split_previous,
        .focus_split_next,
        .swap_split_up,
        .swap_split_down,
        .swap_split_left,
        .swap_split_right,
        .move_divider_up,
        .move_divider_down,
        .move_divider_left,
        .move_divider_right,
        => .{ .enabled = state.pane_count > 1 },

        .toggle_readonly => .{ .checked = state.readonly },

        // The pane sidebar rows (T1848), gated exactly as Mac's
        // `validateMenuItem` gates them: no sidebar, no rows; a stash needs a
        // pane to leave on screen; a restore needs something stashed.
        .toggle_pane_sidebar => .{ .enabled = state.has_pane_sidebar },
        .stash_pane => .{ .enabled = state.has_pane_sidebar and state.visible_pane_count > 1 },
        .restore_stashed_pane => .{ .enabled = state.has_pane_sidebar and state.stashed_count > 0 },

        .undo => .{ .enabled = state.can_undo },
        .redo => .{ .enabled = state.can_redo },

        // A checkmark, and grayed on the one window that manages its own
        // topmost state.
        .toggle_float_on_top => .{
            .enabled = !state.is_quick_terminal,
            .checked = state.float_on_top,
        },

        else => .{},
    };
}

/// The title to render for `item`, which is `item.title` except where the
/// row has to say something different about the current state.
pub fn title(item: Item, state: State) [:0]const u16 {
    // T89e: quitting with session-persistence on detaches persistent
    // sessions for re-attach instead of ending them, and the row that ends
    // the app is the one place a user needs to be told that.
    if (item.cmd == .quit and state.session_persistence)
        return u16lit("E&xit (keep sessions)");
    // Mac retitles this row from the sidebar's state (`validateMenuItem`).
    if (item.cmd == .toggle_pane_sidebar and !state.pane_sidebar_hidden)
        return u16lit("Hide Pane S&idebar");
    return item.title;
}

// --- Tests ----------------------------------------------------------------

/// Visit every leaf item in the tree.
fn forEachItem(nodes: []const Node, ctx: anytype, comptime f: fn (@TypeOf(ctx), Item) anyerror!void) anyerror!void {
    for (nodes) |node| switch (node) {
        .separator => {},
        .item => |it| try f(ctx, it),
        .submenu => |sub| try forEachItem(sub.items, ctx, f),
    };
}

const Collect = struct {
    buf: *std.ArrayList(commands.Id),
    alloc: std.mem.Allocator,
    fn add(self: Collect, item: Item) anyerror!void {
        try self.buf.append(self.alloc, item.cmd);
    }
};

fn collectCommands(alloc: std.mem.Allocator) !std.ArrayList(commands.Id) {
    var list: std.ArrayList(commands.Id) = .empty;
    try forEachItem(&root, Collect{ .buf = &list, .alloc = alloc }, Collect.add);
    return list;
}

test "every command is either placed in the menu or omitted with a reason" {
    const alloc = std.testing.allocator;
    var placed = try collectCommands(alloc);
    defer placed.deinit(alloc);

    for (commands.registry) |c| {
        var in_menu = false;
        for (placed.items) |p| {
            if (p == c.id) in_menu = true;
        }
        var is_omitted = false;
        for (omitted) |o| {
            if (o.cmd == c.id) is_omitted = true;
        }
        // Exactly one of the two: a command that is in both is a stale
        // omission entry, and one in neither is the drift this test exists
        // to catch (T57's failure mode).
        if (in_menu == is_omitted) {
            std.debug.print(
                "command '{s}' is {s}\n",
                .{ c.name, if (in_menu) "both placed and omitted" else "in neither the menu nor `omitted`" },
            );
            return error.CommandCoverage;
        }
    }
}

test "omissions name a real command and give a reason" {
    for (omitted) |o| {
        try std.testing.expect(o.why.len > 10);
        // Must resolve — `get` is exhaustive over the registry.
        _ = commands.get(o.cmd);
    }
    // No duplicate omissions.
    for (omitted, 0..) |a, i| for (omitted[i + 1 ..]) |b| {
        try std.testing.expect(a.cmd != b.cmd);
    };
}

test "no command appears twice in the tree" {
    const alloc = std.testing.allocator;
    var placed = try collectCommands(alloc);
    defer placed.deinit(alloc);
    for (placed.items, 0..) |a, i| for (placed.items[i + 1 ..]) |b| {
        try std.testing.expect(a != b);
    };
}

test "root is the mac menu bar plus the windows settings group" {
    // File / Edit / View / Window / Help, then the app-menu config items
    // Windows has nowhere else to put.
    const expect = std.testing.expect;
    try expect(root.len == 8);
    const titles = [_][:0]const u16{
        u16lit("&File"),
        u16lit("&Edit"),
        u16lit("&View"),
        u16lit("&Window"),
        u16lit("&Help"),
    };
    for (root[0..5], titles) |node, t| {
        try expect(node == .submenu);
        try std.testing.expectEqualSlices(u16, t, node.submenu.title);
        try expect(node.submenu.items.len > 0);
    }
    try expect(root[5] == .separator);
    try std.testing.expectEqual(commands.Id.open_config, root[6].item.cmd);
    try std.testing.expectEqual(commands.Id.reload_config, root[7].item.cmd);
}

/// The mnemonic letter of a title (the char after the first `&`), lowercased,
/// or null when there is none.
fn mnemonic(t: [:0]const u16) ?u16 {
    var i: usize = 0;
    while (i + 1 < t.len) : (i += 1) {
        if (t[i] == '&') {
            const c = t[i + 1];
            return if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
    }
    return null;
}

fn expectUniqueMnemonics(nodes: []const Node) !void {
    var seen: [64]u16 = undefined;
    var n: usize = 0;
    for (nodes) |node| {
        const t = switch (node) {
            .separator => continue,
            .item => |it| it.title,
            .submenu => |sub| sub.title,
        };
        const m = mnemonic(t) orelse {
            std.debug.print("menu row has no mnemonic\n", .{});
            return error.MissingMnemonic;
        };
        for (seen[0..n]) |s| if (s == m) {
            std.debug.print("duplicate mnemonic '{u}' in a menu level\n", .{m});
            return error.DuplicateMnemonic;
        };
        seen[n] = m;
        n += 1;
        // Recurse into submenus: each level has its own mnemonic namespace.
        if (node == .submenu) try expectUniqueMnemonics(node.submenu.items);
    }
}

test "every row has a mnemonic and they are unique within their level" {
    try expectUniqueMnemonics(&root);
}

test "menu command ids round-trip and never collide with dismissal" {
    for (commands.registry) |c| {
        const v = menuCommandId(c.id);
        try std.testing.expect(v != 0);
        try std.testing.expectEqual(c.id, fromMenuCommandId(v).?);
    }
    try std.testing.expect(fromMenuCommandId(0) == null);
    try std.testing.expect(fromMenuCommandId(commands.registry.len + 1) == null);
}

test "state gates the rows whose target may not exist" {
    const empty: State = .{};
    try std.testing.expect(!flags(.copy_to_clipboard, empty).enabled);
    try std.testing.expect(flags(.copy_to_clipboard, .{ .has_selection = true }).enabled);

    try std.testing.expect(!flags(.find_next, empty).enabled);
    try std.testing.expect(flags(.find_next, .{ .search_active = true }).enabled);

    try std.testing.expect(!flags(.close_tab, empty).enabled);
    try std.testing.expect(flags(.close_tab, .{ .tab_count = 2 }).enabled);

    try std.testing.expect(!flags(.equalize_splits, empty).enabled);
    try std.testing.expect(flags(.equalize_splits, .{ .pane_count = 2 }).enabled);

    // Rearrange mode takes EITHER count, because a pane can be dropped on a
    // sibling split or on another tab (T1524). A lone pane in a lone tab has
    // neither, so the row grays.
    try std.testing.expect(!flags(.toggle_rearrange_mode, empty).enabled);
    try std.testing.expect(flags(.toggle_rearrange_mode, .{ .pane_count = 2 }).enabled);
    try std.testing.expect(flags(.toggle_rearrange_mode, .{ .tab_count = 2 }).enabled);

    // Unconditional rows stay enabled in the emptiest possible state.
    try std.testing.expect(flags(.new_window, empty).enabled);
    try std.testing.expect(flags(.quit, empty).enabled);
    try std.testing.expect(flags(.about, empty).enabled);
}

test "float on top is a checkmark, and grayed on the quick terminal (T191)" {
    // Unchecked and reachable on a plain window...
    try std.testing.expect(!flags(.toggle_float_on_top, .{}).checked);
    try std.testing.expect(flags(.toggle_float_on_top, .{}).enabled);
    // ...checked once the window carries the bit...
    try std.testing.expect(flags(.toggle_float_on_top, .{ .float_on_top = true }).checked);
    // ...and grayed on the quick terminal, whichever way the bit reads,
    // because the quick terminal topmosts itself.
    try std.testing.expect(!flags(.toggle_float_on_top, .{ .is_quick_terminal = true }).enabled);
    try std.testing.expect(!flags(
        .toggle_float_on_top,
        .{ .is_quick_terminal = true, .float_on_top = true },
    ).enabled);
    // The gate is specific to this row: a quick terminal's other rows are
    // untouched by it.
    try std.testing.expect(flags(.toggle_fullscreen, .{ .is_quick_terminal = true }).enabled);
}

test "float on top sits where Mac puts it, at the foot of the Window menu (T191)" {
    // `MainMenu.xib` has Float on Top directly after Return To Default Size.
    const last = window_menu[window_menu.len - 1];
    const prev = window_menu[window_menu.len - 2];
    try std.testing.expectEqual(commands.Id.toggle_float_on_top, last.item.cmd);
    try std.testing.expectEqual(commands.Id.reset_window_size, prev.item.cmd);
}

test "pane sidebar rows gate and retitle the way Mac's do (T1848)" {
    const on: State = .{ .has_pane_sidebar = true };
    // The quick terminal has no sidebar: all three gray.
    try std.testing.expect(!flags(.toggle_pane_sidebar, .{}).enabled);
    try std.testing.expect(!flags(.stash_pane, .{ .visible_pane_count = 3 }).enabled);
    try std.testing.expect(!flags(.restore_stashed_pane, .{ .stashed_count = 1 }).enabled);
    // A sidebar can always be shown or hidden.
    try std.testing.expect(flags(.toggle_pane_sidebar, on).enabled);
    // Stash needs a pane left on screen afterwards.
    try std.testing.expect(!flags(.stash_pane, on).enabled);
    try std.testing.expect(flags(.stash_pane, .{ .has_pane_sidebar = true, .visible_pane_count = 2 }).enabled);
    // Restore needs something stashed.
    try std.testing.expect(!flags(.restore_stashed_pane, on).enabled);
    try std.testing.expect(flags(.restore_stashed_pane, .{ .has_pane_sidebar = true, .stashed_count = 1 }).enabled);

    const item: Item = .{ .cmd = .toggle_pane_sidebar, .title = u16lit("Show Pane S&idebar") };
    try std.testing.expectEqualSlices(u16, u16lit("Hide Pane S&idebar"), title(item, on));
    try std.testing.expectEqualSlices(
        u16,
        u16lit("Show Pane S&idebar"),
        title(item, .{ .has_pane_sidebar = true, .pane_sidebar_hidden = true }),
    );
}

test "pane sidebar rows sit where Mac puts them, after Toggle Rearrange Mode (T1848)" {
    const at = for (window_menu, 0..) |n, i| {
        if (n == .item and n.item.cmd == .toggle_rearrange_mode) break i;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(window_menu[at + 1] == .separator);
    try std.testing.expectEqual(commands.Id.toggle_pane_sidebar, window_menu[at + 2].item.cmd);
    try std.testing.expectEqual(commands.Id.stash_pane, window_menu[at + 3].item.cmd);
    try std.testing.expectEqual(commands.Id.restore_stashed_pane, window_menu[at + 4].item.cmd);
    try std.testing.expectEqual(commands.Id.focus_split_previous, window_menu[at + 5].item.cmd);
}

test "read-only is a checkmark, not a gray-out" {
    try std.testing.expect(!flags(.toggle_readonly, .{}).checked);
    try std.testing.expect(flags(.toggle_readonly, .{}).enabled);
    try std.testing.expect(flags(.toggle_readonly, .{ .readonly = true }).checked);
}

test "exit says so when quitting keeps sessions" {
    const item: Item = .{ .cmd = .quit, .title = u16lit("E&xit") };
    try std.testing.expectEqualSlices(u16, u16lit("E&xit"), title(item, .{}));
    try std.testing.expectEqualSlices(
        u16,
        u16lit("E&xit (keep sessions)"),
        title(item, .{ .session_persistence = true }),
    );
    // Every other row is state-independent.
    const other: Item = .{ .cmd = .new_window, .title = u16lit("&New Window") };
    try std.testing.expectEqualSlices(
        u16,
        u16lit("&New Window"),
        title(other, .{ .session_persistence = true }),
    );
}

test "the whole tree resolves against the command registry" {
    const alloc = std.testing.allocator;
    var placed = try collectCommands(alloc);
    defer placed.deinit(alloc);
    try std.testing.expect(placed.items.len > 30);
    for (placed.items) |id| {
        const c = commands.get(id);
        try std.testing.expectEqual(id, c.id);
        try std.testing.expect(c.name.len > 0);
    }
}
