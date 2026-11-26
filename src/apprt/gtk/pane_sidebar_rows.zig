//! The GTK pane sidebar's pure half (T3557, Linux L10b;
//! docs/reference/pane-sidebar.md): what a row says, where the shared flags
//! are kept, and the line format the debug seam reports. No GTK imports, so
//! it runs in the none lane.
//!
//! The rules themselves are win32's pure modules, which carry the Mac's
//! (`PaneSidebarText`, `PaneSidebarSharedState.applyStart`):
//! `win32/pane_sidebar.zig` (the row's name and subtitle, the mode and the
//! column widths) and `win32/pane_sidebar_prefs.zig` (the persisted flags, the
//! forced start against the user's own choice). This file only puts them
//! together for GTK and names the Linux file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ps = @import("../win32/pane_sidebar.zig");
const prefs = @import("../win32/pane_sidebar_prefs.zig");

pub const Mode = ps.Mode;
pub const Prefs = prefs.Prefs;
pub const StartState = prefs.StartState;
pub const Start = prefs.Start;

/// Which mode a window's sidebar is in: hidden, the full panel, or the rail
/// (collapsed, or a window too narrow for the panel). A window that has not
/// been laid out yet (`window_w` 0) is not narrow: it would otherwise start
/// every new window in the rail for one frame.
pub fn mode(p: Prefs, window_w: i32) Mode {
    const w: f32 = if (window_w <= 0) ps.narrow_window_dip else @floatFromInt(window_w);
    return ps.mode(p.expanded, p.hidden, w);
}

/// Whether the toggle can expand at this width (the Mac's `canExpand`).
pub fn canExpand(window_w: i32) bool {
    if (window_w <= 0) return true;
    return ps.canExpand(@floatFromInt(window_w));
}

/// The sidebar card's width in logical pixels: the rail's card collapsed,
/// the panel at the shared width expanded (one card in both modes, Mac
/// `cardWidth`). GTK lays out in logical pixels, so these are the design's
/// DIP numbers unscaled.
pub fn cardWidth(m: Mode, p: Prefs) i32 {
    return @intFromFloat(@round(ps.cardDip(m, p.width_dip)));
}

/// The margin around the card (the design system's `lg`, the grid's gutter).
pub const card_margin: i32 = @intFromFloat(ps.rail_margin_dip);

/// The rail card's width (a row's pill around its icon).
pub fn railCardWidth() i32 {
    return @intFromFloat(@round(ps.rail_card_dip));
}

/// One pane as the sidebar sees it.
pub const Pane = struct {
    /// The terminal-set title (OSC 0/2), or a viewer's page title.
    title: ?[]const u8 = null,
    /// The name the user gave the pane (Change Pane Title), which outranks a
    /// banner's title.
    title_override: ?[]const u8 = null,
    pwd: ?[]const u8 = null,
    banner: ?[]const u8 = null,
    viewer: bool = false,
};

pub const Text = struct {
    label: []const u8,
    subtitle: ?[]const u8,
};

pub const TEXT_BUF_LEN: usize = 512;

/// A row's two lines (Mac `PaneSidebarText`): the banner's title when it has
/// one, else the pane's title (else its directory's name, else its kind); the
/// subtitle is the banner's first line when the banner has no title, else the
/// working directory with the home directory as `~` - and nothing when it
/// would only repeat the label.
pub fn text(p: Pane, home: ?[]const u8, label_buf: *[TEXT_BUF_LEN]u8, sub_buf: *[TEXT_BUF_LEN]u8) Text {
    const kind: []const u8 = if (p.viewer) "viewer" else "terminal";
    const raw = p.title_override orelse p.title;
    const label = ps.paneLabel(raw, p.pwd, kind, if (p.viewer) null else p.banner, p.title_override != null, label_buf);
    const sub: ?[]const u8 = if (p.viewer)
        null
    else if (ps.bannerSubtitle(p.banner, sub_buf)) |b|
        b
    else if (p.pwd) |d|
        // A pane titled by its own directory (the core reports the
        // directory as the title until a program sets one) would show the
        // same place twice - win32's rule.
        (if (d.len == 0 or ps.samePath(d, label)) null else ps.abbreviatePath(d, home, sub_buf))
    else
        null;
    return .{ .label = label, .subtitle = ps.distinct(sub, label) };
}

