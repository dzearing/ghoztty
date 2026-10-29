//! Frame-interval scoring for the composition spike (T2360).
//!
//! The oracle is DWM's own compose clock: a sampler records the target vblank
//! (QPC) of every frame DWM composed (`DCompositionGetFrameId` /
//! `DCompositionGetStatistics`). Over one glide's window this scores how many display
//! refreshes got a new frame, and how long the longest hold was. A glide that
//! advances on every refresh scores `advance` ~1.0 and `skipped` 0.
//!
//! Limit, stated where the number is made: the compose clock is system-wide,
//! so anything else on screen that changes can ADD composes inside a window.
//! Noise can only flatter a path, never penalise one, which is why the spike
//! also runs an `idle` mode (same schedule, nothing animating) as the noise
//! floor to read the other modes against.
const std = @import("std");

pub const Score = struct {
    composes: u32 = 0,
    refreshes: f64 = 0,
    advance: f64 = 0,
    max_gap: f64 = 0,
    p95_gap: f64 = 0,
    /// Refreshes inside the window that got no new frame.
    skipped: u32 = 0,
};

/// Score compose times `ts` (ascending, any range) over the window
/// [t0, t1] with a refresh period of `period` (all in the same unit).
/// `scratch` must hold at least `ts.len + 1` gaps.
pub fn score(ts: []const i64, t0: i64, t1: i64, period: f64, scratch: []f64) Score {
    var s: Score = .{};
    if (t1 <= t0 or period <= 0) return s;
    s.refreshes = @as(f64, @floatFromInt(t1 - t0)) / period;

    var prev = t0;
    var n: usize = 0;
    for (ts) |t| {
        if (t < t0) continue;
        if (t > t1) break;
        s.composes += 1;
        if (n < scratch.len) {
            scratch[n] = @floatFromInt(t - prev);
            n += 1;
        }
        prev = t;
    }
    if (n < scratch.len) {
        scratch[n] = @floatFromInt(t1 - prev);
        n += 1;
    }

    for (scratch[0..n]) |g| {
        s.max_gap = @max(s.max_gap, g);
        const held = @round(g / period);
        if (held > 1) s.skipped += @intFromFloat(held - 1);
    }
    s.advance = @as(f64, @floatFromInt(s.composes)) / s.refreshes;

    std.mem.sort(f64, scratch[0..n], {}, std.sort.asc(f64));
    if (n > 0) {
        const idx = @min(n - 1, (n * 95 + 99) / 100 - 1);
        s.p95_gap = scratch[idx];
    }
    return s;
}

/// How many refreshes each new frame was held for, between consecutive frames
/// inside a window: n[0] counts holds of 1 refresh (a frame on every
/// refresh), n[1] of 2, ... n[4] of 5 or more. The shape tells a capped
/// cadence (all mass on one bucket, e.g. 3 = 40 Hz at 120 Hz) from jitter.
pub const Holds = struct {
    n: [5]u32 = .{ 0, 0, 0, 0, 0 },

    pub fn add(self: *Holds, ts: []const i64, t0: i64, t1: i64, period: f64) void {
        if (period <= 0) return;
        var prev: ?i64 = null;
        for (ts) |t| {
            if (t < t0) continue;
            if (t > t1) break;
            if (prev) |p| {
                const held = @max(1, @round(@as(f64, @floatFromInt(t - p)) / period));
                self.n[@min(4, @as(usize, @intFromFloat(held)) - 1)] += 1;
            }
            prev = t;
        }
    }
};

const testing = std.testing;

test "holds bucket each gap by whole refreshes, inside the window only" {
    var h: Holds = .{};
    h.add(&.{ 0, 10, 20, 50, 60, 130, 200 }, 5, 140, 10);
    // gaps inside [5,140]: 10->20 (1), 20->50 (3), 50->60 (1), 60->130 (5+)
    try testing.expectEqual([5]u32{ 2, 0, 1, 0, 1 }, h.n);
}

test "a frame on every refresh scores advance 1 and no skips" {
    var ts: [12]i64 = undefined;
    for (&ts, 0..) |*t, i| t.* = @intCast(100 + (i + 1) * 10);
    var scratch: [16]f64 = undefined;
    const s = score(&ts, 100, 220, 10, &scratch);
    try testing.expectEqual(@as(u32, 12), s.composes);
    try testing.expectApproxEqAbs(@as(f64, 1.0), s.advance, 1e-9);
    try testing.expectEqual(@as(u32, 0), s.skipped);
    try testing.expectApproxEqAbs(@as(f64, 10), s.max_gap, 1e-9);
}

test "a frame every third refresh skips two of every three" {
    const ts = [_]i64{ 30, 60, 90, 120 };
    var scratch: [8]f64 = undefined;
    const s = score(&ts, 0, 120, 10, &scratch);
    try testing.expectEqual(@as(u32, 4), s.composes);
    try testing.expectEqual(@as(u32, 8), s.skipped);
    try testing.expectApproxEqAbs(@as(f64, 4.0 / 12.0), s.advance, 1e-9);
}

test "a stall shows as one long hold, and composes outside the window are ignored" {
    const ts = [_]i64{ 5, 10, 20, 30, 80, 90, 100, 150 };
    var scratch: [16]f64 = undefined;
    const s = score(&ts, 10, 100, 10, &scratch);
    try testing.expectEqual(@as(u32, 6), s.composes);
    try testing.expectApproxEqAbs(@as(f64, 50), s.max_gap, 1e-9);
    try testing.expectEqual(@as(u32, 4), s.skipped);
}

test "an empty window scores no frames and every refresh skipped" {
    var scratch: [4]f64 = undefined;
    const s = score(&.{}, 0, 100, 10, &scratch);
    try testing.expectEqual(@as(u32, 0), s.composes);
    try testing.expectEqual(@as(u32, 9), s.skipped);
    try testing.expectApproxEqAbs(@as(f64, 100), s.max_gap, 1e-9);
}
