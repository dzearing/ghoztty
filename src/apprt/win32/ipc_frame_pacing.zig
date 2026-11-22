//! The `frame-pacing` IPC action (T1737): read, or reset, a terminal pane's
//! frame-interval probe (`frame_pacing.zig`, recorded in
//! `Surface.markFrameShown`).
//!
//! ## Same gate, same reasons as `capture-pane`
//!
//! There is no `ghoztty +frame-pacing` CLI verb and there is not going to be
//! one: `src/cli/ghostty.zig`'s action enum is a cross-platform CLI surface
//! (the T141 rule), and this is instrumentation with one consumer - an
//! acceptance harness scoring a smoothness claim. It exists only over the IPC
//! endpoint and only where `build_config.is_debug` holds; a ReleaseFast build
//! answers `unknown action: frame-pacing` and records nothing.
//!
//! ## The wire shape
//!
//! ```
//! {"action":"frame-pacing","arguments":["--target=<pane|window|pane-id>","--reset"]}
//!   -> {"success":true,"data":{"reset":true}}
//! {"action":"frame-pacing","arguments":["--target=<pane|window|pane-id>"]}
//!   -> {"success":true,"data":{"frames":N,"intervals":N,"mean_us":N,
//!        "p50_us":N,"p95_us":N,"p99_us":N,"max_us":N,"long":N,"span_us":N,
//!        "captures":N,"histogram":{"<=4ms":N,...,">250ms":N}}}
//! ```
//!
//! A reading covers the frames since the last `--reset` (the ring holds the
//! most recent 512 intervals; `frames` counts them all). `long` is intervals
//! over twice the median. `captures` is how many hero-mode thumbnail captures
//! this pane's renderer committed over the same window - the cost T1423
//! paces, reported beside the frames it would have landed on.
const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const build_config = @import("../../build_config.zig");
const frame_pacing = @import("frame_pacing.zig");
const ipc_capture = @import("ipc_capture.zig");

const log = std.log.scoped(.win32_ipc);

const errorResponse = ipc_capture.errorResponse;

/// True when this build exposes the action at all (see module doc).
pub const enabled = build_config.is_debug and Surface.frame_pacing_enabled;

pub const Request = struct {
    target: []const u8,
    reset: bool,
};

pub const ParseError = error{MissingTarget};

/// Parse the argument vector. Pure, so the wire grammar is unit-tested
/// without an app or a pipe.
pub fn parse(arguments: ?[]const []const u8) ParseError!Request {
    var target: ?[]const u8 = null;
    var reset = false;
    if (arguments) |args| for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) {
            target = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--reset")) {
            reset = true;
        }
    };
    const t = target orelse return error.MissingTarget;
    if (t.len == 0) return error.MissingTarget;
    return .{ .target = t, .reset = reset };
}

/// Handle one `frame-pacing` request on the GUI thread.
pub fn handle(
    app: *App,
    alloc: Allocator,
    arguments: ?[]const []const u8,
) Allocator.Error![]u8 {
    const req = parse(arguments) catch
        return errorResponse(alloc, "--target is required for frame-pacing", .{});

    const entry = app.ipcLookup(req.target) orelse
        return errorResponse(alloc, "pane '{s}' not found in registry", .{req.target});
    const pane = switch (entry) {
        .pane => |p| p,
        .window => |win| if (win.tab_count == 0)
            return errorResponse(alloc, "pane '{s}' is no longer alive", .{req.target})
        else
            win.tab_active_pane[win.active_tab],
    };
    const surface = pane.surface() orelse
        return errorResponse(alloc, "{s} is a viewer pane, not a terminal", .{req.target});

    if (req.reset) {
        surface.framePacingReset();
        log.info("frame-pacing reset target={s}", .{req.target});
        return try writeJson(alloc, null);
    }
    const reading = surface.framePacingRead();
    return try writeJson(alloc, reading);
}

fn writeJson(alloc: Allocator, reading: ?Surface.FramePacingReading) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        if (reading) |r| {
            const s = r.summary;
            inline for (.{
                .{ "frames", s.frames },     .{ "intervals", s.intervals },
                .{ "mean_us", s.mean_us },   .{ "p50_us", s.p50_us },
                .{ "p95_us", s.p95_us },     .{ "p99_us", s.p99_us },
                .{ "max_us", s.max_us },     .{ "long", s.long },
                .{ "span_us", s.span_us },   .{ "captures", r.captures },
            }) |kv| {
                jws.objectField(kv[0]) catch break :write;
                jws.write(kv[1]) catch break :write;
            }
            jws.objectField("histogram") catch break :write;
            jws.beginObject() catch break :write;
            for (s.histogram, 0..) |n, i| {
                jws.objectField(frame_pacing.bucketLabel(i)) catch break :write;
                jws.write(n) catch break :write;
            }
            jws.endObject() catch break :write;
        } else {
            jws.objectField("reset") catch break :write;
            jws.write(true) catch break :write;
        }
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

test "ipc_frame_pacing: parse" {
    const r = try parse(&.{ "--target=hero", "--reset" });
    try std.testing.expectEqualStrings("hero", r.target);
    try std.testing.expect(r.reset);
    const r2 = try parse(&.{"--target=x"});
    try std.testing.expect(!r2.reset);
    try std.testing.expectError(error.MissingTarget, parse(null));
    try std.testing.expectError(error.MissingTarget, parse(&.{"--target="}));
}