/// `<config root>/ghoztty/pane-sidebar[-debug]`: `$XDG_CONFIG_HOME`, else
/// `~/.config` - the session-layout manifest's root, so a test harness that
/// gives the app a private config dir gives this file one too. Debug builds
/// keep their own, so a dev window never changes how the release app opens.
pub fn prefsPath(alloc: Allocator, debug: bool, xdg_config_home: ?[]const u8, home: []const u8) Allocator.Error![]u8 {
    // A Linux path, spelled with `/` on every host so the none lane's test
    // reads the same on the Windows box (`std.fs.path.join` would use `\`).
    return configFile(alloc, if (debug) "pane-sidebar-debug" else "pane-sidebar", xdg_config_home, home);
}

/// `<config root>/ghoztty/pane-sidebar-order[-debug]` (T3697): the
/// all-windows list's order, one key per line (win32
/// `pane_sidebar_window_order` format), beside the flags.
pub fn orderPath(alloc: Allocator, debug: bool, xdg_config_home: ?[]const u8, home: []const u8) Allocator.Error![]u8 {
    return configFile(alloc, if (debug) "pane-sidebar-order-debug" else "pane-sidebar-order", xdg_config_home, home);
}

fn configFile(alloc: Allocator, name: []const u8, xdg_config_home: ?[]const u8, home: []const u8) Allocator.Error![]u8 {
    if (xdg_config_home) |x| if (x.len > 0) return std.fmt.allocPrint(alloc, "{s}/ghoztty/{s}", .{ x, name });
    return std.fmt.allocPrint(alloc, "{s}/.config/ghoztty/{s}", .{ home, name });
}

