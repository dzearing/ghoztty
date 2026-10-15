//! Single-instance guard for the `ghoztty-agent` DAEMON modes (`--listen`,
//! `--listen-unix`, `--relay`) — one guard per ROLE, per user.
//!
//! ## Why
//! Multiple supervisors can (and did, live) race to keep the agent alive on the
//! same box — the installer's scheduled-task launcher AND an SMB deploy-watcher
//! script both respawn-on-exit, and each happily launched its own agent (two
//! tray icons, two daemons fighting over the listen port / relay control
//! socket). The agent itself must be idempotent at the process level: the
//! SECOND daemon instance detects the first and exits immediately with a
//! distinct, documented exit code, so a supervisor's keep-alive loop degrades
//! into a cheap respawn-and-exit heartbeat instead of a second daemon.
//!
//! ## Roles — the guard is per ROLE, not per binary
//! Each daemon mode is a `Role` (`relay`, `listen`, `listen-unix`) with its own
//! guard name. Two daemons of the SAME role exclude each other (the incident
//! above stays fixed); daemons of DIFFERENT roles coexist, because they
//! contend for nothing — a `--listen-unix` session agent serves a filesystem
//! socket, a `--relay` agent dials an outbound WSS. (Before roles, the one
//! shared name made any daemon exclude every other, so a Mac's
//! session-persistence agent and its relay agent could not both run.)
//!
//! The `relay` role keeps the LEGACY, unsuffixed names (`agent.lock`,
//! `agent.heartbeat`, `Global\GhozttyAgentDaemon-<SID>`, `Local\GhozttyAgentDaemon`):
//! every supervisor that ever shipped runs `--relay`, and an older-build relay
//! agent holding the legacy name must still exclude a newer one across a
//! version skew. Other roles append `.<role>` (`agent.listen-unix.lock`,
//! `Global\GhozttyAgentDaemon.listen-<SID>`). A `.` never follows
//! `GhozttyAgentDaemon` in the legacy name, so no user id can make two roles'
//! names collide.
//!
//! ## Mechanism (per platform, per user, per role)
//!   - **Windows**: a named mutex `Global\GhozttyAgentDaemon-<user-SID>` via
//!     `CreateMutexW`. The GLOBAL namespace is shared across ALL logon
//!     sessions, and the SID suffix keeps different users from blocking each
//!     other. This matters because `Local\` scopes per LOGON SESSION, NOT per
//!     user: a scheduled-task/service supervisor ("run whether user is logged
//!     on or not") lives in a DIFFERENT logon session than an interactive
//!     launch, so a `Local\`-only guard let two same-user daemons coexist —
//!     exactly the live dup-daemon incident this rework fixes. Per MS "Kernel
//!     object namespaces": creating a MUTEX in `Global\` requires NO special
//!     privilege — the `SeCreateGlobalPrivilege` check is limited to
//!     file-mapping and symbolic-link objects — and using a global named
//!     object to detect "already an instance running across all sessions" is
//!     the doc's own example. Fallback chain, so the guard never regresses
//!     below the old behavior: SID unavailable → username suffix
//!     (`GetUserNameW`); `Global\` create denied (AppContainer-style sandboxes
//!     where the global namespace is unavailable) → the legacy per-session
//!     `Local\GhozttyAgentDaemon`. An ACCESS_DENIED from `CreateMutexW` is
//!     disambiguated with a minimal `OpenMutexW(SYNCHRONIZE)` probe: name
//!     exists but is unopenable (e.g. the first daemon runs elevated) →
//!     already running; name absent → namespace unusable → fall back. The
//!     handle is held for the process lifetime; the OS destroys the mutex when
//!     the last handle closes (normal exit OR crash), so no stale-lock cleanup
//!     is ever needed. Detection is the classic `GetLastError() ==
//!     ERROR_ALREADY_EXISTS` after `CreateMutexW` — we never wait on the mutex,
//!     so abandonment semantics don't apply.
//!   - **POSIX**: an advisory `flock(LOCK_EX | LOCK_NB)` on a lock file next to
//!     the agent's other per-user state (`~/.config/ghoztty/agent.lock`, or
//!     `$XDG_CONFIG_HOME/ghoztty/agent.lock` for the relay role,
//!     `agent.<role>.lock` for the others). `GHOSTTY_AGENT_LOCK` overrides
//!     the full path VERBATIM — it names ONE daemon's identity, no role suffix
//!     is added: running session agents (older builds) hold an overridden
//!     path, and a newer agent of the same role must contend for that exact
//!     path or an upgrade could put two of them on one socket. Tests and the
//!     macOS LocalAgentManager use it. The fd is held for the process
//!     lifetime; the kernel releases the flock when the fd closes (normal exit
//!     OR crash), so a stale lock file on disk is harmless — it's the LOCK,
//!     not the file's existence, that gates. flock is per open-file-
//!     description, so a second process (or even a second `open()` of the same
//!     path) conflicts.
//!
//! ## Exit code
//! On conflict the daemon logs `ghoztty-agent: another instance is already
//! running; exiting` and exits with **code 183** (`already_running_exit_code`)
//! — deliberately chosen to mirror Windows' `ERROR_ALREADY_EXISTS` (183) so
//! the value is self-describing in supervisor logs on either OS.
//!
//! ## Which modes take the lock
//! Only the daemon modes (`--listen`, `--listen-unix`, `--relay`). `--stdio`
//! is a per-ssh-connection servant
//! (many may legitimately coexist) and `--enroll` is a one-shot utility that
//! must work WHILE a daemon runs — neither takes the lock.
//!
//! ## Takeover — "there should be only one" (`acquireWithTakeover`)
//! Losing the guard race no longer means blind deference: the holder might be
//! SIGSTOP'd, deadlocked, or an anomaly that leaked the lock. The winning
//! daemon proves liveness by touching a HEARTBEAT file containing its PID and
//! ROLE (`<pid>\nrole=<role>\n`; `agent.heartbeat` / `agent.<role>.heartbeat`,
//! sibling of the other per-user agent state: `%LOCALAPPDATA%\ghoztty\` on
//! Windows, `$XDG_CONFIG_HOME|~/.config/ghoztty/` on POSIX;
//! `GHOSTTY_AGENT_HEARTBEAT` overrides verbatim, like the lock) every
//! `heartbeat_interval_ms` (10s). A challenger that hits AlreadyRunning:
//!
//!   1. Reads the heartbeat. FRESH (mtime age < `heartbeat_stale_after_ms`,
//!      45s) → the holder is alive and responsive → yield (exit 183 upstream).
//!   2. STALE → the holder is stuck. Verify the PID still names a
//!      ghoztty-agent image (QueryFullProcessImageNameW / proc_pidpath /
//!      /proc/<pid>/exe, best-effort) so PID reuse can't friendly-fire an
//!      innocent process: confirmed-agent → kill it (TerminateProcess /
//!      SIGKILL) and take the guard; confirmed-OTHER → never kill, yield with
//!      a warning; unverifiable → kill only because the guard is provably
//!      still held (re-checked immediately before the verdict).
//!   3. NO heartbeat file at all → an old-binary (pre-heartbeat) holder or a
//!      racing first run: treated as responsive → yield. (`--force-replace`
//!      cannot help here either — with no PID on record there is nobody safe
//!      to kill.)
//!   4. After a kill, the OS frees the mutex/flock with the process; the
//!      challenger retries acquisition in a short bounded loop (5 × 200ms)
//!      and, if the guard is SOMEHOW still held, yields — when in doubt, die:
//!      never two daemons.
//!
//! `--force-replace` (daemon modes) skips the freshness check and kills the
//! recorded holder unconditionally (still refusing confirmed-other PIDs), for
//! a human who wants THIS launch to win. The decision matrix is the pure
//! `takeoverVerdictForRole` (unit-tested); the kill/probe syscalls are thin
//! glue.
//!
//! ### Takeover never crosses roles
//! A kill additionally requires the holder's role to be CONFIRMED equal to the
//! challenger's (`resolveHolderRole`): the heartbeat's `role=` line, else the
//! holder process's own argv (macOS `KERN_PROCARGS2`, Linux
//! `/proc/<pid>/cmdline` — this identifies a pre-role holder), else "this is
//! my role's DEFAULT heartbeat path" (a role-scoped file is that role's by
//! construction — the only signal on Windows, and what keeps a self-update's
//! `--force-replace` respawn able to replace a pre-role relay agent there).
//! A different or unknown role is never killed, not even under
//! `--force-replace`. This matters because an exact-path override can be
//! INHERITED: a shell spawned by a session agent used to carry that agent's
//! `GHOSTTY_AGENT_LOCK`/`GHOSTTY_AGENT_HEARTBEAT`, so a `--relay
//! --force-replace` run from it read the session agent's heartbeat and would
//! have SIGKILLed the process that owns the user's live panes. (The agent no
//! longer leaks those variables — `pty_child.PtySpawner` strips them — but
//! long-lived shells keep what they inherited, so this rule is the real
//! safety net.)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Exit code used when another daemon instance already holds the lock.
/// 183 == Windows ERROR_ALREADY_EXISTS, reused verbatim on POSIX so the code
/// reads the same in any supervisor's log.
pub const already_running_exit_code: u8 = 183;

