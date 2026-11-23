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
//! Once an agent has dialed, `ensureAutostart` writes the login entry that
//! brings it back without the app - a `systemd --user` unit, else an XDG
//! autostart entry (T3398, `agent_autostart.zig`). Restore/re-attach on
//! relaunch is `SessionLayout.zig` (T3397).
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
const source_checkout = @import("../../os/source_checkout.zig");
const autostart = @import("agent_autostart.zig");

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

/// The login entry was refreshed (or deliberately skipped) this run.
autostart_done: bool = false,

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
    self.ensureAutostart();
    return self.shared.?.conn;
}

/// Write (or refresh) the login entry that starts the agent without the app
/// (T3398): a `systemd --user` unit when the user's systemd is reachable, else
/// an XDG autostart entry - the LaunchAgent / HKCU Run counterpart. Runs once
/// per app run, only after persistence ENGAGED (an agent dialed), the way
/// win32's `ensureAutostart` does. Best-effort: a failure logs and never
/// touches the session. Gates and formats: `agent_autostart.zig`.
///
/// It never runs `systemctl`: the enable link is the file `systemctl --user
/// enable` would make, read at the next login. Nothing here starts, stops or
/// reloads the user's systemd.
fn ensureAutostart(self: *LocalAgent) void {
    if (self.autostart_done) return;
    self.autostart_done = true;

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bin = agentBinary(arena) catch |err| {
        log.warn("agent autostart: agent path unreadable, nothing written err={}", .{err});
        return;
    };
    const mode = autostart.parseMode(posix.getenv("GHOZTTY_AGENT_AUTOSTART"));
    // Ask about the binary the entry will NAME (url_scheme's T980 rule), and
    // fail closed: a path we cannot place is one we cannot clear later.
    const bin_dir = std.fs.path.dirname(bin) orelse "/";
    const in_checkout = source_checkout.inSourceCheckout(arena, bin_dir);
    switch (autostart.gateAllows(mode, build_config.is_debug, in_checkout)) {
        .write => {},
        .disabled, .debug_build => return,
        .source_checkout => {
            log.info("agent autostart: no login entry written from a source checkout ({s})", .{bin_dir});
            return;
        },
    }

    self.writeAutostart(arena, bin) catch |err| {
        log.warn("agent autostart: login entry write failed err={}", .{err});
    };
}

fn writeAutostart(self: *LocalAgent, arena: Allocator, bin: []const u8) !void {
    _ = self;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (try internal_os.home(&home_buf)) orelse return error.NoHome;
    const root = try paths.configRoot(arena, true, posix.getenv("XDG_CONFIG_HOME"), home);
    const dir = try paths.stateDir(arena, build_config.is_debug);

    var lin_buf: [@import("../../remote/agent_lineage.zig").max_len]u8 = undefined;
    const lineage = @import("../../remote/agent_lineage.zig").fromEnv(&lin_buf);
    var base_buf: [autostart.max_base_len]u8 = undefined;
    const base = try autostart.baseName(&base_buf, build_config.is_debug, lineage);
    const where = try autostart.pathsFor(arena, root, base);

    const a = try spawnArgs(arena, dir);
    const spec: autostart.Spec = .{
        .agent = bin,
        .args = &a.args,
        .env = &a.env,
        .log_path = try paths.join(arena, dir, paths.log_file),
    };

    const sock = try autostart.userSystemdSocket(arena, posix.getenv("XDG_RUNTIME_DIR"), std.os.linux.getuid());
    const reachable = if (std.fs.accessAbsolute(sock, .{})) |_| true else |_| false;
    switch (autostart.chooseBackend(reachable)) {
        .systemd => {
            const body = try autostart.renderUnit(arena, spec);
            try writeFileAtomic(arena, where.unit, body);
            try linkReplace(arena, where.unit, where.wants_link);
            // One login entry only: a box that just turned systemd on would
            // otherwise start a second agent from the old autostart file.
            deleteIfPresent(where.desktop);
            log.info("agent autostart: systemd user unit refreshed ({s}, enabled by {s})", .{ where.unit, where.wants_link });
        },
        .xdg => {
            const body = try autostart.renderDesktop(arena, spec);
            try writeFileAtomic(arena, where.desktop, body);
            deleteIfPresent(where.wants_link);
            deleteIfPresent(where.unit);
            log.info("agent autostart: XDG autostart entry refreshed ({s}; no user systemd at {s})", .{ where.desktop, sock });
        },
    }
}

