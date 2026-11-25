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
const agent_recovery = @import("../win32/agent_recovery.zig");
const agent_build = @import("../../remote/agent_build.zig");
const protocol = @import("../../remote/protocol.zig");
const rules = @import("agent_upgrade_rules.zig");

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

/// The protocol skew the last dial hit (T3600, win32's T125): the agent
/// ANSWERED and the handshake could not be agreed. A live process holding
/// live sessions, not a dead one, so `resolve` never spawns a second agent
/// over it; `AgentUpgrade` decides what to do. Null once a dial negotiates.
protocol_skew: ?Skew = null,

/// The bundled agent's build stamp, probed once per run (`bundledVersion`).
bundled_version: ?[]u8 = null,
bundled_version_probed: bool = false,

/// Called (never from inside a pane build) after a find-or-spawn settled -
/// a fresh connection, or a skew - so the upgrade check runs at launch the
/// way win32's runs after its restore (T3600). Set by `AgentUpgrade.start`.
on_resolved: ?*const fn () void = null,

/// What a skewed dial learned. `peer_proto_version` is null when the peer
/// never sent a HELLO we could parse.
pub const Skew = struct {
    peer_proto_version: ?u16 = null,
};

/// Called after a NEW pane's request replaced a dead agent's connection
/// (T3400), so the panes still riding the old one get rebuilt. Set by
/// `AgentRecovery.start`; must not rebuild synchronously (it runs while a
/// pane is being built).
on_reconnected: ?*const fn () void = null,

/// Retire a connection whose agent died or whose link stayed down: it stops
/// carrying anything and is shut down OFF the GTK thread (win32's T229 rule -
/// `shutdown` joins the connection's threads, and a peer thread that does not
/// exit promptly would wedge the app). Never freed: panes borrow it.
fn retire(self: *LocalAgent, d: tcp_dial.Dialed) void {
    self.retired.append(self.alloc, d) catch
        log.warn("retired local-agent connection could not be tracked; leaking it", .{});
    const t = std.Thread.spawn(.{}, shutdownRetired, .{d.conn}) catch |err| {
        log.warn("retired local-agent connection: async teardown unavailable ({}), shutting down inline", .{err});
        d.conn.shutdown();
        return;
    };
    t.detach();
}

fn shutdownRetired(conn: *connection.Connection) void {
    conn.shutdown();
}

/// Whether `conn` is one this app retired - the connection of an agent that
/// died or a link that stayed down. A pane still riding one is frozen and is
/// what in-place recovery rebuilds (T3400).
pub fn isRetired(self: *const LocalAgent, conn: *const connection.Connection) bool {
    for (self.retired.items) |d| if (d.conn == conn) return true;
    return false;
}

/// The shared link's state, or null when there is no shared connection.
pub fn sharedState(self: *LocalAgent) ?connection.LinkState.State {
    const d = self.shared orelse return null;
    return d.conn.state();
}

/// The pid of the agent the shared connection talks to (0 when unknown).
pub fn sharedPid(self: *const LocalAgent) posix.pid_t {
    return self.shared_pid;
}

pub fn sharedPidAlive(self: *const LocalAgent) bool {
    return pidAlive(self.shared_pid);
}