pub const AcquireError = error{
    /// Another daemon instance holds the guard in this user session.
    AlreadyRunning,
    /// The guard infrastructure itself failed (couldn't create the mutex /
    /// lock file). Callers should log and CONTINUE serving — daemon
    /// availability beats guard integrity (mirrors the tray-failure policy).
    GuardUnavailable,
};

/// A held single-instance guard. Keep it alive for the whole daemon lifetime;
/// `release` exists for tests and symmetry — in production the OS reclaims the
/// mutex handle / flock on process exit (clean or crash), so never calling
/// `release` is correct.
pub const Guard = struct {
    impl: Impl,

    const Impl = if (builtin.os.tag == .windows)
        struct { handle: std.os.windows.HANDLE }
    else
        struct { fd: std.posix.fd_t };

    pub fn release(self: *Guard) void {
        if (builtin.os.tag == .windows) {
            std.os.windows.CloseHandle(self.impl.handle);
        } else {
            // Closing the fd drops the flock (per open-file-description).
            std.posix.close(self.impl.fd);
        }
        self.* = undefined;
    }
};

/// Which daemon a guard belongs to. One guard per role per user: same role
/// excludes, different roles coexist (see the module doc §Roles).
pub const Role = enum {
    /// `--relay`: the authenticated relay daemon. Owns the LEGACY names.
    relay,
    /// `--listen`: the TCP listen daemon (local/dev harness).
    listen,
    /// `--listen-unix`: the AF_UNIX session-persistence daemon (macOS).
    listen_unix,

    /// The role as it is spelled in names, heartbeats and logs.
    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .relay => "relay",
            .listen => "listen",
            .listen_unix => "listen-unix",
        };
    }

    pub fn fromLabel(s: []const u8) ?Role {
        inline for (std.meta.fields(Role)) |f| {
            const r: Role = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, r.label())) return r;
        }
        return null;
    }

    /// The per-user state-file stem: `agent` for the relay role (legacy, so a
    /// pre-role relay agent and a new one still share one guard), else
    /// `agent.<role>`. Callers append `.lock` / `.heartbeat`.
    pub fn fileName(self: Role, buf: []u8, ext: []const u8) []const u8 {
        return switch (self) {
            .relay => std.fmt.bufPrint(buf, "agent.{s}", .{ext}) catch unreachable,
            else => std.fmt.bufPrint(buf, "agent.{s}.{s}", .{ self.label(), ext }) catch unreachable,
        };
    }
};

/// Acquire the per-user daemon guard for `role`. See the module doc for the
/// platform mechanisms. `alloc` is only used transiently (path resolution on
/// POSIX); the returned `Guard` owns no heap memory.
pub fn acquire(alloc: Allocator, role: Role) AcquireError!Guard {
    if (builtin.os.tag == .windows) return acquireWindows(role);
    const path = lockFilePath(alloc, role) catch return error.GuardUnavailable;
    defer alloc.free(path);
    return acquirePath(path);
}

// -----------------------------------------------------------------------------
// Windows: named mutex (Global\ per-user, with a Local\ fallback)
// -----------------------------------------------------------------------------

/// UTF-8 prefix of the preferred (cross-logon-session) mutex name. The suffix
/// is the current user's SID string — or the username when the SID can't be
/// resolved — so distinct users never block each other while ALL of one
/// user's logon sessions (interactive, scheduled task, service) share ONE
/// guard. Public so the name composition is unit-testable off-Windows.
pub const global_mutex_name_prefix = "Global\\GhozttyAgentDaemon-";

/// Legacy pre-SID name, kept verbatim as the relay role's last-resort fallback
/// (`Local\` = per-logon-session namespace — see the module doc for why
/// that's too weak as the primary): sandboxed contexts without Global\ access
/// still get today's per-session guard rather than none at all. Other roles
/// fall back to `Local\GhozttyAgentDaemon.<role>` (`composeLocalMutexName`).
pub const local_mutex_name_base = "Local\\GhozttyAgentDaemon";

/// Compose the relay role's `Global\GhozttyAgentDaemon-<user_id>` into `buf`
/// (the pre-role name, unchanged). See `composeRoleMutexName`.
pub fn composeGlobalMutexName(buf: []u8, user_id: []const u8) error{NameTooLong}![]const u8 {
    return composeRoleMutexName(buf, .relay, user_id);
}

/// Compose `role`'s cross-session mutex name into `buf`:
/// `Global\GhozttyAgentDaemon-<user_id>` for the relay role (legacy) and
/// `Global\GhozttyAgentDaemon.<role>-<user_id>` for the others. The id is
/// sanitized: backslashes (illegal in a mutex name anywhere past the
/// namespace prefix) and control characters become `_`. Pure — testable on
/// any host; the Windows path converts the result to UTF-16 for CreateMutexW.
pub fn composeRoleMutexName(buf: []u8, role: Role, user_id: []const u8) error{NameTooLong}![]const u8 {
    const base = global_mutex_name_prefix[0 .. global_mutex_name_prefix.len - 1]; // drop the '-'
    const head = switch (role) {
        .relay => std.fmt.bufPrint(buf, "{s}-", .{base}),
        else => std.fmt.bufPrint(buf, "{s}.{s}-", .{ base, role.label() }),
    } catch return error.NameTooLong;
    const total = head.len + user_id.len;
    if (total > buf.len) return error.NameTooLong;
    for (user_id, head.len..) |c, i| {
        buf[i] = if (c == '\\' or c < 0x20) '_' else c;
    }
    return buf[0..total];
}

/// Compose `role`'s per-logon-session fallback name into `buf`:
/// `Local\GhozttyAgentDaemon` (relay, legacy) or
/// `Local\GhozttyAgentDaemon.<role>`. Pure.
pub fn composeLocalMutexName(buf: []u8, role: Role) error{NameTooLong}![]const u8 {
    return switch (role) {
        .relay => std.fmt.bufPrint(buf, "{s}", .{local_mutex_name_base}),
        else => std.fmt.bufPrint(buf, "{s}.{s}", .{ local_mutex_name_base, role.label() }),
    } catch error.NameTooLong;
}

fn acquireWindows(role: Role) AcquireError!Guard {
    if (builtin.os.tag != .windows) unreachable;

    // Preferred: Global\ + per-user id (SID, else username). Any failure on
    // this path degrades to the legacy Local\ guard — never below it.
    var id_buf: [768]u8 = undefined; // UNLEN=256 UTF-16 units ≤ 768 UTF-8 bytes
    if (windowsUserId(&id_buf)) |id| global: {
        var name8: [800]u8 = undefined;
        const name = composeRoleMutexName(&name8, role, id) catch break :global;
        var name16: [801]u16 = undefined;
        const n16 = std.unicode.utf8ToUtf16Le(name16[0..800], name) catch break :global;
        name16[n16] = 0;
        switch (tryCreateMutex(name16[0..n16 :0])) {
            .acquired => |h| return .{ .impl = .{ .handle = h } },
            .already_running => return error.AlreadyRunning,
            .namespace_unavailable => {},
        }
        std.debug.print(
            "ghoztty-agent: single-instance: Global\\ mutex unavailable; falling back to the per-logon-session Local\\ mutex (guard will NOT span logon sessions)\n",
            .{},
        );
    } else {
        std.debug.print(
            "ghoztty-agent: single-instance: user SID/name lookup failed; falling back to the per-logon-session Local\\ mutex (guard will NOT span logon sessions)\n",
            .{},
        );
    }

    // Fallback: the per-logon-session guard (the legacy behavior), per role.
    var local8: [64]u8 = undefined;
    const local_name = composeLocalMutexName(&local8, role) catch return error.GuardUnavailable;
    var local16: [65]u16 = undefined;
    const nl = std.unicode.utf8ToUtf16Le(local16[0..64], local_name) catch return error.GuardUnavailable;
    local16[nl] = 0;
    return switch (tryCreateMutex(local16[0..nl :0])) {
        .acquired => |h| .{ .impl = .{ .handle = h } },
        .already_running => error.AlreadyRunning,
        .namespace_unavailable => error.GuardUnavailable,
    };
}

const CreateOutcome = union(enum) {
    acquired: std.os.windows.HANDLE,
    already_running,
    /// The name couldn't be created OR proven to exist — the namespace (or
    /// the mutex machinery) is unusable here; try the next fallback.
    namespace_unavailable,
};

/// One CreateMutexW attempt with full outcome classification. bInitialOwner =
/// FALSE: we never wait on / own the mutex — its mere EXISTENCE (first
/// creator wins) is the whole signal, which also means abandoned-mutex
/// semantics can never bite us.
fn tryCreateMutex(name: [*:0]const u16) CreateOutcome {
    if (builtin.os.tag != .windows) unreachable;
    const handle = win32.CreateMutexW(null, 0, name) orelse {
        if (std.os.windows.GetLastError() == .ACCESS_DENIED) {
            // Ambiguous: either the name EXISTS but its DACL / integrity
            // level refuses CreateMutexW's implicit MUTEX_ALL_ACCESS open
            // (e.g. the first daemon runs elevated → that IS another
            // instance), or the namespace itself is off limits (AppContainer-
            // style sandbox). A minimal SYNCHRONIZE probe tells them apart.
            if (win32.OpenMutexW(win32.SYNCHRONIZE, 0, name)) |h| {
                std.os.windows.CloseHandle(h);
                return .already_running;
            }
            if (std.os.windows.GetLastError() == .ACCESS_DENIED) return .already_running;
            return .namespace_unavailable;
        }
        return .namespace_unavailable;
    };
    if (std.os.windows.GetLastError() == .ALREADY_EXISTS) {
        // Another instance created it first. Drop our handle (the winner's
        // handle keeps the mutex alive) and report the conflict.
        std.os.windows.CloseHandle(handle);
        return .already_running;
    }
    return .{ .acquired = handle };
}

