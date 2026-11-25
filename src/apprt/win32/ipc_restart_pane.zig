//! The `restart-pane` IPC action (T3752): Restart Pane with Shell driven from
//! a test - the seam `test/win32/restart-pane.ps1` is built on.
//!
//! Debug builds only, like `workspaces`: the CLI verb list is a cross-platform
//! surface (T141) and this is instrumentation with one consumer. The user's
//! ways in are the pane context menu and the command palette; both end in
//! `pane_restart.restart`, which this calls directly (an IPC dispatch already
//! runs at the top of the message loop, so it needs no deferral).
//!
//! ```
//! {"action":"restart-pane","arguments":["--op=choices"]}
//!   -> {"success":true,"data":{"choices":[{"spec":"pwsh.exe","label":"..."}, ...]}}
//! {"action":"restart-pane","arguments":["--op=restart","--pane=<id|name>","--shell=cmd.exe"]}
//!   -> {"success":true,"data":{"outcome":"restarted","pane_id":"..."}}
//! ```
//!
//! `--mode=probe` (the default) never shows the confirm dialog: a pane with
//! something running answers `confirm_needed` and is left alone, which is how
//! the close-confirm rule is proven without a modal. `--mode=force` restarts
//! regardless.
const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const App = @import("App.zig");
const ipc_capture = @import("ipc_capture.zig");
const pane_restart = @import("pane_restart.zig");

const errorResponse = ipc_capture.errorResponse;

pub const enabled = build_config.is_debug;

pub const Op = enum { choices, restart };

pub const Request = struct {
    op: Op = .choices,
    pane: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    mode: pane_restart.Mode = .probe,
};

pub const ParseError = error{ MissingOp, BadOp, BadMode, MissingPane, MissingShell };

pub fn parse(arguments: ?[]const []const u8) ParseError!Request {
    var req: Request = .{};
    var have_op = false;
    if (arguments) |args| for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) {
            req.op = std.meta.stringToEnum(Op, arg["--op=".len..]) orelse return error.BadOp;
            have_op = true;
        } else if (std.mem.startsWith(u8, arg, "--pane=")) {
            req.pane = arg["--pane=".len..];
        } else if (std.mem.startsWith(u8, arg, "--shell=")) {
            req.shell = arg["--shell=".len..];
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            const m = std.meta.stringToEnum(pane_restart.Mode, arg["--mode=".len..]) orelse return error.BadMode;
            if (m == .ask) return error.BadMode; // a modal over a test is never wanted
            req.mode = m;
        }
    };
    if (!have_op) return error.MissingOp;
    if (req.op == .restart) {
        if (req.pane == null or req.pane.?.len == 0) return error.MissingPane;
        if (req.shell == null or req.shell.?.len == 0) return error.MissingShell;
    }
    return req;
}

pub fn handle(app: *App, alloc: Allocator, arguments: ?[]const []const u8) Allocator.Error![]u8 {
    const req = parse(arguments) catch |err| return switch (err) {
        error.MissingOp => errorResponse(alloc, "--op=choices|restart is required", .{}),
        error.BadOp => errorResponse(alloc, "--op must be choices or restart", .{}),
        error.BadMode => errorResponse(alloc, "--mode must be probe or force", .{}),
        error.MissingPane => errorResponse(alloc, "--op=restart needs --pane=<id or name>", .{}),
        error.MissingShell => errorResponse(alloc, "--op=restart needs --shell=<spec>", .{}),
    };

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };

    switch (req.op) {
        .choices => {
            const list = try pane_restart.installedChoices(arena);
            write: {
                jws.beginObject() catch break :write;
                jws.objectField("success") catch break :write;
                jws.write(true) catch break :write;
                jws.objectField("data") catch break :write;
                jws.beginObject() catch break :write;
                jws.objectField("choices") catch break :write;
                jws.write(list) catch break :write;
                jws.endObject() catch break :write;
                jws.endObject() catch break :write;
            }
        },
        .restart => {
            const target = app.ipcLookup(req.pane.?) orelse
                return errorResponse(alloc, "no pane {s}", .{req.pane.?});
            const pane = switch (target) {
                .pane => |pv| pv,
                .window => return errorResponse(alloc, "{s} is a window, not a pane", .{req.pane.?}),
            };
            const id = try arena.dupe(u8, pane.paneId());
            const outcome = pane_restart.restart(app, pane, req.shell.?, req.mode);
            write: {
                jws.beginObject() catch break :write;
                jws.objectField("success") catch break :write;
                jws.write(true) catch break :write;
                jws.objectField("data") catch break :write;
                jws.beginObject() catch break :write;
                jws.objectField("outcome") catch break :write;
                jws.write(@tagName(outcome)) catch break :write;
                jws.objectField("pane_id") catch break :write;
                jws.write(id) catch break :write;
                jws.endObject() catch break :write;
                jws.endObject() catch break :write;
            }
        },
    }
    return try out.toOwnedSlice();
}

test "parse" {
    const t = std.testing;
    try t.expectError(error.MissingOp, parse(null));
    try t.expectError(error.MissingPane, parse(&.{"--op=restart"}));
    try t.expectError(error.MissingShell, parse(&.{ "--op=restart", "--pane=p" }));
    try t.expectError(error.BadMode, parse(&.{ "--op=restart", "--pane=p", "--shell=cmd.exe", "--mode=ask" }));
    const r = try parse(&.{ "--op=restart", "--pane=p", "--shell=wsl:Ubuntu", "--mode=force" });
    try t.expectEqualStrings("wsl:Ubuntu", r.shell.?);
    try t.expectEqual(pane_restart.Mode.force, r.mode);
    const c = try parse(&.{"--op=choices"});
    try t.expectEqual(Op.choices, c.op);
    try t.expectEqual(pane_restart.Mode.probe, c.mode);
}
