//! Spawning a process that must OUTLIVE this one — i.e. escaping the Windows
//! job object this process sits in.
//!
//! Extracted from `relaunch_guard.zig` (T524) so the local agent can use the
//! same escape (T426). The two callers want the identical thing and for the
//! identical reason: a child joins its parent's job by default, this box's jobs
//! are kill-on-close, and a job teardown kills every member at once. A
//! supervisor that shares its subject's fate supervises nothing, and a daemon
//! that shares the app's fate is not a daemon. `DETACHED_PROCESS` does not
//! leave a job; only the tiers below do.
//!
//!  1. `CREATE_BREAKAWAY_FROM_JOB` — the clean escape, a no-op for a jobless
//!     caller. Refused with ACCESS_DENIED when ANY job in the caller's chain
//!     forbids breakaway — which is the MEASURED reality on this box (the
//!     pane-shell job chain refuses it; verified live 2026-08-06), so this
//!     tier alone would have fixed nothing.
//!  2. Parent-process hop: spawn with `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`
//!     pointing at the shell (explorer). Job membership follows the ACTUAL
//!     parent used for inheritance, so the child lands in the shell's (safe)
//!     job context instead of ours — no breakaway permission involved. The
//!     environment is passed EXPLICITLY, because with a spoofed parent the
//!     child would otherwise be handed the SHELL's environment, and both
//!     callers carry meaning in theirs (the guard's spec variable; the agent's
//!     test seams and `LOCALAPPDATA`).
//!  3. Jobless-donor hop: the same parent-process trick, but the donor is
//!     found by ENUMERATING processes instead of by asking for the shell's
//!     window. `GetShellWindow()` is desktop-scoped — it answers nothing on a
//!     background desktop, from a service, or from a scheduled task — while
//!     explorer (and three dozen other jobless processes) are still right
//!     there in the session, openable and perfectly good parents (T674).
//!     Tier 2 stays ahead of it because it is one call rather than a full
//!     snapshot; this tier is what makes the escape unconditional.
//!  4. Inside the job, loudly: degraded, never absent. A jailed child still
//!     covers every death that is not a job teardown.
//!
//! Which tier fired is returned as well as logged, because "the child escaped"
//! and "the child is jailed with us" are different states and the next
//! incident's log has to say which one it had.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oswin = @import("../../os/windows.zig");

const log = std.log.scoped(.win32_job_spawn);

pub const DETACHED_PROCESS: std.os.windows.DWORD = 0x00000008;
pub const CREATE_NEW_PROCESS_GROUP: std.os.windows.DWORD = 0x00000200;
pub const CREATE_NO_WINDOW: std.os.windows.DWORD = 0x08000000;
pub const CREATE_BREAKAWAY_FROM_JOB: std.os.windows.DWORD = 0x01000000;

const PROCESS_CREATE_PROCESS: std.os.windows.DWORD = 0x0080;
/// ProcThreadAttributeValue(ProcThreadAttributeParentProcess=0, false, true, false)
const PROC_THREAD_ATTRIBUTE_PARENT_PROCESS: std.os.windows.DWORD = 0x00020000;

/// How the child got out — or that it did not.
pub const Tier = enum {
    /// `CREATE_BREAKAWAY_FROM_JOB` was accepted: the child is in no job of ours.
    breakaway,
    /// The shell adopted it, so it is in the shell's job context, not ours.
    shell_parent,
    /// A jobless process found by enumeration adopted it — the headless
    /// equivalent of `shell_parent`, and the tier that fires where there is
    /// no shell window to ask for (T674).
    jobless_parent,
    /// Still inside our job: a teardown that kills us kills it too.
    in_job,

    /// One word for a log line. `escaped` is deliberately NOT collapsed into a
    /// bool — a reader wants to know which mechanism, so the next incident can
    /// be told apart from this one.
    pub fn name(self: Tier) []const u8 {
        return switch (self) {
            .breakaway => "breakaway",
            .shell_parent => "shell-parent",
            .jobless_parent => "jobless-parent",
            .in_job => "IN-JOB (degraded)",
        };
    }

    pub fn escaped(self: Tier) bool {
        return self != .in_job;
    }
};

pub const Spawned = struct {
    pi: std.os.windows.PROCESS_INFORMATION,
    tier: Tier,
};

