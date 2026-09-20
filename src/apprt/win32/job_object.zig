//! What Windows job object are we in, and is that other process in it with us?
//!
//! T426. Four times now the app has ended cleanly — no WER record, no further
//! log line — inside `TerminateProcess(agent)` during the destructive agent
//! refresh. T524 established the mechanism that explains every one of them: the
//! processes here live inside kill-on-close job objects, and a job teardown
//! kills every member at once, which is also how four relaunch guards died
//! before executing one instruction.
//!
//! The leading hypothesis is that the app and the OLD agent share such a job.
//! Nobody has measured that, because at the instant it matters the app is
//! already dead. So the refresh MEASURES it first and writes it down: this
//! module answers, in one line the log can carry, whether we are in a job, what
//! that job's limit flags are, whether the other process is in a job, and —
//! the actual question — whether the other process is a member of OURS.
//!
//! Everything here degrades to "unknown" rather than to a guess: a denied query
//! is not evidence of absence, and a diagnostic that says `?` is worth more
//! than one that confidently says `no`.

const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

/// `JOBOBJECT_BASIC_LIMIT_INFORMATION.LimitFlags` bits we care to name. The
/// rest are CPU/memory caps and say nothing about who dies with whom.
pub const limit_breakaway_ok: u32 = 0x00000800;
pub const limit_silent_breakaway_ok: u32 = 0x00001000;
pub const limit_kill_on_job_close: u32 = 0x00002000;

const JobObjectBasicProcessIdList: c_int = 3;
const JobObjectExtendedLimitInformation: c_int = 9;

/// One process pair's job facts. `null` is "could not tell", never "no".
pub const Facts = struct {
    /// Are WE in any job?
    self_in_job: ?bool = null,
    /// Our innermost job's `LimitFlags` (null when jobless or denied).
    self_flags: ?u32 = null,
    /// Is the other process in any job?
    other_in_job: ?bool = null,
    /// Is the other process a member of OUR job? Note what this does NOT
    /// answer: a process is not a member of a job it merely holds a handle to,
    /// so `false` here is compatible with that process owning the job we are
    /// standing in (T268).
    shared: ?bool = null,
    /// Is OUR job the AGENT'S job? The fatal relation is handle OWNERSHIP, and
    /// handle holders are not enumerable without a driver — but the agent
    /// assigns every PTY child to its process-global job, so a child of the
    /// agent sitting in our job means our job IS that job, the agent owns its
    /// last handle by construction, and killing the agent kills us. This is
    /// the field that predicts death; `shared` is the one that reads like it
    /// does (T771).
    job_is_agents: ?bool = null,
};

/// Human-readable `LimitFlags`, e.g. `0x2800 kill_on_close|breakaway_ok`.
/// Pure — this is the half of the diagnostic that has to be right in the log a
/// year from now, so it is asserted rather than eyeballed.
pub fn describeFlags(buf: []u8, flags: u32) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.print("0x{X}", .{flags}) catch return buf[0..fbs.pos];

    var first = true;
    inline for (.{
        .{ limit_kill_on_job_close, "kill_on_close" },
        .{ limit_breakaway_ok, "breakaway_ok" },
        .{ limit_silent_breakaway_ok, "silent_breakaway_ok" },
    }) |pair| {
        if (flags & pair[0] != 0) {
            w.print("{s}{s}", .{ if (first) " " else "|", pair[1] }) catch
                return buf[0..fbs.pos];
            first = false;
        }
    }
    return buf[0..fbs.pos];
}

/// The whole diagnostic as one log-ready line. Pure, for the same reason.
pub fn describe(buf: []u8, facts: Facts) []const u8 {
    var flag_buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.print(
        "self_in_job={s} self_job_flags={s} agent_in_job={s} SHARED_JOB={s} AGENT_OWNS_JOB={s}",
        .{
            tri(facts.self_in_job),
            if (facts.self_flags) |f| describeFlags(&flag_buf, f) else "?",
            tri(facts.other_in_job),
            tri(facts.shared),
            tri(facts.job_is_agents),
        },
    ) catch {};
    return buf[0..fbs.pos];
}

fn tri(v: ?bool) []const u8 {
    return if (v) |b| (if (b) "yes" else "no") else "?";
}