/// The persisted flags, or null (no file, unreadable, malformed). The file
/// is win32's format (`pane_sidebar_prefs.format`).
pub fn load(path: []const u8) ?Prefs {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf: [prefs.FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    return prefs.parse(buf[0..n]);
}

/// Persist the flags. Best-effort: a preference is never worth an error.
pub fn save(path: []const u8, p: Prefs) void {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [prefs.FORMAT_BUF_LEN]u8 = undefined;
    f.writeAll(prefs.format(&buf, p)) catch {};
}

/// A hovered row's buttons (T3606; Mac `PaneSidebarItemButton`, win32
/// T2280/T2298/T2323): stash or restore, add, close.
/// The Ungrouped header's pencil (`rename`, T3608) names its windows as a
/// group.
pub const Tool = enum { stash, restore, add, close, rename };

/// A pane row's buttons, in order (Mac `PaneSidebarRow`): in the panel, a
/// row of the window the sidebar is in offers - (stash) or, stashed, the
/// restore, then x; another window's row the x alone. A rail tile has none.
pub fn paneTools(expanded: bool, own: bool, stashed: bool) []const Tool {
    if (!expanded) return &.{};
    if (!own) return &.{.close};
    return if (stashed) &.{ .restore, .close } else &.{ .stash, .close };
}

/// A window row's, a project's or the Ungrouped header's buttons: + then x,
/// where its count was; the Ungrouped header's pencil first among them
/// (T3608, Mac `PaneSidebarProjectHeader` with no project). A window's and a
/// project's pencil are a rename in place (T3695). Only the panel's outline
/// has headers.
pub fn headTools(expanded: bool, ungrouped: bool) []const Tool {
    if (!expanded) return &.{};
    return if (ungrouped) &.{ .rename, .add, .close } else &.{ .add, .close };
}

/// A button's tooltip. `window_row`: a window row's + adds a pane to it,
/// where the panel header's and a group header's open a window (the caller
/// names the group's own, `pane_sidebar_add.projectAddTip`).
pub fn toolTip(t: Tool, window_row: bool) [:0]const u8 {
    return switch (t) {
        .stash => "Stash",
        .restore => "Restore",
        .add => if (window_row) "New pane" else "New window",
        .close => if (window_row) "Close window" else "Close",
        .rename => "Name these windows as a group",
    };
}

/// The in-place field's placeholder when it names a group (Create Group...,
/// the Ungrouped pencil; Mac `PaneSidebarRename.key(groupFor:)`).
pub const group_placeholder = "Group name";

/// A window row's right-click menu, top to bottom (T3608; Mac
/// `PaneSidebarView.windowMenu`, win32 `pane_sidebar_menu`): Create Group...,
/// Move to Group (a submenu of the other groups, only when there is one), and
/// Remove from Group for a grouped window.
pub const create_group_label = "Create Group\u{2026}";
pub const move_to_group_label = "Move to Group";
pub const remove_from_group_label = "Remove from Group";

/// A GMenu label shows `_` as a mnemonic mark: a group's name has each one
/// doubled so it shows as typed. Cut short in `buf` (never mid-character)
/// when it does not fit; NUL-terminated.
pub fn menuLabel(buf: []u8, name: []const u8) [:0]const u8 {
    std.debug.assert(buf.len > 0);
    var n: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[i]) catch 1;
        const ch = name[i..@min(name.len, i + len)];
        const need: usize = if (ch.len == 1 and ch[0] == '_') 2 else ch.len;
        if (n + need + 1 > buf.len) break;
        @memcpy(buf[n .. n + ch.len], ch);
        if (need == 2) buf[n + 1] = '_';
        n += need;
        i += ch.len;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

/// The debug seam's report of one window's sidebar, as JSON the acceptance
/// script reads (`pane-sidebar` seam, `IpcHandlers.zig`).
pub const Report = struct {
    mode: []const u8,
    expanded: bool,
    hidden: bool,
    can_expand: bool,
    visible: bool,
    width: i32,
    window_width: i32,
    /// The scope (T3558): every window's panes, not this window's.
    all_windows: bool = false,
    /// The shared search, and what this window's field holds and shows.
    search: []const u8 = "",
    search_shown: bool = false,
    search_field: []const u8 = "",
    scope_button_shown: bool = false,
    /// How many windows the all-windows list gathered.
    window_count: usize = 0,
    /// The header's caption.
    title: []const u8 = "",
    /// The panel header's + (a new window, T3606) is on screen.
    add_shown: bool = false,
    /// A window row's right-click menu, while it is up (T3608).
    menu: ?Menu = null,
    /// The in-place field naming a group, while it is open (T3608).
    editing: ?Editing = null,
    rows: []const Row,

    pub const Menu = struct {
        /// The row it was opened on (`window:<key>`).
        row: []const u8,
        /// Its items, top to bottom; Move to Group's are `groups`.
        items: []const []const u8,
        groups: []const []const u8,
        /// The popover is on screen now. A compositor with no seat (the
        /// headless harness) closes it at once for want of a grab.
        popped: bool = false,
    };

    pub const Editing = struct {
        /// The row the field stands in (`window:<key>`, `ungrouped`).
        row: []const u8,
        /// `create_group` (a window row's Create Group...) or `ungrouped`
        /// (the Ungrouped header's pencil).
        purpose: []const u8,
        placeholder: []const u8,
        text: []const u8,
        /// The field is drawn in the list now, and has the keyboard.
        shown: bool,
        focused: bool,
    };

    pub const Row = struct {
        /// A pane's id; a header's or rail tile's `window:<key>`,
        /// `project:<name>`, `ungrouped`.
        pane: []const u8,
        label: []const u8,
        subtitle: ?[]const u8,
        /// The label is on screen (the panel), not only a tooltip (the rail).
        label_shown: bool,
        tooltip: ?[]const u8,
        selected: bool,
        /// A pane stashed out of its window's layout (T3596).
        stashed: bool = false,
        /// `terminal` / `viewer` for a pane; `window`, `project`,
        /// `ungrouped` for a header; `tile` for a rail window tile.
        kind: []const u8,
        /// A header's windows or panes.
        count: usize = 0,
        folded: bool = false,
        /// Outline level (`pane_sidebar_all.Item.depth`).
        depth: u8 = 0,
        /// A window header's pill: `none`, `unemphasized`, `accent`.
        selection: []const u8 = "none",
        /// The buttons the row offers on hover (T3606), and whether the
        /// pointer is over it so they are on screen now.
        tools: []const Tool = &.{},
        hovered: bool = false,
        tools_shown: bool = false,
        /// The row drags to reorder (T3607): a pane on screen.
        draggable: bool = false,
        /// Where the row is laid out in the list, logical pixels from the
        /// list's top (-1 before layout): what a `--drag` y is read against.
        top: i32 = -1,
        height: i32 = 0,
    };
};

// ---------------------------------------------------------------------------
// Drag to reorder (T3607; docs/reference/pane-sidebar.md "Drag to reorder")

/// Where a row dropped at `y` lands among its siblings - the other rows of
/// its window's list, the dragged one left out - as an index of that list
/// without it: past every sibling whose middle is above the pointer. `mids`
/// are the siblings' middles as laid out, top to bottom, in the same
/// coordinates as `y`. Mac reads the index off the rows' frames the same
/// way (`rowFrameReader`).
pub fn dropIndex(mids: []const f64, y: f64) usize {
    var n: usize = 0;
    for (mids) |m| {
        if (m >= y) break;
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// The stash tray (T3698; docs/reference/pane-sidebar.md "Rows and tiles",
// "Drag to reorder"; win32 `pane_drop.sidebarHit`, Mac `trayTop`)

/// The list, then the tray: a window's panes as the sidebar draws them, its
/// panes on screen first in their order and then its stashed ones, the top
/// of the stash (the largest mark) first. `stash_seqs[i]` is pane i's mark,
/// 0 for a pane on screen. Writes the panes' indices into `out` in that
/// order and returns how many (all of them, up to `out.len`). Stable: panes
/// on screen keep the order they came in.
pub fn trayed(stash_seqs: []const u64, out: []usize) usize {
    var n: usize = 0;
    for (stash_seqs, 0..) |s, i| {
        if (s != 0 or n == out.len) continue;
        out[n] = i;
        n += 1;
    }
    const first_stashed = n;
    for (stash_seqs, 0..) |s, i| {
        if (s == 0 or n == out.len) continue;
        out[n] = i;
        n += 1;
    }
    std.mem.sort(usize, out[first_stashed..n], stash_seqs, struct {
        fn topFirst(seqs: []const u64, a: usize, b: usize) bool {
            return seqs[a] > seqs[b];
        }
    }.topFirst);
    return n;
}

/// Where a window's tray begins in the list's coordinates when no tray
/// header of its own is drawn (the all-windows outline, win32 `trayTop`):
/// between its last row on screen and its first stashed row, or right under
/// the last row on screen when nothing is stashed, or at the first stashed
/// row when nothing is on screen. Null with neither: no tray to drop into.
pub fn trayTopBetween(last_list_bottom: ?f64, first_stashed_top: ?f64) ?f64 {
    if (last_list_bottom) |b| {
        if (first_stashed_top) |t| return (b + t) / 2;
        return b;
    }
    return first_stashed_top;
}

/// Which list a row let go at `y` lands in (Mac `PaneDropCandidate.Sidebar`):
/// at or below the tray's top it is the tray, and a drop there stashes;
/// above it, or with no tray, it is the list.
pub fn inTray(tray_top: ?f64, y: f64) bool {
    const top = tray_top orelse return false;
    return y >= top;
}

/// The tray's caption (Mac: "Stashed" only while it holds panes, with their
/// count; the empty well's words instead, expanded).
pub const tray_caption = "Stashed";
pub const tray_well_label = "Drag a pane here to stash it";

/// The sidebar's own pane order, one per window (a GTK tab, by address;
/// win32 `Window.pane_sidebar_order`, Mac `PaneSidebarState.order`): the ids
/// `pane_sidebar_order.moving` wrote at the last drag, owned. Empty, or a
/// window it has never seen, means tree order.
pub const Orders = struct {
    map: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged([]const u8)) = .empty,

    pub fn deinit(self: *Orders, alloc: Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |l| freeList(alloc, l);
        self.map.deinit(alloc);
    }

    fn freeList(alloc: Allocator, l: *std.ArrayListUnmanaged([]const u8)) void {
        for (l.items) |id| alloc.free(id);
        l.deinit(alloc);
    }

    /// The window's order, borrowed until the next `set` or `prune`.
    pub fn get(self: *const Orders, key: usize) []const []const u8 {
        const l = self.map.getPtr(key) orelse return &.{};
        return l.items;
    }

    /// Replace the window's order with copies of `ids` (which may borrow the
    /// old order). Empty forgets the window.
    pub fn set(self: *Orders, alloc: Allocator, key: usize, ids: []const []const u8) Allocator.Error!void {
        var next: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer freeList(alloc, &next);
        try next.ensureTotalCapacity(alloc, ids.len);
        for (ids) |id| next.appendAssumeCapacity(try alloc.dupe(u8, id));
        if (self.map.fetchRemove(key)) |old| {
            var l = old.value;
            freeList(alloc, &l);
        }
        if (next.items.len == 0) return;
        try self.map.put(alloc, key, next);
    }

    /// Forget every window `live` does not say is still open.
    pub fn prune(self: *Orders, alloc: Allocator, ctx: anytype, comptime live: fn (@TypeOf(ctx), usize) bool) void {
        while (true) {
            var it = self.map.iterator();
            const dead = while (it.next()) |e| {
                if (!live(ctx, e.key_ptr.*)) break e.key_ptr.*;
            } else return;
            if (self.map.fetchRemove(dead)) |old| {
                var l = old.value;
                freeList(alloc, &l);
            }
        }
    }

    pub fn count(self: *const Orders) usize {
        return self.map.count();
    }
};

const testing = std.testing;

test "T3607: a dropped row lands past every sibling whose middle is above the pointer" {
    const mids = [_]f64{ 20, 60, 100 };
    try testing.expectEqual(@as(usize, 0), dropIndex(&mids, 5));
    try testing.expectEqual(@as(usize, 0), dropIndex(&mids, 20));
    try testing.expectEqual(@as(usize, 1), dropIndex(&mids, 21));
    try testing.expectEqual(@as(usize, 2), dropIndex(&mids, 99));
    try testing.expectEqual(@as(usize, 3), dropIndex(&mids, 400));
    // A window with only the dragged row: it can only land where it is.
    try testing.expectEqual(@as(usize, 0), dropIndex(&.{}, 50));
}

test "T3698: the tray follows the list - panes on screen in order, then the stash top first" {
    var out: [8]usize = undefined;
    // a(on) b(stash 5) c(on) d(stash 9) e(on): a c e, then d (top) and b.
    const n = trayed(&.{ 0, 5, 0, 9, 0 }, &out);
    try testing.expectEqualSlices(usize, &.{ 0, 2, 4, 3, 1 }, out[0..n]);
    // Nothing stashed: the order is left as it came.
    const m = trayed(&.{ 0, 0, 0 }, &out);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, out[0..m]);
    // Everything stashed (the normalize invariant forbids it, but no crash).
    const k = trayed(&.{ 3, 7 }, &out);
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, out[0..k]);
    // A short buffer is filled, never overrun.
    var small: [2]usize = undefined;
    try testing.expectEqual(@as(usize, 2), trayed(&.{ 0, 4, 0 }, &small));
}

