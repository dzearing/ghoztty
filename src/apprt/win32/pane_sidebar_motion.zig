//! The pane sidebar's two motions (T1843), pure so they are testable: a busy
//! pane's mark shimmers - drawn dim, with a brighter band sweeping across it -
//! and a question badge breathes a soft ring. Both are Mac's
//! (`PaneSidebarShimmer` and `PaneSidebarQuestionBadge` in
//! PaneSidebarView.swift), translated from SwiftUI's animation clock to a
//! window timer that repaints the column, and both stop outright when the
//! user turned off "Animation effects" (SPI_GETCLIENTAREAANIMATION, Mac's
//! Reduce Motion): the busy mark is then drawn plain and the ring not at all.

const std = @import("std");

/// One shimmer cycle: a sweep, then a short rest before the next (Mac 1.4s).
pub const shimmer_period_ms: u64 = 1400;
/// The part of the period the band spends moving (Mac 0.8).
pub const shimmer_sweep_fraction: f64 = 0.8;
/// The band layer is this many times the mark's width, so that at either end
/// of its travel the bright band is fully off the mark (Mac 3).
pub const band_width_factor: f64 = 3;
/// The mark's opacity under the band (Mac 0.3: at 0.62 the band read as no
/// busy indication at all on a 14pt glyph).
pub const base_opacity: f64 = 0.3;
/// Where the band's gradient stops sit across the band layer (Mac
/// `LinearGradient` stops: clear at 0.35, solid at 0.5, clear at 0.65).
pub const band_stops = [3]f64{ 0.35, 0.5, 0.65 };

/// The question ring breathes 0 -> peak -> 0, each half this long (Mac
/// `.easeInOut(duration: 1.2).repeatForever(autoreverses: true)`).
pub const pulse_half_ms: u64 = 1200;
/// The ring's opacity at its fullest (Mac 0.22).
pub const pulse_peak: f64 = 0.22;
/// The ring's width outside the badge, in DIP (Mac lineWidth 3, padded out
/// by half of it, so the ring sits wholly outside the capsule).
pub const pulse_ring_dip: f32 = 3;

/// The repaint cadence while anything moves: 30 frames a second is smooth
/// for a band crossing a 12-16 DIP mark, at half the cost of 60.
pub const frame_ms: u32 = 33;

/// 1 = band parked off the LEADING edge, 0 = off the TRAILING edge; the
/// sweep runs 1 -> 0 (left to right), eased, then rests at 0. Mac
/// `PaneSidebarShimmer.bandPosition`.
pub fn bandPosition(ms: u64) f64 {
    const phase = @as(f64, @floatFromInt(ms % shimmer_period_ms)) / @as(f64, @floatFromInt(shimmer_period_ms));
    const t = @min(1.0, phase / shimmer_sweep_fraction);
    const eased = if (t < 0.5) 2 * t * t else 1 - std.math.pow(f64, -2 * t + 2, 2) / 2;
    return 1 - eased;
}

/// How opaque the mark is at `x` across it (0 = leading edge, 1 = trailing)
/// with the band at `position`: the dim base, plus the band's light on top
/// (source-over of the same color, so `band + base * (1 - band)`).
pub fn shimmerAlpha(x: f64, position: f64) f64 {
    // The band layer is `band_width_factor` marks wide and starts at
    // -(factor - 1) * position marks (Mac `PaneSidebarShimmer.offset`), so a
    // point x of the mark sits at u across the layer.
    const offset = -(band_width_factor - 1) * position;
    const u = (x - offset) / band_width_factor;
    const band = bandWeight(u);
    return band + base_opacity * (1 - band);
}

/// The gradient's opacity at `u` across the band layer: a triangle on the
/// three stops.
fn bandWeight(u: f64) f64 {
    const lo, const mid, const hi = band_stops;
    if (u <= lo or u >= hi) return 0;
    if (u <= mid) return (u - lo) / (mid - lo);
    return (hi - u) / (hi - mid);
}

