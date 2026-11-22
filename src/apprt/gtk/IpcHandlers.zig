//! The GTK frontend's IPC verb handlers (T3335, Linux L6), plugged into the
//! shared dispatcher in `apprt/ipc/server.zig` exactly as win32's are. The
//! dispatcher refuses to compile a frontend that misses a verb, so every verb
//! has a handler here even before its body exists.
//!
//! Served now: `+list` (windows, tabs, the split tree, each pane's stable id,
//! name, title, cwd, shell pid and tty, plus the serving build so a caller can
//! see WHICH app answered), `+version`, `+send-keys` / `+read` (T3336), and
//! `+new-window` / `+split` / `+rename` over a pane-name registry (T3370).
//! Every other verb answers a plain "not served by the Linux app yet" error
//! naming the task that brings it, so a script learns the gap instead of
//! hanging or guessing.
//!
//! ## Names (T3370)
//!
//! Win32's rules, from `apprt/ipc/target_lookup.zig` (T2250): a window name is
//! global and unique (`+new-window --target`, else a minted `window-N`); a
//! pane name (`--name`) belongs to the window the pane is in, and a lookup
//! starts in the CALLER's window (`request.caller_pane`). The names live on
//! the GTK objects themselves (`Window.ipcName`, `Surface.ipcName`) and every
//! lookup walks the live windows, so a closed pane can never be reached
//! through a stale name - the job win32's `IpcRegistry.forget` does by hand.
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
const configpkg = @import("../../config.zig");
const server = apprt.ipc.server;
const List = apprt.ipc.List;
const Request = server.Request;
const verbs = apprt.ipc.verbs;
const verb_args = apprt.ipc.args;
const split_name_collision = apprt.ipc.split_name_collision;
const target_lookup = @import("../ipc/target_lookup.zig");

const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_ipc);

pub const Context = *Application;
pub const log_scope = .gtk_ipc;

const c_alloc = std.heap.c_allocator;

/// The `IpcServer.Handler` this frontend hands the transport.
pub fn serve(ctx: *anyopaque, request: []const u8) ?[]u8 {
    const app: *Application = @ptrCast(@alignCast(ctx));
    return server.dispatch(@This(), app, c_alloc, request) catch null;
}

// ---------------------------------------------------------------------------
// Caller scope: pane names belong to their window (T2250), so a request's
// lookups start in the window of the pane it was run from. Everything here
// runs on the one GTK main thread, so a file-level slot is the whole state.

pub const CallerScope = ?*Window;

var caller_window: ?*Window = null;

pub fn enterCallerScope(app: Context, caller_pane: ?[]const u8) CallerScope {
    const outer = caller_window;
    caller_window = callerWindow(app, caller_pane);
    return outer;
}

pub fn leaveCallerScope(_: Context, outer: CallerScope) void {
    caller_window = outer;
}

fn callerWindow(app: Context, caller_pane: ?[]const u8) ?*Window {
    const id = server.nonEmpty(caller_pane orelse return null) orelse return null;
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), id)) return p.window;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Verbs that are not served yet.

fn notYet(comptime verb: server.Verb, comptime task: []const u8) Allocator.Error!?[]u8 {
    return try server.errorResponse(
        c_alloc,
        "+{s} is not served by the Linux app yet ({s})",
        .{ verb.action(), task },
    );
}

pub fn handleClose(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.close, "T3367"); }
pub fn handleFocus(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.focus, "T3367"); }
pub fn handleRearrange(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.rearrange, "T3368"); }
pub fn handleReload(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.reload, "T3369"); }
pub fn handleSetState(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.set_state, "T3339"); }
pub fn handleSetBanner(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.set_banner, "T3339"); }
pub fn handleNewRemoteWindow(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.new_remote_window, "T3337"); }
pub fn handleHandoffQuit(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.handoff_quit, "T3337"); }
pub fn handleStash(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.stash, "T3337"); }
pub fn handleRestore(_: Context, _: Request) Allocator.Error!?[]u8 { return notYet(.restore, "T3337"); }

/// `--view` opens a viewer pane, which the Linux app does not have yet.
const view_not_yet = "--view is not served by the Linux app yet (T3338)";

