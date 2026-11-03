//! Persisted pane-sidebar defaults (T1847): the expanded and hidden flags a NEW
//! window starts from, the panel width every window shares, and the
//! all-windows scope the app launches in (T2564).
//!
//! Mac keeps these in UserDefaults (`PaneSidebarExpanded`, falling back to
//! the older `PaneSidebarPinned`; `PaneSidebarHidden`, `PaneSidebarWidth` in
//! `PaneSidebarState`): the most recently chosen expanded and hidden flags,
//! the way a Finder window's sidebar remembers, and one width preference. This is the win32 translation - the `window_memory.zig` /
//! `viewer_prefs.zig` pattern, one tiny text file under
//! `%LOCALAPPDATA%\ghoztty`. Since T2336 (Mac b07b7fa0b) these flags are
//! every window's, restored windows included: each window still records its
//! copy in the session-layout manifest (`session_layout.Window.pane_sidebar_*`)
//! for an older build, but a restore never applies it.
//!
//! Format: `<expanded 0|1> <hidden 0|1> <width dip> <all windows 0|1>\n`. The
//! first flag was the pin until T2289 (Mac e77422577); pinned WAS the expanded
//! panel, so a file written then reads the same way now. The scope arrived in
//! T2564 (Mac 8aefd0c91, `PaneSidebarShowsAllWindows`, on when unset): a
//! three-field file from before it reads as on, the way an unset Mac default
//! does. Only the scope persists - its search and folds never do, so a launch
//! starts every window folded, as turning the scope on does.
//!
//! The parse/format logic is pure so its unit tests run in every app-runtime
//! lane.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const pane_sidebar = @import("pane_sidebar.zig");

pub const Prefs = struct {
    expanded: bool = false,
    hidden: bool = false,
    width_dip: f32 = pane_sidebar.default_width_dip,
    /// The all-windows scope: on until the user leaves it off (T2564).
    all_windows: bool = true,
};

fn flag(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "1")) return true;
    if (std.mem.eql(u8, s, "0")) return false;
    return null;
}

/// Parse the file. Null on anything malformed - the caller then starts from
/// the defaults, exactly as if the file did not exist. A width outside the
/// panel's range is clamped rather than rejected, so a later change to the
/// range keeps the user's flags.
pub fn parse(text: []const u8) ?Prefs {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const expanded = flag(it.next() orelse return null) orelse return null;
    const hidden = flag(it.next() orelse return null) orelse return null;
    const w = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    // Absent in a file from before T2564: on, Mac's unset default.
    const all_windows = if (it.next()) |t| flag(t) orelse return null else true;
    if (it.next() != null) return null;
    if (w <= 0) return null;
    return .{
        .expanded = expanded,
        .hidden = hidden,
        .width_dip = pane_sidebar.clampWidth(@floatFromInt(w)),
        .all_windows = all_windows,
    };
}

/// How every window's sidebar starts: `macos-pane-sidebar` (T2588, Mac
/// 92ab0c9f1), mirrored here so this module stays pure. The sidebar is
/// shared, so this is every window's start, not one window's.
pub const Start = enum { remember, expanded, collapsed, hidden };

