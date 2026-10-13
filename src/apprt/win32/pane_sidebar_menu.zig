//! What a pane sidebar row does when it is clicked, right-clicked or killed,
//! as rules (T1845; Mac `PaneSidebarRow.click` / `contextMenu`,
//! `PaneSidebarView.headerButtons`, `BaseTerminalController.killPane`).
//!
//! - **Click.** A grid row focuses its pane; a stashed row restores it; with
//!   Alt held (Mac's Option) a stashed row SWAPS with the focused pane - it
//!   takes that pane's slot, and the focused pane takes its place in the
//!   stash. Another window's row raises that window and focuses the pane
//!   there, Alt or not: a swap across windows is not a thing Mac offers.
//! - **Right-click.** A grid row: Stash Pane / Move to New Window / Close
//!   Pane. A stashed row: Restore / Swap with Focused Pane / Move to New
//!   Window / Close Pane. Another window's grid row offers Show Pane in place
//!   of Stash, and its stashed row no Swap. Close Pane is the ordinary close -
//!   confirmation and a remote pane's Disconnect included.
//! - **Trash mode.** The header's trash button gives every row and tile a red
//!   x that kills its pane at once: no confirmation, and no undo window.
//!   Escape or the button again leaves it, and nothing about it is persisted.
//!
//! No OS imports, so this unit-tests in every app-runtime lane; the window
//! half is `PaneSidebar.zig`.

const std = @import("std");
const pane_sidebar = @import("pane_sidebar.zig");

/// What a click on a row does.
pub const ClickVerb = enum {
    /// Focus a pane that is on screen.
    focus,
    /// Put a stashed pane back in its slot and focus it.
    restore,
    /// Swap a stashed pane with the focused pane.
    exchange,
    /// Another window's pane: raise that window and focus it there.
    reveal,
};

/// `own` is whether the row is this window's active tab's pane; `alt` whether
/// Alt was down on the click.
pub fn clickVerb(section: pane_sidebar.Section, own: bool, alt: bool) ClickVerb {
    if (!own) return .reveal;
    return switch (section) {
        .grid => .focus,
        .stashed => if (alt) .exchange else .restore,
    };
}

/// A context-menu command. Non-zero, because `TrackPopupMenuEx` answers 0 for
/// a menu dismissed without a choice.
pub const Id = enum(u16) {
    restore = 1,
    exchange = 2,
    stash = 3,
    show = 4,
    pop_out = 5,
    close = 6,
};

pub const Cmd = struct {
    id: Id,
    /// The Windows menu text: `&` marks the access key, and a tab separates
    /// the gesture hint the way a menu shows an accelerator.
    title: []const u8,
    enabled: bool = true,
};

pub const Item = union(enum) {
    separator,
    cmd: Cmd,
};

/// What the menu needs to know about the row and its window.
pub const Facts = struct {
    section: pane_sidebar.Section,
    /// This window's own row, not another window's (the all-windows scope).
    own: bool,
    /// More than one pane on screen in its tab: stashing would not empty it
    /// (Mac disables Stash Pane on the last visible pane).
    can_stash: bool,
    /// Mac's `PaneMoveCoordinator.canPopOut`: a window's only pane cannot
    /// move to a new window - the window would close and another would open
    /// to hold the very same pane.
    can_pop_out: bool,
};

/// The most items `build` returns.
pub const max_items = 6;

/// The row's context menu, top to bottom (Mac `PaneSidebarRow.contextMenu`).
pub fn build(f: Facts, out: *[max_items]Item) []const Item {
    var n: usize = 0;
    switch (f.section) {
        .stashed => {
            out[n] = .{ .cmd = .{ .id = .restore, .title = "&Restore" } };
            n += 1;
            if (f.own) {
                // Mac shows the Option glyph beside it: the click it names.
                out[n] = .{ .cmd = .{ .id = .exchange, .title = "S&wap with Focused Pane\tAlt+Click" } };
                n += 1;
            }
        },
        .grid => if (f.own) {
            out[n] = .{ .cmd = .{ .id = .stash, .title = "&Stash Pane", .enabled = f.can_stash } };
            n += 1;
        } else {
            out[n] = .{ .cmd = .{ .id = .show, .title = "S&how Pane" } };
            n += 1;
        },
    }
    out[n] = .separator;
    n += 1;
    out[n] = .{ .cmd = .{ .id = .pop_out, .title = "Move to &New Window", .enabled = f.can_pop_out } };
    n += 1;
    out[n] = .separator;
    n += 1;
    out[n] = .{ .cmd = .{ .id = .close, .title = "&Close Pane" } };
    n += 1;
    return out[0..n];
}

/// Trash mode's caption, in place of "PANES" (Mac "Click × to kill").
pub const kill_caption = "CLICK \u{00D7} TO KILL";

