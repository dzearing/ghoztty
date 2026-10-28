//! The pure half of the app's frame clock (T2365): which animations are
//! subscribed, and how evenly their ticks actually landed.
//!
//! Every animation used to own a 16 ms `SetTimer`. Windows rounds that to its
//! 15.6 ms system tick and generates WM_TIMER only when the queue is otherwise
//! empty, so on the user's 60 Hz box a "16 ms" tick landed at 16 or 31 ms
//! about half the time each (mean 25.6 ms): a glide whose maths was already
//! wall-clock correct was sampled unevenly and shown on whichever vsync came
//! next, which reads as judder. Mac steps the same glide on a 120 Hz timer
//! inside one CoreAnimation transaction, presented on the display clock.
//!
//! `FrameClock.zig` owns the OS half - a worker blocked on the compositor's
//! clock that posts one coalesced frame message per vblank while anything is
//! subscribed. This file holds what that needs and can be asserted in every
//! lane: the subscription set (keyed by the same `(hwnd, id)` pair `SetTimer`
//! uses, so a converted animation keeps its WM_TIMER handler unchanged), and
//! the per-run interval statistics the acceptance oracle reads.
const std = @import("std");

/// More than every frame-clocked animation the app can run at once: a window
/// holds at most a handful (glide, hero, glow, banner, sidebar), and a full
/// set means a subscription falls back to its own `SetTimer`, never a crash.
pub const capacity: usize = 64;

/// The vblank period assumed before the clock has measured one (60 Hz).
pub const default_period_ns: u64 = 16_666_667;

/// A tick that arrived more than this many periods after the previous one
/// skipped a vsync: the "31 ms on a 60 Hz display" shape this exists to end.
pub const doubled_factor_num: u64 = 3;
pub const doubled_factor_den: u64 = 2;

/// How one animation run's ticks landed, from arm to disarm.
pub const Stats = struct {
    ticks: u32 = 0,
    /// Intervals between consecutive ticks (ticks - 1 of them).
    intervals: u32 = 0,
    interval_sum_ns: u64 = 0,
    interval_max_ns: u64 = 0,
    /// Intervals longer than 1.5 periods: a frame the animation missed.
    doubled: u32 = 0,
    /// What the tick's handler cost on the UI thread.
    cost_sum_ns: u64 = 0,
    cost_max_ns: u64 = 0,

    pub fn recordInterval(self: *Stats, interval_ns: u64, period_ns: u64) void {
        self.intervals += 1;
        self.interval_sum_ns += interval_ns;
        self.interval_max_ns = @max(self.interval_max_ns, interval_ns);
        if (isDoubled(interval_ns, period_ns)) self.doubled += 1;
    }

    pub fn recordCost(self: *Stats, cost_ns: u64) void {
        self.ticks += 1;
        self.cost_sum_ns += cost_ns;
        self.cost_max_ns = @max(self.cost_max_ns, cost_ns);
    }

    pub fn meanIntervalUs(self: Stats) u64 {
        if (self.intervals == 0) return 0;
        return self.interval_sum_ns / self.intervals / std.time.ns_per_us;
    }

    pub fn meanCostUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.cost_sum_ns / self.ticks / std.time.ns_per_us;
    }

    /// Worth a report line: a run of one tick has no interval to judge.
    pub fn reportable(self: Stats) bool {
        return self.intervals >= 2;
    }
};

pub fn isDoubled(interval_ns: u64, period_ns: u64) bool {
    return interval_ns * doubled_factor_den > period_ns * doubled_factor_num;
}

/// How much time a glide's FIRST frame may take up (T2401): at most one
/// display period, however late it lands. The layout pass that starts a
/// glide - moving every card, a web view among them - can hold the UI thread
/// for tens of milliseconds before the first frame is painted, and a glide
/// clocked from the click spends that time on nothing the eye saw: Mac's
/// ease-out puts 80% of the motion in its first third, so 50 ms late is most
/// of a 240 ms glide gone in one frame - a snap. Core Animation starts its
/// clock at the transaction's commit, which is the same rule. `elapsed` and
/// `period` share one unit.
pub fn firstFrame(elapsed: anytype, period: @TypeOf(elapsed)) @TypeOf(elapsed) {
    return @min(elapsed, period);
}