/// Tiers 1–2 only: succeed ONLY with a child that actually got OUT of the
/// caller's job. `error.NoEscape` when neither tier can — and no child exists
/// in that case, which is the property the startup self-escape (T675) needs:
/// an app deciding whether to hand itself off to a twin must never create a
/// twin that is jailed right beside it.
///
/// The caller owns `pi.hProcess`/`pi.hThread` and must close them.
pub fn spawnEscapedOnly(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
    tag: []const u8,
) !Spawned {
    const windows = std.os.windows;

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;

    if (oswin.exp.kernel32.CreateProcessW(
        null,
        cmd_w,
        null,
        null,
        windows.FALSE,
        base | CREATE_BREAKAWAY_FROM_JOB,
        null,
        null,
        &si,
        &pi,
    ) != 0) return .{ .pi = pi, .tier = .breakaway };

    const breakaway_err = windows.kernel32.GetLastError();
    log.warn(
        "{s}: breakaway spawn refused err={}; trying the shell-parent hop",
        .{ tag, breakaway_err },
    );

    if (spawnViaShellParent(arena, cmd_w, base, tag)) |shell_pi| {
        return .{ .pi = shell_pi, .tier = .shell_parent };
    } else |err| {
        log.warn("{s}: shell-parent spawn unavailable err={}", .{ tag, err });
    }

    if (spawnViaJoblessDonor(arena, cmd_w, base, tag)) |donor_pi| {
        return .{ .pi = donor_pi, .tier = .jobless_parent };
    } else |err| {
        log.warn("{s}: jobless-donor spawn unavailable err={}", .{ tag, err });
        return error.NoEscape;
    }
}

/// Spawn `cmd_w` with `base` flags, escaping the caller's job object if it can.
/// `tag` prefixes every log line so two callers' trails stay tellable apart.
///
/// The caller owns `pi.hProcess`/`pi.hThread` and must close them.
pub fn spawnEscapingJob(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
    tag: []const u8,
) !Spawned {
    const windows = std.os.windows;

    if (spawnEscapedOnly(arena, cmd_w, base, tag)) |spawned| {
        return spawned;
    } else |_| {
        log.warn(
            "{s}: spawning INSIDE the job (a job teardown that kills us kills this child too)",
            .{tag},
        );
    }

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;

    if (oswin.exp.kernel32.CreateProcessW(
        null,
        cmd_w,
        null,
        null,
        windows.FALSE,
        base,
        null,
        null,
        &si,
        &pi,
    ) != 0) return .{ .pi = pi, .tier = .in_job };

    log.warn("{s}: CreateProcessW failed err={}", .{ tag, windows.kernel32.GetLastError() });
    return error.SpawnFailed;
}

/// Tier 2: create the child with the SHELL (explorer) as its inheritance
/// parent, which places it in the shell's job context rather than ours. Every
/// failure here is an error return, never fatal — the caller falls back.
fn spawnViaShellParent(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
    tag: []const u8,
) !std.os.windows.PROCESS_INFORMATION {
    const windows = std.os.windows;

    const shell_hwnd = GetShellWindow() orelse return error.NoShellWindow;
    var shell_pid: windows.DWORD = 0;
    _ = GetWindowThreadProcessId(shell_hwnd, &shell_pid);
    if (shell_pid == 0) return error.NoShellWindow;

    const parent = OpenProcess(PROCESS_CREATE_PROCESS, windows.FALSE, shell_pid) orelse
        return error.OpenShellDenied;
    defer windows.CloseHandle(parent);

    return spawnWithParent(arena, cmd_w, base, tag, parent, "shell-parent", shell_pid);
}