/// Resolve a stable per-user identity string for the mutex suffix, into `buf`:
/// the current process token's user SID (canonical — identical across ALL of
/// the user's logon sessions, elevated or not), else the bare username from
/// `GetUserNameW`. Null when both fail (caller falls back to `Local\`).
fn windowsUserId(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) unreachable;

    sid: {
        var tok: std.os.windows.HANDLE = undefined;
        if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &tok) == 0) break :sid;
        defer std.os.windows.CloseHandle(tok);

        // TOKEN_USER (16 bytes on x64) + SECURITY_MAX_SID_SIZE (68) ≤ 128.
        var info_buf: [128]u8 align(8) = undefined;
        var ret_len: u32 = 0;
        if (win32.GetTokenInformation(tok, win32.TokenUser, &info_buf, info_buf.len, &ret_len) == 0) break :sid;
        const tu: *const win32.TOKEN_USER = @ptrCast(&info_buf);

        var sid_w: ?[*:0]u16 = null;
        if (win32.ConvertSidToStringSidW(tu.User.Sid, &sid_w) == 0) break :sid;
        const s = sid_w orelse break :sid;
        defer _ = win32.LocalFree(s);

        const n = std.unicode.utf16LeToUtf8(buf, std.mem.span(s)) catch break :sid;
        if (n == 0) break :sid;
        return buf[0..n];
    }

    // Fallback: username. Less canonical than the SID (renames, collisions
    // across domains) but still per-user and cross-session.
    var name_w: [257]u16 = undefined;
    var len: u32 = name_w.len;
    if (win32.GetUserNameW(&name_w, &len) == 0) return null;
    if (len <= 1) return null; // len includes the terminating NUL
    const n = std.unicode.utf16LeToUtf8(buf, name_w[0 .. len - 1]) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

