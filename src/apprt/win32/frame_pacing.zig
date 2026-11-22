//! A terminal pane's frame pacing, measured (T1737).
//!
//! Every smoothness claim about a terminal pane on this seat used to be
//! validated by reasoning: T1423 paced hero-mode thumbnail captures so they
//! stop stealing the hero pane's frames, and could count capture REQUESTS but
//! could not say what the hero pane's frames actually did. Mac measured
//! requestAnimationFrame intervals inside a WKWebView; a terminal pane here
//! has no such hook, so this is one: the moment each frame of a pane reached
//! the screen (`Surface.markFrameShown`, which both the direct swap and the
//! window presenter report through), kept as intervals in a fixed ring.
//!
//! Pure and clock-injected - `record` takes the timestamp - with no OS
//! imports, so its tests run in every app-runtime lane (the hero_math
//! pattern). The OS half (the QPC clock, the per-surface instance, the
//! `frame-pacing` debug IPC action that reads it) lives in `Surface.zig` and
//! `ipc_frame_pacing.zig`.
//!
//! What it is NOT: a vsync-accurate present clock. `markFrameShown` runs
//! right after the swap call returns, which is when the frame was handed to
//! the compositor, not when DWM put it on the glass. For the question it
//! answers - "did a frame of this pane wait on something it should not have"
//! - that is the right instant: a synchronous readback riding a frame shows
//! up as that frame's swap returning late.
const std = @import("std");

/// How many intervals the ring keeps. At 120 frames a second this is a little
/// over four seconds of a continuously redrawing pane, which is the length of
/// the gestures a harness drives; an idle pane keeps its last 512 frames
/// however long ago they were. Fixed so the recorder never allocates on the
/// thread that presents.
pub const capacity: usize = 512;

/// The histogram's bucket upper bounds, in microseconds. Chosen around the
/// frame periods that matter on real displays: 120 Hz (8.3 ms), 60 Hz
/// (16.7 ms), and the multiples a dropped frame lands on. The last bucket is
/// open-ended.
pub const bucket_bounds_us = [_]u32{ 4_000, 8_500, 12_000, 17_000, 25_000, 34_000, 50_000, 100_000, 250_000 };
pub const bucket_count = bucket_bounds_us.len + 1;

/// The label of bucket `i`, for the wire: `<=4ms`, ..., `>250ms`.
pub fn bucketLabel(i: usize) []const u8 {
    return switch (i) {
        0 => "<=4ms",
        1 => "<=8.5ms",
        2 => "<=12ms",
        3 => "<=17ms",
        4 => "<=25ms",
        5 => "<=34ms",
        6 => "<=50ms",
        7 => "<=100ms",
        8 => "<=250ms",
        else => ">250ms",
    };
}

pub fn bucketOf(interval_us: u32) usize {
    for (bucket_bounds_us, 0..) |bound, i| {
        if (interval_us <= bound) return i;
    }
    return bucket_bounds_us.len;
}

pub const Summary = struct {
    /// Frames recorded since the last reset (not capped by the ring).
    frames: u64 = 0,
    /// Intervals the statistics below are computed over (at most `capacity`:
    /// the most recent ones).
    intervals: u32 = 0,
    mean_us: u32 = 0,
    p50_us: u32 = 0,
    p95_us: u32 = 0,
    p99_us: u32 = 0,
    max_us: u32 = 0,
    /// Intervals longer than twice the median: the frames that waited on
    /// something. Relative to the pane's own median rather than a display
    /// period, so it reads the same on a 60 Hz and a 144 Hz panel and on the
    /// background test desktop, whose presents are not vsync-throttled.
    long: u32 = 0,
    /// Wall time the summarised intervals span, first to last frame.
    span_us: u64 = 0,
    histogram: [bucket_count]u32 = @splat(0),
};

pub const Recorder = struct {
    ring: [capacity]u32 = @splat(0),
    /// Next write position in `ring`.
    head: usize = 0,
    /// Valid entries in `ring` (saturates at `capacity`).
    len: usize = 0,
    frames: u64 = 0,
    last_ns: ?u64 = null,

    /// One frame reached the screen at `now_ns` (a monotonic clock). The
    /// first frame after a reset has nothing to measure against and only
    /// arms the clock. An interval past u32 microseconds (71 minutes) is
    /// clamped rather than wrapped, so an idle pane's next frame reads as
    /// one very long gap and not as a short one.
    pub fn record(self: *Recorder, now_ns: u64) void {
        self.frames +|= 1;
        const last = self.last_ns;
        self.last_ns = now_ns;
        const prev = last orelse return;
        // A clock that went backwards (it should not; QPC is monotonic) is a
        // zero-length interval, never an underflow.
        const delta_ns = if (now_ns > prev) now_ns - prev else 0;
        const us = @min(delta_ns / std.time.ns_per_us, std.math.maxInt(u32));
        self.ring[self.head] = @intCast(us);
        self.head = (self.head + 1) % capacity;
        if (self.len < capacity) self.len += 1;
    }

    pub fn reset(self: *Recorder) void {
        self.* = .{};
    }

    /// Statistics over the intervals in the ring. Allocation-free: the sort
    /// works on a stack copy, which is why `capacity` is small.
    pub fn summary(self: *const Recorder) Summary {
        var out: Summary = .{ .frames = self.frames, .intervals = @intCast(self.len) };
        if (self.len == 0) return out;

        var sorted: [capacity]u32 = undefined;
        const n = self.len;
        // Until the ring wraps its live entries are slots 0..len; after, all
        // of them are. Order does not matter for any statistic here, so the
        // first `len` slots are exactly the data either way.
        @memcpy(sorted[0..n], self.ring[0..n]);
        const xs = sorted[0..n];

        var sum: u64 = 0;
        for (xs) |x| {
            sum += x;
            out.histogram[bucketOf(x)] += 1;
        }
        out.span_us = sum;
        out.mean_us = @intCast(sum / n);

        std.mem.sort(u32, xs, {}, std.sort.asc(u32));
        out.p50_us = percentile(xs, 50);
        out.p95_us = percentile(xs, 95);
        out.p99_us = percentile(xs, 99);
        out.max_us = xs[n - 1];
        const threshold: u64 = @as(u64, out.p50_us) * 2;
        for (xs) |x| {
            if (x > threshold) out.long += 1;
        }
        return out;
    }
};