/// The shared half of tiers 2 and 3: create `cmd_w` with `parent` as its
/// inheritance parent. `donor_label`/`donor_pid` name the donor in the log,
/// because "which process adopted the daemon" is the first question of the
/// next incident.
fn spawnWithParent(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
    tag: []const u8,
    parent: std.os.windows.HANDLE,
    donor_label: []const u8,
    donor_pid: std.os.windows.DWORD,
) !std.os.windows.PROCESS_INFORMATION {
    const windows = std.os.windows;

    var attr_size: windows.SIZE_T = 0;
    _ = oswin.exp.kernel32.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_buf = try arena.alloc(u8, attr_size);
    if (oswin.exp.kernel32.InitializeProcThreadAttributeList(attr_buf.ptr, 1, 0, &attr_size) == 0)
        return error.AttrListFailed;
    var parent_handle: windows.HANDLE = parent;
    if (oswin.exp.kernel32.UpdateProcThreadAttribute(
        attr_buf.ptr,
        0,
        PROC_THREAD_ATTRIBUTE_PARENT_PROCESS,
        @ptrCast(&parent_handle),
        @sizeOf(windows.HANDLE),
        null,
        null,
    ) == 0) return error.AttrListFailed;

    // A spoofed parent would otherwise donate the SHELL's environment to the
    // child, so pass ours explicitly.
    const env = GetEnvironmentStringsW() orelse return error.NoEnvironment;
    defer _ = FreeEnvironmentStringsW(env);

    var siex: oswin.exp.STARTUPINFOEX = .{
        .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW),
        .lpAttributeList = attr_buf.ptr,
    };
    siex.StartupInfo.cb = @sizeOf(oswin.exp.STARTUPINFOEX);

    var pi: windows.PROCESS_INFORMATION = undefined;
    if (oswin.exp.kernel32.CreateProcessW(
        null,
        cmd_w,
        null,
        null,
        windows.FALSE,
        base | oswin.exp.EXTENDED_STARTUPINFO_PRESENT | oswin.exp.CREATE_UNICODE_ENVIRONMENT,
        env,
        null,
        &siex.StartupInfo,
        &pi,
    ) == 0) {
        log.warn("{s}: {s} CreateProcessW failed err={}", .{
            tag,
            donor_label,
            windows.kernel32.GetLastError(),
        });
        return error.ParentSpawnFailed;
    }
    log.info("{s}: escaped the job via {s} spawn (parent pid {d})", .{ tag, donor_label, donor_pid });
    return pi;
}

// =============================================================================
// Tier 3: a jobless donor found by enumeration (T674)
// =============================================================================

/// One process the enumeration offered as a possible inheritance parent.
pub const Donor = struct {
    pid: u32,
    /// Image name as Toolhelp32 reports it, e.g. `explorer.exe`.
    name: []const u8,
};

/// Donors we ask for BY NAME before anything else, best first. Ordering these
/// is not about capability — any jobless process in our session works, and the
/// handle is only used for the one `CreateProcessW` call, so the donor may
/// exit a millisecond later without touching the child. It is about landing on
/// the SAME donor tier 2 would have used when tier 2 could see it, so a
/// headless run and a desktop run produce the same process tree.
const preferred_donors = [_][]const u8{
    "explorer.exe",
    "sihost.exe",
    "taskhostw.exe",
    "ctfmon.exe",
    "RuntimeBroker.exe",
};

/// Lower sorts earlier. Everything unknown shares one middling rank; our own
/// images sort LAST — a sibling ghoztty or agent is a legal donor (it is
/// jobless, or the jobless check drops it) but parenting the daemon off the
/// very process family whose fate it must not share reads as a mistake in
/// every process tree that shows it.
pub fn donorRank(name: []const u8) u8 {
    for (preferred_donors, 0..) |preferred, i| {
        if (std.ascii.eqlIgnoreCase(name, preferred)) return @intCast(i);
    }
    if (name.len >= 7 and std.ascii.eqlIgnoreCase(name[0..7], "ghoztty")) return 254;
    return 200;
}

/// Sort order over candidates: rank first, then pid, so the choice is
/// deterministic across runs rather than "whatever Toolhelp32 listed first".
pub fn donorLessThan(_: void, a: Donor, b: Donor) bool {
    const ra = donorRank(a.name);
    const rb = donorRank(b.name);
    if (ra != rb) return ra < rb;
    return a.pid < b.pid;
}

/// Rank and order `donors` in place. Split out from the enumeration so the
/// choice is unit-testable without a live process table.
pub fn orderDonors(donors: []Donor) void {
    std.sort.pdq(Donor, donors, {}, donorLessThan);
}

/// Snapshot the process table as donor candidates. Returns an EMPTY slice when
/// Toolhelp32 fails, which the caller reads as "no donor" rather than as an
/// error worth reporting differently — either way tier 4 is next.
fn enumerateDonors(arena: Allocator) Allocator.Error![]Donor {
    const windows = std.os.windows;
    var list: std.ArrayListUnmanaged(Donor) = .empty;

    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == windows.INVALID_HANDLE_VALUE) return &.{};
    defer windows.CloseHandle(snap);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == 0) return &.{};
    while (true) {
        const wide = std.mem.sliceTo(&entry.szExeFile, 0);
        const name = std.unicode.utf16LeToUtf8Alloc(arena, wide) catch "";
        try list.append(arena, .{ .pid = entry.th32ProcessID, .name = name });
        if (Process32NextW(snap, &entry) == 0) break;
    }
    return list.items;
}

