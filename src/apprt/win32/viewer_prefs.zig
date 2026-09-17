//! Persisted viewer chrome preferences: the side-panel card width (T160) and
//! the diff layout (T817).
//!
//! A chrome preference rather than a property of any one document or window,
//! so it lives in its own small file and applies to every viewer pane — the
//! same way a sidebar width behaves in a document app, and unlike a split
//! ratio, which is per-window by nature. Mac stores the same number in
//! UserDefaults under `ViewerTOCCardWidth`; this is the `window_memory.zig`
//! pattern (one tiny text file under `%LOCALAPPDATA%\ghoztty`), which is
//! where win32 keeps such preferences — deliberately NOT the session-layout
//! manifest, which restores windows, not user taste.
//!
//! The parse/format/clamp logic is pure so its unit tests run in every
//! app-runtime lane.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const toc_layout = @import("viewer_toc_layout.zig");
const viewer_diff = @import("viewer_diff.zig");

/// Parse the persisted card width (whole DIP). Returns null on malformed or
/// out-of-range input — the caller then uses the design default, exactly as
/// if the file did not exist.
pub fn parseWidth(text: []const u8) ?f32 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const s = it.next() orelse return null;
    if (it.next() != null) return null;
    const v = std.fmt.parseInt(i32, s, 10) catch return null;
    const f: f32 = @floatFromInt(v);
    if (f < toc_layout.card_min_dip or f > toc_layout.card_max_dip) return null;
    return f;
}

/// Format a card width for the file. Stored as whole DIP: sub-pixel width
/// preferences are noise, and an integer file cannot half-parse.
pub fn formatWidth(buf: []u8, width_dip: f32) []const u8 {
    const v: i32 = @intFromFloat(@round(width_dip));
    return std.fmt.bufPrint(buf, "{d}\n", .{v}) catch unreachable;
}

pub const FORMAT_BUF_LEN: usize = 16;

/// One preference file's path under `%LOCALAPPDATA%\ghoztty`. Debug builds get
/// their own (the debug-IPC-pipe coexistence pattern) so dev/test panes never
/// move the release app's chrome.
fn prefPath(alloc: Allocator, comptime stem: []const u8) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (builtin.mode == .Debug) stem ++ "-debug" else stem;
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

fn widthPath(alloc: Allocator) ?[]u8 {
    return prefPath(alloc, "viewer_sidepanel_width");
}

/// The card width to use: the persisted preference, else the design default.
pub fn loadWidth(alloc: Allocator) f32 {
    const path = widthPath(alloc) orelse return toc_layout.card_default_dip;
    defer alloc.free(path);
    const f = std.fs.cwd().openFile(path, .{}) catch return toc_layout.card_default_dip;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return toc_layout.card_default_dip;
    return parseWidth(buf[0..n]) orelse toc_layout.card_default_dip;
}

/// Persist a card width. Best-effort: a preference is never worth an error
/// dialog.
pub fn saveWidth(alloc: Allocator, width_dip: f32) void {
    const path = widthPath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    f.writeAll(formatWidth(&buf, width_dip)) catch {};
}

// ---------------------------------------------------------------------------
// The diff layout (T817)
// ---------------------------------------------------------------------------

/// A chrome preference like the card width, and persisted the same way — Mac
/// keeps the same choice in UserDefaults under `ViewerDiffViewStyle`. It is
/// deliberately NOT part of a pane's restored state: "I read diffs side by
/// side" is a taste that applies to every diff pane, while the session
/// manifest restores windows.
fn stylePath(alloc: Allocator) ?[]u8 {
    return prefPath(alloc, "viewer_diff_style");
}

/// The layout a diff pane opens in: the persisted preference, else unified —
/// the same default Mac's `DiffViewStyle` has, and the readable one in the
/// narrow pane a diff is usually opened into.
pub fn loadDiffStyle(alloc: Allocator) viewer_diff.Style {
    const path = stylePath(alloc) orelse return .unified;
    defer alloc.free(path);
    const f = std.fs.cwd().openFile(path, .{}) catch return .unified;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return .unified;
    return viewer_diff.Style.parse(buf[0..n]) orelse .unified;
}

/// Persist a diff layout. Best-effort, like every preference here: a taste is
/// never worth an error dialog.
pub fn saveDiffStyle(alloc: Allocator, style: viewer_diff.Style) void {
    const path = stylePath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}\n", .{style.wire()}) catch return;
    f.writeAll(text) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseWidth: valid, tolerant of whitespace" {
    try testing.expectEqual(@as(?f32, 240), parseWidth("240\n"));
    try testing.expectEqual(@as(?f32, 170), parseWidth("  170 \r\n"));
    try testing.expectEqual(@as(?f32, 460), parseWidth("460"));
}

test "parseWidth: malformed and out-of-range rejected" {
    try testing.expectEqual(@as(?f32, null), parseWidth(""));
    try testing.expectEqual(@as(?f32, null), parseWidth("abc"));
    try testing.expectEqual(@as(?f32, null), parseWidth("240 240"));
    try testing.expectEqual(@as(?f32, null), parseWidth("240.5"));
    // Outside the draggable range means a corrupt or hand-edited file.
    try testing.expectEqual(@as(?f32, null), parseWidth("169"));
    try testing.expectEqual(@as(?f32, null), parseWidth("461"));
    try testing.expectEqual(@as(?f32, null), parseWidth("-240"));
}

test "formatWidth round-trips through parseWidth" {
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    try testing.expectEqual(@as(?f32, 240), parseWidth(formatWidth(&buf, 240)));
    try testing.expectEqual(@as(?f32, 313), parseWidth(formatWidth(&buf, 312.7)));
    try testing.expectEqual(@as(?f32, 170), parseWidth(formatWidth(&buf, 170)));
}

test "T817: a diff style round-trips through the file's own text" {
    // What `saveDiffStyle` writes and `loadDiffStyle` reads, without touching
    // the disk: the formatting is a newline-terminated tag name, and the parse
    // has to accept exactly that.
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    for ([_]viewer_diff.Style{ .unified, .split }) |style| {
        const text = try std.fmt.bufPrint(&buf, "{s}\n", .{style.wire()});
        try testing.expectEqual(style, viewer_diff.Style.parse(text).?);
    }
}

test "T817: a malformed style file reads as no preference" {
    // The same rule `parseWidth` follows: a hand-edited or truncated file must
    // degrade to the design default, never to a third state the page would
    // reject silently.
    for ([_][]const u8{ "", "sidebyside", "unified split", "UNIFIED", "0" }) |text| {
        try testing.expectEqual(@as(?viewer_diff.Style, null), viewer_diff.Style.parse(text));
    }
}
