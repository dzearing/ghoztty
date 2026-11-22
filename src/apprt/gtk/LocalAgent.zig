//! Finds or spawns the local `ghoztty-agent` and hands back the ONE shared
//! connection every persistent pane rides — the Linux local end of session
//! persistence (T3337, Linux L8). Panes backed by this agent outlive the app
//! (crash, kill, quit), exactly as on macOS (`LocalAgentManager`) and Windows
//! (`apprt/win32/LocalAgent.zig`).
//!
//! The transport is the Mac's: a 0600 AF_UNIX socket with the agent's
//! same-uid `SO_PEERCRED` gate (T3332), at the Mac's file layout
//! (`remote/local_agent_paths.zig`), so only this user can reach the shell.
//!
//! Discovery order, mirroring the Mac:
//!
//!  1. **Find**: read the info file (`port.json`, written by the agent after
//!     its socket binds), check the recorded pid is alive, dial the recorded
//!     `socket`. The dial blocks through the HELLO handshake, so a live
//!     connection IS the health check.
//!  2. **Spawn**: launch `ghoztty-agent` (a sibling of `ghoztty`, override
//!     `GHOSTTY_LOCAL_AGENT_BIN`) in a NEW session via a double fork, so it is
//!     neither the app's child nor in its process group and an app kill cannot
//!     take it down, then poll the info file until a dial succeeds (bounded).
//!
//! Bounded and never fatal: a missing or broken agent yields null within
//! `spawn_deadline_ms` and the pane falls back to a plain exec pty; after a
//! failure, new panes skip straight to exec for `failure_cooldown_ms` so an
//! unspawnable agent never stalls every window (the Mac's
//! `connectFailureCooldown`, win32's same constant).
//!
//! Autostart (a `systemd --user` unit) and restore/re-attach on relaunch are
//! the rest of L8 and live in their own cards; this module is the
//! find-or-spawn every one of them starts from.
//!
//! GTK main thread only (surfaces are built there), so no locking.

const LocalAgent = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const tcp_dial = @import("../../remote/tcp_dial.zig");
const connection = @import("../../remote/connection.zig");
const paths = @import("../../remote/local_agent_paths.zig");
const build_config = @import("../../build_config.zig");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.gtk_local_agent);

/// Wall-clock budget for one find-or-spawn. A healthy agent dials in well
/// under a second; past this the pane opens as a plain exec pane instead.
const spawn_deadline_ms: i64 = 3000;

/// HELLO deadline for one probe dial, so a wedged agent that accepts but never
/// answers cannot eat the whole budget in one attempt.
const probe_handshake_ns: u64 = 1200 * std.time.ns_per_ms;

/// After a failed resolve, new panes go straight to exec for this long.
const failure_cooldown_ms: i64 = 15_000;

/// Poll interval while a freshly spawned agent binds and writes its info file.
const poll_interval_ms: u64 = 50;

alloc: Allocator,

/// The shared connection; surfaces BORROW `.conn`. Null until the first
/// successful resolve.
shared: ?tcp_dial.Dialed = null,

/// The agent pid `shared` talks to (from its info file), 0 when unknown.
shared_pid: posix.pid_t = 0,

/// Connections replaced after their agent died. Never freed before app exit:
/// surfaces borrow `*Connection` and nothing refcounts it, so one may only be
/// destroyed once every surface that could touch it is gone.
retired: std.ArrayList(tcp_dial.Dialed) = .empty,

/// When the last resolve failed (ms), for the cooldown.
last_failure_ms: ?i64 = null,

pub fn init(alloc: Allocator) LocalAgent {
    return .{ .alloc = alloc };
}