const win32 = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    const TOKEN_QUERY: u32 = 0x0008;
    const TokenUser: c_int = 1; // TOKEN_INFORMATION_CLASS
    const SYNCHRONIZE: u32 = 0x0010_0000;

    const SID_AND_ATTRIBUTES = extern struct {
        Sid: *anyopaque,
        Attributes: u32,
    };
    const TOKEN_USER = extern struct {
        User: SID_AND_ATTRIBUTES,
    };

    extern "kernel32" fn CreateMutexW(
        lpMutexAttributes: ?*anyopaque,
        bInitialOwner: windows.BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn OpenMutexW(
        dwDesiredAccess: u32,
        bInheritHandle: windows.BOOL,
        lpName: [*:0]const u16,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn OpenProcessToken(
        ProcessHandle: windows.HANDLE,
        DesiredAccess: u32,
        TokenHandle: *windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetTokenInformation(
        TokenHandle: windows.HANDLE,
        TokenInformationClass: c_int,
        TokenInformation: ?*anyopaque,
        TokenInformationLength: u32,
        ReturnLength: *u32,
    ) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn ConvertSidToStringSidW(
        Sid: *anyopaque,
        StringSid: *?[*:0]u16,
    ) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetUserNameW(
        lpBuffer: [*]u16,
        pcbBuffer: *u32,
    ) callconv(.winapi) windows.BOOL;

    // --- takeover protocol ---
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const PROCESS_TERMINATE: u32 = 0x0001;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: u32,
        bInheritHandle: windows.BOOL,
        dwProcessId: u32,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn TerminateProcess(
        hProcess: windows.HANDLE,
        uExitCode: c_uint,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn QueryFullProcessImageNameW(
        hProcess: windows.HANDLE,
        dwFlags: u32,
        lpExeName: [*]u16,
        lpdwSize: *u32,
    ) callconv(.winapi) windows.BOOL;
} else struct {};

// -----------------------------------------------------------------------------
// POSIX: flock on a per-user lock file
// -----------------------------------------------------------------------------

/// Resolve `role`'s lock-file path (POSIX only):
///   1. `GHOSTTY_AGENT_LOCK` — an explicit full path, used VERBATIM for
///      whichever role reads it (it names one daemon; see the module doc),
///   2. `$XDG_CONFIG_HOME/ghoztty/<file>`,
///   3. `$HOME/.config/ghoztty/<file>`,
/// where `<file>` is `agent.lock` (relay) or `agent.<role>.lock`.
/// Same directory family as `enroll.relayEnvPath` so all agent state cohabits.
/// Owned by the caller.
pub fn lockFilePath(alloc: Allocator, role: Role) ![]u8 {
    if (try envOverride(alloc, "GHOSTTY_AGENT_LOCK")) |p| return p;
    return defaultStatePath(alloc, role, "lock");
}

/// A non-empty env override, owned by the caller; null when unset or empty.
fn envOverride(alloc: Allocator, name: []const u8) !?[]u8 {
    const p = std.process.getEnvVarOwned(alloc, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    if (p.len > 0) return p;
    alloc.free(p);
    return null;
}

/// `role`'s default per-user state file with extension `ext`:
/// `%LOCALAPPDATA%\ghoztty\` on Windows (same dir as relay.env), else
/// `$XDG_CONFIG_HOME|~/.config` + `/ghoztty/`. Owned by the caller.
fn defaultStatePath(alloc: Allocator, role: Role, ext: []const u8) ![]u8 {
    var name_buf: [64]u8 = undefined;
    const name = role.fileName(&name_buf, ext);
    if (builtin.os.tag == .windows) {
        const local = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
        defer alloc.free(local);
        return std.fs.path.join(alloc, &.{ local, "ghoztty", name });
    }
    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
        defer alloc.free(xdg);
        if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ghoztty", name });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".config", "ghoztty", name });
}

/// Open (creating as needed) `path` and take an exclusive, non-blocking
/// advisory flock on it. POSIX only. Split out from `acquire` so tests can
/// point two independent open-file-descriptions at one temp path.
pub fn acquirePath(path: []const u8) AcquireError!Guard {
    if (builtin.os.tag == .windows) unreachable;
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return error.GuardUnavailable;
    }
    const file = std.fs.cwd().createFile(path, .{
        .truncate = false, // never clobber; contents are irrelevant, the lock gates
        .read = true,
    }) catch return error.GuardUnavailable;
    errdefer file.close(); // any error return below must not leak the fd

    std.posix.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| {
        return switch (err) {
            error.WouldBlock => error.AlreadyRunning,
            else => error.GuardUnavailable,
        };
    };
    return .{ .impl = .{ .fd = file.handle } };
}

// -----------------------------------------------------------------------------
// Takeover — "there should be only one" (see the module doc §Takeover)
// -----------------------------------------------------------------------------

/// How often the guard HOLDER touches the heartbeat file.
pub const heartbeat_interval_ms: u64 = 10_000;
/// A heartbeat older than this marks the holder unresponsive (4.5 missed
/// beats — generous enough for a paging stall, far below human patience).
pub const heartbeat_stale_after_ms: i64 = 45_000;
/// Post-kill guard re-acquisition: attempts × delay (the OS frees the
/// mutex/flock with the dying process; 1s total is ample).
const takeover_retry_attempts = 5;
const takeover_retry_delay_ms = 200;

/// Result of the best-effort "does this PID still name a ghoztty-agent?"
/// probe that gates a kill (PID-reuse friendly-fire protection).
pub const ImageCheck = enum {
    /// PID resolves to an image whose basename starts with `ghoztty-agent`.
    confirmed_agent,
    /// PID resolves to some OTHER image: never kill it.
    confirmed_other,
    /// Couldn't resolve (no API, no permission, process gone).
    unavailable,
};

/// What a challenger that lost the guard race should do about the holder.
pub const Verdict = enum {
    /// Holder is (presumed) alive and responsive: exit 183 as always.
    yield,
    /// Holder is stuck/anomalous and safely identified: kill it, then retry
    /// the guard.
    kill_and_take,
    /// Anomaly detected but killing is unsafe (unidentified holder / foreign
    /// PID): log loudly and exit 183 — when in doubt, never two daemons.
    die,
};

/// The holder's role relative to the challenger's, as far as it can be
/// established (`resolveHolderRole`). Only `.same` may ever be killed.
pub const HolderRole = enum { same, different, unknown };

/// Establish the holder's role relative to `ours` — pure, unit-tested. In
/// order of authority:
///   1. `heartbeat_role`: the `role=` line the holder wrote itself;
///   2. `argv_role`: what the holder process was launched as (a pre-role
///      build writes no `role=` line, but its argv still says `--relay`);
///   3. `heartbeat_path_is_default`: the heartbeat came from `ours`'s own
///      DEFAULT (role-scoped) path, not an override — so it is this role's
///      file by construction. This is the only signal on Windows, where no
///      argv probe exists.
/// Anything else is `.unknown`, which is never killed: an override path
/// proves nothing about who wrote it (it can be inherited from another
/// daemon's environment — the module doc's §Takeover never crosses roles).
pub fn resolveHolderRole(
    ours: Role,
    heartbeat_role: ?Role,
    argv_role: ?Role,
    heartbeat_path_is_default: bool,
) HolderRole {
    if (heartbeat_role orelse argv_role) |r| return if (r == ours) .same else .different;
    return if (heartbeat_path_is_default) .same else .unknown;
}

/// THE takeover decision matrix for a holder of the SAME role — kept with its
/// original signature (and tests); see `takeoverVerdictForRole`.
pub fn takeoverVerdict(
    force: bool,
    heartbeat_age_ms: ?i64,
    image: ImageCheck,
    stale_after_ms: i64,
) Verdict {
    return takeoverVerdictForRole(force, heartbeat_age_ms, image, .same, stale_after_ms);
}

/// THE takeover decision matrix — pure, unit-tested. Caller contract: only
/// invoked while the guard is verifiably still held (the caller re-attempts
/// acquisition immediately before asking), which is what makes killing on an
/// `unavailable` image check acceptable: a stale heartbeat AND a genuinely
/// held guard is a real anomaly, not a leftover file.
///
///   heartbeat_age_ms == null  → no/unreadable heartbeat file: an old-binary
///     holder or a racing first run — nobody safe to kill. Yield (die under
///     `force`, which promised a replacement it can't deliver).
///   image == .confirmed_other → PID reuse: never friendly-fire, even forced.
///   holder != .same           → another role's daemon (or one we can't
///     place): never killed, even forced or stale. A fresh unforced case is a
///     plain yield; anything that would otherwise have killed is a `die`, so
///     the refusal is logged.
///   force                     → skip the freshness check, kill the holder.
///   fresh (< stale_after_ms)  → responsive primary: yield.
///   stale                     → kill and take over.
pub fn takeoverVerdictForRole(
    force: bool,
    heartbeat_age_ms: ?i64,
    image: ImageCheck,
    holder: HolderRole,
    stale_after_ms: i64,
) Verdict {
    const age = heartbeat_age_ms orelse return if (force) .die else .yield;
    if (image == .confirmed_other) return .die;
    if (holder != .same) return if (!force and age < stale_after_ms) .yield else .die;
    if (force) return .kill_and_take;
    if (age < stale_after_ms) return .yield;
    return .kill_and_take;
}

/// `acquire` + the takeover protocol: on AlreadyRunning, probe the holder's
/// heartbeat and either yield (`error.AlreadyRunning`), or kill a stuck /
/// force-replaced holder OF THE SAME ROLE and take the guard. This is what the
/// daemon modes call; `acquire` remains the raw primitive.
pub fn acquireWithTakeover(alloc: Allocator, role: Role, force: bool) AcquireError!Guard {
    const lock_path: ?[]u8 = if (builtin.os.tag == .windows)
        null
    else
        lockFilePath(alloc, role) catch return error.GuardUnavailable;
    defer if (lock_path) |p| alloc.free(p);
    const hb_loc = heartbeatLocation(alloc, role) catch null;
    defer if (hb_loc) |l| alloc.free(l.path);
    return takeoverAt(alloc, role, force, lock_path, hb_loc, .{});
}

/// The holder probes `takeoverAt` consults. Real by default; a test swaps the
/// image check, because no test can launch a process whose image is really
/// named `ghoztty-agent…` (a copied binary is killed by code signing).
pub const Probes = struct {
    checkPidImage: *const fn (i32) ImageCheck = checkPidImage,
    pidRole: *const fn (Allocator, i32) ?Role = pidRole,
};

/// Take `role`'s guard (the flock at `lock_path` on POSIX; the role's named
/// mutex on Windows, where `lock_path` is null), running the takeover
/// protocol against the heartbeat at `hb_loc` on contention. The resolved-
/// path core of `acquireWithTakeover`, so tests can aim it at temp files.
pub fn takeoverAt(
    alloc: Allocator,
    role: Role,
    force: bool,
    lock_path: ?[]const u8,
    hb_loc: ?HeartbeatLocation,
    probes: Probes,
) AcquireError!Guard {
    const acquireIt = struct {
        fn f(r: Role, p: ?[]const u8) AcquireError!Guard {
            if (builtin.os.tag == .windows) return acquireWindows(r);
            return acquirePath(p.?);
        }
    }.f;

    if (acquireIt(role, lock_path)) |g| return g else |err| switch (err) {
        error.AlreadyRunning => {},
        error.GuardUnavailable => return error.GuardUnavailable,
    }

    // Probe the holder: heartbeat (PID + role + age), what that PID runs
    // today, and what it was launched as.
    const hb: ?HeartbeatInfo = if (hb_loc) |l| readHeartbeat(l.path) else null;
    const image: ImageCheck = if (hb) |h| probes.checkPidImage(h.pid) else .unavailable;
    const holder: HolderRole = if (hb) |h| resolveHolderRole(
        role,
        h.role,
        probes.pidRole(alloc, h.pid),
        hb_loc.?.is_default,
    ) else .unknown;

    // Re-probe the guard right before deciding: (a) the holder may have
    // exited since the first attempt — then we just take over, no kill —
    // and (b) it upholds takeoverVerdict's "guard genuinely still held"
    // contract for the unverifiable-image kill.
    if (acquireIt(role, lock_path)) |g| return g else |err| switch (err) {
        error.AlreadyRunning => {},
        error.GuardUnavailable => return error.GuardUnavailable,
    }

    if (hb != null and holder == .different) {
        // The one way two roles meet on one guard is an exact-path override
        // shared between them — almost always inherited from the other
        // daemon's environment. Say so: the bare "already running" sent a
        // live diagnosis down the wrong road.
        std.debug.print(
            "ghoztty-agent: single-instance: the {s} guard is held by a different kind of agent (pid {d}); never replacing it. If GHOSTTY_AGENT_LOCK/GHOSTTY_AGENT_HEARTBEAT are set in this shell they were probably inherited from that agent — unset them.\n",
            .{ role.label(), hb.?.pid },
        );
    }

    switch (takeoverVerdictForRole(force, if (hb) |h| h.age_ms else null, image, holder, heartbeat_stale_after_ms)) {
        .yield => return error.AlreadyRunning,
        .die => {
            std.debug.print(
                "ghoztty-agent: single-instance anomaly: guard held but the holder can't be safely replaced (heartbeat {s}, pid image {s}, holder role {s}); yielding — never two daemons\n",
                .{
                    if (hb != null) "present" else "missing",
                    @tagName(image),
                    @tagName(holder),
                },
            );
            return error.AlreadyRunning;
        },
        .kill_and_take => {
            const holder_hb = hb.?; // null heartbeat can never reach kill_and_take
            std.debug.print(
                "ghoztty-agent: single-instance: {s} holder pid {d} is {s} (heartbeat {d}ms old); killing it and taking over\n",
                .{ role.label(), holder_hb.pid, if (force) "being force-replaced" else "unresponsive", holder_hb.age_ms },
            );
            killPid(holder_hb.pid) catch |err| {
                std.debug.print("ghoztty-agent: single-instance: kill of pid {d} failed ({s}); yielding\n", .{ holder_hb.pid, @errorName(err) });
                return error.AlreadyRunning;
            };
            // The OS releases the mutex/flock as the holder dies — give it a
            // few beats, then insist on actually WINNING the guard.
            var attempt: usize = 0;
            while (attempt < takeover_retry_attempts) : (attempt += 1) {
                std.Thread.sleep(takeover_retry_delay_ms * std.time.ns_per_ms);
                if (acquireIt(role, lock_path)) |g| {
                    std.debug.print("ghoztty-agent: single-instance: takeover complete (replaced pid {d})\n", .{holder_hb.pid});
                    return g;
                } else |err| switch (err) {
                    error.AlreadyRunning => continue,
                    error.GuardUnavailable => return error.GuardUnavailable,
                }
            }
            std.debug.print(
                "ghoztty-agent: single-instance: guard still held {d}ms after killing pid {d}; yielding — never two daemons\n",
                .{ takeover_retry_attempts * takeover_retry_delay_ms, holder_hb.pid },
            );
            return error.AlreadyRunning;
        },
    }
}

// --- Heartbeat file ----------------------------------------------------------

/// Where `role`'s heartbeat lives, and whether that is the role-scoped default
/// (which proves the file is this role's — see `resolveHolderRole`) rather
/// than a `GHOSTTY_AGENT_HEARTBEAT` override (which proves nothing).
pub const HeartbeatLocation = struct { path: []u8, is_default: bool };

/// Resolve `role`'s heartbeat path: `GHOSTTY_AGENT_HEARTBEAT` (verbatim, like
/// the lock override), else `agent.heartbeat` (relay) / `agent.<role>.heartbeat`
/// next to the rest of the per-user agent state (`%LOCALAPPDATA%\ghoztty\`
/// on Windows — same dir as relay.env — and `$XDG_CONFIG_HOME|~/.config/ghoztty/`
/// on POSIX — same dir as the lock). `path` is owned by the caller.
pub fn heartbeatLocation(alloc: Allocator, role: Role) !HeartbeatLocation {
    if (try envOverride(alloc, "GHOSTTY_AGENT_HEARTBEAT")) |p| return .{ .path = p, .is_default = false };
    return .{ .path = try defaultStatePath(alloc, role, "heartbeat"), .is_default = true };
}

/// `heartbeatLocation`'s path alone. Owned by the caller.
pub fn heartbeatPath(alloc: Allocator, role: Role) ![]u8 {
    return (try heartbeatLocation(alloc, role)).path;
}

/// One heartbeat tick: (re)write the file with our PID and role
/// (`<pid>\nrole=<role>\n`; a null role writes the pre-role `<pid>\n`). The
/// WRITE is the liveness signal (it bumps mtime); the content identifies who
/// to kill when it goes stale, and whether that is ours to kill. Public +
/// path-parameterized so it's testable anywhere.
pub fn writeHeartbeat(path: []const u8, role: ?Role) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [64]u8 = undefined;
    const line = if (role) |r|
        std.fmt.bufPrint(&buf, "{d}\nrole={s}\n", .{ currentPid(), r.label() }) catch unreachable
    else
        std.fmt.bufPrint(&buf, "{d}\n", .{currentPid()}) catch unreachable;
    try file.writeAll(line);
}

pub const HeartbeatInfo = struct {
    pid: i32,
    age_ms: i64,
    /// The holder's self-declared role; null for a pre-role heartbeat (or an
    /// unrecognized role label, which is treated the same: unproven).
    role: ?Role = null,
};

/// Parse heartbeat content: a PID on the first line, then optional
/// `key=value` lines of which only `role=` is read. Null on a missing or
/// garbage PID. Pure; public for tests.
pub fn parseHeartbeat(content: []const u8) ?struct { pid: i32, role: ?Role } {
    var lines = std.mem.splitScalar(u8, content, '\n');
    const first = std.mem.trim(u8, lines.first(), " \t\r");
    const pid = std.fmt.parseInt(i32, first, 10) catch return null;
    if (pid <= 0) return null;
    var role: ?Role = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "role=")) role = Role.fromLabel(line["role=".len..]);
    }
    return .{ .pid = pid, .role = role };
}

