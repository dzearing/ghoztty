//! Frame memory for a utility window (T2667): the win32 translation of
//! AppKit's `setFrameAutosaveName`, which is how Mac's keyboard shortcut guide
//! (`ShortcutGuideController`, autosave name `ShortcutGuideWindow`) reopens
//! where the user left it.
//!
//! The terminal window's own memory (`window_memory.zig`, T85) remembers a
//! SIZE only, because a terminal window's position belongs to the cascade and
//! the `window-position-x/y` config. A utility window has neither, so this
//! remembers the whole outer rect - position and size - the way AppKit does.
//!
//! Precedence on open: a remembered frame that still overlaps a monitor is
//! replayed (rescaled when the monitor's scale differs from the one it was
//! measured at, T1971's rule via `window_placement.fitToMonitor`); a frame
//! whose monitor is gone is the same size centred on the nearest monitor's
//! work area (`restore_frame.centerOn`); no frame is the caller's default.
//!
//! Storage: one tiny text file per window under `%LOCALAPPDATA%\ghoztty\`,
//! `<name>-frame` (`<name>-frame-debug` from a debug build, so a test run never
//! moves the user's window), format `<x> <y> <w> <h> <dpi>\n` in outer
//! virtual-screen pixels plus the DPI they were measured at. Best-effort both
//! ways: a missing or corrupt file is "nothing remembered".
//!
//! The parse/format/resolve logic is pure so it runs in every test lane.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const restore_frame = @import("restore_frame.zig");
const window_placement = @import("window_placement.zig");
const window_memory = @import("window_memory.zig");

pub const Rect = restore_frame.Rect;

/// Sanity bounds. A size outside them, or a position further out than any
/// real virtual screen, is a corrupt or hand-edited file.
pub const MIN_DIM: i32 = 200;
pub const MAX_DIM: i32 = 30000;
pub const MAX_COORD: i32 = 100000;
/// The DPI bounds `window_memory` keeps (50%..1000%), one definition.
pub const MIN_DPI: u32 = window_memory.MIN_DPI;
pub const MAX_DPI: u32 = window_memory.MAX_DPI;

pub const Saved = struct {
    /// Outer window rect, virtual-screen pixels.
    rect: Rect,
    /// The DPI `rect` was measured at.
    dpi: u32,
};

pub fn parse(text: []const u8) ?Saved {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var v: [5]i64 = undefined;
    for (&v) |*slot| {
        const tok = it.next() orelse return null;
        slot.* = std.fmt.parseInt(i64, tok, 10) catch return null;
    }
    if (it.next() != null) return null;
    if (v[0] < -MAX_COORD or v[0] > MAX_COORD) return null;
    if (v[1] < -MAX_COORD or v[1] > MAX_COORD) return null;
    if (v[2] < MIN_DIM or v[2] > MAX_DIM) return null;
    if (v[3] < MIN_DIM or v[3] > MAX_DIM) return null;
    if (v[4] < MIN_DPI or v[4] > MAX_DPI) return null;
    return .{
        .rect = .{ .x = @intCast(v[0]), .y = @intCast(v[1]), .w = @intCast(v[2]), .h = @intCast(v[3]) },
        .dpi = @intCast(v[4]),
    };
}

pub const FORMAT_BUF_LEN: usize = 64;

pub fn format(buf: []u8, s: Saved) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {d} {d} {d} {d}\n", .{
        s.rect.x, s.rect.y, s.rect.w, s.rect.h, s.dpi,
    }) catch unreachable; // five bounded ints always fit FORMAT_BUF_LEN
}

/// Whether a frame is worth recording: a minimized or degenerate window is
/// not a place the user left it.
pub fn recordable(r: Rect) bool {
    return r.w >= MIN_DIM and r.h >= MIN_DIM and r.w <= MAX_DIM and r.h <= MAX_DIM and
        r.x >= -MAX_COORD and r.x <= MAX_COORD and r.y >= -MAX_COORD and r.y <= MAX_COORD;
}

/// Where a remembered window opens.
///
/// `visible` is whether `saved.rect` still overlaps a monitor (the caller asks
/// `MonitorFromRect(..., MONITOR_DEFAULTTONULL)`); `target_dpi` and `work` are
/// the DPI and work area of the monitor it lands on (the nearest one when it
/// is not visible).
pub fn resolve(saved: Saved, visible: bool, target_dpi: u32, work: Rect) Rect {
    if (visible) return window_placement.fitToMonitor(saved.rect, saved.dpi, target_dpi, work);
    // Its monitor is gone: keep the size (at the new scale) and centre it where
    // it can be seen.
    var r = saved.rect;
    r.w = window_placement.scaleDim(r.w, saved.dpi, target_dpi);
    r.h = window_placement.scaleDim(r.h, saved.dpi, target_dpi);
    return restore_frame.centerOn(r, work);
}

