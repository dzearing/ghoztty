//! Shared helpers for cross-thread TEST waits (imported only from test code).
//!
//! This is the T346/T258 discipline, hoisted out of the agent lane (T498) so
//! every lane can use it: the two `zig build test` lanes analyze this file via
//! the remote modules' test sections, and the agent test binaries (both rooted
//! at `src/`) reach it through `agent/test_util.zig`'s re-export.
//!
//! The rules these helpers encode:
//! - A cross-thread test wait is a WALL-CLOCK deadline, never an iteration
//!   count: 10k `Thread.yield()`s is a duration only when the scheduler
//!   cooperates, and on a loaded box a spin budget burns through before the
//!   watched thread has run once (T346).
//! - The deadline is a LIVENESS bound, not a performance assertion: generous
//!   enough that a busy box cannot spend it, so it only fires when the awaited
//!   effect NEVER happens. 10s proved spendable under acceptance-script load
//!   (T183) — hence 60s.
//! - A wait that cannot time out is a wedge waiting to happen: the T258 hang
//!   was a test blocked ~11 minutes in an untimed wait with no failure text.
//!   Bounding the wait turns the wedge into a red assert that names the test.
//! - A wait that times out SAYS WHAT IT WAS WAITING FOR (T436). Every wait
//!   carries a plain-words label and prints it, with the elapsed time, when it
//!   gives up: `expected true, found false` names neither the condition nor
//!   the minute the lane just spent on it.

const std = @import("std");

/// The shared liveness bound for every test wait: how long an awaited
/// cross-thread effect may take before the test calls it a hang.
pub const liveness_ns: u64 = 60 * std.time.ns_per_s;