/// Nearest-rank percentile of an ascending slice.
fn percentile(sorted: []const u32, p: u32) u32 {
    std.debug.assert(sorted.len > 0);
    // rank = ceil(p/100 * n), 1-based.
    const rank = (@as(usize, p) * sorted.len + 99) / 100;
    const idx = if (rank == 0) 0 else rank - 1;
    return sorted[@min(idx, sorted.len - 1)];
}

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "frame_pacing: the first frame arms the clock and measures nothing" {
    var r: Recorder = .{};
    r.record(5 * ms);
    const s = r.summary();
    try testing.expectEqual(@as(u64, 1), s.frames);
    try testing.expectEqual(@as(u32, 0), s.intervals);
    try testing.expectEqual(@as(u32, 0), s.max_us);
}

test "frame_pacing: a steady 60 Hz pane has no long frames" {
    var r: Recorder = .{};
    var t: u64 = 0;
    for (0..61) |_| {
        r.record(t);
        t += 16_667 * std.time.ns_per_us;
    }
    const s = r.summary();
    try testing.expectEqual(@as(u64, 61), s.frames);
    try testing.expectEqual(@as(u32, 60), s.intervals);
    try testing.expectEqual(@as(u32, 16_667), s.p50_us);
    try testing.expectEqual(@as(u32, 16_667), s.p99_us);
    try testing.expectEqual(@as(u32, 0), s.long);
    try testing.expectEqual(@as(u32, 60), s.histogram[bucketOf(16_667)]);
}

test "frame_pacing: one hitch shows as a long frame, the max, and the tail" {
    var r: Recorder = .{};
    var t: u64 = 0;
    for (0..100) |i| {
        r.record(t);
        // Frame 50 waited 40 ms on something - the shape of a synchronous
        // readback riding a frame.
        t += if (i == 50) 40 * ms else 8 * ms;
    }
    r.record(t);
    const s = r.summary();
    try testing.expectEqual(@as(u32, 100), s.intervals);
    try testing.expectEqual(@as(u32, 8_000), s.p50_us);
    try testing.expectEqual(@as(u32, 40_000), s.max_us);
    try testing.expectEqual(@as(u32, 1), s.long);
    try testing.expectEqual(@as(u32, 1), s.histogram[bucketOf(40_000)]);
    // 99 intervals of 8 ms + one of 40 = 832 ms over 100.
    try testing.expectEqual(@as(u32, 8_320), s.mean_us);
}

test "frame_pacing: the ring keeps the most recent intervals only" {
    var r: Recorder = .{};
    var t: u64 = 0;
    // A slow early stretch that must age out...
    for (0..10) |_| {
        r.record(t);
        t += 100 * ms;
    }
    // ...behind a full ring of fast frames.
    for (0..capacity + 1) |_| {
        r.record(t);
        t += 5 * ms;
    }
    const s = r.summary();
    try testing.expectEqual(@as(u32, capacity), s.intervals);
    try testing.expectEqual(@as(u32, 5_000), s.max_us);
    try testing.expectEqual(@as(u64, 10 + capacity + 1), s.frames);
}

test "frame_pacing: reset forgets everything, including the armed clock" {
    var r: Recorder = .{};
    r.record(0);
    r.record(10 * ms);
    r.reset();
    r.record(1000 * ms);
    const s = r.summary();
    try testing.expectEqual(@as(u64, 1), s.frames);
    try testing.expectEqual(@as(u32, 0), s.intervals);
}

test "frame_pacing: a clock that steps backwards is a zero interval, not a wrap" {
    var r: Recorder = .{};
    r.record(50 * ms);
    r.record(40 * ms);
    const s = r.summary();
    try testing.expectEqual(@as(u32, 1), s.intervals);
    try testing.expectEqual(@as(u32, 0), s.max_us);
}

test "frame_pacing: buckets cover every interval and the last is open-ended" {
    try testing.expectEqual(@as(usize, 0), bucketOf(0));
    try testing.expectEqual(@as(usize, 0), bucketOf(4_000));
    try testing.expectEqual(@as(usize, 1), bucketOf(4_001));
    try testing.expectEqual(@as(usize, 3), bucketOf(16_667));
    try testing.expectEqual(bucket_bounds_us.len, bucketOf(std.math.maxInt(u32)));
    for (0..bucket_count) |i| try testing.expect(bucketLabel(i).len > 0);
}

test "frame_pacing: nearest-rank percentiles" {
    const xs = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try testing.expectEqual(@as(u32, 5), percentile(&xs, 50));
    try testing.expectEqual(@as(u32, 10), percentile(&xs, 95));
    try testing.expectEqual(@as(u32, 10), percentile(&xs, 99));
    const one = [_]u32{7};
    try testing.expectEqual(@as(u32, 7), percentile(&one, 50));
}
