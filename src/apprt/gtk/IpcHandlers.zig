//! The GTK frontend's IPC verb handlers (T3335, Linux L6), plugged into the
//! shared dispatcher in `apprt/ipc/server.zig` exactly as win32's are. The
//! dispatcher refuses to compile a frontend that misses a verb, so every verb
//! has a handler here even before its body exists.
//!
//! Served now: `+list` (windows, tabs, the split tree, each pane's stable id,
//! title, cwd, shell pid and tty, plus the serving build so a caller can see
//! WHICH app answered) and `+version`. Every other verb answers a plain
//! "not served by the Linux app yet" error naming the task that brings it
//! (T3336), so a script learns the gap instead of hanging or guessing.
//!
//! Runs on the GTK main thread (`IpcServer` marshals every request there).
//! Replies are allocated with `std.heap.c_allocator`, which the transport
//! frees.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../apprt.zig");
const build_config = @import("../../build_config.zig");
const server = apprt.ipc.server;
const List = apprt.ipc.List;
const Request = server.Request;

const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;

pub const Context = *Application;
pub const CallerScope = void;
pub const log_scope = .gtk_ipc;

/// The task that brings the verbs this frontend does not serve yet.
pub const pending_task = "T3336";

const c_alloc = std.heap.c_allocator;

/// The `IpcServer.Handler` this frontend hands the transport.
pub fn serve(ctx: *anyopaque, request: []const u8) ?[]u8 {
    const app: *Application = @ptrCast(@alignCast(ctx));
    return server.dispatch(@This(), app, c_alloc, request) catch null;
}

// Pane names are not registered on this frontend yet (T3336), so there is
// no caller window to scope lookups to.
pub fn enterCallerScope(_: Context, _: ?[]const u8) void {}
pub fn leaveCallerScope(_: Context, _: void) void {}

fn notYet(comptime verb: server.Verb) Allocator.Error!?[]u8 {
    return try server.errorResponse(
        c_alloc,
        "+{s} is not served by the Linux app yet ({s})",
        .{ verb.action(), pending_task },
    );
}

pub fn handleNewWindow(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.new_window); }
pub fn handleClose(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.close); }
pub fn handleSplit(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.split); }
pub fn handleRename(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.rename); }
pub fn handleSendKeys(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.send_keys); }
pub fn handleRead(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.read); }
pub fn handleSetState(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.set_state); }
pub fn handleRearrange(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.rearrange); }
pub fn handleNewRemoteWindow(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.new_remote_window); }
pub fn handleHandoffQuit(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.handoff_quit); }
pub fn handleSetBanner(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.set_banner); }
pub fn handleReload(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.reload); }
pub fn handleFocus(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.focus); }
pub fn handleStash(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.stash); }
pub fn handleRestore(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.restore); }

// ---------------------------------------------------------------------------
// +version

const mode: []const u8 = mode: {
    const m = build_config.mode_string;
    break :mode if (m.len > 0 and m[0] == '.') m[1..] else m;
};

fn selfExe(buf: []u8) []const u8 {
    return std.fs.selfExePath(buf) catch "";
}