/// Read + parse a heartbeat file: the holder's PID, role, and the file's
/// mtime age. Null on any problem (missing, unreadable, garbage PID) —
/// callers treat that as "no heartbeat" (old-binary holder rule). Public for
/// tests.
pub fn readHeartbeat(path: []const u8) ?HeartbeatInfo {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const st = file.stat() catch return null;
    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const parsed = parseHeartbeat(buf[0..n]) orelse return null;
    const age_ns = std.time.nanoTimestamp() - st.mtime;
    const age_ms_wide = @divTrunc(age_ns, std.time.ns_per_ms);
    const age_ms: i64 = std.math.cast(i64, @max(0, age_ms_wide)) orelse std.math.maxInt(i64);
    return .{ .pid = parsed.pid, .age_ms = age_ms, .role = parsed.role };
}

/// The holder's heartbeat writer: a daemon-lifetime thread touching the file
/// every `heartbeat_interval_ms`. Start it right after winning the guard.
/// Failures only cost takeover-ability, never the daemon (same availability-
/// first policy as the guard itself and the tray).
pub const Heartbeat = struct {
    alloc: Allocator,
    path: []u8,
    interval_ms: u64,
    /// Written into every beat so a challenger can tell whose file this is.
    role: ?Role,
    stop_ev: std.Thread.ResetEvent = .{},
    thread: ?std.Thread = null,

    /// Resolve the default path, write the first beat synchronously (so the
    /// file exists the moment the daemon is up), and spawn the ticker. Null
    /// (with a log) when any of that fails.
    pub fn start(alloc: Allocator, role: Role) ?*Heartbeat {
        const path = heartbeatPath(alloc, role) catch |err| {
            std.debug.print("ghoztty-agent: heartbeat path unavailable ({s}); takeover-by-challenger disabled\n", .{@errorName(err)});
            return null;
        };
        return startWithPath(alloc, path, heartbeat_interval_ms, role) orelse {
            alloc.free(path);
            return null;
        };
    }

    /// Test seam: explicit path (takes ownership on success) and interval.
    pub fn startWithPath(alloc: Allocator, path: []u8, interval_ms: u64, role: ?Role) ?*Heartbeat {
        const self = alloc.create(Heartbeat) catch return null;
        self.* = .{ .alloc = alloc, .path = path, .interval_ms = interval_ms, .role = role };
        writeHeartbeat(path, role) catch |err| {
            std.debug.print("ghoztty-agent: heartbeat write failed ({s}); takeover-by-challenger disabled\n", .{@errorName(err)});
            alloc.destroy(self);
            return null;
        };
        self.thread = std.Thread.spawn(.{}, Heartbeat.run, .{self}) catch |err| blk: {
            std.debug.print("ghoztty-agent: heartbeat thread spawn failed ({s}); heartbeat will go stale\n", .{@errorName(err)});
            break :blk null; // first beat exists; keep the daemon anyway
        };
        return self;
    }

    fn run(self: *Heartbeat) void {
        while (true) {
            if (self.stop_ev.timedWait(self.interval_ms * std.time.ns_per_ms)) |_| {
                return; // stopped
            } else |_| {}
            writeHeartbeat(self.path, self.role) catch {}; // transient FS hiccup: next tick retries
        }
    }

    /// Stop the ticker, remove the file (a clean exit shouldn't leave a
    /// corpse for challengers to ponder), and free. Tests + main's error
    /// paths; production daemons never stop.
    pub fn stopAndFree(self: *Heartbeat) void {
        self.stop_ev.set();
        if (self.thread) |t| t.join();
        std.fs.cwd().deleteFile(self.path) catch {};
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }
};

// --- PID probes (best-effort, per platform) ----------------------------------

/// Basename-of-image test shared by all platforms' `checkPidImage`: does it
/// start with `ghoztty-agent` (matches the exe, the .exe, and the test
/// binary)? Pure; public for tests.
pub fn imageLooksLikeAgent(image_path: []const u8) bool {
    const cut = std.mem.lastIndexOfAny(u8, image_path, "/\\");
    const base = if (cut) |i| image_path[i + 1 ..] else image_path;
    return std.ascii.startsWithIgnoreCase(base, "ghoztty-agent");
}

/// Which daemon role an agent command line runs as, or null when it is not a
/// guard-holding daemon (`--stdio`, `--enroll`, usage). `args` EXCLUDES
/// argv[0]. Mirrors `main.parseArgs`'s mode spellings (`--x <v>` and
/// `--x=<v>`). Pure; public for tests.
pub fn roleFromArgv(args: []const []const u8) ?Role {
    for (args) |a| {
        // `--enroll --relay=<url>` is the one-shot enrollment, not a daemon.
        if (std.mem.eql(u8, a, "--enroll")) return null;
    }
    for (args) |a| {
        if (flagIs(a, "--relay")) return .relay;
        if (flagIs(a, "--listen-unix")) return .listen_unix;
        if (flagIs(a, "--listen")) return .listen;
    }
    return null;
}

fn flagIs(arg: []const u8, flag: []const u8) bool {
    if (!std.mem.startsWith(u8, arg, flag)) return false;
    return arg.len == flag.len or arg[flag.len] == '=';
}

/// Split a macOS `KERN_PROCARGS2` buffer into argv (argv[0] included):
/// `int argc`, the exec path NUL-terminated, NUL padding, then `argc`
/// NUL-terminated strings (then the environment, which is not read). Fills
/// `out` and returns the used prefix; null on a malformed buffer. Pure;
/// public for tests.
pub fn parseProcArgs2(buf: []const u8, out: [][]const u8) ?[]const []const u8 {
    if (buf.len < @sizeOf(c_int)) return null;
    const argc_raw = std.mem.readInt(i32, buf[0..4], builtin.cpu.arch.endian());
    if (argc_raw < 0) return null;
    const argc: usize = @intCast(argc_raw);
    var i: usize = @sizeOf(c_int);
    // Exec path.
    i = (std.mem.indexOfScalarPos(u8, buf, i, 0) orelse return null);
    // NUL padding up to argv[0].
    while (i < buf.len and buf[i] == 0) i += 1;
    var n: usize = 0;
    while (n < argc and n < out.len) : (n += 1) {
        if (i >= buf.len) return null;
        const end = std.mem.indexOfScalarPos(u8, buf, i, 0) orelse buf.len;
        out[n] = buf[i..end];
        i = end + 1;
    }
    return out[0..n];
}

/// Best-effort: which daemon role is `pid` running as, read from its own
/// argv? Null when it can't be read (no API, process gone) or names no
/// daemon role. This identifies a holder whose heartbeat predates the
/// `role=` line.
fn pidRole(alloc: Allocator, pid: i32) ?Role {
    var argv_buf: [64][]const u8 = undefined;
    switch (builtin.os.tag) {
        .macos => {
            const max = 1 << 20; // kern.argmax on macOS
            const buf = alloc.alloc(u8, max) catch return null;
            defer alloc.free(buf);
            var mib = [_]c_int{ 1, 49, pid }; // CTL_KERN, KERN_PROCARGS2
            var len: usize = buf.len;
            if (darwin.sysctl(&mib, mib.len, buf.ptr, &len, null, 0) != 0) return null;
            const argv = parseProcArgs2(buf[0..len], &argv_buf) orelse return null;
            if (argv.len == 0) return null;
            return roleFromArgv(argv[1..]);
        },
        .linux => {
            var pbuf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&pbuf, "/proc/{d}/cmdline", .{pid}) catch return null;
            const data = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return null;
            defer alloc.free(data);
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, data, "\x00"), 0);
            while (it.next()) |a| {
                if (n == argv_buf.len) break;
                argv_buf[n] = a;
                n += 1;
            }
            if (n == 0) return null;
            return roleFromArgv(argv_buf[1..n]);
        },
        else => return null,
    }
}