/// The live agent's pid as its info file records it, or null when no live
/// agent is there. Only read on a settle window's deciding tick.
pub fn liveAgentPid(self: *LocalAgent) ?posix.pid_t {
    const dir = paths.stateDir(self.alloc, build_config.is_debug) catch return null;
    defer self.alloc.free(dir);
    const port_path = paths.join(self.alloc, dir, paths.port_file) catch return null;
    defer self.alloc.free(port_path);
    const bytes = std.fs.cwd().readFileAlloc(self.alloc, port_path, 64 * 1024) catch return null;
    defer self.alloc.free(bytes);
    const parsed = std.json.parseFromSlice(InfoFile, self.alloc, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const pid = std.math.cast(posix.pid_t, parsed.value.pid) orelse return null;
    return if (pidAlive(pid)) pid else null;
}

/// Find or spawn an agent for in-place recovery (T3400, win32's
/// `reconnectForRecovery`): ignores the failure cooldown, since a confirmed
/// drop already waited out its settle window. Only on success is the old
/// shared connection retired, so a failed attempt leaves the down link in
/// place for the retry schedule to re-check.
pub fn reconnectForRecovery(self: *LocalAgent) ?*connection.Connection {
    const resolved = self.resolve() catch |err| {
        log.warn("in-place recovery: no local agent could be reached ({})", .{err});
        self.last_failure_ms = std.time.milliTimestamp();
        return null;
    };
    if (self.shared) |old| self.retire(old);
    self.shared = resolved.dialed;
    self.shared_pid = resolved.pid;
    self.last_failure_ms = null;
    log.info("in-place recovery: re-dialed the local agent (pid {d})", .{resolved.pid});
    self.ensureAutostart();
    return self.shared.?.conn;
}

pub fn init(alloc: Allocator) LocalAgent {
    return .{ .alloc = alloc };
}

/// The connection a NEW persistent pane should ride, or null to open it as a
/// plain exec pane. Reuses the warm connection while its agent lives; finds
/// or spawns one otherwise.
pub fn sharedConnection(self: *LocalAgent) ?*connection.Connection {
    if (self.shared) |d| {
        // T3400: win32's T764/T1473 verdict, so a new pane never rides a link
        // that cannot carry it.
        switch (agent_recovery.newSurfaceVerdict(d.conn.state(), self.shared_pid, pidAlive(self.shared_pid))) {
            .hand_over => return d.conn,
            // Down but the agent may be alive (a wedge): a plain exec pane
            // now beats a pane frozen on a stalled link.
            .exec_fallback => return null,
            .recover_first, .re_resolve => {
                log.warn("local agent pid {d} is gone; finding or starting a new one", .{self.shared_pid});
                const fresh = self.reconnectForRecovery() orelse return null;
                // The panes that rode the old agent are rebuilt onto the
                // fresh one once this pane is built (never from inside it).
                if (self.on_reconnected) |hook| hook();
                return fresh;
            },
        }
    }

    const now = std.time.milliTimestamp();
    if (self.last_failure_ms) |t| {
        if (now - t < failure_cooldown_ms) return null;
    }

    const resolved = self.resolve() catch |err| {
        log.warn("local agent unavailable ({}); this pane runs without session persistence", .{err});
        self.last_failure_ms = std.time.milliTimestamp();
        // A skew is a decision for the upgrade check, not just a failure.
        if (err == error.ProtocolSkew) if (self.on_resolved) |hook| hook();
        return null;
    };
    self.last_failure_ms = null;
    self.shared = resolved.dialed;
    self.shared_pid = resolved.pid;
    log.info("shared local-agent connection ready (agent pid {d})", .{resolved.pid});
    self.ensureAutostart();
    if (self.on_resolved) |hook| hook();
    return self.shared.?.conn;
}

// ---------------------------------------------------------------------------
// Non-destructive agent upgrade (T3600, win32's T147/T125)
// ---------------------------------------------------------------------------

/// The protocol skew the last dial hit, or null.
pub fn protocolSkew(self: *const LocalAgent) ?Skew {
    return self.protocol_skew;
}

/// The build stamp the CONNECTED agent advertised in its HELLO, or null when
/// there is no shared connection or the agent is too old to advertise one.
pub fn runningVersion(self: *LocalAgent) ?[]const u8 {
    const d = self.shared orelse return null;
    return d.conn.peerBuildVersion();
}

/// The build stamp of the agent binary this app ships beside (`--version`),
/// or null when it cannot be read. Probed ONCE per run, failure included:
/// the binary can be swapped mid-run, but the app that shipped it is this
/// process, so the stamp to adopt is the one beside it at start.
///
/// `GHOZTTY_AGENT_BUNDLED_VERSION` overrides the INPUT in a debug build only
/// (win32's same hook): every stamp in one tree is the same, so without it
/// no test could reach the stale arm. Never honored in a release build.
pub fn bundledVersion(self: *LocalAgent) ?[]const u8 {
    if (self.bundled_version_probed) return self.bundled_version;
    self.bundled_version_probed = true;

    if (build_config.is_debug) {
        if (posix.getenv("GHOZTTY_AGENT_BUNDLED_VERSION")) |v| if (v.len > 0) {
            self.bundled_version = self.alloc.dupe(u8, v) catch return null;
            log.warn("bundled agent build OVERRIDDEN to {s} (debug test hook)", .{v});
            return self.bundled_version;
        };
    }

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bin = agentBinary(arena) catch return null;
    std.fs.accessAbsolute(bin, .{}) catch {
        log.warn("bundled agent binary not found at {s}; upgrade check disabled", .{bin});
        return null;
    };
    const result = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ bin, "--version" },
        .max_output_bytes = 4096,
    }) catch |err| {
        log.warn("agent --version probe failed err={}", .{err});
        return null;
    };
    const stamp = agent_build.parseVersionOutput(result.stdout) orelse {
        log.warn("agent --version printed nothing usable; upgrade check disabled", .{});
        return null;
    };
    self.bundled_version = self.alloc.dupe(u8, stamp) catch return null;
    log.info("bundled agent build is {s}", .{stamp});
    return self.bundled_version;
}