// ---------------------------------------------------------------------------
// Walking the live windows and panes.

const WindowIterator = struct {
    node: ?*glib.List,

    fn next(self: *WindowIterator) ?*Window {
        while (self.node) |n| {
            self.node = n.f_next;
            const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
            if (gobject.ext.cast(Window, obj)) |w| return w;
        }
        return null;
    }
};

fn windowIterator(app: Context) WindowIterator {
    return .{ .node = app.as(gtk.Application).getWindows() };
}

const PaneAt = struct { window: *Window, surface: *Surface };

/// Every terminal pane in every window and tab, in order.
const PaneIterator = struct {
    windows: WindowIterator,
    window: ?*Window = null,
    tab: usize = 0,
    tree: ?*const Surface.Tree = null,
    leaf: usize = 0,

    fn next(self: *PaneIterator) ?PaneAt {
        while (true) {
            if (self.tree) |tree| {
                while (self.leaf < tree.nodes.len) {
                    const i = self.leaf;
                    self.leaf += 1;
                    switch (tree.nodes[i]) {
                        .leaf => |s| return .{ .window = self.window.?, .surface = s },
                        .split => {},
                    }
                }
                self.tree = null;
            }
            const window = self.window orelse {
                self.window = self.windows.next() orelse return null;
                self.tab = 0;
                continue;
            };
            const tab_view = window.getTabView();
            const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
            if (self.tab >= pages) {
                self.window = null;
                continue;
            }
            const page = tab_view.getNthPage(@intCast(self.tab));
            self.tab += 1;
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            self.tree = tab.getSplitTree().getTree() orelse continue;
            self.leaf = 0;
        }
    }
};

fn paneIterator(app: Context) PaneIterator {
    return .{ .windows = windowIterator(app) };
}

/// A window's IPC name, minting `window-N` the first time one is asked for
/// (win32 mints at creation; the name a caller sees is the same either way).
/// Null only on OOM.
var window_counter: u64 = 0;

fn windowName(app: Context, window: *Window) ?[]const u8 {
    if (window.ipcName()) |n| return n;
    var buf: [32]u8 = undefined;
    // Bounded: a pane can be named `window-N` too.
    for (0..64) |_| {
        window_counter += 1;
        const name = std.fmt.bufPrint(&buf, "window-{d}", .{window_counter}) catch return null;
        if (nameTaken(app, name)) continue;
        window.setIpcName(name);
        return window.ipcName();
    }
    return null;
}

/// Whether any window or pane already holds `name` (for minting).
fn nameTaken(app: Context, name: []const u8) bool {
    var windows = windowIterator(app);
    while (windows.next()) |w| {
        if (w.ipcName()) |n| if (std.mem.eql(u8, n, name)) return true;
    }
    var panes = paneIterator(app);
    while (panes.next()) |p| {
        if (p.surface.ipcName()) |n| if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

const Target = union(enum) {
    window: *Window,
    pane: PaneAt,

    fn window_(self: Target) *Window {
        return switch (self) {
            .window => |w| w,
            .pane => |p| p.window,
        };
    }

    /// The pane a target means: the pane, or a window's active pane.
    fn surface(self: Target) ?*Surface {
        return switch (self) {
            .window => |w| w.getActiveSurface(),
            .pane => |p| p.surface,
        };
    }
};

const Resolved = union(enum) {
    found: Target,
    /// Panes in several windows hold the name, none of them the caller's.
    ambiguous: []const []const u8,
    not_found,
};

/// What `name` means, by T2250's order: a pane id first (an id names exactly
/// one pane), then `target_lookup.pick` over the named windows and panes.
fn resolve(arena: Allocator, app: Context, name: []const u8) Allocator.Error!Resolved {
    var panes = paneIterator(app);
    while (panes.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), name)) return .{ .found = .{ .pane = p } };
    }

    var candidates: std.ArrayList(target_lookup.Candidate) = .empty;
    var targets: std.ArrayList(Target) = .empty;
    var windows = windowIterator(app);
    while (windows.next()) |w| {
        const wn = windowName(app, w) orelse continue;
        if (!std.mem.eql(u8, wn, name)) continue;
        try candidates.append(arena, .{ .kind = .window, .window_name = wn });
        try targets.append(arena, .{ .window = w });
    }
    panes = paneIterator(app);
    while (panes.next()) |p| {
        const n = p.surface.ipcName() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        try candidates.append(arena, .{
            .kind = .pane,
            .window_name = windowName(app, p.window) orelse "",
            .in_caller_window = caller_window != null and p.window == caller_window.?,
        });
        try targets.append(arena, .{ .pane = p });
    }

    return switch (try target_lookup.pick(arena, candidates.items)) {
        .found => |i| .{ .found = targets.items[i] },
        .ambiguous => |w| .{ .ambiguous = w },
        .not_found => .not_found,
    };
}

