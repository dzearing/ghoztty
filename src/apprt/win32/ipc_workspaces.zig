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
//!        "shown":true,"windows_with_hwnd":1,"activity":"idle",
//!        "workspaces":[{"name":"window-1","parked":false,"hwnd":1234,
//!                       "tabs":1,"tab_bar":false,"panes":1,"activity":"idle",
//!                       "presenting":1,"holding_targets":1,
//!                       "overlays_shown":0}, ...]}}
//! ```
//!
//! `presenting` / `holding_targets` / `overlays_shown` (T3192) say what the
//! workspace draws: a parked one reports 0 for all three.
//!
//! `closed_for_undo` (T3200) counts closed workspaces still waiting out
//! their undo: they are out of `workspaces`, and an undo puts one on show.
//!
//! `popups_misowned` (T3202) counts pane popups owned by a top-level window
//! the pane is not in: 0 always, or a window closing would destroy them.
//!
//! `desk_seed` / `desk_fade` (T3183) are the workspace's gradient and its
//! shade crossfade: `on`, `from_seed`, `started`, `frames`, `last_keep`
//! (the old desk's strength, 255..0) and `desks` (desks rendered with the
//! fade laid on - the pixels' own count, not the clock's).
//!
//! `cols` / `rows` (T3193) are the grid of the active tab's first terminal
//! pane (0 when it has none yet): a parked workspace is laid out at the
//! shared window's size, so it reads the grid it will have on show.
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

/// What a workspace is drawing (T3192): panes presenting, terminal panes
/// still holding render targets, and pane popups on screen - all three zero
/// for a parked one ("Parked counts as hidden").
/// `popups_misowned` (T3202): pane popups owned by a top-level the pane is
/// not in - zero unless a re-parent forgot to hand them over.
const Drawing = struct { presenting: usize = 0, holding_targets: usize = 0, overlays_shown: usize = 0, popups_misowned: usize = 0 };

fn drawing(w: *Window) Drawing {
    var d: Drawing = .{};
    for (0..w.tab_count) |t| {
        var it = w.tab_trees[t].iterator();
        while (it.next()) |entry| {
            if (entry.view.presenting()) d.presenting += 1;
            if (!entry.view.targetsReleased()) d.holding_targets += 1;
            d.overlays_shown += entry.view.overlaysShown();
            d.popups_misowned += entry.view.popupsMisowned();
        }
    }
    return d;
}

/// The grid of the active tab's first terminal pane (T3193), 0x0 when there
/// is none or its core is not up yet.
fn firstGrid(w: *Window) struct { cols: usize = 0, rows: usize = 0 } {
    if (w.tab_count == 0) return .{};
    var it = w.tab_trees[w.active_tab].iterator();
    while (it.next()) |entry| {
        const s = entry.view.surface() orelse continue;
        if (!s.core_surface_ready) return .{};
        const g = s.core_surface.size.grid();
        return .{ .cols = g.columns, .rows = g.rows };
    }
    return .{};
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
        // Closed workspaces waiting out their undo (T3200): out of the list
        // below, their panes hidden under the park host, still running.
        jws.objectField("closed_for_undo") catch break :write;
        jws.write(app.close_undo.closedWorkspaceCount()) catch break :write;
        // The shared window's activity: the most urgent of every
        // workspace's (T3186, `App.refreshWindowActivity`).
        jws.objectField("activity") catch break :write;
        jws.write(@tagName(app.window_activity)) catch break :write;
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
            // Whether its tab strip is showing (T3182: never, for a workspace).
            jws.objectField("tab_bar") catch break :write;
            jws.write(w.tab_bar_visible) catch break :write;
            jws.objectField("panes") catch break :write;
            jws.write(paneCount(w)) catch break :write;
            // Its own activity, which never pauses while parked (T3186).
            jws.objectField("activity") catch break :write;
            jws.write(@tagName(w.activityAggregate())) catch break :write;
            const d = drawing(w);
            jws.objectField("presenting") catch break :write;
            jws.write(d.presenting) catch break :write;
            jws.objectField("holding_targets") catch break :write;
            jws.write(d.holding_targets) catch break :write;
            jws.objectField("overlays_shown") catch break :write;
            jws.write(d.overlays_shown) catch break :write;
            jws.objectField("popups_misowned") catch break :write;
            jws.write(d.popups_misowned) catch break :write;
            const g = firstGrid(w);
            jws.objectField("cols") catch break :write;
            jws.write(g.cols) catch break :write;
            jws.objectField("rows") catch break :write;
            jws.write(g.rows) catch break :write;
            // The shade crossfade (T3183): this workspace's gradient (0: the
            // ocean), whether a fade is running and from what, how many it
            // has started, its frames, the old desk's strength on the last
            // one, and the desks rendered with a fade laid on.
            jws.objectField("desk_seed") catch break :write;
            jws.write(if (w.desk_variant) |v| v.seed else 0) catch break :write;
            jws.objectField("desk_fade") catch break :write;
            jws.beginObject() catch break :write;
            jws.objectField("on") catch break :write;
            jws.write(w.desk_fade_from != null) catch break :write;
            jws.objectField("from_seed") catch break :write;
            jws.write(if (w.desk_fade_from) |f| (if (f) |v| v.seed else 0) else 0) catch break :write;
            jws.objectField("started") catch break :write;
            jws.write(w.desk_fades_started) catch break :write;
            jws.objectField("frames") catch break :write;
            jws.write(w.desk_fade_frames) catch break :write;
            jws.objectField("last_keep") catch break :write;
            jws.write(w.desk_fade_last_keep) catch break :write;
            jws.objectField("desks") catch break :write;
            jws.write(w.pane_desk.fade_desks) catch break :write;
            jws.endObject() catch break :write;
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
