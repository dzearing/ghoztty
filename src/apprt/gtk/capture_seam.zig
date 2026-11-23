//! The pure half of the GTK app's `capture-pane` IPC seam (T3359, Linux):
//! what the request asks for, the size the picture is rendered at, and the
//! reply. The GTK half (`IpcHandlers.handleSeam`) resolves the target and
//! renders through `pane_snapshot.zig`; this file holds only arithmetic and
//! JSON so it asserts in the `-Dapp-runtime=none` lane.
//!
//! ## The same seam as win32's, not a CLI verb
//!
//! win32 answers `capture-pane` (T275, `win32/ipc_capture.zig`) for its
//! acceptance harness, which runs on a background desktop with no composite.
//! The Linux harness has the same problem in a sharper form: the headless
//! Weston it runs in offers a client no capture, and Wayland has no global
//! capture at all. So it is the same answer - the app hands over its OWN
//! render - on the same wire shape, with the same Debug-only gate (a release
//! build answers `unknown action: capture-pane`), and for the same reason
//! there is no `+capture-pane`: a CLI verb is a cross-platform product surface.
//!
//! ```
//! {"action":"capture-pane","arguments":[
//!    "--target=<pane|window|pane-id>","--path=<file.png>",
//!    "--width=<px>","--height=<px>","--window"]}
//! ```
//!
//! → `{"success":true,"data":{"path":…,"width":N,"height":N,"bytes":N,
//!     "x":N,"y":N,"client_width":N,"client_height":N,"scope":"pane"|"window"}}`
//!
//! Arguments are parsed by win32's own `pane_capture.parse`, so the two
//! frontends cannot disagree about a flag. Two differences, both because of
//! what the GTK picture is:
//!
//! - **`--window`** captures the whole window (title bar, tabs, every pane)
//!   instead of one pane. win32 composes a window out of pane captures and a
//!   `PrintWindow` of the parent (T778); a GTK window is one widget tree that
//!   renders in one pass, so the harness can simply ask for it. An older
//!   win32 server ignores the flag (unknown arguments are ignored there).
//! - **`x`/`y` are window-relative**, in device pixels: Wayland gives a client
//!   no screen coordinates. They place a pane capture inside a `--window`
//!   capture of the same window, which is what win32's screen origin is for.
//!
//! A viewer pane is captured too (its page and chrome, WebKit included); win32
//! refuses one because its capture is the terminal renderer's readback.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pane_capture = @import("../win32/pane_capture.zig");

pub const max_dimension = pane_capture.max_dimension;
pub const ParseError = pane_capture.Error;

pub const Request = struct {
    target: []const u8,
    path: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    /// Capture the target's whole window rather than one pane.
    window: bool = false,
};

pub fn parse(args: ?[]const []const u8) ParseError!Request {
    const base = try pane_capture.parse(args);
    var window = false;
    if (args) |list| for (list) |arg| {
        if (std.mem.eql(u8, arg, "--window") or std.mem.eql(u8, arg, "--window=true")) window = true;
        if (std.mem.eql(u8, arg, "--window=false")) window = false;
    };
    return .{
        .target = base.target,
        .path = base.path,
        .width = base.width,
        .height = base.height,
        .window = window,
    };
}

/// The render: the output size in pixels and the scale from the widget's
/// LOGICAL size to it on each axis.
pub const Plan = struct {
    w: u32,
    h: u32,
    sx: f32,
    sy: f32,
};

/// How to render a widget of logical size `w`x`h` at device scale `scale`:
/// at its device-pixel size unless the request names a size, in which case
/// that axis is stretched to it. Null for a widget with no area (mid-layout,
/// unmapped), which the caller reports as "no content area" rather than
/// handing back a 1x1 nobody asked for.
pub fn plan(w: i32, h: i32, scale: i32, req: Request) ?Plan {
    if (w <= 0 or h <= 0) return null;
    const s: u32 = @intCast(@max(1, scale));
    const dw: u32 = @min(@as(u32, @intCast(w)) * s, max_dimension);
    const dh: u32 = @min(@as(u32, @intCast(h)) * s, max_dimension);
    const ow = if (req.width) |r| @min(r, max_dimension) else dw;
    const oh = if (req.height) |r| @min(r, max_dimension) else dh;
    return .{
        .w = ow,
        .h = oh,
        .sx = @as(f32, @floatFromInt(ow)) / @as(f32, @floatFromInt(w)),
        .sy = @as(f32, @floatFromInt(oh)) / @as(f32, @floatFromInt(h)),
    };
}

