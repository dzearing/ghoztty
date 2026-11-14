//! What DWM did while one glide tick ran (T2952): from the target vblanks of
//! the frames it completed inside the tick, how many it composed and the
//! longest stretch it went without completing one.
//!
//! A 4K fold glide has a rare tick where a tiny GDI blit to the window, or a
//! pane's present at its new size, blocks for 20-40 ms. That shape - a cheap
//! call waiting a frame or more, with the box otherwise idle - points at the
//! compositor. This is the arithmetic that says whether DWM itself went quiet
//! across such a stall, free of win32 so the `none` lane tests it; the probe
//! that feeds it is `stall_probe.zig`.
//!
//! Limit, stated where the number is made: DWM composes only when something
//! on screen changed, so a gap also opens when nothing did. During a glide the
//! panes present every tick, so a gap of several periods while the UI thread
//! sat blocked is the compositor not composing, not the screen being still.
const std = @import("std");

pub const Gaps = struct {
    /// Frames DWM completed whose target vblank fell after `t0`.
    frames: u32 = 0,
    /// The longest span with no completed frame, from `t0` through each
    /// target to `t1`, in the caller's units.
    max_gap: i64 = 0,
};

/// Score `targets` (target vblanks of completed frames, ascending) over the
/// window [t0, t1]. Targets before `t0` are ignored; a target after `t1`
/// (a frame aimed at a vblank still to come) counts as a frame and closes the
/// last gap at `t1`.
pub fn score(targets: []const i64, t0: i64, t1: i64) Gaps {
    var g: Gaps = .{};
    if (t1 <= t0) return g;
    var prev = t0;
    for (targets) |t| {
        if (t <= t0) continue;
        g.frames += 1;
        const at = @min(t, t1);
        g.max_gap = @max(g.max_gap, at - prev);
        prev = at;
    }
    g.max_gap = @max(g.max_gap, t1 - prev);
    return g;
}

test "a steady compositor leaves gaps of one period" {
    const p = 8;
    const ts = [_]i64{ 8, 16, 24, 32 };
    const g = score(&ts, 0, 33);
    try std.testing.expectEqual(@as(u32, 4), g.frames);
    try std.testing.expectEqual(@as(i64, p), g.max_gap);
}

test "a compositor that stops shows the stretch it stopped for" {
    const ts = [_]i64{ 8, 40, 48 };
    const g = score(&ts, 0, 50);
    try std.testing.expectEqual(@as(u32, 3), g.frames);
    try std.testing.expectEqual(@as(i64, 32), g.max_gap);
}

test "no frame at all is one gap the length of the window" {
    const g = score(&.{}, 100, 130);
    try std.testing.expectEqual(@as(u32, 0), g.frames);
    try std.testing.expectEqual(@as(i64, 30), g.max_gap);
}

test "frames before the window are not counted, a future target closes at t1" {
    const ts = [_]i64{ 2, 5, 12, 60 };
    const g = score(&ts, 10, 20);
    try std.testing.expectEqual(@as(u32, 2), g.frames);
    // 10 -> 12, then 12 -> 20 (the frame aimed at 60 is clamped to t1).
    try std.testing.expectEqual(@as(i64, 8), g.max_gap);
}

test "an empty window scores nothing" {
    const ts = [_]i64{ 1, 2 };
    const g = score(&ts, 5, 5);
    try std.testing.expectEqual(@as(u32, 0), g.frames);
    try std.testing.expectEqual(@as(i64, 0), g.max_gap);
}