/// Just this process's side of the question: are WE in a job, and with what
/// limit flags? The startup self-escape (T675) asks exactly this, with no other
/// process in the picture. Same degradation rule as `probe`: null is "could not
/// tell", never "no".
pub const SelfJob = struct {
    in_job: ?bool = null,
    flags: ?u32 = null,
};

pub fn selfJob() SelfJob {
    if (comptime builtin.os.tag != .windows) return .{};

    var facts: SelfJob = .{};

    var b: windows.BOOL = 0;
    if (IsProcessInJob(windows.kernel32.GetCurrentProcess(), null, &b) != 0)
        facts.in_job = b != 0;

    // A NULL job handle asks about the CALLER's job. Denied ⇒ we are not in one
    // (or may not ask), which the null already says.
    var ext: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    var ret: windows.DWORD = 0;
    if (QueryInformationJobObject(
        null,
        JobObjectExtendedLimitInformation,
        &ext,
        @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        &ret,
    ) != 0) facts.flags = ext.BasicLimitInformation.LimitFlags;

    return facts;
}

/// Are we a member of the job named `name` — the EXACT question the startup
/// escape wants answered (T902), as opposed to the first-job flags and pane
/// lineage it has to infer from otherwise.
///
/// `null` means "could not tell", with the same force it has everywhere else in
/// this module: no such job exists (an agent too old to name its job, or none
/// running), we may not open it, or the membership call itself failed. Only a
/// successful `IsProcessInJob` against a job we actually opened answers `false`,
/// and even that answer is about THAT job alone — the caller must not read it as
/// "in no hostile job", because a job we could not open is a job we know nothing
/// about.
///
/// `JOB_OBJECT_QUERY` is the whole access we ask for: this is a question, and a
/// handle with the rights to TERMINATE the user's panes is not one this process
/// has any business holding.
pub fn inNamedJob(name: []const u8) ?bool {
    if (comptime builtin.os.tag != .windows) return null;

    var w_buf: [256]u16 = undefined;
    if (name.len + 1 > w_buf.len) return null;
    const n = std.unicode.utf8ToUtf16Le(&w_buf, name) catch return null;
    w_buf[n] = 0;

    const job = OpenJobObjectW(JOB_OBJECT_QUERY, 0, @ptrCast(w_buf[0..n :0].ptr)) orelse {
        // Names the reason, because the two reasons are worlds apart: FILE_NOT_FOUND
        // is the ordinary "no agent of this lineage is running" and needs nobody,
        // while ACCESS_DENIED is a real defect in how the job was created.
        std.log.scoped(.win32_job_object).debug(
            "named job '{s}' not opened (gle={d})",
            .{ name, @intFromEnum(windows.kernel32.GetLastError()) },
        );
        return null;
    };
    defer windows.CloseHandle(job);

    var b: windows.BOOL = 0;
    if (IsProcessInJob(windows.kernel32.GetCurrentProcess(), job, &b) == 0) return null;
    return b != 0;
}

/// Measure the facts for `other_pid`. Never fails: every step that cannot be
/// answered leaves its field null.
///
/// `other_handle` is an ALREADY-OPEN handle to that process when the caller has
/// one (the refresh does — it opened it to terminate it), so the probe does not
/// need `PROCESS_QUERY_*` rights of its own. Null is fine; the membership
/// question is answered from our own job's process-id list either way.
pub fn probe(other_pid: u32, other_handle: ?windows.HANDLE) Facts {
    if (comptime builtin.os.tag != .windows) return .{};

    const self = selfJob();
    var facts: Facts = .{
        .self_in_job = self.in_job,
        .self_flags = self.flags,
    };

    if (other_handle) |h| {
        var ob: windows.BOOL = 0;
        if (IsProcessInJob(h, null, &ob) != 0) facts.other_in_job = ob != 0;
    }

    facts.shared = ownJobContains(other_pid);
    facts.job_is_agents = ownJobIsAgents(other_pid);
    return facts;
}

/// Is `pid` a member of the job WE are in? Null when it cannot be answered -
/// including the case where the list came back truncated and the pid was not in
/// the part we got, since the tail could still hold it.
pub fn ownJobContains(pid: u32) ?bool {
    if (comptime builtin.os.tag != .windows) return null;

    var buf: MemberBuf align(member_buf_align) = @splat(0);
    const members = ownJobMembers(&buf) orelse return null;
    for (members.ids) |id| {
        if (id == pid) return true;
    }
    // Not in what we were given. Only conclusive if we were given all of it.
    if (!members.complete) return null;
    return false;
}

