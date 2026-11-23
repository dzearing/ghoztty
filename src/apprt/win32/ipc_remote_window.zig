//! `+new-remote-window` for the win32 apprt (T1782, split from
//! IpcHandlers.zig): argument validation, relay token resolution, and the
//! dial job the IPC listener runs off the GUI thread (T3022).
const std = @import("std");
const Allocator = std.mem.Allocator;

const IpcHandlers = @import("IpcHandlers.zig");
const Context = IpcHandlers.Context;
const apprt = @import("../../apprt.zig");
const ipc_server = apprt.ipc.server;
const Request = ipc_server.Request;
const errorResponse = ipc_server.errorResponse;
const nonEmpty = ipc_server.nonEmpty;
const verb_args = apprt.ipc.args;
const parseVerbArgs = verb_args.parseVerbArgs;

const App = @import("App.zig");
const Window = @import("Window.zig");
const ipc_remote_dial = @import("ipc_remote_dial.zig");
const relay_account = @import("../../remote/relay_account.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");

const log = std.log.scoped(.win32_ipc);

/// Open a remote-machine window, dialing the agent at `--host=<h> --port=<p>`
/// over TCP (T20 / Phase G) or through a rendezvous relay at
/// `--relay=<base> --device=<id> [--token=<tok>]` (T21b). Semantics mirror
/// the Mac server's handleNewRemoteWindow: validation error strings
/// byte-match; the relay path takes precedence when both are present;
/// `--name` registers the window for later targeting.
///
/// The DIAL does not run here (T3022). This handler validates and resolves the
/// token — every refusal it can make, it makes before any dial, as before — and
/// leaves a `RemoteDialJob` in `app.ipc_remote_dial`. The IPC listener dials it
/// on a worker while the GUI thread keeps pumping, then hands it back to
/// `finishRemoteWindow`, which opens the window and writes the reply. A dial to
/// a black-holed host used to freeze every window for the OS connect timeout
/// plus the 10 s HELLO deadline.
///
/// Relay token tiers (T21a/T21b/T93): explicit `--token` wins (the CLI
/// already forwards its own GHOSTTY_RELAY_TOKEN env as `--token`), then the
/// signed-in account (its relay session token, renewed as needed — Mac
/// `RelayAccount.resolveToken()` parity), then this GUI process's
/// GHOSTTY_RELAY_TOKEN.
///
/// `--working-directory`/`--shell`/`--command` are REMOTE-native values
/// forwarded verbatim in the agent OPEN (empty ⇒ absent, like the Mac);
/// they are never wrapped by the local shell table — the agent applies its
/// own shell's convention.
pub fn handleNewRemoteWindow(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);

    // Relay path: --relay + --device dial through a rendezvous relay. Takes
    // precedence over the direct host:port path when both are present (Mac
    // rule; empty values are absent).
    const relay = nonEmpty(args.relay);
    const device = nonEmpty(args.device);
    const use_relay = relay != null and device != null;
    if (!use_relay) {
        const host = args.host orelse "";
        if (host.len == 0) {
            return try errorResponse(
                ctx.alloc,
                "--host is required (or use --relay + --device) for +new-remote-window",
                .{},
            );
        }
        if (args.port == 0) {
            return try errorResponse(
                ctx.alloc,
                "--port is required (or use --relay + --device) for +new-remote-window",
                .{},
            );
        }
    }

    // Empty string => absent (the Mac treats `--shell=` as nil so an empty
    // value can never forward "").
    const options: ipc_remote_dial.Options = .{
        .working_directory = nonEmpty(args.working_directory),
        .shell = nonEmpty(args.shell),
        .command = nonEmpty(args.command),
        .name = args.name,
        .title = args.title,
        .activate = args.focus, // T1797: background unless `--focus`
    };

    const target: ipc_remote_dial.Target = if (use_relay) target: {
        // Token tiers: explicit --token, then the signed-in account (relay
        // session token), then the GUI's env. A tokenless relay dial is a
        // guaranteed 401 — refuse BEFORE dialing (Mac rule).
        const token = nonEmpty(args.token) orelse resolveAccountToken(arena) orelse resolveEnvToken(arena) orelse {
            return try errorResponse(
                ctx.alloc,
                "not signed in: sign in from the machine chooser (ctrl+shift+n), pass --token=, or set GHOSTTY_RELAY_TOKEN to open relay windows",
                .{},
            );
        };
        break :target .{ .relay = .{ .base = relay.?, .device = device.?, .token = token } };
    } else .{ .tcp = .{ .host = args.host.?, .port = args.port } };

    // Hand the dial to the listener (T3022). A handler that already left a job
    // (it cannot: one verb per dispatch) would leak it, so the slot is checked.
    std.debug.assert(app.ipc_remote_dial == null);
    app.ipc_remote_dial = try RemoteDialJob.create(app.core_app.alloc, target, options);

    // A placeholder: the listener answers with `finishRemoteWindow`'s reply.
    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

/// The dial job `+new-remote-window` leaves for the IPC listener (T3022).
pub const RemoteDialJob = ipc_remote_dial.Job(Window.RemoteDialed);