/// `path` holds `body` afterwards, never a torn file: write a sibling, then
/// rename over. Parents are created.
fn writeFileAtomic(arena: Allocator, path: []const u8, body: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.BadPath;
    try std.fs.cwd().makePath(parent);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp-{d}", .{ path, std.os.linux.getpid() });
    {
        const f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o644 });
        defer f.close();
        try f.writeAll(body);
    }
    std.fs.renameAbsolute(tmp, path) catch |err| {
        std.fs.deleteFileAbsolute(tmp) catch {};
        return err;
    };
}

/// `link` -> `target`, replacing whatever `link` was.
fn linkReplace(arena: Allocator, target: []const u8, link: []const u8) !void {
    const parent = std.fs.path.dirname(link) orelse return error.BadPath;
    try std.fs.cwd().makePath(parent);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.readLinkAbsolute(link, &buf)) |cur| {
        if (std.mem.eql(u8, cur, target)) return;
    } else |_| {}
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp-{d}", .{ link, std.os.linux.getpid() });
    std.fs.deleteFileAbsolute(tmp) catch {};
    try std.fs.symLinkAbsolute(target, tmp, .{});
    std.fs.renameAbsolute(tmp, link) catch |err| {
        std.fs.deleteFileAbsolute(tmp) catch {};
        return err;
    };
}

fn deleteIfPresent(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

/// The agent's argv after argv[0] and its environment overrides - ONE
/// spelling for the on-demand spawn and the login entry, so the agent a login
/// starts is the agent the app would have spawned.
const SpawnArgs = struct {
    args: [3][]const u8,
    env: [3]autostart.EnvVar,
};

fn spawnArgs(arena: Allocator, dir: []const u8) !SpawnArgs {
    return .{
        .args = .{
            try std.fmt.allocPrint(arena, "--listen-unix={s}", .{try paths.join(arena, dir, paths.socket_file)}),
            try std.fmt.allocPrint(arena, "--port-file={s}", .{try paths.join(arena, dir, paths.port_file)}),
            try std.fmt.allocPrint(arena, "--sessions-file={s}", .{try paths.join(arena, dir, paths.sessions_file)}),
        },
        // The per-lineage guard paths (so a debug and a release agent, or two
        // test lineages, never take each other's lock) and no self-update: the
        // install owns the binary's lifecycle. The Mac's exact overrides.
        .env = .{
            .{ .name = "GHOSTTY_AGENT_LOCK", .value = try paths.join(arena, dir, paths.lock_file) },
            .{ .name = "GHOSTTY_AGENT_HEARTBEAT", .value = try paths.join(arena, dir, paths.heartbeat_file) },
            .{ .name = "GHOSTTY_AGENT_NO_SELFUPDATE", .value = "1" },
        },
    };
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
    // We are about to LAUNCH the sibling, so go through the self-spawn guard:
    // a test binary's dir is build output, never an install (T980).
    const dir = try internal_os.self_exe.productExeDirPathAlloc(alloc);
    defer alloc.free(dir);
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
    const spawn = try spawnArgs(arena, dir);
    const argv = try arena.allocSentinel(?[*:0]const u8, 1 + spawn.args.len, null);
    argv[0] = bin_z.ptr;
    for (spawn.args, 1..) |a, i| argv[i] = (try arena.dupeZ(u8, a)).ptr;

    var env = try std.process.getEnvMap(arena);
    for (spawn.env) |e| try env.put(e.name, e.value);
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