/// Is OUR job the AGENT'S job - the relation that actually predicts the app
/// dying inside `TerminateProcess(agent)` (T268/T771)?
///
/// What kills us is the agent holding the last HANDLE to a kill-on-close job we
/// are a member of, and handle holders cannot be enumerated without a driver.
/// The proxy: the agent assigns every PTY child to its one process-global job
/// and holds that job's handle for its whole life, so if a process the agent
/// PARENTED is in our job, our job is that job and the ownership follows by
/// construction.
///
/// Same degradation rule as everything else here: `null` when the answer cannot
/// be established - no snapshot, no children seen, a truncated member list -
/// never a confident `no`.
pub fn ownJobIsAgents(agent_pid: u32) ?bool {
    if (comptime builtin.os.tag != .windows) return null;
    if (agent_pid == 0) return null;

    var kid_buf: [max_children]u32 = undefined;
    const kids = childrenOf(agent_pid, &kid_buf);

    var buf: MemberBuf align(member_buf_align) = @splat(0);
    const members = ownJobMembers(&buf) orelse return null;

    return jobIsAgentsFrom(members.ids, members.complete, kids.pids, kids.complete);
}

/// The verdict itself, separated from the two enumerations so it can be
/// asserted - the shape T268 met (agent not a member, and yet the job is the
/// agent's) is exactly the one no live box will reproduce on demand.
///
/// A match is conclusive even from partial lists: an id present is an id
/// present. Only a NEGATIVE needs both lists whole.
pub fn jobIsAgentsFrom(
    members: []const usize,
    members_complete: bool,
    children: []const u32,
    children_complete: bool,
) ?bool {
    for (children) |child| {
        for (members) |m| {
            if (m == child) return true;
        }
    }
    // No children observed at all says nothing about whose job this is: an
    // agent with no live PTY sessions still owns the job it created.
    if (children.len == 0) return null;
    if (!members_complete or !children_complete) return null;
    return false;
}

/// 4 KiB holds ~500 pids on x64. A job with more members than that is not one
/// we can answer about honestly, and says so.
pub const MemberBuf = [4096]u8;
const member_buf_align = @alignOf(JOBOBJECT_BASIC_PROCESS_ID_LIST);

/// Our job's member pids, as a view into the caller's buffer.
pub const JobMembers = struct {
    ids: []const usize,
    /// Whether `ids` is the WHOLE membership. A truncated list can prove a
    /// positive and never a negative.
    complete: bool,
};

/// Read our own job's process-id list into `buf`. Null when the question cannot
/// be answered (jobless, denied).
///
/// `buf` is ZEROED, not `undefined`: a failed query leaves it exactly as it
/// found it, and reading a count out of uninitialised stack could scan garbage
/// and report a shared job that does not exist. A diagnostic that can lie is
/// worse than one that says `?`.
pub fn ownJobMembers(buf: *align(member_buf_align) MemberBuf) ?JobMembers {
    if (comptime builtin.os.tag != .windows) return null;

    @memset(buf, 0);
    var ret: windows.DWORD = 0;
    if (QueryInformationJobObject(
        null,
        JobObjectBasicProcessIdList,
        buf,
        buf.len,
        &ret,
    ) == 0) {
        // ERROR_MORE_DATA means the list was TRUNCATED, not that it is absent:
        // what we were given is real, it is just not all of it. Anything else
        // (not in a job, denied) is unanswerable.
        if (windows.kernel32.GetLastError() != .MORE_DATA) return null;
    }

    const list: *const JOBOBJECT_BASIC_PROCESS_ID_LIST = @ptrCast(buf);
    const returned = list.NumberOfProcessIdsInList;
    // Guard against a bogus count before indexing: the buffer is written by the
    // kernel, but the arithmetic is ours.
    const max_ids = (buf.len - @sizeOf(JOBOBJECT_BASIC_PROCESS_ID_LIST)) /
        @sizeOf(usize) + 1;
    const n = @min(returned, max_ids);

    const ids: [*]const usize = @ptrCast(&list.ProcessIdList);
    return .{
        .ids = ids[0..n],
        .complete = returned >= list.NumberOfAssignedProcesses,
    };
}

