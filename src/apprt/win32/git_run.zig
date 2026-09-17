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
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

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
    child: *std.process.Child,
    ms: u64,
    done: std.Thread.ResetEvent = .{},
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *Deadline) void {
        self.thread = std.Thread.spawn(.{}, watch, .{self}) catch null;
    }

    fn watch(self: *Deadline) void {
        self.done.timedWait(self.ms * std.time.ns_per_ms) catch {
            // Marked BEFORE the kill: a reader that wakes on the EOF our
            // terminate produces must not be able to read `fired` as false and
            // report a wedged git as a clean empty answer.
            self.fired.store(true, .release);
            // `Child.kill` would do this AND reap the child, closing the handle
            // out from under the `wait` the caller is about to make; the raw
            // terminate is the half that is ours to do.
            windows.TerminateProcess(self.child.id, 1) catch {};
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

/// Run `argv`, returning its stdout in `buf`. Null when the binary could not be
/// launched at all — the only case worth trying another `git` path for. A git
/// that ran and failed returns its (usually empty) stdout, because "git said
/// no" is an ANSWER: a directory outside a repository, a repository with no
/// commits.
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
    child.spawn() catch return null;

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    var deadline: Deadline = .{ .child = &child, .ms = deadline_ms };
    deadline.start();
    const n = stdout.readAll(buf) catch 0;
    _ = deadline.stop();
    _ = child.wait() catch return null;
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

    child.spawn() catch return null;
    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };

    var deadline: Deadline = .{ .child = &child, .ms = deadline_ms };
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
    const term = child.wait() catch {
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