pub const Sub = struct {
    hwnd: usize,
    id: usize,
    /// When this subscription's previous tick was delivered (monotonic ns).
    last_ns: ?u64 = null,
    stats: Stats = .{},
};

/// The subscribed animations, in arm order. Touched on the UI thread only.
pub const Set = struct {
    items: [capacity]Sub = undefined,
    len: usize = 0,

    pub const ArmResult = enum { added, already, full };

    /// Subscribe `(hwnd, id)`. Re-arming a live pair is a no-op that keeps
    /// its statistics running, the way `SetTimer` on a live id replaces the
    /// timer rather than adding a second one.
    pub fn arm(self: *Set, hwnd: usize, id: usize) ArmResult {
        if (self.indexOf(hwnd, id) != null) return .already;
        if (self.len == capacity) return .full;
        self.items[self.len] = .{ .hwnd = hwnd, .id = id };
        self.len += 1;
        return .added;
    }

    /// Unsubscribe `(hwnd, id)` and hand back what its run measured, or null
    /// when it was not subscribed (`KillTimer` on a dead id: harmless).
    pub fn disarm(self: *Set, hwnd: usize, id: usize) ?Sub {
        const i = self.indexOf(hwnd, id) orelse return null;
        const sub = self.items[i];
        // Keep arm order: dispatch walks it, and a later arm ticking first
        // would make two animations armed in one handler step in a new order.
        std.mem.copyForwards(Sub, self.items[i .. self.len - 1], self.items[i + 1 .. self.len]);
        self.len -= 1;
        return sub;
    }

    pub fn contains(self: *const Set, hwnd: usize, id: usize) bool {
        return self.indexOf(hwnd, id) != null;
    }

    pub fn get(self: *Set, hwnd: usize, id: usize) ?*Sub {
        const i = self.indexOf(hwnd, id) orelse return null;
        return &self.items[i];
    }

    pub fn slice(self: *const Set) []const Sub {
        return self.items[0..self.len];
    }

    fn indexOf(self: *const Set, hwnd: usize, id: usize) ?usize {
        for (self.items[0..self.len], 0..) |s, i| {
            if (s.hwnd == hwnd and s.id == id) return i;
        }
        return null;
    }
};

/// The vblank period, learned from the clock's own wakeups: the shortest
/// interval in a sliding window is the display's period (a late wakeup is
/// only ever longer), held within plausible display rates.
pub const PeriodEstimator = struct {
    window: [32]u64 = [_]u64{0} ** 32,
    next: usize = 0,
    filled: usize = 0,

    pub const min_ns: u64 = 4 * std.time.ns_per_ms; // 250 Hz
    pub const max_ns: u64 = 50 * std.time.ns_per_ms; // 20 Hz

    pub fn record(self: *PeriodEstimator, interval_ns: u64) void {
        // A clock that parked while idle wakes with one huge interval; it says
        // nothing about the display.
        if (interval_ns > max_ns) return;
        self.window[self.next] = interval_ns;
        self.next = (self.next + 1) % self.window.len;
        self.filled = @min(self.filled + 1, self.window.len);
    }

    pub fn periodNs(self: *const PeriodEstimator) u64 {
        if (self.filled < 4) return default_period_ns;
        var best: u64 = std.math.maxInt(u64);
        for (self.window[0..self.filled]) |v| best = @min(best, v);
        return std.math.clamp(best, min_ns, max_ns);
    }
};

/// Whether the worker should post a frame now. One frame message is ever in
/// flight: the UI thread clears `pending` only AFTER it has run every tick, so
/// a dispatch slower than a vblank skips the next post instead of queueing one
/// behind it. That matters because a posted message outranks input in
/// `GetMessage`: back-to-back frame posts would starve the very mouse moves a
/// glide under a drag is following.
pub fn shouldPost(live: usize, pending: bool) bool {
    return live > 0 and !pending;
}

const testing = std.testing;