/// `resolve` with no caller window: what a GLOBAL name (a window's) means.
fn resolveGlobal(arena: Allocator, app: Context, name: []const u8) Allocator.Error!Resolved {
    const saved = caller_window;
    caller_window = null;
    defer caller_window = saved;
    return resolve(arena, app, name);
}

/// The reply for a name `resolve` did not find: the ambiguity sentence when
/// several windows hold it, else the handler's own not-found text.
fn missingResponse(
    arena: Allocator,
    resolved: Resolved,
    name: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error![]u8 {
    switch (resolved) {
        .ambiguous => |windows| {
            const msg = try target_lookup.ambiguityError(arena, name, windows);
            return try server.errorResponse(c_alloc, "{s}", .{msg});
        },
        else => return try server.errorResponse(c_alloc, fmt, args),
    }
}

/// What holds `name` where a `+split --name` into `window` would put it, for
/// `split_name_collision`: a window of that name anywhere (window names are
/// global), else a pane of that name in `window`.
fn holderIn(app: Context, name: []const u8, window: *Window) ?split_name_collision.Existing {
    var windows = windowIterator(app);
    while (windows.next()) |w| {
        const wn = windowName(app, w) orelse continue;
        if (std.mem.eql(u8, wn, name)) return .{ .kind = .window, .window_name = wn };
    }
    var panes = paneIterator(app);
    while (panes.next()) |p| {
        if (p.window != window) continue;
        const n = p.surface.ipcName() orelse continue;
        if (std.mem.eql(u8, n, name)) return .{
            .kind = .terminal,
            .window_name = windowName(app, window) orelse "",
        };
    }
    return null;
}

/// The window a default-target verb means: the active one, else the most
/// recently created (the head of GTK's window list is the most recent).
fn frontWindow(app: Context) ?*Window {
    var first: ?*Window = null;
    var windows = windowIterator(app);
    while (windows.next()) |w| {
        if (w.as(gtk.Window).isActive() != 0) return w;
        if (first == null) first = w;
    }
    return first;
}

// ---------------------------------------------------------------------------
// The pane a new window or split runs.

/// The shell `--command` runs in: `--shell`, then `command-shell`, then
/// `$SHELL`, then `/bin/sh` (the Mac's `resolveShell`, less its passwd
/// lookup: a pane without `$SHELL` is a broken login anyway).
fn resolveShell(app: Context, shell_flag: ?[]const u8) []const u8 {
    if (server.nonEmpty(shell_flag)) |s| return s;
    const config = app.getConfig();
    defer config.unref();
    if (config.get().@"command-shell") |s| if (s.len > 0) return s;
    if (std.posix.getenv("SHELL")) |s| if (s.len > 0) return s;
    return "/bin/sh";
}

/// The command a new pane runs (null: the configured shell). `-e` execs its
/// argv verbatim; `--command` runs in a login shell that stays open after it
/// (the Mac's `wrapCommandInShell`: `<sh> -lic '<cmd>; exec <sh> -li'`), so a
/// pane opened to run something is still a pane `+send-keys` can drive;
/// `--shell` alone opens that shell (T1665).
fn paneCommand(
    arena: Allocator,
    app: Context,
    e_args: []const [:0]const u8,
    command: ?[]const u8,
    shell_flag: ?[]const u8,
) Allocator.Error!?configpkg.Command {
    if (e_args.len > 0) return .{ .direct = e_args };
    if (server.nonEmpty(command)) |cmd| {
        const sh = resolveShell(app, shell_flag);
        var escaped: std.ArrayList(u8) = .empty;
        for (cmd) |ch| {
            if (ch == '\'') try escaped.appendSlice(arena, "'\\''") else try escaped.append(arena, ch);
        }
        return .{ .shell = try std.fmt.allocPrintSentinel(
            arena,
            "{s} -lic '{s}; exec {s} -li'",
            .{ sh, escaped.items, sh },
            0,
        ) };
    }
    if (server.nonEmpty(shell_flag)) |sh| {
        const argv = try arena.alloc([:0]const u8, 1);
        argv[0] = try arena.dupeZ(u8, sh);
        return .{ .direct = argv };
    }
    return null;
}

/// `--env` plus the pane/window name variables, as `KEY=VALUE` strings.
fn paneEnv(
    arena: Allocator,
    env: []const verb_args.EnvVar,
    window_name: ?[]const u8,
    pane_name: ?[]const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (env) |e| try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ e.key, e.value }));
    if (window_name) |w| try out.append(arena, try std.fmt.allocPrint(arena, "GHOZTTY_WINDOW_NAME={s}", .{w}));
    if (pane_name) |p| try out.append(arena, try std.fmt.allocPrint(arena, "GHOZTTY_PANE_NAME={s}", .{p}));
    return out.items;
}

