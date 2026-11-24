//! `+new-remote-window` for the GTK apprt (T3597, Linux L8d-3): win32's
//! `ipc_remote_window.zig` over the GTK window model. Validation, the
//! refusal sentences and the relay token tiers are win32's (which byte-match
//! the Mac's `handleNewRemoteWindow`); the dial is the std-only job win32
//! already shares (`win32/ipc_remote_dial.zig`, T3022), carried off the GTK
//! thread by `IpcServer`'s deferred hop.
//!
//! The verb is three hops, and only the outer two touch the GTK thread:
//!
//!   1. GTK thread - `handle` validates the flags and resolves the relay
//!      token (every refusal it can make, it makes before any dial), then
//!      leaves a `Job` that `takeDeferred` hands the transport.
//!   2. A worker thread - `runDial` dials and records the outcome while the
//!      GTK thread keeps drawing.
//!   3. GTK thread - `finish` opens the window on the dialed connection, or
//!      answers the failure in win32's words.
//!
//! The opened window's panes ride the dial through a `RemoteLink`: its first
//! pane via `RemoteLink.pending_open`, its splits by inheriting the link from
//! the pane they split off (`SplitTree.newSplitAt`). `+new-window
//! --from-focused` on a remote window re-dials its machine (`fromFocused`).
//! The machine chooser, the connection pill and reconnects are T3563's.
const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const server = apprt.ipc.server;
const Request = server.Request;
const errorResponse = server.errorResponse;
const nonEmpty = server.nonEmpty;
const verb_args = apprt.ipc.args;

