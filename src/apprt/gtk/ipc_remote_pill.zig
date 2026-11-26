//! `remote-pill --target=<window|pane> [--op=state|click]` (T3675): the
//! DEBUG-ONLY seam the Linux acceptance test reads a window's remote
//! connection pill through and clicks it with - the headless harness has no
//! pointer. `click` emits the header-bar pill's own `clicked`; every reply is
//! the pill as drawn (visible, the name and status labels, which mark shows,
//! whether it is the red action button, its tooltip) plus the ladder state
//! `+list` reports and what the last click did.
const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const server = apprt.ipc.server;
const Request = server.Request;
const target_lookup = @import("../ipc/target_lookup.zig");
const wk = @import("webkit.zig");
const RemotePill = @import("RemotePill.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const Application = @import("class/application.zig").Application;

const c_alloc = std.heap.c_allocator;

pub fn seam(app: *Application, request: Request) Allocator.Error![]u8 {
    var op: []const u8 = "state";
    var target_arg: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) op = arg["--op=".len..];
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for remote-pill", .{});
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = switch (try IpcHandlers.resolve(arena, app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena, target_name, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "'{s}' not found in registry", .{target_name}),
    };
    const window = target.window_();
    const pill = window.remotePill() orelse return server.errorResponse(c_alloc, "remote-pill: the window has no pill", .{});

    if (std.mem.eql(u8, op, "click")) {
        // The button's own signal, as a press would emit it.
        wk.g_signal_emit_by_name(pill.button, "clicked");
    } else if (!std.mem.eql(u8, op, "state")) {
        return server.errorResponse(c_alloc, "remote-pill: unknown --op={s} (state|click)", .{op});
    }

    var out: std.Io.Writer.Allocating = .init(c_alloc);
    errdefer out.deinit();
    var j: std.json.Stringify = .{ .writer = &out.writer };
    write(&j, window, pill) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(j: *std.json.Stringify, window: anytype, pill: RemotePill.Widgets) !void {
    const visible = wk.gtk_widget_get_visible(pill.button) != 0;
    try j.beginObject();
    try j.objectField("success");
    try j.write(true);
    try j.objectField("data");
    try j.beginObject();
    try j.objectField("visible");
    try j.write(visible);
    try j.objectField("name");
    try j.write(std.mem.sliceTo(wk.gtk_label_get_text(pill.name), 0));
    try j.objectField("status");
    try j.write(if (wk.gtk_widget_get_visible(pill.status) != 0) std.mem.sliceTo(wk.gtk_label_get_text(pill.status), 0) else "");
    try j.objectField("mark");
    try j.write(if (wk.gtk_widget_get_visible(pill.dot) != 0) "dot" else if (wk.gtk_widget_get_visible(pill.glyph) != 0) "refresh" else "none");
    try j.objectField("dot_class");
    try j.write(if (wk.gtk_widget_has_css_class(pill.dot, "success") != 0)
        "success"
    else if (wk.gtk_widget_has_css_class(pill.dot, "warning") != 0)
        "warning"
    else
        "none");
    try j.objectField("action");
    try j.write(wk.gtk_widget_has_css_class(pill.button, "destructive-action") != 0);
    try j.objectField("tooltip");
    try j.write(if (wk.gtk_widget_get_tooltip_text(pill.button)) |t| std.mem.sliceTo(t, 0) else null);
    try j.objectField("last_click");
    try j.write(@tagName(RemotePill.last_click));
    try j.objectField("connection");
    if (IpcHandlers.remoteLinkOf(window)) |l| try j.write(l.listConnection()) else try j.write(null);
    try j.endObject();
    try j.endObject();
}
