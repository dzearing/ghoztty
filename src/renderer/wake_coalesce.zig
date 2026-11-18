//! Coalescing for output-driven renderer wakeups (T3061, audit finding PA-C04).
//!
//! Every output batch the IO thread parses asks the renderer to draw. The
//! renderer builds at most one frame per wakeup, so under a flood (measured by
//! T3059: ~30k batches/s against ~120 frames/s) nearly every request is
//! redundant. On IOCP each one is a PostQueuedCompletionStatus plus a packet
//! the loop dequeues and throws away, and libxev's `Async.notify` takes a
//! guard mutex first. Upstream libxev is not forked; the coalescing lives here.
//!
//! The contract is one flag per renderer wakeup:
//!
//! - a producer (`request`) sets the flag and notifies only when it was CLEAR,
//!   so N requests with no wakeup in between cost one notify;
//! - the renderer (`consume`) clears the flag at the top of its wakeup
//!   callback, BEFORE it drains the mailbox or reads the terminal. Any output
//!   parsed after that point finds the flag clear and notifies again, so the
//!   frame for it is never lost. Clearing after the read would open exactly
//!   the window a frozen pane needs (T40: a lost wakeup is a pane that stops
//!   repainting until something else wakes it).
//!
//! Both sides use an acq_rel swap: the renderer's clear reads the producer's
//! set and so synchronizes with it, which orders the producer's terminal
//! unlock before the renderer's terminal lock for the frame that follows.
//!
//! Wakeups that do not go through `request` (resize, focus, config, mailbox
//! producers) still notify the Async directly. That is safe: they only ever
//! ADD wakeups, and a wakeup always clears the flag.

const std = @import("std");

pub const Pending = std.atomic.Value(bool);

/// Ask for a render. `notifier` is anything with `notify() !void` (an
/// `xev.Async` in the app, a counter in tests). With no flag the request is
/// passed straight through, which is the behavior before T3061.
///
/// A failed notify clears the flag again so the next request retries it rather
/// than believing a wakeup is already on its way.
///
/// Returns whether a notify was actually posted (for GHOZTTY_PERF telemetry).
pub fn request(pending: ?*Pending, notifier: anytype) !bool {
    const flag = pending orelse {
        try notifier.notify();
        return true;
    };
    if (flag.swap(true, .acq_rel)) return false;
    notifier.notify() catch |err| {
        flag.store(false, .release);
        return err;
    };
    return true;
}

/// Called by the renderer at the top of its wakeup callback, before it reads
/// any state the request was about.
pub fn consume(pending: *Pending) void {
    _ = pending.swap(false, .acq_rel);
}

const CountingNotifier = struct {
    count: u32 = 0,
    fail: bool = false,

    pub fn notify(self: *CountingNotifier) !void {
        if (self.fail) return error.NotifyFailed;
        self.count += 1;
    }
};

test "requests with no wakeup in between notify once" {
    var pending: Pending = .init(false);
    var n: CountingNotifier = .{};
    for (0..1000) |_| _ = try request(&pending, &n);
    try std.testing.expectEqual(@as(u32, 1), n.count);
    try std.testing.expect(pending.load(.acquire));
}

test "a request after the wakeup cleared the flag notifies again" {
    var pending: Pending = .init(false);
    var n: CountingNotifier = .{};
    _ = try request(&pending, &n);
    _ = try request(&pending, &n);
    consume(&pending);
    _ = try request(&pending, &n);
    _ = try request(&pending, &n);
    try std.testing.expectEqual(@as(u32, 2), n.count);
}

test "no flag passes every request through" {
    var n: CountingNotifier = .{};
    for (0..5) |_| _ = try request(null, &n);
    try std.testing.expectEqual(@as(u32, 5), n.count);
}

test "a failed notify leaves the flag clear so the next request retries" {
    var pending: Pending = .init(false);
    var n: CountingNotifier = .{ .fail = true };
    try std.testing.expectError(error.NotifyFailed, request(&pending, &n));
    try std.testing.expect(!pending.load(.acquire));
    n.fail = false;
    _ = try request(&pending, &n);
    try std.testing.expectEqual(@as(u32, 1), n.count);
}

test "concurrent producers against a consuming renderer never strand a request" {
    // The renderer consumes one wakeup per notify it was sent. Once every
    // producer has finished and every notify has been consumed, a flag still
    // set would be a request with no wakeup coming: the frozen pane.
    const Shared = struct {
        pending: Pending = .init(false),
        notifies: std.atomic.Value(u32) = .init(0),
        finished: std.atomic.Value(u32) = .init(0),

        pub fn notify(self: *@This()) !void {
            _ = self.notifies.fetchAdd(1, .acq_rel);
        }
    };
    const producers = 4;
    const per = 20_000;
    const Producer = struct {
        fn run(sh: *Shared) void {
            for (0..per) |_| _ = request(&sh.pending, sh) catch unreachable;
            _ = sh.finished.fetchAdd(1, .acq_rel);
        }
    };
    var s: Shared = .{};
    var threads: [producers]std.Thread = undefined;
    // thread-join-audit: array of handles, each joined by the `t.join()` loop below; producers end after `per` requests
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Producer.run, .{&s});
    var consumed: u32 = 0;
    while (true) {
        const all_done = s.finished.load(.acquire) == producers;
        if (s.notifies.load(.acquire) > consumed) {
            consumed += 1;
            consume(&s.pending);
        } else if (all_done) break else std.Thread.yield() catch {};
    }
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(s.notifies.load(.acquire), consumed);
    try std.testing.expect(!s.pending.load(.acquire));
    try std.testing.expect(consumed >= 1);
}