pub const Reply = struct {
    path: []const u8,
    width: u32,
    height: u32,
    bytes: usize,
    /// The captured widget's top-left inside its window, device pixels.
    x: i32,
    y: i32,
    /// The captured widget's own size in device pixels (differs from
    /// width/height when the request named a size).
    client_width: u32,
    client_height: u32,
    window: bool,
};

pub fn successJson(alloc: Allocator, r: Reply) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    jws.write(.{
        .success = true,
        .data = .{
            .path = r.path,
            .width = r.width,
            .height = r.height,
            .bytes = r.bytes,
            .x = r.x,
            .y = r.y,
            .client_width = r.client_width,
            .client_height = r.client_height,
            .scope = if (r.window) "window" else "pane",
        },
    }) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse: win32's arguments, plus --window" {
    const r = try parse(&.{ "--target=main", "--path=/tmp/a.png", "--width=40", "--window" });
    try testing.expectEqualStrings("main", r.target);
    try testing.expectEqualStrings("/tmp/a.png", r.path);
    try testing.expectEqual(@as(?u32, 40), r.width);
    try testing.expectEqual(@as(?u32, null), r.height);
    try testing.expect(r.window);

    const p = try parse(&.{ "--path=x.png", "--target=t" });
    try testing.expect(!p.window);
    const off = try parse(&.{ "--target=t", "--path=x.png", "--window", "--window=false" });
    try testing.expect(!off.window);
}

test "parse: the refusals are win32's" {
    try testing.expectError(error.MissingTarget, parse(&.{"--path=x.png"}));
    try testing.expectError(error.MissingPath, parse(&.{"--target=t"}));
    try testing.expectError(error.BadDimension, parse(&.{ "--target=t", "--path=x", "--width=0" }));
    try testing.expectError(error.MissingTarget, parse(null));
}

test "plan: device pixels by default, a named size stretches that axis" {
    const req: Request = .{ .target = "t", .path = "p" };
    const a = plan(400, 300, 2, req).?;
    try testing.expectEqual(@as(u32, 800), a.w);
    try testing.expectEqual(@as(u32, 600), a.h);
    try testing.expectEqual(@as(f32, 2), a.sx);
    try testing.expectEqual(@as(f32, 2), a.sy);

    var sized = req;
    sized.width = 200;
    const b = plan(400, 300, 1, sized).?;
    try testing.expectEqual(@as(u32, 200), b.w);
    try testing.expectEqual(@as(u32, 300), b.h);
    try testing.expectEqual(@as(f32, 0.5), b.sx);
    try testing.expectEqual(@as(f32, 1), b.sy);
}

test "plan: no area is no capture; scale under 1 counts as 1; clamped" {
    const req: Request = .{ .target = "t", .path = "p" };
    try testing.expectEqual(@as(?Plan, null), plan(0, 300, 1, req));
    try testing.expectEqual(@as(?Plan, null), plan(400, -1, 1, req));
    const c = plan(10, 10, 0, req).?;
    try testing.expectEqual(@as(u32, 10), c.w);
    const big = plan(9000, 10, 1, req).?;
    try testing.expectEqual(max_dimension, big.w);
}

test "successJson: win32's fields plus scope" {
    const j = try successJson(testing.allocator, .{
        .path = "/tmp/a \"b\".png",
        .width = 10,
        .height = 20,
        .bytes = 99,
        .x = 3,
        .y = 4,
        .client_width = 10,
        .client_height = 20,
        .window = true,
    });
    defer testing.allocator.free(j);
    try testing.expectEqualStrings(
        "{\"success\":true,\"data\":{\"path\":\"/tmp/a \\\"b\\\".png\",\"width\":10,\"height\":20,\"bytes\":99," ++
            "\"x\":3,\"y\":4,\"client_width\":10,\"client_height\":20,\"scope\":\"window\"}}",
        j,
    );
}