/// The forced start against the user's own choice (Mac
/// `PaneSidebarSharedState.applyStart` / `isApplyingStart`). The live flags
/// (`Prefs`, what every window draws) take a forced start; the file keeps
/// what the USER last left (`own_*`), so `remember` still has their choice
/// after a launch that forced another. A toggle afterwards is the user's and
/// is kept as always.
pub const StartState = struct {
    own_expanded: bool = false,
    own_hidden: bool = false,
    /// The value last applied; a reload that leaves it alone must not undo
    /// the user's toggles since.
    applied: ?Start = null,

    /// From the flags the file had (or the defaults, without one).
    pub fn init(p: Prefs) StartState {
        return .{ .own_expanded = p.expanded, .own_hidden = p.hidden };
    }

    /// Apply `start` to `live`, at launch and on a config change - but only
    /// when the value CHANGED. `hidden` keeps the expanded/rail choice for
    /// when the sidebar is shown again. True when `live`'s flags moved.
    pub fn apply(self: *StartState, live: *Prefs, start: Start) bool {
        if (self.applied == start) return false;
        self.applied = start;
        const before = live.*;
        switch (start) {
            .remember => {},
            .expanded => {
                live.hidden = false;
                live.expanded = true;
            },
            .collapsed => {
                live.hidden = false;
                live.expanded = false;
            },
            .hidden => live.hidden = true,
        }
        return before.expanded != live.expanded or before.hidden != live.hidden;
    }

    /// The user set the flags (a toggle, a hide or show): each one that
    /// changed is theirs and is remembered; `live` takes both.
    pub fn userSet(self: *StartState, live: *Prefs, expanded: bool, hidden: bool) void {
        if (expanded != live.expanded) self.own_expanded = expanded;
        if (hidden != live.hidden) self.own_hidden = hidden;
        live.expanded = expanded;
        live.hidden = hidden;
    }

    /// What the file keeps: the live width and scope, the user's own flags.
    pub fn toSave(self: StartState, live: Prefs) Prefs {
        var p = live;
        p.expanded = self.own_expanded;
        p.hidden = self.own_hidden;
        return p;
    }
};

pub const FORMAT_BUF_LEN: usize = 32;

/// Format for the file. The width is stored as whole DIP: a sub-pixel width
/// preference is noise, and an integer file cannot half-parse.
pub fn format(buf: []u8, p: Prefs) []const u8 {
    const w: i32 = @intFromFloat(@round(pane_sidebar.clampWidth(p.width_dip)));
    return std.fmt.bufPrint(buf, "{d} {d} {d} {d}\n", .{
        @intFromBool(p.expanded),
        @intFromBool(p.hidden),
        w,
        @intFromBool(p.all_windows),
    }) catch unreachable;
}

