//! The GTK frontend's IPC verb handlers (T3335, Linux L6), plugged into the
//! shared dispatcher in `apprt/ipc/server.zig` exactly as win32's are. The
//! dispatcher refuses to compile a frontend that misses a verb, so every verb
//! has a handler here even before its body exists.
//!
//! Served now: `+list` (windows, tabs, the split tree, each pane's stable id,
//! title, cwd, shell pid and tty, plus the serving build so a caller can see
//! WHICH app answered), `+version`, and `+send-keys` / `+read` against a
//! pane id (T3336). Every other verb answers a plain
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
const verb_args = apprt.ipc.args;
const verb_segments = apprt.ipc.segments;
const terminal = @import("../../terminal/main.zig");

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
// Pane lookup

/// The terminal pane whose stable id (`$GHOZTTY_PANE_ID`, the `id` `+list`
/// prints) is `id`, in any window and any tab. Pane names are not registered
/// on this frontend yet, so the id is the only target a pane answers to; on
/// the Mac an unnamed pane answers to its id the same way.
fn findSurface(app: Context, id: []const u8) ?*Surface {
    var node: ?*glib.List = app.as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const window = gobject.ext.cast(Window, obj) orelse continue;
        const tab_view = window.getTabView();
        const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const tree = tab.getSplitTree().getTree() orelse continue;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.paneId(), id)) return entry.view;
            }
        }
    }
    return null;
}

fn dropPrefix(arg: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, arg, prefix)) arg[prefix.len..] else null;
}

const ok_reply = "{\"success\":true}";

// ---------------------------------------------------------------------------
// +send-keys

/// The CLI resolves all key notation (C-x, Enter, `\n` escapes) before
/// sending, so this only writes bytes - the Mac's `handleSendKeys` exactly:
/// with `--segments=` each text run is written as a paste (framed when the
/// program asked for bracketed paste) and each key run bare, so the trailing
/// `Enter` of `"msg" Enter` submits; without it the flat `--keys=` payload is
/// written raw. A POSIX pty takes a bare LF as a line end, so nothing here
/// rewrites newlines - that mapping is a conhost necessity only win32 has.
pub fn handleSendKeys(app: Context, request: Request) Allocator.Error!?[]u8 {
    var target: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var segments_value: ?[]const u8 = null;
    if (request.arguments) |arguments| for (arguments) |arg| {
        if (dropPrefix(arg, "--target=")) |v| {
            target = v;
        } else if (dropPrefix(arg, verb_segments.prefix)) |v| {
            segments_value = v;
        } else if (dropPrefix(arg, "--keys=")) |v| {
            text = v;
        }
    };
    const target_name = target orelse
        return try server.errorResponse(c_alloc, "--target is required for +send-keys", .{});
    const bytes = text orelse
        return try server.errorResponse(c_alloc, "text is required for +send-keys", .{});
    if (bytes.len == 0)
        return try server.errorResponse(c_alloc, "text is required for +send-keys", .{});

    const surface = findSurface(app, target_name) orelse
        return try server.errorResponse(c_alloc, "target '{s}' not found", .{target_name});
    const core = surface.core() orelse return try server.errorResponse(
        c_alloc,
        "target '{s}' is not writable: its terminal never finished starting up",
        .{target_name},
    );

    if (segments_value) |value| decode: {
        // A `--segments=` we cannot parse loses only the framing: the same
        // bytes are in `--keys=`, so fall through to the flat write.
        const runs = verb_segments.decode(c_alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => {
                std.log.scoped(log_scope).warn("+send-keys: ignoring malformed --segments=, sending flat", .{});
                break :decode;
            },
        };
        defer verb_segments.freeSegments(c_alloc, runs);
        if (runs.len == 0) break :decode;
        for (runs) |run| {
            const written = switch (run.kind) {
                .text => core.writePtyBracketed(run.bytes),
                .key => core.writePtyRaw(run.bytes),
            };
            written catch return try server.errorResponse(c_alloc, "failed to queue input", .{});
        }
        return try c_alloc.dupe(u8, ok_reply);
    }

    core.writePtyRaw(bytes) catch
        return try server.errorResponse(c_alloc, "failed to queue input", .{});
    return try c_alloc.dupe(u8, ok_reply);
}

// ---------------------------------------------------------------------------
// +read

/// The pane's whole screen (scrollback + active) as laid out, the last
/// `--lines=` (default 50) of it by the shared rule. A pane that has printed
/// nothing answers success with empty text, as on the Mac and win32 (T181).
pub fn handleRead(app: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const name = args.name orelse
        return try server.errorResponse(c_alloc, "--name is required for +read", .{});
    const line_count: usize = if (args.lines) |l| (if (l > 0) @intCast(l) else 50) else 50;

    const surface = findSurface(app, name) orelse
        return try server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{name});
    const core = surface.core() orelse return try server.errorResponse(
        c_alloc,
        "pane '{s}' is not readable: its terminal never finished starting up",
        .{name},
    );

    const full: ?[]const u8 = dump: {
        // This runs on the GTK main thread: take the renderer lock with
        // priority so a flooding pane cannot starve the UI (T114).
        core.renderer_state.lockPriority();
        defer core.renderer_state.unlockPriority();
        const pages = &core.io.terminal.screens.active.pages;
        const tl = pages.getTopLeft(.screen);
        const br = pages.getBottomRight(.screen) orelse break :dump null;
        const sel = terminal.Selection.init(tl, br, false);
        // `+read` reports the screen as laid out, so no reflow (main d886ba4b5).
        const t = core.dumpTextLocked(arena, sel, false) catch break :dump null;
        break :dump t.text;
    };
    const text = full orelse
        return try server.errorResponse(c_alloc, "failed to read terminal content from '{s}'", .{name});
    const result = apprt.ipc.read_tail.tail(text, line_count);

    var out: std.Io.Writer.Allocating = .init(c_alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("text") catch break :write;
        jws.write(result) catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

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