test "T3698: the tray begins between the last row on screen and the first stashed one" {
    try testing.expectEqual(@as(?f64, 110), trayTopBetween(100, 120));
    try testing.expectEqual(@as(?f64, 100), trayTopBetween(100, null));
    try testing.expectEqual(@as(?f64, 40), trayTopBetween(null, 40));
    try testing.expectEqual(@as(?f64, null), trayTopBetween(null, null));
    // At or below the top is the tray; above it, or with no tray, the list.
    try testing.expect(inTray(110, 110));
    try testing.expect(inTray(110, 300));
    try testing.expect(!inTray(110, 109.5));
    try testing.expect(!inTray(null, 1000));
}

test "T3607: a window's order is copied in, replaced whole, forgotten when empty or closed" {
    const alloc = testing.allocator;
    var o: Orders = .{};
    defer o.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), o.get(1).len);

    var src = [_][]const u8{ "b", "a" };
    try o.set(alloc, 1, &src);
    src[0] = "x"; // the store owns its copies
    try testing.expectEqualStrings("b", o.get(1)[0]);
    try testing.expectEqualStrings("a", o.get(1)[1]);

    // A set may borrow the order it replaces.
    try o.set(alloc, 1, o.get(1)[1..]);
    try testing.expectEqual(@as(usize, 1), o.get(1).len);
    try testing.expectEqualStrings("a", o.get(1)[0]);

    try o.set(alloc, 2, &.{"c"});
    try testing.expectEqual(@as(usize, 2), o.count());
    const Live = struct {
        fn f(keep: usize, k: usize) bool {
            return k == keep;
        }
    };
    o.prune(alloc, @as(usize, 2), Live.f);
    try testing.expectEqual(@as(usize, 1), o.count());
    try testing.expectEqual(@as(usize, 0), o.get(1).len);

    try o.set(alloc, 2, &.{});
    try testing.expectEqual(@as(usize, 0), o.count());
}