/// `%LOCALAPPDATA%\ghoztty\pane_sidebar[-debug]`. Debug builds get their own
/// file (the debug-IPC-pipe coexistence pattern), so a dev or test window
/// never changes how the user's release app opens.
fn path(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (builtin.mode == .Debug) "pane_sidebar-debug" else "pane_sidebar";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// The persisted defaults, or null when there are none (no file, unreadable,
/// malformed).
pub fn load(alloc: Allocator) ?Prefs {
    const p = path(alloc) orelse return null;
    defer alloc.free(p);
    const f = std.fs.cwd().openFile(p, .{}) catch return null;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    return parse(buf[0..n]);
}

/// Persist the defaults. Best-effort: a preference is never worth an error.
pub fn save(alloc: Allocator, prefs: Prefs) void {
    const p = path(alloc) orelse return;
    defer alloc.free(p);
    std.fs.cwd().makePath(std.fs.path.dirname(p) orelse return) catch return;
    const f = std.fs.cwd().createFile(p, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    f.writeAll(format(&buf, prefs)) catch {};
}

const testing = std.testing;

test "T1847: prefs round-trip through the file format" {
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    for ([_]Prefs{
        .{},
        .{ .expanded = true, .hidden = false, .width_dip = 300 },
        .{ .expanded = false, .hidden = true, .width_dip = pane_sidebar.min_width_dip },
        .{ .expanded = true, .hidden = true, .width_dip = pane_sidebar.max_width_dip },
        .{ .expanded = true, .width_dip = 300, .all_windows = false },
    }) |p| {
        const got = parse(format(&buf, p)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(p.expanded, got.expanded);
        try testing.expectEqual(p.hidden, got.hidden);
        try testing.expectEqual(p.width_dip, got.width_dip);
        try testing.expectEqual(p.all_windows, got.all_windows);
    }
}

test "T1847: the width is stored whole and clamped to the panel's range" {
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("1 0 251 1\n", format(&buf, .{ .expanded = true, .width_dip = 250.6 }));
    try testing.expectEqualStrings("0 0 380 0\n", format(&buf, .{ .width_dip = 9000, .all_windows = false }));
    try testing.expectEqual(pane_sidebar.max_width_dip, parse("1 1 9000").?.width_dip);
    try testing.expectEqual(pane_sidebar.min_width_dip, parse("1 1 5").?.width_dip);
    // CRLF from a hand edit still reads.
    try testing.expectEqual(@as(f32, 260), parse("0 1 260\r\n").?.width_dip);
}

test "T1847: a malformed file reads as no preference at all" {
    for ([_][]const u8{
        "",
        "1",
        "1 0",
        "yes no 240",
        "2 0 240",
        "1 0 wide",
        "1 0 0",
        "1 0 -40",
        "1 0 240 extra",
        "1 0 240 2",
        "1 0 240 1 0",
    }) |text| try testing.expectEqual(@as(?Prefs, null), parse(text));
}

test "T2564: the all-windows scope is on by default and when a file predates it" {
    // A first launch (no file) starts from the defaults: all windows.
    try testing.expect((Prefs{}).all_windows);
    // A three-field file from before the scope persisted reads as on, the
    // way Mac's unset `PaneSidebarShowsAllWindows` does - and keeps its flags.
    const old = parse("1 0 300\n") orelse return error.TestUnexpectedResult;
    try testing.expect(old.all_windows and old.expanded and !old.hidden);
    try testing.expectEqual(@as(f32, 300), old.width_dip);
    // Left off, it stays off.
    try testing.expect(!parse("0 0 240 0").?.all_windows);
    try testing.expect(parse("0 0 240 1").?.all_windows);
}

// macos-pane-sidebar (T2588): Mac `PaneSidebarSharedStateTests`, one for one.

test "T2588: remember starts as the file left it" {
    var live: Prefs = .{ .expanded = true, .hidden = true };
    var st = StartState.init(live);
    try testing.expect(!st.apply(&live, .remember));
    try testing.expect(live.expanded and live.hidden);
}

test "T2588: a forced start wins over the file and is not remembered" {
    for ([_]struct { start: Start, expanded: bool }{
        .{ .start = .expanded, .expanded = true },
        .{ .start = .collapsed, .expanded = false },
    }) |c| {
        var live: Prefs = .{ .expanded = !c.expanded, .hidden = true, .width_dip = 300 };
        var st = StartState.init(live);
        try testing.expect(st.apply(&live, c.start));
        try testing.expect(live.expanded == c.expanded and !live.hidden);
        // `remember` keeps the user's own last choice; the width is live.
        const saved = st.toSave(live);
        try testing.expect(saved.expanded == !c.expanded and saved.hidden);
        try testing.expectEqual(@as(f32, 300), saved.width_dip);
    }
}

test "T2588: hidden keeps the remembered mode for when it is shown" {
    var live: Prefs = .{ .expanded = true };
    var st = StartState.init(live);
    try testing.expect(st.apply(&live, .hidden));
    try testing.expect(live.hidden and live.expanded);
    try testing.expect(!st.toSave(live).hidden);
}

test "T2588: toggling after a forced start still works and is remembered" {
    var live: Prefs = .{};
    var st = StartState.init(live);
    _ = st.apply(&live, .collapsed);
    st.userSet(&live, true, false);
    st.userSet(&live, true, true);
    try testing.expect(live.expanded and live.hidden);
    const saved = st.toSave(live);
    try testing.expect(saved.expanded and saved.hidden);
}

test "T2588: a toggle remembers only the flag it changed" {
    // Forced collapsed over a file that said expanded; the user then hides
    // it. Hidden is theirs; expanded was the config's, so the file keeps
    // the expanded choice they made before (Mac writes each key on its own).
    var live: Prefs = .{ .expanded = true };
    var st = StartState.init(live);
    _ = st.apply(&live, .collapsed);
    st.userSet(&live, false, true);
    const saved = st.toSave(live);
    try testing.expect(saved.expanded and saved.hidden);
}

test "T2588: a reload reapplies only when the value changes" {
    var live: Prefs = .{};
    var st = StartState.init(live);
    _ = st.apply(&live, .collapsed);
    st.userSet(&live, true, false);
    try testing.expect(!st.apply(&live, .collapsed));
    try testing.expect(live.expanded); // the same value again does not undo the toggle
    try testing.expect(st.apply(&live, .hidden));
    try testing.expect(live.hidden);
    try testing.expect(st.apply(&live, .expanded));
    try testing.expect(live.expanded and !live.hidden);
}