/// Best-effort: what does `pid` run right now? See `ImageCheck`.
fn checkPidImage(pid: i32) ImageCheck {
    switch (builtin.os.tag) {
        .windows => {
            const h = win32.OpenProcess(
                win32.PROCESS_QUERY_LIMITED_INFORMATION,
                0,
                @intCast(pid),
            ) orelse return .unavailable;
            defer std.os.windows.CloseHandle(h);
            var buf16: [1024]u16 = undefined;
            var size: u32 = buf16.len;
            if (win32.QueryFullProcessImageNameW(h, 0, &buf16, &size) == 0) return .unavailable;
            var buf8: [3072]u8 = undefined;
            const n = std.unicode.utf16LeToUtf8(&buf8, buf16[0..size]) catch return .unavailable;
            return if (imageLooksLikeAgent(buf8[0..n])) .confirmed_agent else .confirmed_other;
        },
        .linux => {
            var pbuf: [64]u8 = undefined;
            const proc = std.fmt.bufPrint(&pbuf, "/proc/{d}/exe", .{pid}) catch return .unavailable;
            var tbuf: [std.fs.max_path_bytes]u8 = undefined;
            const target = std.fs.cwd().readLink(proc, &tbuf) catch return .unavailable;
            return if (imageLooksLikeAgent(target)) .confirmed_agent else .confirmed_other;
        },
        .macos => {
            var buf: [1024]u8 = undefined;
            const n = darwin.proc_pidpath(pid, &buf, buf.len);
            if (n <= 0) return .unavailable;
            return if (imageLooksLikeAgent(buf[0..@intCast(n)])) .confirmed_agent else .confirmed_other;
        },
        else => return .unavailable,
    }
}

/// Terminate `pid` (TerminateProcess / SIGKILL). Only ever called on a PID
/// `takeoverVerdict` approved.
fn killPid(pid: i32) !void {
    if (builtin.os.tag == .windows) {
        const h = win32.OpenProcess(win32.PROCESS_TERMINATE, 0, @intCast(pid)) orelse
            return error.OpenProcessFailed;
        defer std.os.windows.CloseHandle(h);
        if (win32.TerminateProcess(h, 1) == 0) return error.TerminateFailed;
        return;
    }
    try std.posix.kill(@intCast(pid), std.posix.SIG.KILL);
}

fn currentPid() i32 {
    return switch (builtin.os.tag) {
        .windows => @intCast(win32.GetCurrentProcessId()),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

const darwin = if (builtin.os.tag == .macos) struct {
    extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
    extern "c" fn sysctl(
        name: [*]c_int,
        namelen: c_uint,
        oldp: ?*anyopaque,
        oldlenp: ?*usize,
        newp: ?*anyopaque,
        newlen: usize,
    ) c_int;
} else struct {};

// -----------------------------------------------------------------------------
// Tests. The Windows MUTEX mechanics are compile-verified only (by the
// x86_64-windows-gnu agent build); the NAME composition is pure and tested
// here on every host. The flock mechanics are tested for real (POSIX).
// -----------------------------------------------------------------------------

test "takeover verdict: the full decision matrix" {
    const V = takeoverVerdict;
    const stale = heartbeat_stale_after_ms;
    const eq = std.testing.expectEqual;

    // No heartbeat file: old-binary holder / racing first run — treated as
    // responsive; force can't help (no PID on record → nobody safe to kill).
    try eq(Verdict.yield, V(false, null, .unavailable, stale));
    try eq(Verdict.die, V(true, null, .unavailable, stale));

    // Fresh heartbeat → responsive primary → yield (boundary: strict <).
    try eq(Verdict.yield, V(false, 0, .confirmed_agent, stale));
    try eq(Verdict.yield, V(false, stale - 1, .unavailable, stale));

    // Stale heartbeat → stuck holder → kill, when the PID is (confirmed_agent)
    // or may be (unavailable — guard-still-held is the caller's precondition)
    // an agent.
    try eq(Verdict.kill_and_take, V(false, stale, .confirmed_agent, stale));
    try eq(Verdict.kill_and_take, V(false, std.math.maxInt(i64), .unavailable, stale));

    // PID reuse friendly-fire guard: a pid confirmed to be some OTHER program
    // is never killed — not even under --force-replace.
    try eq(Verdict.die, V(false, std.math.maxInt(i64), .confirmed_other, stale));
    try eq(Verdict.die, V(true, 50, .confirmed_other, stale));

    // --force-replace skips the freshness check (kills a HEALTHY holder).
    try eq(Verdict.kill_and_take, V(true, 0, .confirmed_agent, stale));
    try eq(Verdict.kill_and_take, V(true, 0, .unavailable, stale));
}

test "image check: basename must start with ghoztty-agent" {
    try std.testing.expect(imageLooksLikeAgent("/usr/local/bin/ghoztty-agent"));
    try std.testing.expect(imageLooksLikeAgent("C:\\Program Files\\Ghoztty\\ghoztty-agent.exe"));
    try std.testing.expect(imageLooksLikeAgent("ghoztty-agent-test")); // the zig test binary
    try std.testing.expect(imageLooksLikeAgent("/opt/GHOZTTY-AGENT.exe")); // case-insensitive
    try std.testing.expect(!imageLooksLikeAgent("/usr/bin/python3"));
    try std.testing.expect(!imageLooksLikeAgent("/home/x/ghoztty-agent/README")); // dir name doesn't count
}

test "heartbeat: write/read roundtrip reports our pid, fresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "agent.heartbeat" });
    defer std.testing.allocator.free(path);

    try writeHeartbeat(path, .relay);
    const hb = readHeartbeat(path) orelse return error.HeartbeatUnreadable;
    try std.testing.expectEqual(currentPid(), hb.pid);
    try std.testing.expect(hb.age_ms >= 0);
    try std.testing.expect(hb.age_ms < heartbeat_stale_after_ms); // just written = fresh
}

test "heartbeat: missing or garbage file reads as no-heartbeat" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "agent.heartbeat" });
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(@as(?HeartbeatInfo, null), readHeartbeat(path)); // missing

    try tmp.dir.writeFile(.{ .sub_path = "agent.heartbeat", .data = "not-a-pid\n" });
    try std.testing.expectEqual(@as(?HeartbeatInfo, null), readHeartbeat(path));

    try tmp.dir.writeFile(.{ .sub_path = "agent.heartbeat", .data = "-5\n" });
    try std.testing.expectEqual(@as(?HeartbeatInfo, null), readHeartbeat(path));
}

test "heartbeat writer: first beat is synchronous, ticker recreates a deleted file, stop removes it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "agent.heartbeat" });
    // Ownership of `path` moves into the Heartbeat on success.

    const hb = Heartbeat.startWithPath(alloc, path, 10, .relay) orelse {
        alloc.free(path);
        return error.HeartbeatStartFailed;
    };
    // First beat happened before startWithPath returned.
    try std.testing.expect(readHeartbeat(hb.path) != null);

    // Prove the ticker ticks: delete the file and watch it come back.
    try tmp.dir.deleteFile("agent.heartbeat");
    var waited_ms: u64 = 0;
    while (readHeartbeat(hb.path) == null) {
        if (waited_ms > 5_000) return error.TickerNeverRewrote;
        std.Thread.sleep(10 * std.time.ns_per_ms);
        waited_ms += 10;
    }

    // Clean stop removes the corpse.
    const path_copy = try alloc.dupe(u8, hb.path);
    defer alloc.free(path_copy);
    hb.stopAndFree();
    try std.testing.expectEqual(@as(?HeartbeatInfo, null), readHeartbeat(path_copy));
}

test "global mutex name: SID suffix composes verbatim" {
    var buf: [256]u8 = undefined;
    const name = try composeGlobalMutexName(&buf, "S-1-5-21-3623811015-3361044348-30300820-1013");
    try std.testing.expectEqualStrings(
        "Global\\GhozttyAgentDaemon-S-1-5-21-3623811015-3361044348-30300820-1013",
        name,
    );
}

test "global mutex name: username fallback — backslash and control chars sanitized" {
    // A mutex name may not contain '\' past the namespace prefix; a
    // DOMAIN\user-shaped id must not smuggle one in (it would silently
    // create the object under a nested name).
    var buf: [256]u8 = undefined;
    const name = try composeGlobalMutexName(&buf, "CORP\\dzearing\x01");
    try std.testing.expectEqualStrings("Global\\GhozttyAgentDaemon-CORP_dzearing_", name);
    // Exactly one backslash total: the Global\ namespace separator.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, name, "\\"),
    );
}

test "global mutex name: oversized id errors instead of truncating" {
    var buf: [64]u8 = undefined;
    const long_id = "S-1-5-21-" ++ "9" ** 100;
    try std.testing.expectError(error.NameTooLong, composeGlobalMutexName(&buf, long_id));
}

test "flock guard: second acquire fails, release frees it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const lock_path = try std.fs.path.join(std.testing.allocator, &.{ path, "agent.lock" });
    defer std.testing.allocator.free(lock_path);

    // First acquire wins.
    var g1 = try acquirePath(lock_path);

    // Second acquire — a fresh open() of the same path is a fresh open-file-
    // description, so flock semantics here are IDENTICAL to a second process
    // contending for the lock (flock is per-OFD, not per-process).
    try std.testing.expectError(error.AlreadyRunning, acquirePath(lock_path));

    // Release the first; now the lock is free and a new acquire succeeds.
    g1.release();
    var g2 = try acquirePath(lock_path);
    g2.release();
}