/// Stop the running agent so the next resolve starts the bundled build
/// (T3600). The CALLER decided this is safe: no live sessions (silent), or a
/// user-confirmed protocol skew. The connection is RETIRED, never freed -
/// panes borrow it - and the stranded panes are what in-place recovery
/// rebuilds next. Returns true when an agent was actually stopped.
///
/// The pid comes out of `port.json`, so it is VERIFIED before any signal
/// (win32's T421 gates): never this process, and only a process whose
/// executable is the agent binary (`agent_upgrade_rules.isAgentExe`).
pub fn restartForUpgrade(self: *LocalAgent) bool {
    log.info("agent restart: begin (reading agent info file)", .{});
    const pid: posix.pid_t = self.liveAgentPid() orelse self.shared_pid;
    // A deliberate restart is not a failure, and whatever skew was recorded
    // belonged to the agent being stopped; its replacement speaks this build.
    self.last_failure_ms = null;
    self.protocol_skew = null;

    const stopped = if (pid > 0) self.stopAgent(pid) else false;
    if (self.shared) |old| {
        log.info("agent restart: retiring the shared connection (agent pid {d})", .{self.shared_pid});
        self.retire(old);
        self.shared = null;
        self.shared_pid = 0;
    }
    if (stopped)
        log.info("stopped local agent pid {d} to adopt the bundled build", .{pid})
    else
        log.warn("no local agent process to stop (pid {d}); the next resolve starts one", .{pid});
    return stopped;
}

/// SIGTERM, a bounded wait, then SIGKILL - so the respawn never races the
/// dying agent's still-bound socket and lock.
fn stopAgent(self: *LocalAgent, pid: posix.pid_t) bool {
    if (pid == std.os.linux.getpid()) {
        log.err("agent restart: REFUSING to stop pid {d} - that is THIS process (stale port.json or a recycled pid)", .{pid});
        return false;
    }
    var link_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buf, "/proc/{d}/exe", .{pid}) catch return false;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.fs.readLinkAbsolute(link, &exe_buf) catch |err| {
        log.warn("agent restart: cannot read {s} err={}; not signalling it", .{ link, err });
        return false;
    };
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const expected = agentBinary(arena_state.allocator()) catch null;
    if (!rules.isAgentExe(exe, expected)) {
        log.err("agent restart: REFUSING to stop pid {d} - its executable {s} is not the agent", .{ pid, exe });
        return false;
    }
    log.info("agent restart: stopping agent pid {d} ({s})", .{ pid, exe });
    posix.kill(pid, posix.SIG.TERM) catch return false;
    var waited: u64 = 0;
    while (waited < stop_grace_ms) : (waited += poll_interval_ms) {
        if (!pidAlive(pid)) return true;
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
    }
    log.warn("agent restart: pid {d} still up after {d} ms; SIGKILL", .{ pid, stop_grace_ms });
    posix.kill(pid, posix.SIG.KILL) catch {};
    waited = 0;
    while (waited < stop_grace_ms) : (waited += poll_interval_ms) {
        if (!pidAlive(pid)) return true;
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
    }
    return !pidAlive(pid);
}

/// How long a stopping agent gets after each signal.
const stop_grace_ms: u64 = 2000;

/// Whether a shared connection exists right now.
pub fn hasSharedConnection(self: *const LocalAgent) bool {
    return self.shared != null;
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
    // The agent answered and could not agree: it is alive and holds the
    // lock, so a spawn would only collide with it (win32's findOrSpawn rule).
    if (self.protocol_skew != null) return error.ProtocolSkew;

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
    var report: tcp_dial.DialReport = .{};
    const dialed = tcp_dial.dialUnixTimeoutReport(self.alloc, sock, .raw, probe_handshake_ns, &report) catch |err| {
        if (err == error.ProtocolIncompatible) {
            // A live process holding live sessions, not a dead one: recorded
            // for `AgentUpgrade` (the mandatory-update path, T3600/T125).
            self.protocol_skew = .{ .peer_proto_version = report.peer_proto_version };
            log.warn("local agent refused the handshake: protocol skew (agent offers {?d}, this app speaks {d})", .{
                report.peer_proto_version, protocol.proto_version,
            });
            return null;
        }
        log.debug("dial {s} failed: {}", .{ sock, err });
        return null;
    };
    // A dial we could negotiate is proof the skew (if any) is over.
    self.protocol_skew = null;
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