fn workingDirectory(arena: Allocator, wd: ?[]const u8) Allocator.Error!?[:0]const u8 {
    const v = server.nonEmpty(wd) orelse return null;
    return try arena.dupeZ(u8, v);
}

fn parseSplitDirection(s: []const u8) ?Surface.Tree.Split.Direction {
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "down")) return .down;
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "up")) return .up;
    return null;
}

/// Raise and focus a target for `--focus`. Wayland only lets a compositor-
/// granted activation take focus (xdg-activation), so this is a request the
/// compositor may decline; the default (no `--focus`) never asks.
fn focusTarget(target: Target) void {
    const window = target.window_();
    if (target.surface()) |s| s.grabFocus();
    window.as(gtk.Window).present();
}

// ---------------------------------------------------------------------------
// +new-window

pub fn handleNewWindow(app: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try verb_args.parseVerbArgs(arena, request.arguments);

    if (verb_args.viewConflictsWithCommand(args))
        return try server.errorResponse(c_alloc, "{s}", .{verb_args.view_command_conflict_error});
    if (args.view != null) return try server.errorResponse(c_alloc, view_not_yet, .{});

    // `--from-focused` inherits a REMOTE parent's machine; the Linux app has
    // no remote windows yet (T3337), so it is a plain local window, dropping
    // the flags win32 drops on its local path.
    if (args.from_focused) {
        args.target = null;
        args.name = null;
        args.split_direction = null;
        args.title = null;
    }

    // Idempotent: an existing window of that name is found, not recreated,
    // and raised only with `--focus` (T1797). A pane's name is never a
    // window's (T2250).
    if (args.target) |target| {
        const held = try resolveGlobal(arena, app, target);
        switch (held) {
            .ambiguous => return try server.errorResponse(
                c_alloc,
                "'{s}' is already the name of a pane, so no window can take it. Use another --target.",
                .{target},
            ),
            .found => |entry| {
                if (entry == .pane) return try server.errorResponse(
                    c_alloc,
                    "'{s}' is already the name of a pane, so no window can take it. Use another --target.",
                    .{target},
                );
                if (args.focus) focusTarget(entry);
                if (try verb_args.droppedOnExistingTarget(arena, args)) |dropped| {
                    const note = try std.fmt.allocPrint(
                        arena,
                        "target '{s}' already exists; {s} it. Ignored: {s}. +close it first to recreate.",
                        .{ target, server.foundVerb(args.focus), dropped },
                    );
                    return try server.successResponse(c_alloc, "focused", note);
                }
                return try server.successResponse(c_alloc, "focused", null);
            },
            .not_found => {},
        }
    }

    // T968: `--name` names a PANE and is idempotent the same way.
    if (args.name) |name| if (args.target == null) {
        switch (try resolve(arena, app, name)) {
            .found => |entry| {
                if (args.focus) focusTarget(entry);
                var lost = args;
                lost.name = null;
                if (try verb_args.droppedOnExistingTarget(arena, lost)) |dropped| {
                    const note = try std.fmt.allocPrint(
                        arena,
                        "pane '{s}' already exists; {s} it. Ignored: {s}. +close it first to recreate.",
                        .{ name, server.foundVerb(args.focus), dropped },
                    );
                    return try server.successResponse(c_alloc, "focused", note);
                }
                return try server.successResponse(c_alloc, "focused", null);
            },
            else => {},
        }
    };

    // Validate the inline split before anything opens.
    const split_dir: ?Surface.Tree.Split.Direction = if (args.split_direction) |d|
        parseSplitDirection(d) orelse
            return try server.errorResponse(c_alloc, "invalid split direction: {s}", .{d})
    else
        null;

    const first_pane_name = verb_args.newWindowFirstPaneName(args);
    const window = app.newWindowForIpc(
        try paneCommand(arena, app, args.e_args, args.command, args.shell),
        try workingDirectory(arena, args.working_directory),
        try paneEnv(arena, args.env, args.target, first_pane_name orelse args.target),
    );

    if (args.target) |t| window.setIpcName(t) else _ = windowName(app, window);
    if (first_pane_name) |n| if (window.getActiveSurface()) |s| s.setIpcName(n);

    // T92: an empty `--title=` means "no pin".
    if (args.title) |title| if (title.len > 0) window.setTitleOverride(title);

    if (split_dir) |dir| {
        const tab = window.getSelectedTab() orelse
            return try server.errorResponse(c_alloc, "failed to create split", .{});
        const parent = window.getActiveSurface();
        const split_cmd = server.nonEmpty(args.split_command);
        const s = tab.getSplitTree().newSplitAt(dir, parent, .{
            .command = if (split_cmd) |cmd| try paneCommand(arena, app, &.{}, cmd, args.shell) else null,
            .env = try paneEnv(arena, &.{}, args.target, args.name),
            .at = parent,
            .focus = args.focus,
        }) catch |err| {
            log.warn("IPC inline split failed err={}", .{err});
            return try server.errorResponse(c_alloc, "failed to create split", .{});
        };
        if (args.name) |n| s.setIpcName(n);
    }

    return try server.successResponse(c_alloc, "created", null);
}