/// Spawn a genuinely separate process (python3, present on macOS and every
/// Linux CI base) that tries to flock `lock_path` non-blocking. Returns its
/// exit code: 0 = child got the lock, 183 = child was refused. Returns
/// error.SkipZigTest when python3 is unavailable.
fn childTryLock(alloc: Allocator, lock_path: []const u8) !u32 {
    const script = try std.fmt.allocPrint(
        alloc,
        \\import fcntl,sys
        \\f=open('{s}','a')
        \\try:
        \\    fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        \\except OSError:
        \\    sys.exit(183)
        \\sys.exit(0)
    ,
        .{lock_path},
    );
    defer alloc.free(script);

    var child = std.process.Child.init(&.{ "python3", "-c", script }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.SkipZigTest; // no python3 → skip
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code,
        else => error.ChildDidNotExit,
    };
}

test "flock guard: two real processes — holder blocks the child, release frees it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const lock_path = try std.fs.path.join(alloc, &.{ dir_path, "agent.lock" });
    defer alloc.free(lock_path);

    // While THIS process holds the lock, a separate child process must be
    // refused (exits 183 — the same code the real daemon uses).
    var g = try acquirePath(lock_path);
    try std.testing.expectEqual(@as(u32, 183), try childTryLock(alloc, lock_path));

    // After release, a fresh child must win it (exit 0) — proving the lock,
    // not the file's existence, is what gates.
    g.release();
    try std.testing.expectEqual(@as(u32, 0), try childTryLock(alloc, lock_path));
}

// --- Roles -------------------------------------------------------------------

test "role names: relay keeps the legacy names, other roles are suffixed" {
    var buf: [64]u8 = undefined;
    const eqs = std.testing.expectEqualStrings;
    try eqs("agent.lock", Role.relay.fileName(&buf, "lock"));
    try eqs("agent.heartbeat", Role.relay.fileName(&buf, "heartbeat"));
    try eqs("agent.listen.lock", Role.listen.fileName(&buf, "lock"));
    try eqs("agent.listen-unix.lock", Role.listen_unix.fileName(&buf, "lock"));
    try eqs("agent.listen-unix.heartbeat", Role.listen_unix.fileName(&buf, "heartbeat"));

    var m: [128]u8 = undefined;
    const sid = "S-1-5-21-1-2-3-1013";
    try eqs("Global\\GhozttyAgentDaemon-S-1-5-21-1-2-3-1013", try composeRoleMutexName(&m, .relay, sid));
    try eqs("Global\\GhozttyAgentDaemon.listen-S-1-5-21-1-2-3-1013", try composeRoleMutexName(&m, .listen, sid));
    try eqs("Global\\GhozttyAgentDaemon.listen-unix-S-1-5-21-1-2-3-1013", try composeRoleMutexName(&m, .listen_unix, sid));
    try eqs("Local\\GhozttyAgentDaemon", try composeLocalMutexName(&m, .relay));
    try eqs("Local\\GhozttyAgentDaemon.listen", try composeLocalMutexName(&m, .listen));

    // The username fallback is sanitized per role exactly as before.
    try eqs("Global\\GhozttyAgentDaemon.listen-CORP_x", try composeRoleMutexName(&m, .listen, "CORP\\x"));
    // No user id can make one role's name another's: the relay name always
    // has '-' right after the base, every other role a '.'.
    var r: [128]u8 = undefined;
    const relay_named_like_listen = try composeRoleMutexName(&r, .relay, ".listen-S-1");
    try std.testing.expect(!std.mem.eql(
        u8,
        relay_named_like_listen,
        try composeRoleMutexName(&m, .listen, "S-1"),
    ));

    for (std.meta.tags(Role)) |role| try std.testing.expectEqual(role, Role.fromLabel(role.label()).?);
    try std.testing.expectEqual(@as(?Role, null), Role.fromLabel("bogus"));
}

/// The default lock path of `role` under a temp config dir — what `acquire`
/// resolves when no override is set.
fn testLockPath(alloc: Allocator, dir: []const u8, role: Role) ![]u8 {
    var buf: [64]u8 = undefined;
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", role.fileName(&buf, "lock") });
}

test "role guard: the same role excludes, different roles coexist" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("ghoztty");
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    const relay_path = try testLockPath(alloc, dir, .relay);
    defer alloc.free(relay_path);
    const unix_path = try testLockPath(alloc, dir, .listen_unix);
    defer alloc.free(unix_path);
    const listen_path = try testLockPath(alloc, dir, .listen);
    defer alloc.free(listen_path);

    // The session agent's guard is held — by a SEPARATE process, as it is live.
    var holder = try HolderProcess.start(alloc, unix_path, &.{"--listen-unix=/tmp/x.sock"});
    defer holder.stop();

    // A second session agent is refused (the dual-supervisor incident)...
    try std.testing.expectError(error.AlreadyRunning, acquirePath(unix_path));
    // ...while a relay agent and a TCP listen agent each get their own guard.
    var relay = try acquirePath(relay_path);
    defer relay.release();
    var listen = try acquirePath(listen_path);
    defer listen.release();
    // And a second relay agent is refused in turn.
    try std.testing.expectError(error.AlreadyRunning, acquirePath(relay_path));
    try std.testing.expectEqual(@as(u32, 183), try childTryLock(alloc, relay_path));
}

test "holder role: heartbeat line, then argv, then default path; else unknown" {
    const R = resolveHolderRole;
    const eq = std.testing.expectEqual;
    // The holder's own role= line wins over everything.
    try eq(HolderRole.same, R(.relay, .relay, .listen_unix, false));
    try eq(HolderRole.different, R(.relay, .listen_unix, .relay, true));
    // A pre-role heartbeat: the holder's argv decides.
    try eq(HolderRole.different, R(.relay, null, .listen_unix, true));
    try eq(HolderRole.same, R(.listen_unix, null, .listen_unix, false));
    // No role anywhere: only this role's own DEFAULT file proves it is ours
    // (Windows; self-update's respawn against a pre-role relay agent).
    try eq(HolderRole.same, R(.relay, null, null, true));
    // An override path proves nothing — it may be inherited.
    try eq(HolderRole.unknown, R(.relay, null, null, false));
}

test "takeover verdict: never across roles, not even forced or stale" {
    const V = takeoverVerdictForRole;
    const stale = heartbeat_stale_after_ms;
    const eq = std.testing.expectEqual;
    const old = std.math.maxInt(i64);
    for ([_]HolderRole{ .different, .unknown }) |h| {
        try eq(Verdict.die, V(true, 0, .confirmed_agent, h, stale)); // forced
        try eq(Verdict.die, V(false, old, .confirmed_agent, h, stale)); // stale
        try eq(Verdict.die, V(true, old, .unavailable, h, stale));
        try eq(Verdict.yield, V(false, 0, .confirmed_agent, h, stale)); // fresh: plain yield
    }
    // The same role behaves exactly as before roles existed.
    try eq(Verdict.kill_and_take, V(true, 0, .confirmed_agent, .same, stale));
    try eq(Verdict.kill_and_take, V(false, old, .unavailable, .same, stale));
    try eq(Verdict.yield, V(false, 0, .confirmed_agent, .same, stale));
    try eq(Verdict.die, V(true, old, .confirmed_other, .same, stale));
    try eq(Verdict.die, V(true, null, .unavailable, .same, stale));
}

test "heartbeat: role line roundtrip; a pre-role heartbeat parses with no role" {
    const eq = std.testing.expectEqual;
    const a = parseHeartbeat("123\nrole=listen-unix\n").?;
    try eq(@as(i32, 123), a.pid);
    try eq(@as(?Role, .listen_unix), a.role);
    const b = parseHeartbeat("456\n").?;
    try eq(@as(i32, 456), b.pid);
    try eq(@as(?Role, null), b.role);
    try eq(@as(?Role, null), parseHeartbeat("7\r\nrole=martian\r\n").?.role);
    try eq(@as(?Role, .relay), parseHeartbeat("7\r\nrole=relay\r\n").?.role);
    try std.testing.expect(parseHeartbeat("role=relay\n") == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "hb" });
    defer std.testing.allocator.free(path);
    try writeHeartbeat(path, .listen_unix);
    const hb = readHeartbeat(path).?;
    try eq(currentPid(), hb.pid);
    try eq(@as(?Role, .listen_unix), hb.role);
}

test "argv role: daemon flags in either spelling; enroll and stdio hold no guard" {
    const eq = std.testing.expectEqual;
    try eq(@as(?Role, .relay), roleFromArgv(&.{ "--relay=https://r", "--headless" }));
    try eq(@as(?Role, .relay), roleFromArgv(&.{ "--headless", "--relay", "https://r" }));
    try eq(@as(?Role, .listen_unix), roleFromArgv(&.{"--listen-unix=/x/agent.sock"}));
    try eq(@as(?Role, .listen), roleFromArgv(&.{ "--listen", "127.0.0.1:7777" }));
    try eq(@as(?Role, .listen), roleFromArgv(&.{"--listen=127.0.0.1:7777"}));
    try eq(@as(?Role, null), roleFromArgv(&.{ "--enroll", "--relay=https://r" }));
    try eq(@as(?Role, null), roleFromArgv(&.{"--stdio"}));
    try eq(@as(?Role, null), roleFromArgv(&.{"--relayx"}));
    try eq(@as(?Role, null), roleFromArgv(&.{}));
}