/// Tier 3: adopt the child out to any process in OUR session, running as US,
/// that is in no job at all. This is tier 2 with a wider search: the parent
/// hop itself is identical, only the way the donor is found changes.
fn spawnViaJoblessDonor(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
    tag: []const u8,
) !std.os.windows.PROCESS_INFORMATION {
    const windows = std.os.windows;

    const self_pid = GetCurrentProcessId();
    var self_session: windows.DWORD = 0;
    if (ProcessIdToSessionId(self_pid, &self_session) == 0) return error.NoSession;

    const self_sid = try tokenUserSid(arena, GetCurrentProcess());

    const donors = try enumerateDonors(arena);
    orderDonors(donors);

    for (donors) |donor| {
        // pid 0 is the idle process and 4 the system process; neither is ours
        // to open, and neither is a parent.
        if (donor.pid <= 4 or donor.pid == self_pid) continue;

        var session: windows.DWORD = 0;
        if (ProcessIdToSessionId(donor.pid, &session) == 0) continue;
        if (session != self_session) continue;

        const handle = OpenProcess(
            PROCESS_CREATE_PROCESS | PROCESS_QUERY_LIMITED_INFORMATION,
            windows.FALSE,
            donor.pid,
        ) orelse continue;
        // The handle matters only for the one CreateProcessW call below: job
        // membership and the token are decided at creation, so a donor that
        // exits a millisecond later cannot touch the child.
        defer windows.CloseHandle(handle);

        // A jobless donor is the whole point: adopting into ANOTHER job would
        // just trade our killer for someone else's.
        var in_job: windows.BOOL = 0;
        if (IsProcessInJob(handle, null, &in_job) == 0) continue;
        if (in_job != 0) continue;

        // The child inherits the DONOR's token, so a donor that is not us
        // would hand the daemon somebody else's identity — and with it a
        // different LOCALAPPDATA, a different profile, and no access to the
        // state it exists to own.
        const donor_sid = tokenUserSid(arena, handle) catch continue;
        if (EqualSid(self_sid, donor_sid) == 0) continue;

        if (spawnWithParent(arena, cmd_w, base, tag, handle, "jobless-parent", donor.pid)) |pi| {
            log.info("{s}: jobless donor was {s} (pid {d})", .{ tag, donor.name, donor.pid });
            return pi;
        } else |err| {
            log.warn("{s}: jobless donor {s} (pid {d}) refused err={}", .{
                tag,
                donor.name,
                donor.pid,
                err,
            });
        }
    }

    return error.NoJoblessDonor;
}

/// The SID of the user `proc` runs as. Allocated in `arena`; the returned
/// pointer points INTO that allocation, so it lives as long as the arena.
fn tokenUserSid(arena: Allocator, proc: std.os.windows.HANDLE) !*anyopaque {
    const windows = std.os.windows;

    var token: windows.HANDLE = undefined;
    if (OpenProcessToken(proc, TOKEN_QUERY, &token) == 0) return error.TokenOpenFailed;
    defer windows.CloseHandle(token);

    var needed: windows.DWORD = 0;
    _ = GetTokenInformation(token, TokenUser, null, 0, &needed);
    if (needed == 0) return error.TokenInfoFailed;
    const buf = try arena.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(@alignOf(*anyopaque)),
        needed,
    );
    if (GetTokenInformation(token, TokenUser, buf.ptr, needed, &needed) == 0)
        return error.TokenInfoFailed;
    const user: *const TOKEN_USER = @ptrCast(buf.ptr);
    return user.User.Sid;
}

