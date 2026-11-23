//! Running `git` and capturing its stdout, in the one shape the viewer needs
//! (T636 — extracted from `ViewerWorktreeProbe` when the feedback report writer
//! became a second caller).
//!
//! There is deliberately ONE of these. The two flags below are both the kind
//! that are invisible until they are missing, and a second hand-rolled spawn
//! would eventually be missing one of them:
//!
//! - **`create_no_window`.** `git.exe` is a console program and the app is a
//!   GUI-subsystem process, so without it every call flashes a console window
//!   over the user's terminal.
//! - **stderr IGNORED, not piped.** With one pipe there is nothing to
//!   interleave, so the read below cannot deadlock against a second pipe
//!   filling up while nobody drains it.
//!
//! BLOCKING — worker threads only. The viewer's message loop is the one the
//! terminal next door draws on, and a `CreateProcess` on it is a visible
//! stutter in a pane that has nothing to do with the viewer.
//!
//! And BOUNDED (T818). Every call here is made from a worker the pane's
//! teardown JOINS — it must, because the worker writes into memory the deinit
//! then frees — so a `git` that never answers does not merely leave a stale
//! pane, it stops the pane, and the app behind it, from closing at all. The two
//! documented ways a read-only `git` blocks forever are already shut off below,
//! which is why no such hang has been observed here; the deadline is for
//! everything else — a filesystem that stopped responding, a hook, a helper
//! nobody anticipated. Mac's `ViewerProcess.run` has carried the same belt as a
//! 15 s `DispatchWorkItem` since it was written.
//!
//! Also the Linux viewer's (T3417): POSIX builds use a process group where
//! Windows uses a job object (see `Running`), and nothing else differs.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const is_windows = builtin.os.tag == .windows;
const Allocator = std.mem.Allocator;
const worker_pool = @import("worker_pool.zig");

/// How long any one `git` may take before it is given up on. Matches the Mac
/// viewer's deadline, and generous on purpose: a cold `git diff` over a large
/// repository is slow, and a deadline that fires on a SLOW git is worse than no
/// deadline at all — it turns a working pane into an error card.
pub const default_deadline_ms: u64 = 15_000;

/// Kills `child` if `done` is not signalled within the deadline.
///
/// A thread rather than a timer, because the thing that has to happen on expiry
/// — terminating the child — must happen somewhere other than the thread
/// blocked reading the child's stdout, and that read is the whole reason we are
/// stuck. Terminating the child closes its end of the pipe, so the reader sees
/// EOF and unwinds through the ordinary path; nothing here touches the reader's
/// state.
///
/// The handle is the CHILD's and `Child.wait` CLOSES it, so `stop` — which
/// joins this thread — is always called BEFORE the wait. That ordering is the
/// invariant this struct exists to make obvious.
const Deadline = struct {
    running: *const Running,
    ms: u64,
    done: std.Thread.ResetEvent = .{},
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?worker_pool.Thread = null,

    fn start(self: *Deadline) void {
        self.thread = worker_pool.spawn(watch, .{self}) catch null;
    }

    fn watch(self: *Deadline) void {
        self.done.timedWait(self.ms * std.time.ns_per_ms) catch {
            // Marked BEFORE the kill: a reader that wakes on the EOF our
            // terminate produces must not be able to read `fired` as false and
            // report a wedged git as a clean empty answer.
            self.fired.store(true, .release);
            // `Child.kill` would do this AND reap the child, closing the handle
            // out from under the `wait` the caller is about to make; the raw
            // terminate is the half that is ours to do. It ends the whole
            // TREE when there is a job (T3045), since the stdout pipe may be
            // held by a grandchild rather than by the process we launched.
            self.running.kill();
        };
    }

    /// Stops the watchdog and answers whether it had already fired. Call it
    /// exactly once, and before `child.wait()`.
    fn stop(self: *Deadline) bool {
        self.done.set();
        if (self.thread) |t| t.join();
        return self.fired.load(.acquire);
    }
};

/// git processes this THREAD has launched (T3038). Per thread so a worker can
/// read what its own job cost by differencing it around the job, with no lock
/// and no other worker's spawns mixed in.
pub threadlocal var spawned_on_thread: u64 = 0;