/// The most direct children we will look at. The agent parents one ConPTY shell
/// per live session, so a handful is the shape; filling the buffer costs us the
/// ability to say a conclusive `no`, not correctness.
pub const max_children = 64;

pub const Children = struct {
    pids: []const u32,
    /// False when the snapshot failed or the buffer filled - either way a
    /// negative verdict cannot be drawn from this list.
    complete: bool,
};

/// Direct children of `parent_pid`, from a Toolhelp32 snapshot, into `out`.
/// Direct rather than the whole subtree on purpose: `pty_child.zig` assigns the
/// shell the agent itself spawned, and a deeper descendant may have broken away
/// into a job of its own.
fn childrenOf(parent_pid: u32, out: *[max_children]u32) Children {
    if (comptime builtin.os.tag != .windows) return .{ .pids = &.{}, .complete = false };

    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == windows.INVALID_HANDLE_VALUE) return .{ .pids = &.{}, .complete = false };
    defer windows.CloseHandle(snap);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == 0) return .{ .pids = &.{}, .complete = false };

    var n: usize = 0;
    var complete = true;
    while (true) {
        if (entry.th32ParentProcessID == parent_pid and entry.th32ProcessID != parent_pid) {
            if (n == out.len) {
                complete = false;
                break;
            }
            out[n] = entry.th32ProcessID;
            n += 1;
        }
        if (Process32NextW(snap, &entry) == 0) break;
    }
    return .{ .pids = out[0..n], .complete = complete };
}

// =============================================================================
// Win32 declarations
// =============================================================================

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: windows.LARGE_INTEGER,
    PerJobUserTimeLimit: windows.LARGE_INTEGER,
    LimitFlags: windows.DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: windows.DWORD,
    Affinity: usize,
    PriorityClass: windows.DWORD,
    SchedulingClass: windows.DWORD,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

const JOBOBJECT_BASIC_PROCESS_ID_LIST = extern struct {
    NumberOfAssignedProcesses: windows.DWORD,
    NumberOfProcessIdsInList: windows.DWORD,
    ProcessIdList: [1]usize,
};

/// `JOB_OBJECT_QUERY` (winnt.h 0x0004): read the job's limits and membership,
/// and nothing else. Deliberately not `JOB_OBJECT_ALL_ACCESS`.
const JOB_OBJECT_QUERY: windows.DWORD = 0x0004;

