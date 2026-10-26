//! The pane sidebar's motion (T1843, T2279), pure so it is testable: a busy
//! pane's row sheens - an upright band of light crosses its pill from the
//! right edge to the left, now and then, starting and ending fully off it.
//! It is the SAME sheen on a full row and on a rail tile, since a tile is its
//! row without the text (Mac 75dc046e3, 2924ea5cc, 919fba868:
//! `PaneSidebarTileSheenLayer` / `PaneSidebarSheen`). It replaced the glyph
//! shimmer that ran across the icon alone. Mac's Core Animation clock is a
//! window timer that repaints the column here, and it stops outright when the
//! user turned off "Animation effects" (SPI_GETCLIENTAREAANIMATION, Mac's
//! Reduce Motion): a busy row then shows no sheen at all, as Mac's does not.
//! The question badge's breathing ring that was the other motion went with
//! the badge (T2280, Mac 2924ea5cc).

const std = @import("std");

/// One sheen cycle: a sweep, then a rest before the next - an occasional
/// glint, not a strobe (Mac `period` 2s).
pub const sheen_period_ms: u64 = 2000;
/// The part of the period the band spends crossing (Mac `sweep` 0.8s).
pub const sheen_sweep_ms: u64 = 800;
/// The band's light at its brightest: faint, a glint that says "working"
/// rather than a flash (Mac `peak` 0.25 white).
pub const sheen_peak: f64 = 0.25;
/// The band layer is this many pills wide… (Mac `bandWidthFactor`)
pub const band_width_factor: f64 = 3;
/// …and its light lies in this stretch of it, brightest in the middle (Mac
/// `PaneSidebarSheen.light`).
pub const light_lo: f64 = 0.4;
pub const light_hi: f64 = 0.6;
/// How far past each edge of the pill the light starts and ends, as a share
/// of the pill's width (Mac `travel`'s margin).
pub const travel_margin: f64 = 0.15;

/// The sheen fades in as work starts and out as it stops, so it never pops
/// on or off (Mac `busyFade`, easeInOut 0.6s).
pub const fade_ms: u64 = 600;

/// The repaint cadence while anything moves: 30 frames a second is smooth
/// for a faint band crossing a row, at half the cost of 60.
pub const frame_ms: u32 = 33;

pub const Travel = struct { from: f64, to: f64 };

/// Where the band layer's left edge travels for a pill `width` wide: from
/// the light just past the pill's right edge to just past its left, so a
/// sweep starts off the pill, crosses it right to left, and leaves it
/// entirely (Mac `PaneSidebarSheen.travel`; one that stopped short at either
/// end jumped in, or never quite left).
pub fn travel(width: f64) Travel {
    const margin = width * travel_margin;
    const light_start = light_lo * band_width_factor * width;
    const light_end = light_hi * band_width_factor * width;
    return .{ .from = width - light_start + margin, .to = -light_end - margin };
}

/// Mac's sweep curve, `CAMediaTimingFunction(0.455, 0.03, 0.515, 0.955)`:
/// the classic ease-in-out, which a quadratic tracks to within a pixel on a
/// row.
fn easeInOut(t: f64) f64 {
    const c = std.math.clamp(t, 0, 1);
    return if (c < 0.5) 2 * c * c else 1 - std.math.pow(f64, -2 * c + 2, 2) / 2;
}

/// The band layer's left edge at `ms`, for a pill `width` wide. Every busy
/// row shares the one clock, so they all sweep in phase (Mac phases its
/// animation to the reference date for the same reason).
pub fn bandLeft(ms: u64, width: f64) f64 {
    const tr = travel(width);
    const phase = ms % sheen_period_ms;
    if (phase >= sheen_sweep_ms) return tr.to;
    const t = @as(f64, @floatFromInt(phase)) / @as(f64, @floatFromInt(sheen_sweep_ms));
    return tr.from + (tr.to - tr.from) * easeInOut(t);
}

/// The white's opacity at `x` across a pill `width` wide, with the band
/// layer's left edge at `left`: a triangle over the light's stretch of the
/// layer, `sheen_peak` at its middle (Mac's three gradient stops).
pub fn sheenAlpha(x: f64, left: f64, width: f64) f64 {
    if (width <= 0) return 0;
    const u = (x - left) / (band_width_factor * width);
    if (u <= light_lo or u >= light_hi) return 0;
    const mid = (light_lo + light_hi) / 2;
    const half = (light_hi - light_lo) / 2;
    return sheen_peak * (1 - @abs(u - mid) / half);
}

/// One pane's sheen fading in or out: which way, and since when.
pub const Fade = struct {
    on: bool,
    since_ms: u64,

    /// How far in, 0 (gone) to 1 (full), eased.
    pub fn level(self: Fade, now_ms: u64) f64 {
        return easeInOut(self.progress(now_ms));
    }

    /// Whether it has finished fading, so it needs no clock.
    pub fn settled(self: Fade, now_ms: u64) bool {
        return now_ms -| self.since_ms >= fade_ms;
    }

    /// The linear share of the way to where it is heading: 1 means full on
    /// the way in, gone on the way out.
    fn progress(self: Fade, now_ms: u64) f64 {
        const t = @min(1.0, @as(f64, @floatFromInt(now_ms -| self.since_ms)) / @as(f64, @floatFromInt(fade_ms)));
        return if (self.on) t else 1 - t;
    }

    /// Head the other way at `now_ms` from wherever it has got to, so a
    /// pane that stops mid-fade-in fades out from there rather than jumping
    /// (the ease is symmetric, so the level is continuous).
    pub fn retarget(self: Fade, on: bool, now_ms: u64) Fade {
        if (on == self.on) return self;
        const p = self.progress(now_ms);
        const done = if (on) p else 1 - p;
        const back: u64 = @intFromFloat(done * @as(f64, @floatFromInt(fade_ms)));
        return .{ .on = on, .since_ms = now_ms -| back };
    }
};