const ipc_remote_dial = @import("../win32/ipc_remote_dial.zig");
const relay_account = @import("../../remote/relay_account.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const RemoteLink = @import("RemoteLink.zig");
const RelayWindows = @import("RelayWindows.zig");
const IpcServer = @import("IpcServer.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;

const log = std.log.scoped(.gtk_ipc);

const c_alloc = std.heap.c_allocator;

pub const Job = ipc_remote_dial.Job(RemoteLink.Dialed);

/// The dial `handle` left for `takeDeferred`. One verb per dispatch, so one
/// slot. GTK thread only.
var pending: ?*Job = null;

/// Validate `+new-remote-window` and leave its dial for the transport. Direct
/// TCP with `--host=<h> --port=<p>`, or a relay with `--relay=<base>
/// --device=<id> [--token=<tok>]`, which wins when both are given (Mac rule;
/// empty values are absent). `--working-directory`/`--shell`/`--command` are
/// REMOTE-native and forwarded verbatim in the agent OPEN.
pub fn handle(app: *Application, request: Request) Allocator.Error!?[]u8 {
    _ = app;
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);

    const relay = nonEmpty(args.relay);
    const device = nonEmpty(args.device);
    const use_relay = relay != null and device != null;
    if (!use_relay) {
        if ((args.host orelse "").len == 0) return try errorResponse(
            c_alloc,
            "--host is required (or use --relay + --device) for +new-remote-window",
            .{},
        );
        if (args.port == 0) return try errorResponse(
            c_alloc,
            "--port is required (or use --relay + --device) for +new-remote-window",
            .{},
        );
    }

    const options: ipc_remote_dial.Options = .{
        .working_directory = nonEmpty(args.working_directory),
        .shell = nonEmpty(args.shell),
        .command = nonEmpty(args.command),
        .name = args.name,
        .title = args.title,
        .activate = args.focus, // T1797: background unless `--focus`
    };

    const target: ipc_remote_dial.Target = if (use_relay) target: {
        // Explicit --token, then the signed-in account, then the GUI's env.
        // A tokenless relay dial is a guaranteed 401: refuse BEFORE dialing.
        const token = nonEmpty(args.token) orelse resolveToken(arena) orelse return try errorResponse(
            c_alloc,
            "not signed in: sign in from the machine chooser (ctrl+shift+n), pass --token=, or set GHOSTTY_RELAY_TOKEN to open relay windows",
            .{},
        );
        break :target .{ .relay = .{ .base = relay.?, .device = device.?, .token = token } };
    } else .{ .tcp = .{ .host = args.host.?, .port = args.port } };

    std.debug.assert(pending == null);
    pending = try Job.create(c_alloc, target, options);
    // A placeholder: the transport answers with `finish`'s reply.
    return try c_alloc.dupe(u8, "{\"success\":true}");
}

/// `IpcServer.TakeDeferred`: the dial `handle` just left, if any.
pub fn takeDeferred(_: *anyopaque) ?IpcServer.Deferred {
    const job = pending orelse return null;
    pending = null;
    return .{
        .ud = job,
        .start = start,
        .wait = wait,
        .finish = finish,
        .release = release,
    };
}

fn jobOf(ud: *anyopaque) *Job {
    return @ptrCast(@alignCast(ud));
}

fn start(ud: *anyopaque) void {
    const job = jobOf(ud);
    const t = std.Thread.spawn(.{}, runDial, .{job}) catch |err| {
        log.warn("IPC new-remote-window: no dial worker ({}); dialing on the IPC thread", .{err});
        runDial(job);
        return;
    };
    t.detach();
}

fn wait(ud: *anyopaque, ns: u64) bool {
    jobOf(ud).done.timedWait(ns) catch return false;
    return true;
}

fn release(ud: *anyopaque) void {
    jobOf(ud).release();
}

fn finish(ctx: *anyopaque, ud: *anyopaque) ?[]u8 {
    const app: *Application = @ptrCast(@alignCast(ctx));
    return finishWindow(app, jobOf(ud)) catch null;
}

/// Worker-thread body: dial the job's target and record the outcome. Touches
/// no GTK state. Drops the worker's reference on the way out.
fn runDial(job: *Job) void {
    defer job.release();
    const a = job.alloc;
    switch (job.target) {
        .tcp => |t| {
            const d = a.create(tcp_dial.Dialed) catch return job.finish(error.OutOfMemory);
            if (tcp_dial.dial(a, t.host, t.port, .raw)) |ok| {
                d.* = ok;
                job.finish(RemoteLink.Dialed{ .tcp = d });
            } else |err| {
                a.destroy(d);
                log.warn("IPC new-remote-window: dial failed host={s} port={d} err={}", .{ t.host, t.port, err });
                job.finish(err);
            }
        },
        .relay => |r| {
            const d = a.create(relay_dial.Dialed) catch return job.finish(error.OutOfMemory);
            if (relay_dial.dial(a, r.base, r.device, r.token, .raw)) |ok| {
                d.* = ok;
                job.finish(RemoteLink.Dialed{ .relay = d });
            } else |err| {
                a.destroy(d);
                log.warn("remote window: relay dial failed relay={s} device={s} err={}", .{ r.base, r.device, err });
                job.finish(err);
            }
        },
    }
}

/// GTK-thread tail: open the window on the dialed connection, or answer the
/// failure in the words win32 and the Mac use.
fn finishWindow(app: *Application, job: *Job) Allocator.Error![]u8 {
    const dialed = job.adopt() orelse {
        var buf: [1024]u8 = undefined;
        const msg = ipc_remote_dial.failureMessage(&buf, job.target, job.outcome) catch
            "failed to reach the machine: the agent is not running or not reachable";
        return try errorResponse(c_alloc, "{s}", .{msg});
    };
    const machine: RemoteLink.Machine = switch (job.target) {
        .tcp => |t| .{ .tcp = .{ .host = t.host, .port = t.port } },
        // An explicit `--name` is the caller's label for the machine (T1736).
        .relay => |r| .{ .relay = .{
            .base = r.base,
            .device = r.device,
            .token = r.token,
            .name = nonEmpty(job.options.name),
        } },
    };
    const link = try RemoteLink.adopt(dialed, machine);
    _ = openWith(app, .{
        .link = link,
        .working_directory = job.options.working_directory,
        .shell = job.options.shell,
        .command = job.options.command,
    }, job.options.activate, .{
        // `--name` registers the window for later targeting (Mac rule).
        .ipc_name = nonEmpty(job.options.name),
        // T92: an empty `--title=` means "no pin".
        .title = nonEmpty(job.options.title),
    });
    log.info("IPC new-remote-window: opened a window on {s}", .{link.machine.displayName()});
    return try c_alloc.dupe(u8, "{\"success\":true}");
}

/// The ONE remote-window open tail (win32 `openDialedWindow`): the window's
/// first pane rides `remote.link`. A link no pane took (a window that built
/// no terminal) is closed again.
pub fn open(app: *Application, remote: RemoteLink.Open, activate: bool) *Window {
    return openWith(app, remote, activate, .{});
}

/// `open`, then the window's IPC name and pinned title, and - for a relay
/// window - its entry in the relaunch record (T3671, `RelayWindows.record`),
/// after the name and title so the entry carries both. A window whose first
/// pane did not take the link records nothing.
pub fn openWith(app: *Application, remote: RemoteLink.Open, activate: bool, r: RelayWindows.Record) *Window {
    RemoteLink.pending_open = remote;
    const window = app.newWindowForIpc(null, null, &.{}, null, activate);
    RemoteLink.pending_open = null;
    if (remote.link.refs == 0) {
        log.warn("remote window: its first pane did not take the link; closing it", .{});
        remote.link.retire();
        return window;
    }
    if (r.ipc_name) |n| window.setIpcName(n);
    if (r.title) |t| window.setTitleOverride(t);
    RelayWindows.record(window, remote.link, r);
    return window;
}

/// `+new-window --from-focused` on a window riding `parent` (T68, Mac
/// `newWindowInheritingRemote`): re-dial the same machine, inheriting the
/// active pane's command and REMOTE cwd unless the flags name their own.
/// Dials on the GTK thread, as win32's `openRemoteWindowFrom` does.
pub fn fromFocused(
    app: *Application,
    arena: Allocator,
    parent: *RemoteLink.Link,
    inherited: struct { command: ?[]const u8 = null, working_directory: ?[]const u8 = null },
    args: verb_args.VerbArgs,
) Allocator.Error![]u8 {
    var machine = parent.machine;
    if (machine == .relay) {
        // The store's renewable bearer first, then the one the parent was
        // dialed with (a `--token` window leaves the store empty, T1277).
        if (resolveToken(arena)) |tok| machine.relay.token = tok;
    }
    const dialed = RemoteLink.dial(machine) catch |err| {
        log.warn("new window remote inherit: dial to {s} failed err={}", .{ machine.displayName(), err });
        return switch (ipc_remote_dial.outcomeFor(err)) {
            .incompatible => try errorResponse(
                c_alloc,
                "incompatible Ghoztty version on the focused window's remote machine: update one side",
                .{},
            ),
            else => try errorResponse(
                c_alloc,
                "failed to reach the focused window's remote machine: the agent is not running or not reachable",
                .{},
            ),
        };
    };
    const link = try RemoteLink.adopt(dialed, machine);
    _ = open(app, .{
        .link = link,
        .working_directory = nonEmpty(args.working_directory) orelse inherited.working_directory,
        .shell = nonEmpty(args.shell),
        .command = nonEmpty(args.command) orelse inherited.command,
    }, args.focus);
    return try server.successResponse(c_alloc, "created", null);
}

/// Relay token resolution after an explicit `--token`: the signed-in account
/// (its relay session token, renewed as needed - T3341's store), then this
/// process's `GHOSTTY_RELAY_TOKEN`. Null: no credential. On `arena`. Also the
/// relaunch restore's credential (`RelayWindows.settle`, off the GTK thread:
/// it touches only the account store and the environment).
pub fn resolveToken(arena: Allocator) ?[]const u8 {
    return resolveAccountToken(arena) orelse resolveEnvToken(arena);
}

fn resolveAccountToken(arena: Allocator) ?[]const u8 {
    const path = relay_account.accountPath(arena) catch return null;
    if (!relay_account.isSignedIn(arena, path)) return null;
    return relay_account.resolveSessionToken(arena, path) catch |err| {
        log.warn("IPC new-remote-window: account session renew failed err={}", .{err});
        return null;
    };
}

fn resolveEnvToken(arena: Allocator) ?[]const u8 {
    const tok = std.process.getEnvVarOwned(arena, "GHOSTTY_RELAY_TOKEN") catch return null;
    return nonEmpty(tok);
}