/// The trash button's tooltip (Mac's `.help`, em dash as Mac writes it).
pub fn trashTip(on: bool) []const u8 {
    return if (on)
        "Done killing panes (Esc)"
    else
        "Quick close \u{2014} kill panes with one click, no confirmation";
}

/// The red x's tooltip.
pub const kill_tip = "Kill now \u{2014} no confirmation";

/// What Escape does to trash mode: it leaves it, and is consumed, only in the
/// window whose sidebar is in it (Mac: "only this window's sidebar answers")
/// and only when no pane drag is in flight - a drag owns Escape first, since
/// cancelling it is the innermost thing Escape can mean.
pub fn escapeLeavesTrash(quick_kill: bool, key_in_this_window: bool, drag_active: bool) bool {
    return quick_kill and key_in_this_window and !drag_active;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn titles(items: []const Item, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    for (items, 0..) |it, i| {
        if (i > 0) w.writeAll("|") catch {};
        switch (it) {
            .separator => w.writeAll("SEP") catch {},
            .cmd => |c| {
                if (!c.enabled) w.writeAll("~") catch {};
                w.writeAll(c.title) catch {};
            },
        }
    }
    return fbs.getWritten();
}

test "pane_sidebar_menu: a click focuses, restores, swaps with Alt, or reveals another window's pane" {
    try testing.expectEqual(ClickVerb.focus, clickVerb(.grid, true, false));
    // Alt means nothing on a pane that is already on screen.
    try testing.expectEqual(ClickVerb.focus, clickVerb(.grid, true, true));
    try testing.expectEqual(ClickVerb.restore, clickVerb(.stashed, true, false));
    try testing.expectEqual(ClickVerb.exchange, clickVerb(.stashed, true, true));
    // Another window's pane: never a cross-window swap.
    for ([_]pane_sidebar.Section{ .grid, .stashed }) |s| for ([_]bool{ false, true }) |alt| {
        try testing.expectEqual(ClickVerb.reveal, clickVerb(s, false, alt));
    };
}

test "pane_sidebar_menu: a grid row offers Stash / Move to New Window / Close Pane" {
    var out: [max_items]Item = undefined;
    var buf: [256]u8 = undefined;
    const items = build(.{ .section = .grid, .own = true, .can_stash = true, .can_pop_out = true }, &out);
    try testing.expectEqualStrings("&Stash Pane|SEP|Move to &New Window|SEP|&Close Pane", titles(items, &buf));
}

test "pane_sidebar_menu: a stashed row offers Restore and the Alt-click swap first" {
    var out: [max_items]Item = undefined;
    var buf: [256]u8 = undefined;
    const items = build(.{ .section = .stashed, .own = true, .can_stash = true, .can_pop_out = true }, &out);
    try testing.expectEqualStrings(
        "&Restore|S&wap with Focused Pane\tAlt+Click|SEP|Move to &New Window|SEP|&Close Pane",
        titles(items, &buf),
    );
}

test "pane_sidebar_menu: the last pane on screen cannot be stashed, and a window's only pane cannot pop out" {
    var out: [max_items]Item = undefined;
    var buf: [256]u8 = undefined;
    const items = build(.{ .section = .grid, .own = true, .can_stash = false, .can_pop_out = false }, &out);
    try testing.expectEqualStrings("~&Stash Pane|SEP|~Move to &New Window|SEP|&Close Pane", titles(items, &buf));
}

test "pane_sidebar_menu: another window's row shows its pane and never swaps" {
    var out: [max_items]Item = undefined;
    var buf: [256]u8 = undefined;
    const grid = build(.{ .section = .grid, .own = false, .can_stash = true, .can_pop_out = true }, &out);
    try testing.expectEqualStrings("S&how Pane|SEP|Move to &New Window|SEP|&Close Pane", titles(grid, &buf));
    const stashed = build(.{ .section = .stashed, .own = false, .can_stash = true, .can_pop_out = true }, &out);
    try testing.expectEqualStrings("&Restore|SEP|Move to &New Window|SEP|&Close Pane", titles(stashed, &buf));
}

test "pane_sidebar_menu: every id is non-zero, so a dismissed menu is never a command" {
    inline for (std.meta.fields(Id)) |f| try testing.expect(f.value != 0);
}

test "pane_sidebar_menu: Escape leaves trash mode only in its own window, and never under a drag" {
    try testing.expect(escapeLeavesTrash(true, true, false));
    try testing.expect(!escapeLeavesTrash(false, true, false));
    try testing.expect(!escapeLeavesTrash(true, false, false));
    try testing.expect(!escapeLeavesTrash(true, true, true));
}

test "pane_sidebar_menu: trash wording is Mac's" {
    try testing.expect(std.mem.startsWith(u8, trashTip(false), "Quick close"));
    try testing.expect(std.mem.endsWith(u8, trashTip(true), "(Esc)"));
    try testing.expect(std.mem.startsWith(u8, kill_tip, "Kill now"));
}
