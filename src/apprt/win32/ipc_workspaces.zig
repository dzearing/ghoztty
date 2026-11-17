//! The `workspaces` IPC action (T3191): read single-window mode's workspace
//! bookkeeping and put a workspace on show - the seam
//! `test/win32/single-window-mode.ps1` section B is built on.
//!
//! Debug builds only, like `settings`: the CLI verb list is a cross-platform
//! surface (T141) and this is instrumentation with one consumer. Which
//! controller holds the one shared HWND, and which are parked with none, is a
//! model no screenshot can check - the seam reports it from the same host
//! (`App.workspaces`) every hand-off asks. Until the sidebar switch lands
//! (T3182), `--op=show` is also the only way to drive a hand-off by hand.
//!
//! ```
//! {"action":"workspaces","arguments":["--op=state"]}
//! {"action":"workspaces","arguments":["--op=show","--target=window-2"]}
//!   -> {"success":true,"data":{"mode":"single","active":"window-1",
//!        "shown":true,"windows_with_hwnd":1,
//!        "workspaces":[{"name":"window-1","parked":false,"hwnd":1234,
//!                       "tabs":1,"panes":1}, ...]}}
//! ```
const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const ipc_capture = @import("ipc_capture.zig");
const window_mode = @import("window_mode.zig");

const errorResponse = ipc_capture.errorResponse;

pub const enabled = build_config.is_debug;

pub const Op = enum { state, show };

pub const Request = struct {
    op: Op,
    target: ?[]const u8 = null,
};

pub const ParseError = error{ MissingOp, BadOp, MissingTarget };

pub fn parse(arguments: ?[]const []const u8) ParseError!Request {
    var req: Request = .{ .op = .state };
    var have_op = false;
    if (arguments) |args| for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) {
            req.op = std.meta.stringToEnum(Op, arg["--op=".len..]) orelse return error.BadOp;
            have_op = true;
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            req.target = arg["--target=".len..];
        }
    };
    if (!have_op) return error.MissingOp;
    if (req.op == .show and (req.target == null or req.target.?.len == 0)) return error.MissingTarget;
    return req;
}

fn byName(app: *App, name: []const u8) ?*Window {
    for (app.windows.items) |w| {
        const n = w.ipc_name orelse continue;
        if (std.mem.eql(u8, n, name)) return w;
    }
    return null;
}

pub fn handle(app: *App, alloc: Allocator, arguments: ?[]const []const u8) Allocator.Error![]u8 {
    const req = parse(arguments) catch |err| return switch (err) {
        error.MissingOp => errorResponse(alloc, "--op=state|show is required", .{}),
        error.BadOp => errorResponse(alloc, "--op must be state or show", .{}),
        error.MissingTarget => errorResponse(alloc, "--op=show needs --target=<window name>", .{}),
    };
    var shown: ?bool = null;
    if (req.op == .show) {
        const w = byName(app, req.target.?) orelse
            return errorResponse(alloc, "no window named {s}", .{req.target.?});
        shown = app.showWorkspace(w);
    }
    return stateResponse(app, alloc, shown);
}

fn paneCount(w: *Window) usize {
    var n: usize = 0;
    for (0..w.tab_count) |t| n += w.leafCount(t);
    return n;
}

fn stateResponse(app: *App, alloc: Allocator, shown: ?bool) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("mode") catch break :write;
        jws.write(@tagName(window_mode.current())) catch break :write;
        jws.objectField("active") catch break :write;
        jws.write(if (app.workspaces.active) |a| a.ipc_name else null) catch break :write;
        if (shown) |s| {
            jws.objectField("shown") catch break :write;
            jws.write(s) catch break :write;
        }
        var with_hwnd: usize = 0;
        for (app.windows.items) |w| {
            if (w.hwnd != null) with_hwnd += 1;
        }
        jws.objectField("windows_with_hwnd") catch break :write;
        jws.write(with_hwnd) catch break :write;
        jws.objectField("workspaces") catch break :write;
        jws.beginArray() catch break :write;
        // The host's order: on show first, then most recently shown.
        for (app.workspaces.order.items) |w| {
            jws.beginObject() catch break :write;
            jws.objectField("name") catch break :write;
            jws.write(w.ipc_name) catch break :write;
            jws.objectField("parked") catch break :write;
            jws.write(app.workspaces.isParked(w)) catch break :write;
            jws.objectField("hwnd") catch break :write;
            jws.write(if (w.hwnd) |h| @intFromPtr(h) else 0) catch break :write;
            jws.objectField("tabs") catch break :write;
            jws.write(w.tab_count) catch break :write;
            jws.objectField("panes") catch break :write;
            jws.write(paneCount(w)) catch break :write;
            jws.endObject() catch break :write;
        }
        jws.endArray() catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
    }
    return try out.toOwnedSlice();
}

test "ipc_workspaces: parse ops and refusals" {
    const t = std.testing;
    try t.expectError(error.MissingOp, parse(null));
    try t.expectError(error.BadOp, parse(&.{"--op=explode"}));
    try t.expectError(error.MissingTarget, parse(&.{"--op=show"}));
    try t.expectError(error.MissingTarget, parse(&.{ "--op=show", "--target=" }));
    try t.expectEqual(Op.state, (try parse(&.{"--op=state"})).op);
    const r = try parse(&.{ "--op=show", "--target=window-2" });
    try t.expectEqual(Op.show, r.op);
    try t.expectEqualStrings("window-2", r.target.?);
}
