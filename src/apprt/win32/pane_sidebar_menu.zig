//! What a pane sidebar row does when it is clicked, right-clicked or closed
//! from its hover x, as rules (T1845, T2280; Mac `PaneSidebarRow.click` /
//! `contextMenu` / `trailingButton`).
//!
//! - **Click.** A grid row focuses its pane; a stashed row restores it; with
//!   Alt held (Mac's Option) a stashed row SWAPS with the focused pane - it
//!   takes that pane's slot, and the focused pane takes its place in the
//!   stash. Another window's row raises that window and focuses the pane
//!   there, Alt or not: a swap across windows is not a thing Mac offers.
//! - **Right-click.** A grid row: Stash Pane / Move to New Window / Close
//!   Pane. A stashed row: Restore / Swap with Focused Pane / Move to New
//!   Window / Close Pane. Another window's grid row offers Show Pane in place
//!   of Stash, and its stashed row no Swap. Close Pane is the hover x's close
//!   (T2298, Mac 345be6b02), not the confirmed one. A window row: Create
//!   Group... / Move to Group / Remove from Group (T2527, below).
//! - **Hover x** (T2280, T2298; Mac dc2bbab6b / 345be6b02). A hovered row
//!   offers stash/restore (this window's rows only), then an x - every row,
//!   another window's too. A hovered window or project header puts an x where
//!   its count was. Every close from the sidebar asks nothing (no running
//!   process, no remote Disconnect), takes no focus (never raises another
//!   window), and ends the sessions it closes rather than detaching them. It
//!   is undoable; the sessions end when the undo expires. It replaced trash
//!   mode, whose red x killed with no undo at all.
//!
//! No OS imports, so this unit-tests in every app-runtime lane; the window
//! half is `PaneSidebar.zig`.

const std = @import("std");
const pane_sidebar = @import("pane_sidebar.zig");
const outline = @import("pane_sidebar_outline.zig");

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

/// What a left press in the sidebar lands on, as far as activating the
/// sidebar's own window is concerned (T2863).
pub const Press = enum {
    /// Anything that acts on this window: a fold, the search field, the
    /// edge, a project header, a header's x, empty space.
    other,
    /// A pane's row.
    row,
    /// A window's tile on the all-windows rail.
    tile,
    /// A window header (not its fold chevron).
    window_header,
    /// A window header's + (raises that window and splits it).
    window_add,
};