extern "user32" fn GetShellWindow() callconv(.winapi) ?std.os.windows.HWND;
extern "user32" fn GetWindowThreadProcessId(
    hWnd: std.os.windows.HWND,
    lpdwProcessId: ?*std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.DWORD;
extern "kernel32" fn OpenProcess(
    dwDesiredAccess: std.os.windows.DWORD,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
extern "kernel32" fn FreeEnvironmentStringsW(penv: [*]u16) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
extern "kernel32" fn ProcessIdToSessionId(
    dwProcessId: std.os.windows.DWORD,
    pSessionId: *std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn IsProcessInJob(
    ProcessHandle: std.os.windows.HANDLE,
    JobHandle: ?std.os.windows.HANDLE,
    Result: *std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn OpenProcessToken(
    ProcessHandle: std.os.windows.HANDLE,
    DesiredAccess: std.os.windows.DWORD,
    TokenHandle: *std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn GetTokenInformation(
    TokenHandle: std.os.windows.HANDLE,
    TokenInformationClass: c_int,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: std.os.windows.DWORD,
    ReturnLength: *std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;
extern "advapi32" fn EqualSid(
    pSid1: *anyopaque,
    pSid2: *anyopaque,
) callconv(.winapi) std.os.windows.BOOL;

const PROCESS_QUERY_LIMITED_INFORMATION: std.os.windows.DWORD = 0x1000;
const TOKEN_QUERY: std.os.windows.DWORD = 0x0008;
const TokenUser: c_int = 1;
const TH32CS_SNAPPROCESS: std.os.windows.DWORD = 0x00000002;

const SID_AND_ATTRIBUTES = extern struct {
    Sid: *anyopaque,
    Attributes: std.os.windows.DWORD,
};
const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

const PROCESSENTRY32W = extern struct {
    dwSize: std.os.windows.DWORD,
    cntUsage: std.os.windows.DWORD,
    th32ProcessID: std.os.windows.DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: std.os.windows.DWORD,
    cntThreads: std.os.windows.DWORD,
    th32ParentProcessID: std.os.windows.DWORD,
    pcPriClassBase: i32,
    dwFlags: std.os.windows.DWORD,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(
    dwFlags: std.os.windows.DWORD,
    th32ProcessID: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn Process32FirstW(
    hSnapshot: std.os.windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn Process32NextW(
    hSnapshot: std.os.windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) std.os.windows.BOOL;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "a tier reports whether the child actually got out" {
    try testing.expect(Tier.breakaway.escaped());
    try testing.expect(Tier.shell_parent.escaped());
    // T674: the headless tier is an ESCAPE, not a degraded state. If this ever
    // reads false, a run with no shell window silently reports the daemon as
    // jailed while it is in fact out.
    try testing.expect(Tier.jobless_parent.escaped());
    try testing.expect(!Tier.in_job.escaped());
}

test "the shell's own process is the preferred jobless donor" {
    // Tier 3 exists because GetShellWindow is desktop-scoped, not because
    // explorer is a bad parent — so when the enumeration can see explorer, it
    // must pick the same donor tier 2 would have.
    try testing.expect(donorRank("explorer.exe") < donorRank("sihost.exe"));
    try testing.expect(donorRank("sihost.exe") < donorRank("SomeVendorTray.exe"));
    try testing.expect(donorRank("EXPLORER.EXE") == donorRank("explorer.exe"));
}

test "our own images are the donor of last resort" {
    // A daemon parented off the app family it must outlive reads as a mistake
    // in every process tree that shows it, even where it would work.
    try testing.expect(donorRank("ghoztty.exe") > donorRank("SomeVendorTray.exe"));
    try testing.expect(donorRank("ghoztty-agent.exe") > donorRank("SomeVendorTray.exe"));
}

test "donor order is deterministic, not whatever the snapshot listed first" {
    var donors = [_]Donor{
        .{ .pid = 900, .name = "ghoztty-agent.exe" },
        .{ .pid = 700, .name = "msedge.exe" },
        .{ .pid = 300, .name = "explorer.exe" },
        .{ .pid = 100, .name = "nvcontainer.exe" },
        .{ .pid = 500, .name = "ctfmon.exe" },
    };
    orderDonors(&donors);

    try testing.expectEqualStrings("explorer.exe", donors[0].name);
    try testing.expectEqualStrings("ctfmon.exe", donors[1].name);
    // Unranked donors tie on rank, so the pid breaks it: two runs on the same
    // box choose the same parent, which is what makes a process tree readable.
    try testing.expectEqual(@as(u32, 100), donors[2].pid);
    try testing.expectEqual(@as(u32, 700), donors[3].pid);
    try testing.expectEqualStrings("ghoztty-agent.exe", donors[4].name);
}

test "every tier names itself for the log" {
    // The in-job name must READ as the bad case: a log reader scanning for why
    // a daemon died with the app has to see it without decoding an enum.
    try testing.expectEqualStrings("breakaway", Tier.breakaway.name());
    try testing.expectEqualStrings("shell-parent", Tier.shell_parent.name());
    try testing.expectEqualStrings("jobless-parent", Tier.jobless_parent.name());
    try testing.expect(std.mem.indexOf(u8, Tier.in_job.name(), "IN-JOB") != null);
}