/// The connection a NEW persistent pane should ride, or null to open it as a
/// plain exec pane. Reuses the warm connection while its agent lives; finds
/// or spawns one otherwise.
pub fn sharedConnection(self: *LocalAgent) ?*connection.Connection {
    if (self.shared) |*d| {
        if (pidAlive(self.shared_pid)) return d.conn;
        log.warn("local agent pid {d} is gone; finding or starting a new one", .{self.shared_pid});
        self.retired.append(self.alloc, d.*) catch {};
        self.shared = null;
        self.shared_pid = 0;
    }

    const now = std.time.milliTimestamp();
    if (self.last_failure_ms) |t| {
        if (now - t < failure_cooldown_ms) return null;
    }

    const resolved = self.resolve() catch |err| {
        log.warn("local agent unavailable ({}); this pane runs without session persistence", .{err});
        self.last_failure_ms = std.time.milliTimestamp();
        return null;
    };
    self.last_failure_ms = null;
    self.shared = resolved.dialed;
    self.shared_pid = resolved.pid;
    log.info("shared local-agent connection ready (agent pid {d})", .{resolved.pid});
    return self.shared.?.conn;
}

const Resolved = struct { dialed: tcp_dial.Dialed, pid: posix.pid_t };

fn resolve(self: *LocalAgent) !Resolved {
    const dir = try paths.stateDir(self.alloc, build_config.is_debug);
    defer self.alloc.free(dir);
    const port_path = try paths.join(self.alloc, dir, paths.port_file);
    defer self.alloc.free(port_path);

    if (self.dialExisting(port_path)) |r| return r;

    const bin = try agentBinary(self.alloc);
    defer self.alloc.free(bin);
    std.fs.accessAbsolute(bin, .{}) catch {
        log.warn("no agent binary at {s}", .{bin});
        return error.AgentBinaryMissing;
    };

    try std.fs.cwd().makePath(dir);
    // 0700: the dir holds the socket, the roster and the log. `.iterate`
    // because a plain openDir is an O_PATH fd on Linux, which fchmod refuses
    // with EBADF (and std turns that into a panic).
    if (std.fs.cwd().openDir(dir, .{ .iterate = true })) |d| {
        var dd = d;
        defer dd.close();
        std.posix.fchmod(dd.fd, 0o700) catch {};
    } else |_| {}

    try self.spawnDetached(bin, dir);

    const deadline = std.time.milliTimestamp() + spawn_deadline_ms;
    while (std.time.milliTimestamp() < deadline) {
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        if (self.dialExisting(port_path)) |r| return r;
    }
    return error.AgentUnresponsive;
}

/// The info file body: `{"port":0,"pid":P,"socket":"<path>","startedAt":MS}`.
const InfoFile = struct {
    port: u16 = 0,
    pid: i64 = 0,
    socket: ?[]const u8 = null,
};

fn dialExisting(self: *LocalAgent, port_path: []const u8) ?Resolved {
    const bytes = std.fs.cwd().readFileAlloc(self.alloc, port_path, 64 * 1024) catch return null;
    defer self.alloc.free(bytes);
    const parsed = std.json.parseFromSlice(InfoFile, self.alloc, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const info = parsed.value;
    if (info.pid <= 0) return null;
    const pid: posix.pid_t = std.math.cast(posix.pid_t, info.pid) orelse return null;
    // A stale file names a dead pid; that is "no agent", not an error.
    if (!pidAlive(pid)) return null;
    const sock = info.socket orelse return null;
    if (sock.len == 0) return null;
    const dialed = tcp_dial.dialUnixTimeout(self.alloc, sock, .raw, probe_handshake_ns) catch |err| {
        log.debug("dial {s} failed: {}", .{ sock, err });
        return null;
    };
    return .{ .dialed = dialed, .pid = pid };
}

fn pidAlive(pid: posix.pid_t) bool {
    if (pid <= 0) return false;
    posix.kill(pid, 0) catch |err| return err == error.PermissionDenied;
    return true;
}

/// `GHOSTTY_LOCAL_AGENT_BIN`, else `ghoztty-agent` beside this executable.
fn agentBinary(alloc: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_LOCAL_AGENT_BIN")) |v| {
        if (v.len > 0) return v;
        alloc.free(v);
    } else |_| {}
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fs.selfExePath(&buf);
    const dir = std.fs.path.dirname(exe) orelse return error.NoExeDir;
    return std.fs.path.join(alloc, &.{ dir, "ghoztty-agent" });
}