fn framePath(alloc: Allocator, name: []const u8) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const file = std.fmt.allocPrint(alloc, "{s}-frame{s}", .{
        name, if (builtin.mode == .Debug) "-debug" else "",
    }) catch return null;
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", file }) catch null;
}

pub fn load(alloc: Allocator, name: []const u8) ?Saved {
    const path = framePath(alloc, name) orelse return null;
    defer alloc.free(path);
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    return parse(buf[0..n]);
}

pub fn save(alloc: Allocator, name: []const u8, s: Saved) void {
    if (!recordable(s.rect)) return;
    if (s.dpi < MIN_DPI or s.dpi > MAX_DPI) return;
    const path = framePath(alloc, name) orelse return;
    defer alloc.free(path);
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    f.writeAll(format(&buf, s)) catch {};
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "panel frame: format round-trips through parse, negative positions included" {
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const cases = [_]Saved{
        .{ .rect = .{ .x = 100, .y = 80, .w = 900, .h = 660 }, .dpi = 96 },
        .{ .rect = .{ .x = -1920, .y = -200, .w = 1760, .h = 1280 }, .dpi = 192 },
        .{ .rect = .{ .x = MAX_COORD, .y = -MAX_COORD, .w = MAX_DIM, .h = MIN_DIM }, .dpi = MAX_DPI },
    };
    for (cases) |s| try testing.expectEqual(s, parse(format(&buf, s)).?);
}

test "panel frame: a corrupt or out-of-range file is nothing remembered" {
    const bad = [_][]const u8{
        "",                      "100 80 900 660", // no dpi
        "100 80 900 660 96 1",   "100 80 199 660 96",
        "100 80 900 30001 96",   "100 80 900 660 47",
        "100 80 900 660 961",    "100001 80 900 660 96",
        "a 80 900 660 96",       "100 80 900 660 9999999999999",
    };
    for (bad) |t| try testing.expectEqual(@as(?Saved, null), parse(t));
    // Tolerant of CRLF and extra spaces.
    try testing.expect(parse("  100\t80 900 660 96\r\n") != null);
}

test "panel frame: a frame still on a monitor at the same scale replays verbatim" {
    const s: Saved = .{ .rect = .{ .x = 2100, .y = 40, .w = 900, .h = 660 }, .dpi = 144 };
    const work: Rect = .{ .x = 1920, .y = 0, .w = 2560, .h = 1400 };
    try testing.expectEqual(s.rect, resolve(s, true, 144, work));
}

test "panel frame: a frame whose monitor changed scale keeps its spot and rescales" {
    const s: Saved = .{ .rect = .{ .x = 100, .y = 100, .w = 880, .h = 640 }, .dpi = 96 };
    const work: Rect = .{ .x = 0, .y = 0, .w = 3840, .h = 2100 };
    try testing.expectEqual(
        Rect{ .x = 100, .y = 100, .w = 1760, .h = 1280 },
        resolve(s, true, 192, work),
    );
}

test "panel frame: a frame on a monitor that is gone is centred on the nearest one" {
    // Remembered on a left-hand monitor that has since been unplugged.
    const s: Saved = .{ .rect = .{ .x = -1700, .y = 200, .w = 900, .h = 660 }, .dpi = 96 };
    const work: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1040 };
    const r = resolve(s, false, 96, work);
    try testing.expectEqual(Rect{ .x = 510, .y = 190, .w = 900, .h = 660 }, r);
    try testing.expect(restore_frame.isVisible(r, &.{work}));
    // ...and shrunk to fit a smaller one, at its scale.
    const big: Saved = .{ .rect = .{ .x = 5000, .y = 0, .w = 2400, .h = 1600 }, .dpi = 96 };
    const small = resolve(big, false, 96, work);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 1920, .h = 1040 }, small);
}

test "panel frame: only a real window frame is recordable" {
    try testing.expect(recordable(.{ .x = 0, .y = 0, .w = 900, .h = 660 }));
    // A minimized window's rect (-32000, -32000, 160x28).
    try testing.expect(!recordable(.{ .x = -32000, .y = -32000, .w = 160, .h = 28 }));
    try testing.expect(!recordable(.{ .x = 0, .y = 0, .w = 0, .h = 0 }));
}