// ---------------------------------------------------------------------------
// +split

pub fn handleSplit(app: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);

    if (verb_args.viewConflictsWithCommand(args))
        return try server.errorResponse(c_alloc, "{s}", .{verb_args.view_command_conflict_error});
    if (args.view != null) return try server.errorResponse(c_alloc, view_not_yet, .{});

    // Where the split lands: --pane names the exact pane; --target a window
    // (or a pane, whose window's active pane is used); neither, the pane the
    // command was run from (T1079), else the front window's active pane.
    var window: *Window = undefined;
    var at: *Surface = undefined;
    if (args.pane) |pane_name| {
        const resolved = try resolve(arena, app, pane_name);
        const entry = switch (resolved) {
            .found => |e| e,
            else => return try missingResponse(arena, resolved, pane_name, "pane '{s}' not found", .{pane_name}),
        };
        switch (entry) {
            .pane => |p| {
                window = p.window;
                at = p.surface;
            },
            .window => return try server.errorResponse(c_alloc, "pane '{s}' not found", .{pane_name}),
        }
    } else if (args.target) |target| {
        const resolved = try resolve(arena, app, target);
        const entry = switch (resolved) {
            .found => |e| e,
            else => return try missingResponse(arena, resolved, target, "target '{s}' not found in registry", .{target}),
        };
        window = entry.window_();
        at = window.getActiveSurface() orelse
            return try server.errorResponse(c_alloc, "target '{s}' has no surface to split", .{target});
    } else if (callerAnchor(app, args)) |caller| {
        window = caller.window;
        at = caller.surface;
    } else {
        window = frontWindow(app) orelse
            return try server.errorResponse(c_alloc, "no window found for split", .{});
        at = window.getActiveSurface() orelse
            return try server.errorResponse(c_alloc, "no surface to split", .{});
    }

    // Idempotent: a --name already held in THE WINDOW THIS SPLIT LANDS IN is
    // the answer when it is what was asked for, and a failure naming what
    // holds it when not (T2184, `split_name_collision`). A pane of that name
    // in another window does not count (T2250).
    if (args.name) |name| if (!args.from_focused) {
        if (holderIn(app, name, window)) |existing| {
            switch (try split_name_collision.decide(arena, name, existing, null)) {
                .conflict => |msg| {
                    logSplit(request, args, window, null, msg);
                    return try server.errorResponse(c_alloc, "{s}", .{msg});
                },
                .reuse => |msg| {
                    logSplit(request, args, window, null, msg);
                    if (args.focus) if (namedPaneIn(window, app, name)) |p| focusTarget(.{ .pane = p });
                    return try server.messageResponse(c_alloc, msg);
                },
            }
        }
    };

    const ratio: f16 = if (args.percent) |percent| ratio: {
        if (percent < 1 or percent > 99) return try server.errorResponse(
            c_alloc,
            "percent must be between 1 and 99, got {d}",
            .{percent},
        );
        const r = @as(f16, @floatFromInt(100 - percent)) / 100.0;
        break :ratio @min(0.9, @max(0.1, r));
    } else 0.5;

    const dir_str = args.split_direction orelse "right";
    const direction = parseSplitDirection(dir_str) orelse
        return try server.errorResponse(c_alloc, "invalid direction: {s}", .{dir_str});

    const tab = tabOf(window, at) orelse
        return try server.errorResponse(c_alloc, "failed to create split", .{});

    // `--from-focused` mirrors the keyboard split (inherits everything, names
    // nothing), as win32 and the Mac do.
    const name: ?[]const u8 = if (args.from_focused) null else args.name;
    const command = args.split_command orelse args.command;
    const surface = tab.getSplitTree().newSplitAt(direction, at, .{
        .command = if (args.from_focused) null else try paneCommand(arena, app, args.e_args, command, args.shell),
        .working_directory = if (args.from_focused) null else try workingDirectory(arena, args.working_directory),
        .env = if (args.from_focused) &.{} else try paneEnv(arena, args.env, windowName(app, window), name),
        .at = at,
        .ratio = ratio,
        .focus = args.focus,
    }) catch |err| {
        log.warn("IPC split failed err={}", .{err});
        logSplit(request, args, window, null, "failed to create split");
        return try server.errorResponse(c_alloc, "failed to create split", .{});
    };

    if (name) |n| surface.setIpcName(n);
    if (args.focus) focusTarget(.{ .pane = .{ .window = window, .surface = surface } });

    const message = try verb_args.splitCreatedMessage(arena, .{
        .name = name,
        .pane_id = surface.paneId(),
        .window_name = windowName(app, window) orelse "",
    });
    logSplit(request, args, window, surface, "created");
    return try server.messageResponse(c_alloc, message);
}