/// Whether a press should leave the sidebar's own window where it is in the
/// z-order rather than activating it (T2863).
///
/// A press in a background window normally activates it on the DOWN, and the
/// click's verb runs on the UP. For a press whose verb raises ANOTHER window
/// that ordering is visible: the background window the sidebar sits in comes
/// over the window already in front, and only on release does the target come
/// forward - over a held press it stays on top. Users read it as the window
/// rising on its own ("hovering it raised it"). Those presses leave the
/// window alone; the release raises the target, which the click's input
/// entitles this process to do.
pub fn pressLeavesWindowBehind(press: Press, own: bool) bool {
    if (own) return false;
    return switch (press) {
        .row, .tile, .window_header, .window_add => true,
        .other => false,
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

// ---------------------------------------------------------------------------
// A window row's menu (T2527, Mac 7bee055c9 `PaneSidebarView.windowMenu`)
//
// Create Group... turns the row's name into an empty field (placeholder
// "Group name"); Return makes the window `<group>: <name>`. Move to Group
// lists every other group, as listed - only when there is one. Remove from
// Group, for a grouped window, puts it back to its own name. Each pins the
// title as the user's and moves it as a rename does.

pub const create_group_title = "Create &Group...";
pub const move_to_group_title = "&Move to Group";
pub const remove_from_group_title = "&Remove from Group";

/// The command ids. A Move to Group entry is `move_base + ` its index among
/// the groups `movingTo` listed; non-zero, as the row menu's are.
pub const create_group_id: u16 = 1;
pub const remove_from_group_id: u16 = 2;
pub const move_base: u16 = 16;

/// The most groups Move to Group lists.
pub const max_groups = 64;

pub const WindowCmd = union(enum) {
    create_group,
    /// An index into the groups the menu listed.
    move_to_group: usize,
    remove_from_group,
};

/// The command a chosen id names, given how many groups were listed; null for
/// a dismissed menu (0) or anything the menu did not offer.
pub fn windowCmd(id: usize, groups: usize) ?WindowCmd {
    if (id == create_group_id) return .create_group;
    if (id == remove_from_group_id) return .remove_from_group;
    if (id >= move_base and id - move_base < groups) return .{ .move_to_group = id - move_base };
    return null;
}

/// The groups window `title` can move to (Mac
/// `PaneSidebarWindowGrouping.groups(movingTo:in:)`): every group the list
/// shows but its own, once each, as listed. `listed` is each window's group,
/// in list order (null for an ungrouped one).
pub fn movingTo(title: []const u8, listed: []const ?[]const u8, out: [][]const u8) []const []const u8 {
    const own: ?[]const u8 = if (outline.splitWindowTitle(title)) |s| s.project else null;
    var n: usize = 0;
    next: for (listed) |maybe| {
        const p = maybe orelse continue;
        if (own) |o| if (std.mem.eql(u8, o, p)) continue;
        for (out[0..n]) |seen| if (std.mem.eql(u8, seen, p)) continue :next;
        if (n == out.len) break;
        out[n] = p;
        n += 1;
    }
    return out[0..n];
}

/// Whether the menu offers Remove from Group: the window is in one.
pub fn offersRemove(title: []const u8) bool {
    return outline.splitWindowTitle(title) != null;
}

/// A group's name as a menu item's text: a `&` is doubled, so it shows
/// rather than marking an access key. Cut short in `buf` if it must be.
pub fn menuText(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        const need: usize = if (c == '&') 2 else 1;
        if (n + need > buf.len) break;
        buf[n] = c;
        if (c == '&') buf[n + 1] = '&';
        n += need;
    }
    return buf[0..n];
}

/// The hover x's tooltip (Mac's `.help`).
pub const close_tip = "Close pane";

/// A window header's x tooltip (Mac `PaneSidebarWindowHeader`).
pub const close_window_tip = "Close window";

/// Whether a hovered row offers stash/restore before its x (Mac 345be6b02
/// `trailingButton`): this window's rows do; another window's row offers the
/// x alone.
pub fn rowOffersStash(own: bool) bool {
    return own;
}

/// A project header's x tooltip (Mac `PaneSidebarProjectHeader`): "Close its
/// window", or "Close its N windows".
pub fn projectCloseTip(windows: usize, buf: []u8) []const u8 {
    if (windows == 1) return "Close its window";
    return std.fmt.bufPrint(buf, "Close its {d} windows", .{windows}) catch "Close its windows";
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

test "T2863: a press that raises another window leaves this one where it is" {
    // Every press whose click brings ANOTHER window forward.
    for ([_]Press{ .row, .tile, .window_header, .window_add }) |p| {
        try testing.expect(pressLeavesWindowBehind(p, false));
        // The same press on this window's own item acts here, so the
        // window comes forward as any click in it would.
        try testing.expect(!pressLeavesWindowBehind(p, true));
    }
    // Folds, the search field, the edge, project headers: this window's.
    try testing.expect(!pressLeavesWindowBehind(.other, false));
    try testing.expect(!pressLeavesWindowBehind(.other, true));
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

test "T2527: Move to Group lists every other group once, as listed; Remove only for a grouped window" {
    var out: [max_groups][]const u8 = undefined;
    const listed = [_]?[]const u8{ null, "proj", "proj", null, "web", "proj" };
    // Mac groupsFromTheSidebar: no group, nothing to move to.
    try testing.expectEqual(@as(usize, 0), movingTo("beta", &.{ null, null }, &out).len);
    const lone = movingTo("gamma", &listed, &out);
    try testing.expectEqual(@as(usize, 2), lone.len);
    try testing.expectEqualStrings("proj", lone[0]);
    try testing.expectEqualStrings("web", lone[1]);
    const grouped = movingTo("proj: one", &listed, &out);
    try testing.expectEqual(@as(usize, 1), grouped.len);
    try testing.expectEqualStrings("web", grouped[0]);
    try testing.expect(!offersRemove("gamma"));
    try testing.expect(offersRemove("proj: gamma"));
    // A colon that heads no group is part of the name.
    try testing.expect(!offersRemove("http://x"));
}

test "T2527: a window menu id names its command; a dismissed menu or a stray id names none" {
    try testing.expectEqual(WindowCmd.create_group, windowCmd(create_group_id, 0).?);
    try testing.expectEqual(WindowCmd.remove_from_group, windowCmd(remove_from_group_id, 0).?);
    try testing.expectEqual(@as(usize, 1), windowCmd(move_base + 1, 2).?.move_to_group);
    try testing.expect(windowCmd(0, 2) == null);
    try testing.expect(windowCmd(move_base + 2, 2) == null);
    try testing.expect(windowCmd(move_base - 1, 2) == null);
    try testing.expect(create_group_id != remove_from_group_id and move_base > remove_from_group_id);
}

test "T2527: a group's & shows in the menu rather than marking a key" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("R&&D", menuText(&buf, "R&D"));
    try testing.expectEqualStrings("proj", menuText(&buf, "proj"));
    var small: [3]u8 = undefined;
    // Never half an escape.
    try testing.expectEqualStrings("ab", menuText(&small, "ab&c"));
}

test "T2298: this window's row offers stash before its x, another window's the x alone; header tips say what closes" {
    try testing.expect(rowOffersStash(true));
    try testing.expect(!rowOffersStash(false));
    try testing.expectEqualStrings("Close pane", close_tip);
    try testing.expectEqualStrings("Close window", close_window_tip);
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("Close its window", projectCloseTip(1, &buf));
    try testing.expectEqualStrings("Close its 3 windows", projectCloseTip(3, &buf));
}