test "arm adds once, re-arm keeps the run, disarm returns it in order" {
    var set: Set = .{};
    try testing.expectEqual(Set.ArmResult.added, set.arm(1, 0x534C));
    try testing.expectEqual(Set.ArmResult.added, set.arm(1, 0x4841));
    try testing.expectEqual(Set.ArmResult.added, set.arm(2, 0x534C));
    set.get(1, 0x534C).?.stats.recordCost(1000);
    try testing.expectEqual(Set.ArmResult.already, set.arm(1, 0x534C));
    try testing.expectEqual(@as(u32, 1), set.get(1, 0x534C).?.stats.ticks);
    try testing.expectEqual(@as(usize, 3), set.len);

    const gone = set.disarm(1, 0x534C).?;
    try testing.expectEqual(@as(u32, 1), gone.stats.ticks);
    try testing.expect(!set.contains(1, 0x534C));
    try testing.expectEqual(@as(usize, 0x4841), set.slice()[0].id);
    try testing.expectEqual(@as(usize, 2), set.slice()[1].hwnd);
    try testing.expectEqual(@as(?Sub, null), set.disarm(1, 0x534C));
}

test "a full set refuses rather than overwriting" {
    var set: Set = .{};
    for (0..capacity) |i| try testing.expectEqual(Set.ArmResult.added, set.arm(i, 1));
    try testing.expectEqual(Set.ArmResult.full, set.arm(capacity, 1));
    try testing.expectEqual(Set.ArmResult.already, set.arm(0, 1));
    _ = set.disarm(5, 1);
    try testing.expectEqual(Set.ArmResult.added, set.arm(capacity, 1));
}

test "an interval past 1.5 periods is a missed frame; one inside is not" {
    const p = default_period_ns;
    try testing.expect(!isDoubled(p, p));
    try testing.expect(!isDoubled(p + 2 * std.time.ns_per_ms, p));
    try testing.expect(isDoubled(31 * std.time.ns_per_ms, p));
    try testing.expect(isDoubled(26 * std.time.ns_per_ms, p));
}

test "stats: the user's measured 16/31 ms timer is half doubled; a vsync clock is not" {
    const p = default_period_ns;
    var timer: Stats = .{};
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        timer.recordInterval(if (i % 2 == 0) 16 * std.time.ns_per_ms else 31 * std.time.ns_per_ms, p);
    }
    try testing.expectEqual(@as(u32, 10), timer.doubled);
    try testing.expectEqual(@as(u64, 23_500), timer.meanIntervalUs());

    var vsync: Stats = .{};
    i = 0;
    while (i < 20) : (i += 1) vsync.recordInterval(p + @as(u64, if (i % 2 == 0) 300_000 else 0), p);
    try testing.expectEqual(@as(u32, 0), vsync.doubled);
    try testing.expect(vsync.reportable());
    try testing.expect(!(Stats{ .intervals = 1 }).reportable());
}

test "period estimator: shortest recent interval, ignoring idle gaps and bounded" {
    var est: PeriodEstimator = .{};
    try testing.expectEqual(default_period_ns, est.periodNs());
    est.record(16_700_000);
    est.record(33_400_000);
    est.record(10 * std.time.ns_per_s); // parked while idle
    est.record(16_600_000);
    try testing.expectEqual(default_period_ns, est.periodNs()); // only 3 real samples
    est.record(16_900_000);
    try testing.expectEqual(@as(u64, 16_600_000), est.periodNs());

    var fast: PeriodEstimator = .{};
    for (0..8) |_| fast.record(std.time.ns_per_ms);
    try testing.expectEqual(PeriodEstimator.min_ns, fast.periodNs());
}

test "one frame in flight: post only while live and not already pending" {
    try testing.expect(shouldPost(1, false));
    try testing.expect(!shouldPost(1, true));
    try testing.expect(!shouldPost(0, false));
}

test "T2401: a glide's first frame takes up at most one period, however late" {
    // On time: the time that actually passed.
    try std.testing.expectEqual(@as(u64, 5), firstFrame(@as(u64, 5), 8));
    // 50 ms of layout before it: one 8 ms period, not 50.
    try std.testing.expectEqual(@as(u64, 8), firstFrame(@as(u64, 50), 8));
    try std.testing.expectEqual(@as(u64, 0), firstFrame(@as(u64, 0), 8));
    // The grid's glide steps in float milliseconds.
    try std.testing.expectEqual(@as(f64, 8.3), firstFrame(@as(f64, 41.5), 8.3));
}