/// The pane in `window` named `name`.
fn namedPaneIn(window: *Window, app: Context, name: []const u8) ?PaneAt {
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (p.window != window) continue;
        const n = p.surface.ipcName() orelse continue;
        if (std.mem.eql(u8, n, name)) return p;
    }
    return null;
}

/// The tab holding `surface` in `window`.
fn tabOf(window: *Window, surface: *Surface) ?*Tab {
    const tab_view = window.getTabView();
    const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
    for (0..pages) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const tree = tab.getSplitTree().getTree() orelse continue;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return tab;
        }
    }
    return null;
}

/// The pane a command with no explicit anchor splits off: the one it was run
/// from (`--caller-pane`, T1079), when it still exists.
fn callerAnchor(app: Context, args: verb_args.VerbArgs) ?PaneAt {
    const id = verb_args.callerAnchorPane(args, app, paneAlive) orelse return null;
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), id)) return p;
    }
    return null;
}

fn paneAlive(app: Context, id: []const u8) bool {
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), id)) return true;
    }
    return false;
}

/// Every `+split`, in the log (T2250): who asked, where it went, what came
/// of it.
fn logSplit(
    request: Request,
    args: verb_args.VerbArgs,
    window: ?*Window,
    surface: ?*Surface,
    outcome: []const u8,
) void {
    log.info("IPC +split: caller={s} window={s} pane={s} name={s} outcome={s}", .{
        request.caller_pane orelse args.caller_pane orelse "-",
        if (window) |w| w.ipcName() orelse "-" else "-",
        if (surface) |s| s.paneId() else "-",
        args.name orelse "-",
        outcome,
    });
}