test "T3557: a row is named by its banner's title, else its title, else its directory" {
    var a: [TEXT_BUF_LEN]u8 = undefined;
    var b: [TEXT_BUF_LEN]u8 = undefined;

    // The banner hook's heading names the pane; the directory is the subtitle.
    var t = text(.{ .title = "vim", .pwd = "/home/ann/src", .banner = "## Fix the parser\n| a | b |" }, "/home/ann", &a, &b);
    try testing.expectEqualStrings("Fix the parser", t.label);
    try testing.expectEqualStrings("~/src", t.subtitle.?);

    // No banner: the title, and the directory under it.
    t = text(.{ .title = "make test", .pwd = "/tmp/work" }, "/home/ann", &a, &b);
    try testing.expectEqualStrings("make test", t.label);
    try testing.expectEqualStrings("/tmp/work", t.subtitle.?);

    // The ghost placeholder names nothing: the directory's name, and the
    // subtitle does not repeat it when it is the whole of it.
    t = text(.{ .title = "\u{1F47B}", .pwd = "/srv" }, null, &a, &b);
    try testing.expectEqualStrings("srv", t.label);

    // Titled by its own directory: the path once, no subtitle repeating it.
    t = text(.{ .title = "/home/ann/src", .pwd = "/home/ann/src/" }, "/home/ann", &a, &b);
    try testing.expectEqualStrings("/home/ann/src", t.label);
    try testing.expect(t.subtitle == null);

    // A banner with no title (a bold label) leaves the title in place and
    // gives the row its first line as the subtitle.
    t = text(.{ .title = "zsh", .pwd = "/home/ann", .banner = "**Goal:** ship it\n- [x] a" }, "/home/ann", &a, &b);
    try testing.expectEqualStrings("zsh", t.label);
    try testing.expectEqualStrings("Goal: ship it", t.subtitle.?);

    // The user's own name outranks the banner's title.
    t = text(.{ .title = "zsh", .title_override = "build box", .banner = "## Task" }, null, &a, &b);
    try testing.expectEqualStrings("build box", t.label);

    // A viewer has no banner and no directory line.
    t = text(.{ .title = "README.md", .pwd = "/x", .viewer = true, .banner = "## ignored" }, null, &a, &b);
    try testing.expectEqualStrings("README.md", t.label);
    try testing.expect(t.subtitle == null);

    // Nothing at all: the pane's kind.
    t = text(.{}, null, &a, &b);
    try testing.expectEqualStrings("terminal", t.label);
    try testing.expect(t.subtitle == null);
}