/// The cancel token of whatever job this worker thread is running (T3045), or
/// null. A worker sets it for the length of one job and clears it after — the
/// threads are POOLED (`worker_pool`), so a value left behind would cancel the
/// next pane's work. Thread-local rather than a parameter because every one of
/// the dozen call sites below a worker would otherwise have to carry it, and
/// the one that forgot would be the one that freezes the app.
pub threadlocal var cancel_on_thread: ?*Cancel = null;

/// How a pane's teardown stops the git its worker is running (T3045).
///
/// Every worker that calls into this file is JOINED by its pane's `deinit`, on
/// the GUI thread, because the worker writes into memory that deinit frees. A
/// listing is up to six gits in a row with a 15 s deadline each, so before
/// this a close during a slow git froze the whole app until git finished.
/// `request` ends the git in flight (its whole process tree) and makes every
/// later call on that worker refuse to start one, so the join that follows
/// waits for a worker that is already unwinding.
pub const Cancel = struct {
    requested: std.atomic.Value(bool) = .init(false),
    /// Guards `running` against the worker publishing or retiring it while
    /// `request` is killing it: the handle must not be closed underneath the
    /// terminate.
    mutex: std.Thread.Mutex = .{},
    running: ?*const Running = null,

    /// Callable from any thread, any number of times.
    pub fn request(self: *Cancel) void {
        self.requested.store(true, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.running) |r| r.kill();
    }

    pub fn isRequested(self: *const Cancel) bool {
        return self.requested.load(.acquire);
    }

    /// Publish the process just launched. If the cancel already happened, the
    /// process is killed here — the window between the check before spawning
    /// and this point is where a cancel would otherwise be lost.
    fn track(self: *Cancel, r: *const Running) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.isRequested()) r.kill();
        self.running = r;
    }

    /// Retire it, before its handles are closed.
    fn untrack(self: *Cancel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.running = null;
    }
};