// ---------------------------------------------------------------------------
// +rename

pub fn handleRename(app: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const target = args.target orelse
        return try server.errorResponse(c_alloc, "--target is required for +rename", .{});
    const title = args.title orelse
        return try server.errorResponse(c_alloc, "--title is required for +rename", .{});

    const resolved = try resolve(arena, app, target);
    const entry = switch (resolved) {
        .found => |e| e,
        else => return try missingResponse(arena, resolved, target, "target '{s}' not found in registry", .{target}),
    };

    // The pin wins over the tabs' titles until cleared; `--title=""` clears
    // it (T92). The GTK app has no user-set WINDOW title (its prompts title a
    // tab or a pane), so T2404's "the user's title outranks a script's"
    // refusal has nothing to protect here yet.
    entry.window_().setTitleOverride(title);
    return try c_alloc.dupe(u8, "{\"success\":true}");
}

// ---------------------------------------------------------------------------
// +send-keys and +read: the shared bodies in apprt/ipc/verbs.zig (T3361),
// over the model below - the same argument handling, sentences and replies
// win32 answers with. A POSIX pty takes a bare LF as a line end, so nothing
// is rewritten on the way in; that mapping is a ConPTY necessity only win32
// has.

pub fn handleSendKeys(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.sendKeys(@This(), app, request);
}

pub fn handleRead(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.read(@This(), app, request);
}

pub const Terminal = apprt.ipc.CoreTerminal;
pub const input_line_ends: verbs.LineEnds = .pty;

pub fn replyAllocator(_: Context) Allocator {
    return c_alloc;
}

/// A pane id, a pane name or a window name (its active pane). A surface
/// whose core never came up is the "never finished starting up" state.
pub fn lookupTerminal(app: Context, name: []const u8) verbs.Lookup(Terminal) {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const resolved = resolve(arena_state.allocator(), app, name) catch return .not_found;
    const entry = switch (resolved) {
        .found => |e| e,
        else => return .not_found,
    };
    const surface = entry.surface() orelse return .gone;
    const core = surface.core() orelse return .not_started;
    return .{ .ready = .{ .core = core } };
}

/// A name nothing answers to may be one several windows hold (T2250).
pub fn notFoundResponse(app: Context, name: []const u8, fallback: []const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return missingResponse(arena, try resolve(arena, app, name), name, "{s}", .{fallback});
}

// ---------------------------------------------------------------------------
// +version

/// The build's comptime identity, the same constants win32's provenance
/// reads (T3361).
const build_identity = @import("../ipc/build_identity.zig");

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
        jws.write(build_identity.version) catch break :write;
        jws.objectField("commit") catch break :write;
        jws.write(build_identity.commit) catch break :write;
        jws.objectField("mode") catch break :write;
        jws.write(build_identity.mode) catch break :write;
        jws.objectField("runtime") catch break :write;
        jws.write(build_identity.runtime) catch break :write;
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
    var it = windowIterator(app);
    while (it.next()) |window| {
        try windows.append(arena, try buildWindow(arena, app, window));
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const list: List = .{
        .windows = windows.items,
        .build = .{
            .version = build_identity.version,
            .commit = build_identity.commit,
            .mode = build_identity.mode,
            .runtime = build_identity.runtime,
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

fn buildWindow(arena: Allocator, app: Context, window: *Window) Allocator.Error!List.Window {
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

    const name: ?[]const u8 = if (windowName(app, window)) |wn| try arena.dupe(u8, wn) else null;
    return .{
        .id = try std.fmt.allocPrint(arena, "{d}", .{
            window.as(gtk.ApplicationWindow).getId(),
        }),
        .title = try arena.dupe(u8, cstr(window.as(gtk.Window).getTitle())),
        .target = name,
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
                // An unnamed pane answers to its id, the Mac's fallback.
                .name = if (surface.ipcName()) |nm| try arena.dupe(u8, nm) else id,
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