/// Start the agent so it outlives this app: fork, `setsid` in the child,
/// fork again and exec in the grandchild, reap the child at once. The agent
/// ends up in its own session, reparented to init, with stdin on /dev/null and
/// stdout/stderr appended to `agent.log` beside its socket. Its cwd is the
/// user's home (the default cwd of a session OPENed without one).
///
/// Everything the children touch is prepared BEFORE the fork: this process is
/// multi-threaded, so between fork and exec only async-signal-safe calls run.
fn spawnDetached(self: *LocalAgent, bin: []const u8, dir: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bin_z = try arena.dupeZ(u8, bin);
    const sock = try paths.join(arena, dir, paths.socket_file);
    const port = try paths.join(arena, dir, paths.port_file);
    const sessions = try paths.join(arena, dir, paths.sessions_file);
    const argv = try arena.allocSentinel(?[*:0]const u8, 4, null);
    argv[0] = bin_z.ptr;
    argv[1] = (try std.fmt.allocPrintSentinel(arena, "--listen-unix={s}", .{sock}, 0)).ptr;
    argv[2] = (try std.fmt.allocPrintSentinel(arena, "--port-file={s}", .{port}, 0)).ptr;
    argv[3] = (try std.fmt.allocPrintSentinel(arena, "--sessions-file={s}", .{sessions}, 0)).ptr;

    var env = try std.process.getEnvMap(arena);
    // The per-lineage guard paths (so a debug and a release agent, or two
    // test lineages, never take each other's lock) and no self-update: the
    // install owns the binary's lifecycle. The Mac's exact overrides.
    try env.put("GHOSTTY_AGENT_LOCK", try paths.join(arena, dir, paths.lock_file));
    try env.put("GHOSTTY_AGENT_HEARTBEAT", try paths.join(arena, dir, paths.heartbeat_file));
    try env.put("GHOSTTY_AGENT_NO_SELFUPDATE", "1");
    // This app's own IPC endpoint and pane identity are not the agent's.
    env.remove("GHOZTTY_IPC_SOCKET");
    env.remove("GHOZTTY_PANE_ID");
    const envp = try std.process.createNullDelimitedEnvMap(arena, &env);

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (internal_os.home(&home_buf) catch null) orelse "/";
    const home_z = try arena.dupeZ(u8, home);

    const log_path = try paths.join(arena, dir, paths.log_file);
    const log_fd = try posix.open(log_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o600);
    defer posix.close(log_fd);
    const null_fd = try posix.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer posix.close(null_fd);

    const child = try posix.fork();
    if (child == 0) {
        // Child: new session, then the grandchild that becomes the agent.
        // `_exit`, never `exit`: atexit handlers are not ours to run here.
        _ = posix.setsid() catch {};
        const grandchild = posix.fork() catch std.c._exit(1);
        if (grandchild != 0) std.c._exit(0);
        // dup2 clears CLOEXEC on the target fd, so 0/1/2 survive the exec.
        posix.dup2(null_fd, 0) catch std.c._exit(126);
        posix.dup2(log_fd, 1) catch std.c._exit(126);
        posix.dup2(log_fd, 2) catch std.c._exit(126);
        posix.chdirZ(home_z) catch {};
        // An app thread may have blocked signals; the agent starts with none.
        const empty = posix.sigemptyset();
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
        posix.execveZ(bin_z.ptr, argv.ptr, envp.ptr) catch {};
        std.c._exit(127);
    }
    // Reap the intermediate child (it exits at once) so it never zombies.
    _ = posix.waitpid(child, 0);
    log.info("spawned local agent {s} (log: {s})", .{ bin, log_path });
}