/// The Win32 job surface `std.os.windows` does not expose (same constants as
/// `remote/agent/pty_child.zig`, which needs them for the PTY children).
const win_job = struct {
    const DWORD = windows.DWORD;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
    const JobObjectExtendedLimitInformation: c_int = 9;
    const IO_COUNTERS = extern struct { counts: [6]u64 = @splat(0) };
    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64 = 0,
        PerJobUserTimeLimit: i64 = 0,
        LimitFlags: DWORD = 0,
        MinimumWorkingSetSize: usize = 0,
        MaximumWorkingSetSize: usize = 0,
        ActiveProcessLimit: DWORD = 0,
        Affinity: usize = 0,
        PriorityClass: DWORD = 0,
        SchedulingClass: DWORD = 0,
    };
    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
        IoInfo: IO_COUNTERS = .{},
        ProcessMemoryLimit: usize = 0,
        JobMemoryLimit: usize = 0,
        PeakProcessMemoryUsed: usize = 0,
        PeakJobMemoryUsed: usize = 0,
    };
    extern "kernel32" fn CreateJobObjectW(?*windows.SECURITY_ATTRIBUTES, ?windows.LPCWSTR) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetInformationJobObject(HANDLE, c_int, *const anyopaque, DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn AssignProcessToJobObject(HANDLE, HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateJobObject(HANDLE, c_uint) callconv(.winapi) BOOL;
    extern "kernel32" fn ResumeThread(HANDLE) callconv(.winapi) DWORD;
};

/// One launched git: its process, and the kill-on-close job holding it and
/// everything it starts (T3045).
///
/// Why a job: Git for Windows' `cmd\git.exe` — what "git" on PATH resolves to —
/// is a launcher whose CHILD does the work and inherits the stdout pipe. Ending
/// only the launcher, which is what the deadline did before, leaves the pipe
/// open and the reader blocked until the real git finishes on its own; and it
/// leaves that git running after the pane that asked is gone. The process is
/// started suspended and assigned before it runs a single instruction, so
/// nothing it starts can escape the job.
///
/// No job (an OS or policy that refuses one) falls back to the process alone:
/// the behavior from before this change, never worse.
///
/// POSIX has no job object; the same guarantee comes from a PROCESS GROUP.
/// git is started as the leader of a group of its own (`pgid = 0`), whatever
/// it starts inherits the group, and the kill signals the whole group - so a
/// helper still holding the stdout pipe ends with it.
const Running = struct {
    child: *std.process.Child,
    job: if (is_windows) ?windows.HANDLE else void = if (is_windows) null else {},

    /// End the tree. Safe to call more than once and from any thread while
    /// the handles are open, which `Cancel`'s mutex and `Deadline.stop`
    /// guarantee.
    fn kill(self: *const Running) void {
        if (comptime !is_windows) {
            // The negative pid names the group. The leader is not reaped
            // until `finish` waits, which runs after `Deadline.stop` and
            // `untrack`, so its pid cannot have been reused by then.
            std.posix.kill(-self.child.id, std.posix.SIG.KILL) catch {
                std.posix.kill(self.child.id, std.posix.SIG.KILL) catch {};
            };
            return;
        }
        if (self.job) |j| {
            if (win_job.TerminateJobObject(j, 1) != 0) return;
        }
        windows.TerminateProcess(self.child.id, 1) catch {};
    }
};

/// Spawn `child` inside its own job and publish it to the thread's cancel
/// token. False when it could not be launched — or when a cancel already
/// asked this worker to stop, which callers read the same way: try nothing
/// else.
fn launch(child: *std.process.Child, running: *Running) bool {
    if (cancel_on_thread) |c| if (c.isRequested()) return false;
    if (comptime !is_windows) {
        // A process group of its own, so `kill` reaches everything it starts.
        child.pgid = 0;
        child.spawn() catch return false;
        spawned_on_thread += 1;
        running.* = .{ .child = child };
        if (cancel_on_thread) |c| c.track(running);
        return true;
    }
    child.start_suspended = true;
    child.spawn() catch return false;
    spawned_on_thread += 1;
    running.* = .{ .child = child, .job = makeJob(child.id) };
    if (win_job.ResumeThread(child.thread_handle) == std.math.maxInt(windows.DWORD)) {
        // A process that never resumes is a reader that never sees EOF.
        running.kill();
    }
    if (cancel_on_thread) |c| c.track(running);
    return true;
}

/// A kill-on-close job holding `process`, or null when the OS refuses one.
fn makeJob(process: windows.HANDLE) ?windows.HANDLE {
    const job = win_job.CreateJobObjectW(null, null) orelse return null;
    var info: win_job.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    info.BasicLimitInformation.LimitFlags = win_job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    const ok = win_job.SetInformationJobObject(
        job,
        win_job.JobObjectExtendedLimitInformation,
        &info,
        @sizeOf(win_job.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) != 0 and win_job.AssignProcessToJobObject(job, process) != 0;
    if (!ok) {
        windows.CloseHandle(job);
        return null;
    }
    return job;
}

/// The other half of `launch`: retire the process from the cancel token, reap
/// it, and close the job — which, being kill-on-close, also ends anything git
/// left behind. Returns the wait's answer, and whether a cancel ended the run
/// (whose output is then not an answer to anything).
fn finish(running: *Running) struct { term: ?std.process.Child.Term, cancelled: bool } {
    if (cancel_on_thread) |c| c.untrack();
    const term = running.child.wait() catch null;
    if (comptime is_windows) {
        if (running.job) |j| windows.CloseHandle(j);
        running.job = null;
    }
    const cancelled = if (cancel_on_thread) |c| c.isRequested() else false;
    return .{ .term = term, .cancelled = cancelled };
}

/// Run `argv`, returning its stdout in `buf`. Null when the binary could not be
/// launched at all — the only case worth trying another `git` path for. A git
/// that ran and failed returns its (usually empty) stdout, because "git said
/// no" is an ANSWER: a directory outside a repository, a repository with no
/// commits. Null too when the worker was cancelled (T3045).
pub fn capture(alloc: Allocator, argv: []const []const u8, buf: []u8) ?[]const u8 {
    return captureDeadline(alloc, argv, buf, default_deadline_ms);
}

/// `capture` with the deadline spelled out. Only a test should need this; every
/// caller in the app wants the default.
///
/// A timeout reads as a short (usually empty) answer rather than null, because
/// the questions the fixed-buffer form asks — "is this a worktree", "what is
/// the branch" — all already handle not being answered, and null is reserved
/// for "git is not installed", the one case worth trying another path for.
pub fn captureDeadline(
    alloc: Allocator,
    argv: []const []const u8,
    buf: []u8,
    deadline_ms: u64,
) ?[]const u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    var running: Running = undefined;
    if (!launch(&child, &running)) return null;

    const stdout = child.stdout orelse {
        _ = finish(&running);
        return null;
    };
    var deadline: Deadline = .{ .running = &running, .ms = deadline_ms };
    deadline.start();
    const n = stdout.readAll(buf) catch 0;
    _ = deadline.stop();
    const end = finish(&running);
    if (end.term == null or end.cancelled) return null;
    return buf[0..n];
}

/// What a diff invocation produced (T463).
pub const Output = struct {
    /// stdout, up to the caller's cap. Owned by the caller.
    bytes: []u8,
    /// git exited 0. A diff caller must NOT treat a non-zero exit as an empty
    /// answer: `git diff nosuchref` prints nothing and fails, and rendering
    /// that as "no changes" is exactly the swallowed error T463 exists to fix.
    ok: bool,
    /// Output past `max` was read and discarded — see below.
    truncated: bool = false,
    /// git was still running at the deadline and was terminated (T818). `ok` is
    /// false with it, and a caller showing an error card should say THIS rather
    /// than "git refused": a wedged git and a bad revspec want different words
    /// in front of the user.
    timed_out: bool = false,
};

/// Run `argv` and read its stdout **to EOF**, retaining at most `max` bytes.
/// Null when the binary could not be launched at all.
///
/// The fixed-buffer `capture` above cannot serve a diff, and the reason is a
/// deadlock rather than a size limit: a `readAll` that stops on a full buffer
/// leaves git blocked writing into a pipe nobody is draining, and the `wait`
/// that follows then never returns. A whole-repository `--name-status` is
/// routinely megabytes, so that is not a theoretical shape here. Reading to EOF
/// and DISCARDING the overflow keeps the child able to exit no matter how much
/// it wants to say.
///
/// BLOCKING — worker threads only, for the reason in the file header.
pub fn captureAlloc(
    alloc: Allocator,
    argv: []const []const u8,
    max: usize,
) ?Output {
    return captureAllocDeadline(alloc, argv, max, default_deadline_ms);
}

/// `captureAlloc` with the deadline spelled out, for tests.
pub fn captureAllocDeadline(
    alloc: Allocator,
    argv: []const []const u8,
    max: usize,
    deadline_ms: u64,
) ?Output {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    // A git hook or config that reads the terminal would hang this worker
    // forever, and the pane's teardown JOINS it; this makes any such prompt
    // fail immediately instead. Optional locks off so a read-only diff never
    // fights a concurrent `git` running in a pane next door. (Mac's
    // `ViewerProcess.run` sets the same two.)
    var env = std.process.getEnvMap(alloc) catch return null;
    defer env.deinit();
    env.put("GIT_TERMINAL_PROMPT", "0") catch {};
    env.put("GIT_OPTIONAL_LOCKS", "0") catch {};
    child.env_map = &env;

    var running: Running = undefined;
    if (!launch(&child, &running)) return null;
    const stdout = child.stdout orelse {
        _ = finish(&running);
        return null;
    };

    var deadline: Deadline = .{ .running = &running, .ms = deadline_ms };
    deadline.start();

    var out: std.ArrayList(u8) = .empty;
    var truncated = false;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = stdout.read(&chunk) catch break;
        if (n == 0) break;
        if (out.items.len >= max) {
            truncated = true;
            continue;
        }
        const take = @min(n, max - out.items.len);
        out.appendSlice(alloc, chunk[0..take]) catch {
            truncated = true;
            continue;
        };
        if (take < n) truncated = true;
    }

    const timed_out = deadline.stop();
    const end = finish(&running);
    // A cancelled run answers nothing: the pane that asked is going away.
    if (end.cancelled) {
        out.deinit(alloc);
        return null;
    }
    const term = end.term orelse {
        out.deinit(alloc);
        return null;
    };
    const bytes = out.toOwnedSlice(alloc) catch {
        out.deinit(alloc);
        return null;
    };
    return .{
        .bytes = bytes,
        // A terminated git never said yes, whatever its exit code reads as.
        .ok = !timed_out and term == .Exited and term.Exited == 0,
        .truncated = truncated,
        .timed_out = timed_out,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// A child that outlives any deadline a test is willing to wait for. `ping`
/// is the one such program that is on every Windows box, needs no console,
/// and holds its stdout open the whole time — which is the property that
/// matters, since the hang being reproduced is a reader blocked on a pipe
/// that never closes.
const forever_argv: []const []const u8 = &.{ "ping", "-n", "120", "127.0.0.1" };

test "captureAlloc gives up on a git that never answers" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var timer = try std.time.Timer.start();
    const out = captureAllocDeadline(
        testing.allocator,
        forever_argv,
        1 << 20,
        150,
    ) orelse return error.SpawnFailed;
    defer testing.allocator.free(out.bytes);
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    // The point of the whole change: the call RETURNED, and said why.
    try testing.expect(out.timed_out);
    try testing.expect(!out.ok);
    // Loose upper bound — this asserts "the deadline is what ended it", not a
    // scheduling guarantee, so it must not be flaky on a loaded box.
    try testing.expect(elapsed_ms < 10_000);
}

test "capture gives up on a git that never answers" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var buf: [4096]u8 = undefined;
    var timer = try std.time.Timer.start();
    const out = captureDeadline(
        testing.allocator,
        forever_argv,
        &buf,
        150,
    ) orelse return error.SpawnFailed;
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    // The fixed-buffer form has no field to say so; what it owes the caller is
    // simply to come back, with whatever the child had managed to say.
    _ = out;
    try testing.expect(elapsed_ms < 10_000);
}