pub fn handleVersion(_: Context, _: Request) Allocator.Error!?[]u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = selfExe(&exe_buf);

    var out: std.Io.Writer.Allocating = .init(c_alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("version") catch break :write;
        jws.write(build_config.version_string) catch break :write;
        jws.objectField("commit") catch break :write;
        jws.write(build_config.version.build orelse "unknown") catch break :write;
        jws.objectField("mode") catch break :write;
        jws.write(mode) catch break :write;
        jws.objectField("runtime") catch break :write;
        jws.write(@tagName(build_config.app_runtime)) catch break :write;
        jws.objectField("update_check") catch break :write;
        jws.write(false) catch break :write;
        jws.objectField("exe") catch break :write;
        jws.write(exe) catch break :write;
        jws.objectField("pid") catch break :write;
        jws.write(@as(i64, std.c.getpid())) catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// +list

pub fn handleList(app: Context, request: Request) Allocator.Error!?[]u8 {
    // `--pid` is the Windows spelling of "which pane is this process in";
    // Linux has real ttys and the CLI answers `--tty` from the tree below.
    if (request.arguments) |argv| for (argv) |a| {
        if (std.mem.startsWith(u8, a, "--pid")) return try server.errorResponse(
            c_alloc,
            "--pid is the Windows form; on Linux use --tty=$(tty), or $GHOZTTY_PANE_ID names the pane directly",
            .{},
        );
    };

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var windows: std.ArrayList(List.Window) = .empty;
    var node: ?*glib.List = app.as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const widget: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const window = gobject.ext.cast(Window, widget) orelse continue;
        try windows.append(arena, try buildWindow(arena, window));
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const list: List = .{
        .windows = windows.items,
        .build = .{
            .version = build_config.version_string,
            .commit = build_config.version.build orelse "unknown",
            .mode = mode,
            .runtime = @tagName(build_config.app_runtime),
            .exe = try arena.dupe(u8, selfExe(&exe_buf)),
            .exe_modified = "",
            .pid = std.c.getpid(),
        },
    };
    return try list.serializeResponse(c_alloc);
}

fn cstr(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "";
}

fn buildWindow(arena: Allocator, window: *Window) Allocator.Error!List.Window {
    const tab_view = window.getTabView();
    const selected = tab_view.getSelectedPage();
    const n: usize = @intCast(@max(tab_view.getNPages(), 0));

    const tabs = try arena.alloc(List.Tab, n);
    for (tabs, 0..) |*t, i| {
        const page = tab_view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild());
        const active: ?*Surface = if (tab) |tb| tb.getActiveSurface() else null;
        const splits: *const List.Node = if (tab) |tb| splits: {
            if (tb.getSplitTree().getTree()) |tree| break :splits try buildNode(arena, tree, .root, active);
            break :splits try emptyNode(arena);
        } else try emptyNode(arena);
        t.* = .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{i}),
            .title = try arena.dupe(u8, cstr(page.getTitle())),
            .index = @intCast(i),
            .selected = selected == page,
            .splits = splits,
        };
    }

    return .{
        .id = try std.fmt.allocPrint(arena, "{d}", .{
            window.as(gtk.ApplicationWindow).getId(),
        }),
        .title = try arena.dupe(u8, cstr(window.as(gtk.Window).getTitle())),
        .target = null,
        .focused = window.as(gtk.Window).isActive() != 0,
        .tabs = tabs,
    };
}

fn emptyNode(arena: Allocator) Allocator.Error!*const List.Node {
    const node = try arena.create(List.Node);
    node.* = .{ .leaf = List.empty_terminal };
    return node;
}

fn buildNode(
    arena: Allocator,
    tree: *const Surface.Tree,
    handle: Surface.Tree.Node.Handle,
    active: ?*Surface,
) Allocator.Error!*const List.Node {
    if (tree.isEmpty()) return emptyNode(arena);
    const node = try arena.create(List.Node);
    switch (tree.nodes[handle.idx()]) {
        .leaf => |surface| {
            const id = try arena.dupe(u8, surface.paneId());
            const shell = surface.shellInfo();
            node.* = .{ .leaf = .{
                .id = id,
                .title = try arena.dupe(u8, surface.getTitle() orelse ""),
                .working_directory = try arena.dupe(u8, surface.getPwd() orelse ""),
                .pid = shell.pid,
                .tty = try arena.dupe(u8, shell.tty),
                // No pane-name registry on this frontend yet (T3336): the
                // id is the name, the Mac's fallback.
                .name = id,
                .focused = surface == active,
                .exit_code = null,
            } };
        },
        .split => |split| node.* = .{ .split = .{
            .direction = switch (split.layout) {
                .horizontal => "horizontal",
                .vertical => "vertical",
            },
            .ratio = @floatCast(split.ratio),
            .left = try buildNode(arena, tree, split.left, active),
            .right = try buildNode(arena, tree, split.right, active),
        } },
    }
    return node;
}

comptime {
    server.checkFrontend(@This());
}