test "T3606: a row's hover buttons - stash/restore and x on this window's rows, x alone on another's, none in the rail" {
    try testing.expectEqualSlices(Tool, &.{ .stash, .close }, paneTools(true, true, false));
    try testing.expectEqualSlices(Tool, &.{ .restore, .close }, paneTools(true, true, true));
    try testing.expectEqualSlices(Tool, &.{.close}, paneTools(true, false, false));
    try testing.expectEqualSlices(Tool, &.{.close}, paneTools(true, false, true));
    try testing.expectEqual(@as(usize, 0), paneTools(false, true, false).len);
    try testing.expectEqualSlices(Tool, &.{ .add, .close }, headTools(true, false));
    try testing.expectEqual(@as(usize, 0), headTools(false, false).len);
    try testing.expectEqualStrings("Stash", toolTip(.stash, false));
    try testing.expectEqualStrings("New window", toolTip(.add, false));
}

test "T3608: the Ungrouped header's pencil comes first, and only on it" {
    try testing.expectEqualSlices(Tool, &.{ .rename, .add, .close }, headTools(true, true));
    try testing.expectEqual(@as(usize, 0), headTools(false, true).len);
    try testing.expectEqualStrings("Name these windows as a group", toolTip(.rename, false));
}

test "T3608: a group's menu label doubles its underscores and fits its buffer" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("my__proj", menuLabel(&buf, "my_proj"));
    try testing.expectEqualStrings("plain", menuLabel(&buf, "plain"));
    // Five bytes of room (one is the NUL): "a__b" fits, the next "__" does not.
    var small: [6]u8 = undefined;
    try testing.expectEqualStrings("a__b", menuLabel(&small, "a_b_c"));
    // Never cut inside a character: the e-acute is two bytes.
    var tiny: [3]u8 = undefined;
    try testing.expectEqualStrings("x", menuLabel(&tiny, "x\u{e9}"));
}