/// What the column shows right now, and so whether it needs a clock.
pub const Marks = struct {
    /// Busy rows drawn (each sheens when motion is on).
    busy: usize = 0,
    /// Sheens still fading in or out.
    fading: usize = 0,

    /// Bell dots on stashed rows: shown, never animated.
    bells: usize = 0,

    pub fn moving(self: Marks, motion: bool) bool {
        return motion and (self.busy > 0 or self.fading > 0);
    }
};

test "T2279: a sweep starts off the pill and leaves it entirely, right to left" {
    // Mac's PaneSidebarSheenTests widths: a tile, and two panel widths.
    for ([_]f64{ 36, 240, 380 }) |w| {
        const tr = travel(w);
        const bw = band_width_factor * w;
        try std.testing.expect(tr.from + light_lo * bw > w); // starts past the right edge
        try std.testing.expect(tr.to + light_hi * bw < 0); // ends past the left edge
        try std.testing.expect(tr.from > tr.to); // right to left
        // So at both ends of its travel no pixel of the pill is lit.
        var x: f64 = 0;
        while (x < w) : (x += 1) {
            try std.testing.expectEqual(@as(f64, 0), sheenAlpha(x + 0.5, tr.from, w));
            try std.testing.expectEqual(@as(f64, 0), sheenAlpha(x + 0.5, tr.to, w));
        }
    }
}

test "T2279: one sweep every 2s, taking 0.8s, then resting off the pill" {
    const w: f64 = 36;
    const tr = travel(w);
    try std.testing.expectApproxEqAbs(tr.from, bandLeft(0, w), 1e-9);
    try std.testing.expectApproxEqAbs((tr.from + tr.to) / 2, bandLeft(400, w), 1e-9);
    try std.testing.expectApproxEqAbs(tr.to, bandLeft(800, w), 1e-9);
    try std.testing.expectApproxEqAbs(tr.to, bandLeft(1999, w), 1e-9);
    try std.testing.expectApproxEqAbs(tr.from, bandLeft(2000, w), 1e-9);
    // Monotone right to left over the sweep.
    var prev = std.math.inf(f64);
    var ms: u64 = 0;
    while (ms <= 800) : (ms += 10) {
        const b = bandLeft(ms, w);
        try std.testing.expect(b <= prev);
        prev = b;
    }
}

test "T2279: the light is a faint upright band, at most 25% white, brightest in its middle" {
    const w: f64 = 100;
    // Left edge at -150: the light spans -150 + [120, 180] = [-30, 30],
    // brightest at x = 0.
    try std.testing.expectApproxEqAbs(sheen_peak, sheenAlpha(0, -150, w), 1e-9);
    try std.testing.expect(sheenAlpha(15, -150, w) < sheen_peak);
    try std.testing.expect(sheenAlpha(15, -150, w) > 0);
    try std.testing.expectEqual(@as(f64, 0), sheenAlpha(31, -150, w));
    var i: usize = 0;
    while (i <= 200) : (i += 1) {
        const a = sheenAlpha(@as(f64, @floatFromInt(i)) - 100, -150, w);
        try std.testing.expect(a >= 0 and a <= sheen_peak + 1e-12);
    }
}

test "T2279: the sheen fades in over 0.6s, and out from wherever it got to" {
    const in: Fade = .{ .on = true, .since_ms = 1000 };
    try std.testing.expectEqual(@as(f64, 0), in.level(1000));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), in.level(1300), 1e-9);
    try std.testing.expectEqual(@as(f64, 1), in.level(1600));
    try std.testing.expect(!in.settled(1599));
    try std.testing.expect(in.settled(1600));
    // Stopped a third of the way in: it fades out from that level, with no
    // jump, and is gone a third of a fade later.
    const mid_level = in.level(1200);
    const out = in.retarget(false, 1200);
    try std.testing.expectApproxEqAbs(mid_level, out.level(1200), 1e-3);
    try std.testing.expectEqual(@as(f64, 0), out.level(1400));
    // Retargeting the way it is already heading changes nothing.
    try std.testing.expectEqual(in, in.retarget(true, 1300));
}

test "the clock runs only for something that moves, and never with motion off" {
    try std.testing.expect(!(Marks{}).moving(true));
    try std.testing.expect(!(Marks{ .bells = 3 }).moving(true));
    try std.testing.expect((Marks{ .busy = 1 }).moving(true));
    try std.testing.expect((Marks{ .fading = 1 }).moving(true));
    try std.testing.expect(!(Marks{ .busy = 1, .bells = 2 }).moving(false));
}