/// Worker-thread body: dial `job`'s target and record the outcome. Touches no
/// GUI state — the same dials `MachineConnectionPool.dialWorker` runs off the
/// GUI thread. Drops the worker's reference on the way out.
pub fn runRemoteDial(job: *RemoteDialJob) void {
    defer job.release();
    const alloc = job.alloc;
    switch (job.target) {
        .tcp => |t| {
            const d = alloc.create(tcp_dial.Dialed) catch return job.finish(error.OutOfMemory);
            if (tcp_dial.dial(alloc, t.host, t.port, .raw)) |ok| {
                d.* = ok;
                job.finish(Window.RemoteDialed{ .tcp = d });
            } else |err| {
                alloc.destroy(d);
                log.warn(
                    "IPC new-remote-window: dial failed host={s} port={d} err={}",
                    .{ t.host, t.port, err },
                );
                job.finish(err);
            }
        },
        .relay => |r| {
            const d = alloc.create(relay_dial.Dialed) catch return job.finish(error.OutOfMemory);
            if (relay_dial.dial(alloc, r.base, r.device, r.token, .raw)) |ok| {
                d.* = ok;
                job.finish(Window.RemoteDialed{ .relay = d });
            } else |err| {
                alloc.destroy(d);
                log.warn(
                    "remote window: relay dial failed relay={s} device={s} err={}",
                    .{ r.base, r.device, err },
                );
                job.finish(err);
            }
        },
    }
}

/// GUI-thread tail of `+new-remote-window` (T3022): open the window on the
/// connection the worker dialed, or answer the failure in the same words the
/// handler always used. Called once the job's dial is done. Does not release
/// the job; the listener does.
pub fn finishRemoteWindow(ctx: Context, job: *RemoteDialJob) Allocator.Error![]u8 {
    const app = ctx.app;
    const dialed = job.adopt() orelse {
        var buf: [1024]u8 = undefined;
        const msg = ipc_remote_dial.failureMessage(&buf, job.target, job.outcome) catch
            "failed to reach the machine: the agent is not running or not reachable";
        return try errorResponse(ctx.alloc, "{s}", .{msg});
    };
    var opts: App.RemoteOpenOptions = .{
        .working_directory = job.options.working_directory,
        .shell = job.options.shell,
        .command = job.options.command,
        .ipc_name = job.options.name,
        .title = job.options.title,
        .activate = job.options.activate,
    };
    opts.machine = switch (job.target) {
        .tcp => |t| .{ .tcp = .{ .host = t.host, .port = t.port } },
        // An explicit `--name=` is the caller's label for the machine (T1736,
        // Mac IPCServer `namePinned: name != nil`): the pill says it, and a
        // directory listing never renames it. Without one the window resolves
        // the directory/HELLO name as before.
        .relay => |r| .{ .relay = .{
            .base = r.base,
            .device = r.device,
            .token = r.token,
            .name = nonEmpty(job.options.name),
            .name_pinned = nonEmpty(job.options.name) != null,
        } },
    };
    _ = app.openDialedWindow(dialed, opts) catch |err| switch (err) {
        error.CreateFailed => return try errorResponse(ctx.alloc, "failed to create window", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}

/// The account tier of relay token resolution (T21a; brokered per T93): if an
/// account is signed in (`account.dat` exists), return its relay session
/// token — renewed (and rotated) at the stored relay when it nears expiry. A
/// missing account, a legacy pre-T93 store, or a refused renewal returns null
/// so resolution falls through to the env token (graceful — Mac
/// `resolveToken` behavior). Allocated on `arena`.
pub fn resolveAccountToken(arena: Allocator) ?[]const u8 {
    const path = relay_account.accountPath(arena) catch return null;
    if (!relay_account.isSignedIn(arena, path)) return null;

    return relay_account.resolveSessionToken(arena, path) catch |err| {
        switch (err) {
            error.Legacy => log.warn(
                "account store predates the brokered sign-in — sign in once from the machine chooser (ctrl+shift+n) to migrate",
                .{},
            ),
            else => log.warn("IPC new-remote-window: account session renew failed err={}", .{err}),
        }
        return null;
    };
}

/// The env tier of relay token resolution: `GHOSTTY_RELAY_TOKEN` (empty ⇒
/// null). Allocated on `arena`.
pub fn resolveEnvToken(arena: Allocator) ?[]const u8 {
    const tok = std.process.getEnvVarOwned(arena, "GHOSTTY_RELAY_TOKEN") catch return null;
    return nonEmpty(tok);
}

/// Combined relay bearer-token resolution shared by the `+new-remote-window`
/// verb and the machine chooser (T22c): the signed-in account first (its
/// relay session token, renewed as needed), then `GHOSTTY_RELAY_TOKEN`.
/// Null ⇒ no credential — the chooser shows an empty list + a sign-in hint,
/// never an error. (`--token` is a per-call override the IPC verb applies
/// ahead of this.) Allocated on `arena`.
pub fn resolveToken(arena: Allocator) ?[]const u8 {
    return resolveAccountToken(arena) orelse resolveEnvToken(arena);
}
