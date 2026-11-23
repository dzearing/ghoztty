//! Build identity over IPC for the win32 apprt (T1782, split from
//! IpcHandlers.zig): `version`, the `handoff-quit` half of the switch-builds
//! handshake (T1070), and the note a launch handoff from a different build
//! earns (T1022).
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

const build_config = @import("../../build_config.zig");
const ipc_handoff = @import("../../os/ipc_handoff.zig");
const provenance = @import("provenance.zig");

const log = std.log.scoped(.win32_ipc);

/// The caveat a LAUNCH HANDOFF earns when the build that asked for the window
/// is not the build that opened it (T1022, D79's remaining con).
///
/// Returned as the reply's `note` — the CLI prints it to stderr, so a `ghoztty`
/// run from a shell says it in the shell — AND shown as a desktop notification,
/// because the case that matters is a GUI launch from a shortcut, which has no
/// stderr to read. Same build, no handoff, or a launch too old to send one: no
/// note, no balloon. The join is meant to be invisible when the two copies are
/// the same bits.
pub fn handoffNote(ctx: Context, arena: Allocator, request: Request) Allocator.Error!?[]const u8 {
    const launcher = request.handoff orelse return null;

    const running: ipc_handoff.Identity = .{
        .version = provenance.version,
        .commit = provenance.commit,
        .exe = (provenance.collect(arena) catch return null).exe,
    };

    const notice = (try ipc_handoff.mismatchNotice(arena, launcher, running)) orelse return null;
    log.warn(
        "launch handoff from a different build: launcher={s} running={s} prompted={}",
        .{ launcher.version, running.version, launcher.prompted },
    );
    // T1023: a launch that already put the difference in front of the user and
    // got an answer has said it better than a balloon can. Repeating it as a
    // toast the moment they click through the dialog is the same fact twice.
    // The note is returned either way — a CLI reads it, and so does the
    // acceptance harness.
    if (!launcher.prompted) ctx.app.showLaunchHandoffNotice(notice.title, notice.body);
    return notice.note;
}

/// `version` (T52): build provenance of THIS instance, so any pane can
/// answer "which build is this window running?" (`ghoztty +version` shows
/// it as the "Running Instance" section).
pub fn handleVersion(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    _ = request;
    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prov = try provenance.collect(arena);

    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("version") catch break :write;
        jws.write(prov.version) catch break :write;
        jws.objectField("commit") catch break :write;
        jws.write(prov.commit) catch break :write;
        jws.objectField("mode") catch break :write;
        jws.write(prov.mode) catch break :write;
        jws.objectField("runtime") catch break :write;
        jws.write(prov.runtime) catch break :write;
        jws.objectField("update_check") catch break :write;
        jws.write(prov.update_check) catch break :write;
        jws.objectField("exe") catch break :write;
        jws.write(prov.exe) catch break :write;
        jws.objectField("exe_modified") catch break :write;
        jws.write(prov.exe_modified) catch break :write;
        // T1205: `exe_modified` describes the FILE. These two describe the
        // PROCESS and the relationship between them, so a reader can never
        // again mistake a fresh file for a fresh window.
        jws.objectField("started") catch break :write;
        jws.write(prov.started) catch break :write;
        jws.objectField("newer_build_installed") catch break :write;
        jws.write(prov.newer_build_installed) catch break :write;
        jws.objectField("pid") catch break :write;
        jws.write(prov.pid) catch break :write;
        // T1070: the capability half of the switch-builds handshake. A launch
        // of another build reads these before it offers "Switch"; a build that
        // predates them sends neither, and the launch then offers only the two
        // answers that work against it.
        if (!actsPreSwitch()) {
            jws.objectField("handoff_quit") catch break :write;
            jws.write(true) catch break :write;
            jws.objectField("session_persistence") catch break :write;
            jws.write(ctx.app.config.@"session-persistence") catch break :write;
        }
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

/// DEBUG-ONLY test seam (T1070): answer `version` and `handoff-quit` the way a
/// build from before the switch does, so the acceptance script can prove a
/// launch against an older build degrades to the two answers. There is only one
/// build in zig-out, so "older" is otherwise unreachable from outside. Compiled
/// out of every release build.
fn actsPreSwitch() bool {
    if (comptime !build_config.is_debug) return false;
    return std.process.hasNonEmptyEnvVarConstant("GHOZTTY_TEST_PRE_SWITCH");
}

/// `handoff-quit` (T1070): a launch of a DIFFERENT build asks this instance to
/// quit so it can start in its place — the "Switch" answer on the T1023
/// question. The user chose it in that dialog, so nothing is asked here.
///
/// The quit is deferred to a timer rather than posted inline: the reply has to
/// reach the launch first (it is what tells the launch to wait for this process
/// to exit), and the listener thread only writes it after this returns.
/// Teardown is the ordinary Quit, so with persistence on every pane's session
/// is detached rather than closed and the saved layout is flushed — which is
/// what the launch's own restore re-attaches.
pub fn handleHandoffQuit(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    // A build from before the switch answers exactly this.
    if (actsPreSwitch()) return try errorResponse(ctx.alloc, "unknown action: {s}", .{request.action});
    const own: ipc_handoff.Identity = .{
        .version = provenance.version,
        .commit = provenance.commit,
    };
    if (ipc_handoff.refuseHandoffQuit(request.handoff, own)) |why| {
        log.warn("handoff-quit refused: {s}", .{why});
        return try errorResponse(ctx.alloc, "{s}", .{why});
    }
    const launcher = request.handoff.?;
    log.warn("handoff-quit: quitting so the launch of {s} ({s}) can take over (persistence={})", .{
        launcher.version, launcher.exe, ctx.app.config.@"session-persistence",
    });
    ctx.app.scheduleHandoffQuit();
    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}