/// A wall-clock budget for a test that waits by SPINNING on another thread's
/// progress — the shape `waitUntil` cannot express, because the condition is
/// not a predicate call but "this loop made progress" (a ring drain, a capture
/// sink, a position that has to settle).
///
/// Spin counts do not measure time, they measure scheduler contention (T472).
/// On a box running three test lanes and a WebView2 host, 100_000 yields can
/// burn through in far less time than the watched thread needed, so a green
/// tree produces `error.Timeout` at random — and a flaky red costs more than a
/// real one, because it trains whoever is watching to shrug at red. On Windows
/// the other direction hurts too: `Thread.sleep(100µs)` rounds up to the
/// ~15.6ms timer tick, so 30k sleeping spins was ~8 MINUTES per miss (T89b).
/// A deadline is neither: it says "nothing arrived within the liveness bound."
///
/// This lived twice — `connection.zig`'s `TestDeadline` and `pty_child.zig`'s
/// `waitContains`, each written after the other's lesson was already paid for
/// (T831). One home, so the third one is an import rather than a rediscovery.
pub const Deadline = struct {
    timer: std.time.Timer,
    budget_ns: u64,
    what: []const u8,

    /// `what` names the condition in plain words, and is what a timeout prints
    /// (T436): "the agent recorded the metrics unsubscribe", not `error.Timeout`.
    pub fn start(comptime what: []const u8) Deadline {
        return startWith(what, liveness_ns);
    }

    /// `start` with an explicit budget. Only the shared `liveness_ns` bound
    /// belongs in a test body — this exists so the timeout path itself is
    /// testable without spending that bound.
    pub fn startWith(comptime what: []const u8, budget_ns: u64) Deadline {
        return .{
            .timer = std.time.Timer.start() catch unreachable,
            .budget_ns = budget_ns,
            .what = what,
        };
    }

    pub fn expired(self: *Deadline) bool {
        return self.timer.read() > self.budget_ns;
    }

    /// Progress: the budget bounds a STALL from here, not the whole wait, so a
    /// slow loaded box cannot spend it while the transfer is still moving.
    pub fn progress(self: *Deadline) void {
        self.timer.reset();
    }

    /// Yield to the thread we are waiting on, or report the budget is spent.
    pub fn yield(self: *Deadline) error{Timeout}!void {
        if (self.spent()) return error.Timeout;
        std.Thread.yield() catch {};
    }

    /// `yield` for a wait on something that is NOT another runnable thread of
    /// this process (a child process's output, a file appearing): sleeping a
    /// millisecond leaves the box alone instead of spinning a core hot.
    pub fn tick(self: *Deadline) error{Timeout}!void {
        if (self.spent()) return error.Timeout;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    fn spent(self: *Deadline) bool {
        const waited = self.timer.read();
        if (waited <= self.budget_ns) return false;
        std.debug.print(
            "\ntest wait TIMEOUT after {d} ms waiting for: {s}\n",
            .{ waited / std.time.ns_per_ms, self.what },
        );
        return true;
    }
};

/// Poll `pred(args...)` until it returns true or the liveness deadline
/// expires; returns whether the predicate ever held.
///
/// A predicate that errors counts as "not yet", and callers must
/// `try testing.expect(waitUntil(...))` rather than discard the bool, so a
/// timeout fails AT the wait, named, instead of falling through to a later
/// `.?` panic (T183).
///
/// `what` names the condition in plain words ("the session left the store").
/// A timeout PRINTS it along with how long it waited (T436): the bool alone
/// reaches the caller as `expected true, found false`, which says neither what
/// the test was waiting for nor that it waited a full minute for it.
pub fn waitUntil(comptime what: []const u8, comptime pred: anytype, args: anytype) bool {
    return waitUntilFor(what, liveness_ns, pred, args);
}

/// `waitUntil` with an explicit deadline. Only the shared `liveness_ns` bound
/// belongs in a test body — this exists so the timeout path itself is testable
/// without spending that bound.
pub fn waitUntilFor(
    comptime what: []const u8,
    deadline_ns: u64,
    comptime pred: anytype,
    args: anytype,
) bool {
    var timer = std.time.Timer.start() catch unreachable;
    while (true) {
        const r = @call(.auto, pred, args);
        const ok = if (comptime @typeInfo(@TypeOf(r)) == .error_union)
            (r catch false)
        else
            r;
        if (ok) return true;
        const waited = timer.read();
        if (waited >= deadline_ns) {
            std.debug.print(
                "\nwaitUntil TIMEOUT after {d} ms waiting for: {s}\n",
                .{ waited / std.time.ns_per_ms, what },
            );
            return false;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

/// Wait on a `ResetEvent` another thread will set, bounded by the liveness
/// deadline. Use this in test bodies instead of the untimed `.wait()`, whose
/// failure mode is the T258 wedge (a lane hung with no failure text).
pub fn waitEvent(ev: *std.Thread.ResetEvent) error{Timeout}!void {
    ev.timedWait(liveness_ns) catch return error.Timeout;
}

/// Drain a pane ring (`inbound_ring.Channel`-shaped: `pop` returns a struct
/// with a `read` count) until `want` bytes have accumulated into `buf`, or
/// the liveness deadline expires with no progress. Returns the total byte
/// count collected. The deadline resets on progress: it bounds a STALL, not
/// the whole transfer, so a slow loaded box cannot spend it while bytes are
/// still flowing.
pub fn drainRing(ring: anytype, buf: []u8, want: usize) error{Timeout}!usize {
    var total: usize = 0;
    var timer = std.time.Timer.start() catch unreachable;
    while (total < want) {
        const r = ring.pop(buf[total..]);
        if (r.read > 0) {
            total += r.read;
            timer.reset();
            continue;
        }
        if (timer.read() >= liveness_ns) return error.Timeout;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return total;
}

test "waitUntil: an already-true predicate returns immediately" {
    const Pred = struct {
        fn yes() bool {
            return true;
        }
    };
    try std.testing.expect(waitUntil("the predicate that is already true", Pred.yes, .{}));
}

test "waitUntil: a predicate that never holds gives up at the deadline" {
    const Pred = struct {
        fn no() bool {
            return false;
        }
    };
    var timer = std.time.Timer.start() catch unreachable;
    // Prints the "waitUntil TIMEOUT after N ms waiting for: ..." line this
    // test cannot capture; what it asserts is the giving-up itself, bounded,
    // rather than spinning to the 60s liveness deadline.
    try std.testing.expect(!waitUntilFor("the deliberately unsatisfiable condition in test_util's own timeout test", 5 * std.time.ns_per_ms, Pred.no, .{}));
    try std.testing.expect(timer.read() >= 5 * std.time.ns_per_ms);
}

test "waitEvent: a pre-set event returns without waiting; args pass through" {
    var ev: std.Thread.ResetEvent = .{};
    ev.set();
    try waitEvent(&ev);
}

test "drainRing: bytes already present are collected without waiting" {
    // A minimal ring stand-in with the `pop -> .{ .read }` shape.
    const FakeRing = struct {
        data: []const u8,
        off: usize = 0,
        const Res = struct { read: usize };
        fn pop(self: *@This(), dst: []u8) Res {
            const n = @min(dst.len, self.data.len - self.off);
            @memcpy(dst[0..n], self.data[self.off..][0..n]);
            self.off += n;
            return .{ .read = n };
        }
    };
    var ring = FakeRing{ .data = "ping" };
    var buf: [8]u8 = undefined;
    const total = try drainRing(&ring, &buf, 4);
    try std.testing.expectEqualStrings("ping", buf[0..total]);
}

test "T472/T831: a test wait is bounded by the wall clock, not by a spin count" {
    // A spent budget is a timeout, and says so through the error rather than
    // by falling off the end of a loop.
    var spent = Deadline.startWith("the deliberately spent budget in Deadline's own test", 0);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    try std.testing.expect(spent.expired());
    try std.testing.expectError(error.Timeout, spent.yield());

    // ...and no number of yields can spend a budget that has not elapsed. This
    // is the property the old oracle lacked: 100_000 contended yields on a
    // loaded box were a "timeout" while nothing was actually late.
    var generous = Deadline.startWith("the generous budget no yield count can spend", 10 * std.time.ns_per_s * 60);
    for (0..200_000) |_| try generous.yield();
    try std.testing.expect(!generous.expired());
}

test "Deadline: progress resets the budget, so a moving wait is never a stall" {
    // The three numbers below are the whole test, and they are sized against
    // the SCHEDULER rather than for brevity (T1647). The first version asked a
    // 20 ms budget to survive four 8 ms sleeps: on a busy box an 8 ms sleep
    // routinely lands at 20 ms and more, so the assertion measured Windows'
    // timer slack rather than Deadline, and it reddened the win32 lane - and
    // test-reach-audit's lane arm with it - every time the box had work on it.
    //
    // step must be far enough under budget that ordinary overshoot cannot
    // reach it (3x here), and steps * step must be over budget, or a
    // progress() that reset NOTHING would pass this loop just as happily.
    const step_ns = 100 * std.time.ns_per_ms;
    const budget_ns = 300 * std.time.ns_per_ms;
    var d = Deadline.startWith("the budget a progress report keeps alive", budget_ns);
    // test-wait-audit: this counts deliberate sleeps to MEASURE the budget, it
    // does not wait on another thread - the count is the subject, not an oracle.
    for (0..5) |_| {
        std.Thread.sleep(step_ns);
        try std.testing.expect(!d.expired());
        d.progress();
    }
    // ...and with no progress reported, elapsed time past the budget spends it.
    std.Thread.sleep(budget_ns + step_ns);
    try std.testing.expect(d.expired());
    try std.testing.expectError(error.Timeout, d.tick());
}