test "KERN_PROCARGS2 parse: argc, exec path, padding, argv" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var argc: [4]u8 = undefined;
    std.mem.writeInt(i32, &argc, 3, builtin.cpu.arch.endian());
    try w.writeAll(&argc);
    try w.writeAll("/Applications/G.app/ghoztty-agent\x00\x00\x00\x00");
    try w.writeAll("ghoztty-agent\x00--relay=https://r\x00--headless\x00HOME=/u\x00");
    var out: [8][]const u8 = undefined;
    const argv = parseProcArgs2(w.buffered(), &out).?;
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("ghoztty-agent", argv[0]);
    try std.testing.expectEqualStrings("--headless", argv[2]);
    try std.testing.expectEqual(@as(?Role, .relay), roleFromArgv(argv[1..]));
    try std.testing.expect(parseProcArgs2("ab", &out) == null);
}

test "argv role probe: reads a live process's own command line" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const lock = try std.fs.path.join(alloc, &.{ dir, "l" });
    defer alloc.free(lock);
    var holder = try HolderProcess.start(alloc, lock, &.{ "--relay=https://r", "--headless" });
    defer holder.stop();
    try std.testing.expectEqual(@as(?Role, .relay), pidRole(alloc, holder.pid()));

    // A process whose argv names no daemon role. (Not this test binary: the
    // zig test runner is itself launched with `--listen=-`.)
    const lock2 = try std.fs.path.join(alloc, &.{ dir, "l2" });
    defer alloc.free(lock2);
    var plain = try HolderProcess.start(alloc, lock2, &.{"--verbose"});
    defer plain.stop();
    try std.testing.expectEqual(@as(?Role, null), pidRole(alloc, plain.pid()));
}

// --- Takeover is role-scoped: real processes --------------------------------

/// A separate process (python3) that takes the flock at `lock_path` and holds
/// it until stopped, with `role_args` in its argv so the real argv probe
/// (`pidRole`) sees what a real agent's would. Its image is python, so these
/// tests swap only the IMAGE probe (`Probes.checkPidImage`) to claim it is an
/// agent — otherwise `confirmed_other` would refuse every kill and prove
/// nothing about roles.
const HolderProcess = struct {
    child: std.process.Child,
    script: []u8,
    alloc: Allocator,

    fn start(alloc: Allocator, lock_path: []const u8, role_args: []const []const u8) !HolderProcess {
        const script = try std.fmt.allocPrint(alloc,
            \\import fcntl,sys,time
            \\f=open('{s}','a')
            \\fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            \\sys.stdout.write('ready\n'); sys.stdout.flush()
            \\time.sleep(60)
        , .{lock_path});
        errdefer alloc.free(script);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.appendSlice(alloc, &.{ "python3", "-c", script });
        try argv.appendSlice(alloc, role_args);

        var child = std.process.Child.init(argv.items, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return error.SkipZigTest; // no python3 → skip
        var line: [16]u8 = undefined;
        const n = try child.stdout.?.read(&line);
        if (!std.mem.startsWith(u8, line[0..n], "ready")) {
            _ = child.kill() catch {};
            return error.HolderDidNotLock;
        }
        return .{ .child = child, .script = script, .alloc = alloc };
    }

    fn pid(self: *const HolderProcess) i32 {
        return @intCast(self.child.id);
    }

    /// Whether the holder is still running (it has not been killed).
    fn alive(self: *const HolderProcess) bool {
        std.posix.kill(self.child.id, 0) catch return false;
        // A killed-but-unreaped child is a zombie, which kill(0) still finds.
        var status: c_int = 0;
        return std.c.waitpid(self.child.id, &status, std.c.W.NOHANG) == 0;
    }

    fn stop(self: *HolderProcess) void {
        std.posix.kill(self.child.id, std.posix.SIG.KILL) catch {};
        var status: c_int = 0;
        _ = std.c.waitpid(self.child.id, &status, 0);
        self.alloc.free(self.script);
    }
};

fn claimAgentImage(_: i32) ImageCheck {
    return .confirmed_agent;
}

/// Write a heartbeat for `pid` at `path`, aged `age_s` seconds.
fn plantHeartbeat(path: []const u8, pid: i32, role: ?Role, age_s: i64) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [64]u8 = undefined;
    try file.writeAll(if (role) |r|
        try std.fmt.bufPrint(&buf, "{d}\nrole={s}\n", .{ pid, r.label() })
    else
        try std.fmt.bufPrint(&buf, "{d}\n", .{pid}));
    const t: i128 = (std.time.timestamp() - age_s) * std.time.ns_per_s;
    try file.updateTimes(t, t);
}

const TakeoverFixture = struct {
    alloc: Allocator,
    tmp: std.testing.TmpDir,
    lock: []u8,
    hb: []u8,

    fn init(alloc: Allocator) !TakeoverFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(dir);
        return .{
            .alloc = alloc,
            .tmp = tmp,
            .lock = try std.fs.path.join(alloc, &.{ dir, "agent.lock" }),
            .hb = try std.fs.path.join(alloc, &.{ dir, "agent.heartbeat" }),
        };
    }

    fn deinit(self: *TakeoverFixture) void {
        self.alloc.free(self.lock);
        self.alloc.free(self.hb);
        self.tmp.cleanup();
    }
};

test "takeover: a relay --force-replace with the session agent's inherited paths never kills it" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fx = try TakeoverFixture.init(alloc);
    defer fx.deinit();

    // The live incident: the session agent holds the overridden lock and
    // writes the overridden heartbeat — an OLDER build, so no role= line, and
    // stale for good measure. A relay agent started from one of its panes
    // inherited both paths, and is run with --force-replace.
    var session_agent = try HolderProcess.start(alloc, fx.lock, &.{"--listen-unix=/tmp/agent.sock"});
    defer session_agent.stop();
    try plantHeartbeat(fx.hb, session_agent.pid(), null, 3600);

    const hb_loc: HeartbeatLocation = .{ .path = fx.hb, .is_default = false };
    try std.testing.expectError(
        error.AlreadyRunning,
        takeoverAt(alloc, .relay, true, fx.lock, hb_loc, .{ .checkPidImage = claimAgentImage }),
    );
    try std.testing.expect(session_agent.alive());

    // Same with a NEW session agent, which declares its role itself.
    try plantHeartbeat(fx.hb, session_agent.pid(), .listen_unix, 3600);
    try std.testing.expectError(
        error.AlreadyRunning,
        takeoverAt(alloc, .relay, true, fx.lock, hb_loc, .{ .checkPidImage = claimAgentImage }),
    );
    try std.testing.expect(session_agent.alive());
}

test "takeover: an override path alone never licenses a kill" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fx = try TakeoverFixture.init(alloc);
    defer fx.deinit();

    // Pre-role heartbeat, a holder whose argv names no role: unknown.
    var holder = try HolderProcess.start(alloc, fx.lock, &.{});
    defer holder.stop();
    try plantHeartbeat(fx.hb, holder.pid(), null, 3600);
    try std.testing.expectError(error.AlreadyRunning, takeoverAt(
        alloc,
        .relay,
        true,
        fx.lock,
        .{ .path = fx.hb, .is_default = false },
        .{ .checkPidImage = claimAgentImage },
    ));
    try std.testing.expect(holder.alive());
}

test "takeover: the same role is still replaced — forced, and when stuck" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fx = try TakeoverFixture.init(alloc);
    defer fx.deinit();
    const probes: Probes = .{ .checkPidImage = claimAgentImage };

    // A healthy relay agent, force-replaced (the self-update respawn).
    {
        var old = try HolderProcess.start(alloc, fx.lock, &.{"--relay=https://r"});
        defer old.stop();
        try plantHeartbeat(fx.hb, old.pid(), .relay, 0);
        var g = try takeoverAt(alloc, .relay, true, fx.lock, .{ .path = fx.hb, .is_default = false }, probes);
        g.release();
        try std.testing.expect(!old.alive());
    }
    // A STUCK pre-role relay agent (no role= line), identified by its argv.
    {
        var old = try HolderProcess.start(alloc, fx.lock, &.{"--relay=https://r"});
        defer old.stop();
        try plantHeartbeat(fx.hb, old.pid(), null, 3600);
        var g = try takeoverAt(alloc, .relay, false, fx.lock, .{ .path = fx.hb, .is_default = false }, probes);
        g.release();
        try std.testing.expect(!old.alive());
    }
    // A pre-role holder with no readable role, but at the role's own DEFAULT
    // heartbeat path: that file is the relay role's by construction.
    {
        var old = try HolderProcess.start(alloc, fx.lock, &.{});
        defer old.stop();
        try plantHeartbeat(fx.hb, old.pid(), null, 0);
        var g = try takeoverAt(alloc, .relay, true, fx.lock, .{ .path = fx.hb, .is_default = true }, probes);
        g.release();
        try std.testing.expect(!old.alive());
    }
    // ...and a FRESH same-role holder without --force-replace is left alone.
    {
        var live = try HolderProcess.start(alloc, fx.lock, &.{"--relay=https://r"});
        defer live.stop();
        try plantHeartbeat(fx.hb, live.pid(), .relay, 0);
        try std.testing.expectError(error.AlreadyRunning, takeoverAt(
            alloc,
            .relay,
            false,
            fx.lock,
            .{ .path = fx.hb, .is_default = false },
            probes,
        ));
        try std.testing.expect(live.alive());
    }
}
