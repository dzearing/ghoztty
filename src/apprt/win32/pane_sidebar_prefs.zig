//! Persisted pane-sidebar defaults (T1847): the pin and hidden flags a NEW
//! window starts from, and the panel width every window shares.
//!
//! Mac keeps these in UserDefaults (`PaneSidebarPinned`, `PaneSidebarHidden`,
//! `PaneSidebarWidth` in `PaneSidebarState`): the most recently chosen pin and
//! hidden flags, the way a Finder window's sidebar remembers, and one width
//! preference. This is the win32 translation - the `window_memory.zig` /
//! `viewer_prefs.zig` pattern, one tiny text file under
//! `%LOCALAPPDATA%\ghoztty`. A RESTORED window's own flags come from the
//! session-layout manifest instead (`session_layout.Window.pane_sidebar_*`);
//! this file only seeds windows that have no recorded state.
//!
//! Format: `<pinned 0|1> <hidden 0|1> <width dip>\n`.
//!
//! The parse/format logic is pure so its unit tests run in every app-runtime
//! lane.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const pane_sidebar = @import("pane_sidebar.zig");

pub const Prefs = struct {
    pinned: bool = false,
    hidden: bool = false,
    width_dip: f32 = pane_sidebar.default_width_dip,
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
    const pinned = flag(it.next() orelse return null) orelse return null;
    const hidden = flag(it.next() orelse return null) orelse return null;
    const w = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    if (w <= 0) return null;
    return .{
        .pinned = pinned,
        .hidden = hidden,
        .width_dip = pane_sidebar.clampWidth(@floatFromInt(w)),
    };
}

pub const FORMAT_BUF_LEN: usize = 32;

/// Format for the file. The width is stored as whole DIP: a sub-pixel width
/// preference is noise, and an integer file cannot half-parse.
pub fn format(buf: []u8, p: Prefs) []const u8 {
    const w: i32 = @intFromFloat(@round(pane_sidebar.clampWidth(p.width_dip)));
    return std.fmt.bufPrint(buf, "{d} {d} {d}\n", .{
        @intFromBool(p.pinned),
        @intFromBool(p.hidden),
        w,
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
        .{ .pinned = true, .hidden = false, .width_dip = 300 },
        .{ .pinned = false, .hidden = true, .width_dip = pane_sidebar.min_width_dip },
        .{ .pinned = true, .hidden = true, .width_dip = pane_sidebar.max_width_dip },
    }) |p| {
        const got = parse(format(&buf, p)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(p.pinned, got.pinned);
        try testing.expectEqual(p.hidden, got.hidden);
        try testing.expectEqual(p.width_dip, got.width_dip);
    }
}

test "T1847: the width is stored whole and clamped to the panel's range" {
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("1 0 251\n", format(&buf, .{ .pinned = true, .width_dip = 250.6 }));
    try testing.expectEqualStrings("0 0 380\n", format(&buf, .{ .width_dip = 9000 }));
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
    }) |text| try testing.expectEqual(@as(?Prefs, null), parse(text));
}