/// The Git-for-Windows shape (T3045): `cmd\git.exe` on PATH is a LAUNCHER that
/// runs the real `mingw64\bin\git.exe` as its child, and that child inherits
/// the stdout pipe. Killing only the launcher leaves the pipe open and the
/// reader blocked until the grandchild finishes on its own. `cmd /c ping`
/// reproduces it with programs every Windows box has. `-n 8` caps what a
/// regression costs (about seven seconds) instead of hanging the lane.
const launcher_argv: []const []const u8 = &.{ "cmd", "/c", "ping", "-n", "8", "127.0.0.1" };

test "the deadline ends a git whose real worker is a grandchild" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var timer = try std.time.Timer.start();
    const out = captureAllocDeadline(
        testing.allocator,
        launcher_argv,
        1 << 20,
        150,
    ) orelse return error.SpawnFailed;
    defer testing.allocator.free(out.bytes);
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    try testing.expect(out.timed_out);
    // Well under the grandchild's own seven seconds: the TREE was ended, not
    // just the launcher.
    try testing.expect(elapsed_ms < 3_000);
}

fn cancelSoon(c: *Cancel) void {
    std.Thread.sleep(150 * std.time.ns_per_ms);
    c.request();
}

test "a cancel ends the git in flight, grandchild included, and answers nothing" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var cancel: Cancel = .{};
    cancel_on_thread = &cancel;
    defer cancel_on_thread = null;
    const t = try std.Thread.spawn(.{}, cancelSoon, .{&cancel});
    defer t.join();

    var timer = try std.time.Timer.start();
    // A deadline far past the test: only the cancel can end this early.
    const out = captureAllocDeadline(testing.allocator, launcher_argv, 1 << 20, 60_000);
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    try testing.expect(out == null);
    try testing.expect(elapsed_ms < 3_000);
}

test "a worker that was already cancelled starts no git at all" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var cancel: Cancel = .{};
    cancel.request();
    cancel_on_thread = &cancel;
    defer cancel_on_thread = null;

    const before = spawned_on_thread;
    var buf: [64]u8 = undefined;
    try testing.expect(capture(testing.allocator, launcher_argv, &buf) == null);
    try testing.expect(captureAlloc(testing.allocator, launcher_argv, 64) == null);
    try testing.expectEqual(before, spawned_on_thread);
}

test "a git that answers promptly is untouched by the deadline" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    // The negative control for the two above: the same code path, a child that
    // exits on its own, and a deadline long enough that only a bug fires it.
    const out = captureAllocDeadline(
        testing.allocator,
        &.{ "cmd", "/c", "echo", "hello" },
        1 << 20,
        10_000,
    ) orelse return error.SpawnFailed;
    defer testing.allocator.free(out.bytes);

    try testing.expect(!out.timed_out);
    try testing.expect(out.ok);
    try testing.expect(std.mem.indexOf(u8, out.bytes, "hello") != null);
}