test "T3557: the mode follows the shared flags, and a narrow window gets the rail" {
    try testing.expectEqual(Mode.expanded, mode(.{ .expanded = true }, 1000));
    try testing.expectEqual(Mode.mini, mode(.{ .expanded = false }, 1000));
    try testing.expectEqual(Mode.hidden, mode(.{ .expanded = true, .hidden = true }, 1000));
    // Under 720: the rail whatever the flag says, and the toggle cannot expand.
    try testing.expectEqual(Mode.mini, mode(.{ .expanded = true }, 500));
    try testing.expect(!canExpand(500));
    try testing.expect(canExpand(800));
    // Not laid out yet is not narrow.
    try testing.expectEqual(Mode.expanded, mode(.{ .expanded = true }, 0));
    // The rail is narrower than the panel; the panel takes the shared width.
    try testing.expect(cardWidth(.mini, .{}) < cardWidth(.expanded, .{}));
    try testing.expectEqual(@as(i32, 300), cardWidth(.expanded, .{ .width_dip = 300 }));
    try testing.expectEqual(railCardWidth(), cardWidth(.mini, .{}));
    try testing.expectEqual(@as(i32, 0), cardWidth(.hidden, .{}));
}

test "T3557: the flags live under the config root, debug apart from release" {
    const alloc = testing.allocator;
    const a = try prefsPath(alloc, true, "/x/cfg", "/home/ann");
    defer alloc.free(a);
    try testing.expectEqualStrings("/x/cfg/ghoztty/pane-sidebar-debug", a);
    const b = try prefsPath(alloc, false, null, "/home/ann");
    defer alloc.free(b);
    try testing.expectEqualStrings("/home/ann/.config/ghoztty/pane-sidebar", b);
    const c = try prefsPath(alloc, false, "", "/home/ann");
    defer alloc.free(c);
    try testing.expectEqualStrings("/home/ann/.config/ghoztty/pane-sidebar", c);
    // T3697: the list's order sits beside them.
    const d = try orderPath(alloc, true, "/x/cfg", "/home/ann");
    defer alloc.free(d);
    try testing.expectEqualStrings("/x/cfg/ghoztty/pane-sidebar-order-debug", d);
    const e = try orderPath(alloc, false, null, "/home/ann");
    defer alloc.free(e);
    try testing.expectEqualStrings("/home/ann/.config/ghoztty/pane-sidebar-order", e);
}

test "T3557: a forced start is not written over the user's own flags" {
    var live: Prefs = .{ .expanded = false, .hidden = false };
    var st = StartState.init(live);
    try testing.expect(st.apply(&live, .expanded));
    try testing.expect(live.expanded);
    // The file still keeps the user's collapsed choice.
    try testing.expect(!st.toSave(live).expanded);
    // A reload with the same value changes nothing (the user's toggles stand).
    st.userSet(&live, false, true);
    try testing.expect(!st.apply(&live, .expanded));
    try testing.expect(live.hidden);
}