/// The question ring's opacity at `ms`: up and back down, eased at both ends.
pub fn pulseAlpha(ms: u64) f64 {
    const cycle = 2 * pulse_half_ms;
    const phase = ms % cycle;
    const half = @as(f64, @floatFromInt(pulse_half_ms));
    const t = if (phase < pulse_half_ms)
        @as(f64, @floatFromInt(phase)) / half
    else
        @as(f64, @floatFromInt(cycle - phase)) / half;
    // SwiftUI's easeInOut is a cubic bezier; smoothstep is its close twin.
    return pulse_peak * (t * t * (3 - 2 * t));
}

/// What the column shows right now, and so whether it needs a clock.
pub const Marks = struct {
    /// Busy marks drawn (each shimmers when motion is on).
    busy: usize = 0,
    /// Question badges with a ring (rows and window headers - a rail tile's
    /// corner "?" holds still, as Mac's does).
    pulsing: usize = 0,
    /// Bell dots on stashed rows: shown, never animated.
    bells: usize = 0,

    pub fn moving(self: Marks, motion: bool) bool {
        return motion and (self.busy > 0 or self.pulsing > 0);
    }
};

test "the band sweeps leading to trailing, then rests off the trailing edge" {
    try std.testing.expectApproxEqAbs(@as(f64, 1), bandPosition(0), 1e-9);
    // Halfway through the sweep (0.8 * 1400 / 2 = 560 ms) the ease is at 0.5.
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), bandPosition(560), 1e-9);
    // The sweep ends at 1120 ms and the band rests at 0 until the period ends.
    try std.testing.expectApproxEqAbs(@as(f64, 0), bandPosition(1120), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), bandPosition(1399), 1e-9);
    // And starts again.
    try std.testing.expectApproxEqAbs(@as(f64, 1), bandPosition(1400), 1e-9);
    // Monotone over the sweep.
    var prev: f64 = 2;
    var ms: u64 = 0;
    while (ms <= 1120) : (ms += 10) {
        const p = bandPosition(ms);
        try std.testing.expect(p <= prev);
        prev = p;
    }
}

test "parked at either end, the band is fully off the mark: the mark is its dim base" {
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        const x = @as(f64, @floatFromInt(i)) / 20;
        try std.testing.expectApproxEqAbs(base_opacity, shimmerAlpha(x, 1), 1e-9);
        try std.testing.expectApproxEqAbs(base_opacity, shimmerAlpha(x, 0), 1e-9);
    }
}

test "mid-sweep the band's bright middle is on the mark, and never dims it below its base" {
    // position 0.5: offset -1 mark, layer 3 marks wide - the solid stop
    // (u = 0.5) lands on x = 0.5, the mark's middle.
    try std.testing.expectApproxEqAbs(@as(f64, 1), shimmerAlpha(0.5, 0.5), 1e-9);
    try std.testing.expect(shimmerAlpha(0.3, 0.5) < 1);
    try std.testing.expect(shimmerAlpha(0.3, 0.5) > base_opacity);
    var i: usize = 0;
    while (i <= 100) : (i += 1) {
        const p = @as(f64, @floatFromInt(i)) / 100;
        var j: usize = 0;
        while (j <= 10) : (j += 1) {
            const a = shimmerAlpha(@as(f64, @floatFromInt(j)) / 10, p);
            try std.testing.expect(a >= base_opacity - 1e-9 and a <= 1 + 1e-9);
        }
    }
}

test "the question ring breathes from clear to its peak and back, eased" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), pulseAlpha(0), 1e-9);
    try std.testing.expectApproxEqAbs(pulse_peak, pulseAlpha(1200), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), pulseAlpha(2400), 1e-9);
    try std.testing.expectApproxEqAbs(pulse_peak / 2, pulseAlpha(600), 1e-9);
    // Symmetric on the way back down.
    try std.testing.expectApproxEqAbs(pulseAlpha(300), pulseAlpha(2100), 1e-9);
    // Eased: slow off the bottom.
    try std.testing.expect(pulseAlpha(120) < pulse_peak * 0.1 * 0.5);
}

test "the clock runs only for something that moves, and never with motion off" {
    try std.testing.expect(!(Marks{}).moving(true));
    try std.testing.expect(!(Marks{ .bells = 3 }).moving(true));
    try std.testing.expect((Marks{ .busy = 1 }).moving(true));
    try std.testing.expect((Marks{ .pulsing = 1 }).moving(true));
    try std.testing.expect(!(Marks{ .busy = 1, .pulsing = 2 }).moving(false));
}