extern "kernel32" fn OpenJobObjectW(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    lpName: windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn IsProcessInJob(
    ProcessHandle: windows.HANDLE,
    JobHandle: ?windows.HANDLE,
    Result: *windows.BOOL,
) callconv(.winapi) windows.BOOL;

const TH32CS_SNAPPROCESS: windows.DWORD = 0x00000002;

const PROCESSENTRY32W = extern struct {
    dwSize: windows.DWORD,
    cntUsage: windows.DWORD,
    th32ProcessID: windows.DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: windows.DWORD,
    cntThreads: windows.DWORD,
    th32ParentProcessID: windows.DWORD,
    pcPriClassBase: i32,
    dwFlags: windows.DWORD,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(
    dwFlags: windows.DWORD,
    th32ProcessID: windows.DWORD,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn Process32FirstW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn Process32NextW(
    hSnapshot: windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn QueryInformationJobObject(
    hJob: ?windows.HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
    lpReturnLength: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "describeFlags names the production shape" {
    var buf: [64]u8 = undefined;
    // 0x3C00 is what a pane-shell descendant reported on this box (T524).
    try testing.expectEqualStrings(
        "0x3C00 kill_on_close|breakaway_ok|silent_breakaway_ok",
        describeFlags(&buf, 0x3C00),
    );
    try testing.expectEqualStrings(
        "0x2800 kill_on_close|breakaway_ok",
        describeFlags(&buf, 0x2800),
    );
}

test "describeFlags still prints a job with none of the interesting bits" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("0x0", describeFlags(&buf, 0));
    // An unrelated limit (ACTIVE_PROCESS 0x8) is shown as a number, not
    // silently dropped: the hex is the fact, the names are the reading of it.
    try testing.expectEqualStrings("0x8", describeFlags(&buf, 0x8));
}

test "describe says ? rather than no for what it could not measure" {
    var buf: [256]u8 = undefined;
    // The whole point of the diagnostic: an unanswerable question must not read
    // as a negative answer, which is what would send the next investigation
    // back down the wrong path.
    try testing.expectEqualStrings(
        "self_in_job=? self_job_flags=? agent_in_job=? SHARED_JOB=? AGENT_OWNS_JOB=?",
        describe(&buf, .{}),
    );
    try testing.expectEqualStrings(
        "self_in_job=yes self_job_flags=0x2000 kill_on_close agent_in_job=yes " ++
            "SHARED_JOB=yes AGENT_OWNS_JOB=yes",
        describe(&buf, .{
            .self_in_job = true,
            .self_flags = limit_kill_on_job_close,
            .other_in_job = true,
            .shared = true,
            .job_is_agents = true,
        }),
    );
    try testing.expectEqualStrings(
        "self_in_job=yes self_job_flags=0x0 agent_in_job=no SHARED_JOB=no AGENT_OWNS_JOB=no",
        describe(&buf, .{
            .self_in_job = true,
            .self_flags = 0,
            .other_in_job = false,
            .shared = false,
            .job_is_agents = false,
        }),
    );
}

test "describe carries the T268 field shape: membership no, ownership yes" {
    var buf: [256]u8 = undefined;
    // The exact line the app wrote on 2026-08-11 while it was being destroyed,
    // plus the term this task adds. `SHARED_JOB=no` is still correct and still
    // not an exoneration; `AGENT_OWNS_JOB=yes` is the half that predicts death.
    try testing.expectEqualStrings(
        "self_in_job=yes self_job_flags=0x2000 kill_on_close agent_in_job=yes " ++
            "SHARED_JOB=no AGENT_OWNS_JOB=yes",
        describe(&buf, .{
            .self_in_job = true,
            .self_flags = limit_kill_on_job_close,
            .other_in_job = true,
            .shared = false,
            .job_is_agents = true,
        }),
    );
}

test "jobIsAgentsFrom reproduces the shape T268 met" {
    // The app (pid 43076) is a member of a job whose other members are the
    // agent's three pane shells. The AGENT (24620) is not a member of it at
    // all - it only holds the handle - so `ownJobContains(agent)` is false and
    // always would be. The child that IS in the list is what gives it away.
    const members = [_]usize{ 43076, 51120, 60204, 12888 };
    const children = [_]u32{ 51120, 60204 };
    try testing.expectEqual(
        @as(?bool, true),
        jobIsAgentsFrom(&members, true, &children, true),
    );
    // And the membership question over the same whole list, asked about the
    // agent itself, answers a truthful `no` to a job that is about to kill us -
    // which is precisely why the old diagnostic read as an exoneration.
    try testing.expectEqual(
        @as(?bool, false),
        jobIsAgentsFrom(&members, true, &[_]u32{24620}, true),
    );
}

test "jobIsAgentsFrom says ? rather than no whenever a list could be hiding it" {
    const members = [_]usize{ 1, 2, 3 };
    const children = [_]u32{ 9 };

    // Both lists whole and no overlap: the only shape that earns a `no`.
    try testing.expectEqual(
        @as(?bool, false),
        jobIsAgentsFrom(&members, true, &children, true),
    );
    // A truncated member list could hold the child further down.
    try testing.expectEqual(
        @as(?bool, null),
        jobIsAgentsFrom(&members, false, &children, true),
    );
    // A truncated child list could hold one that IS a member.
    try testing.expectEqual(
        @as(?bool, null),
        jobIsAgentsFrom(&members, true, &children, false),
    );
    // No children seen at all is not evidence: an agent with no live sessions
    // still owns the job it created.
    try testing.expectEqual(
        @as(?bool, null),
        jobIsAgentsFrom(&members, true, &.{}, true),
    );
    // ...and a positive is conclusive even from partial lists, because an id
    // that is present is present.
    try testing.expectEqual(
        @as(?bool, true),
        jobIsAgentsFrom(&[_]usize{7}, false, &[_]u32{7}, false),
    );
}

test "probe never traps on a pid that does not exist" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    // Whatever the box's job situation is, a probe is a diagnostic and must
    // never be the thing that fails a refresh.
    _ = probe(0xFFFF_FFFF, null);
    _ = ownJobContains(0);
    _ = ownJobIsAgents(0xFFFF_FFFF);
    // pid 0 is the System Idle Process and is nobody's parent; asking about it
    // must be a `?`, never a snapshot walk that decides something.
    try testing.expectEqual(@as(?bool, null), ownJobIsAgents(0));
}
