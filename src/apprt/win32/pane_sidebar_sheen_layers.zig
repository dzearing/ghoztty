//! A busy pill's sheen as compositor pieces (T2801), pure so it is testable.
//!
//! `pane_sidebar_motion.Overlay` paints the sheen one frame at a time: the
//! drift, the glint over it and the busy rim over both, faded together. The
//! frame clock that drives it stalls whenever the app is busy - which is
//! exactly when an agent's row sheens. Here the same picture is cut into
//! pieces DirectComposition can move on its own:
//!
//! - a BOX the pill's size at the pill's place, clipped to its rounded
//!   silhouette, whose opacity is the busy fade;
//! - under it the DRIFT strip, its whole repeating gradient pre-rendered,
//!   whose X offset loops one period every 5 s;
//! - the BAND, only the lit stretch of the glint, whose X offset sweeps for
//!   0.8 s of every 2 s on the same ease;
//! - and the RIM, a still hairline over both.
//!
//! Every piece is a premultiplied BGRA bitmap rendered once from the very
//! functions the stepped paint samples, and every loop is phased to one
//! shared origin (`originMs`), so the compositor shows the stepped paint's
//! frames - only smoothly, and off this thread.

const std = @import("std");
const motion = @import("pane_sidebar_motion.zig");
const comp_overlay = @import("../../renderer/comp_overlay.zig");

const Cubic = comp_overlay.Cubic;

/// One premultiplied BGRA pixel, the way `PaneSidebar.paintOverlay` packs it.
pub fn pack(px: motion.Px) u32 {
    const a: u32 = @intFromFloat(@round(std.math.clamp(px.alpha, 0, 1) * 255));
    const c: u32 = @intFromFloat(@round(std.math.clamp(px.white, 0, px.alpha) * 255));
    return (a << 24) | (c << 16) | (c << 8) | c;
}

/// The two loops share one origin: a multiple of both periods (2 s glint,
/// 5 s drift) on the tick clock, so `ms % sheen_period_ms` and `ms %
/// Drift.duration_ms` - what the stepped paint reads - are each loop's own
/// time since it.
pub const cycle_ms: u64 = 10_000;

comptime {
    std.debug.assert(cycle_ms % motion.sheen_period_ms == 0);
    std.debug.assert(cycle_ms % motion.Drift.duration_ms == 0);
}

/// The tick-clock moment both loops last started from, at or before `now_ms`.
pub fn originMs(now_ms: u64) u64 {
    return now_ms - now_ms % cycle_ms;
}

/// `originMs` on the performance counter, the clock DirectComposition's
/// begin times are on: `now_qpc` read at `now_ms`, ticking `freq` a second.
pub fn originQpc(now_qpc: i64, freq: i64, now_ms: u64) i64 {
    const back: i64 = @intCast(now_ms - originMs(now_ms));
    return now_qpc - @divTrunc(back * freq, 1000);
}

/// One pill's pieces: their sizes and where each loop runs.
pub const Plan = struct {
    width: u32,
    height: u32,
    radius: f64,
    rim_w: f64,
    dark: bool,
    drift: motion.Drift,
    /// The band bitmap starts this far into the glint layer: where its light
    /// begins (`light_lo` of the layer's width).
    band_skip: f64,
    drift_w: u32,
    band_w: u32,

    pub fn init(width: u32, height: u32, radius: f64, rim_w: f64, dark: bool) Plan {
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const d = motion.Drift.init(w, h);
        const lit = (motion.light_hi - motion.light_lo) * motion.band_width_factor * w;
        return .{
            .width = width,
            .height = height,
            .radius = radius,
            .rim_w = rim_w,
            .dark = dark,
            .drift = d,
            .band_skip = motion.light_lo * motion.band_width_factor * w,
            .drift_w = @intFromFloat(@ceil(d.length + motion.slant * h) + 1),
            .band_w = @intFromFloat(@ceil(lit + motion.slant * h) + 2),
        };
    }

    fn rise(self: Plan, row: usize) f64 {
        return @as(f64, @floatFromInt(self.height)) - (@as(f64, @floatFromInt(row)) + 0.5);
    }

    /// Drift strip pixel (`col`, `row`): the gradient laid out with its
    /// layer's bottom-left edge at the strip's left, so the strip at X offset
    /// `drift.left(ms)` is the stepped paint's drift at `ms`.
    pub fn driftPixel(self: Plan, col: usize, row: usize) u32 {
        const x = @as(f64, @floatFromInt(col)) + 0.5;
        const ink: f64 = if (self.dark) 1 else 0;
        return pack((motion.Px{}).over(ink, self.drift.alpha(x, self.rise(row), 0, self.dark)));
    }

    /// Band pixel (`col`, `row`): the glint's lit stretch, so the band at X
    /// offset `bandLeft(ms) + band_skip` is the stepped paint's glint.
    pub fn bandPixel(self: Plan, col: usize, row: usize) u32 {
        const x = @as(f64, @floatFromInt(col)) + 0.5 + self.band_skip;
        const w: f64 = @floatFromInt(self.width);
        return pack((motion.Px{}).over(1, motion.sheenAlpha(x, self.rise(row), 0, w)));
    }

    /// Rim pixel (`col`, `row`): the busy hairline, still.
    pub fn rimPixel(self: Plan, col: usize, row: usize) u32 {
        const x = @as(f64, @floatFromInt(col)) + 0.5;
        const y = @as(f64, @floatFromInt(row)) + 0.5;
        const c = motion.cover(x, y, @floatFromInt(self.width), @floatFromInt(self.height), self.radius, self.rim_w);
        const ink: f64 = if (self.dark) 1 else 0;
        const a = (if (self.dark) motion.busy_rim_dark else motion.busy_rim_light) * c.ring;
        return pack((motion.Px{}).over(ink, a));
    }

    pub const Piece = enum { drift, band, rim };

    pub fn size(self: Plan, p: Piece) [2]u32 {
        return switch (p) {
            .drift => .{ self.drift_w, self.height },
            .band => .{ self.band_w, self.height },
            .rim => .{ self.width, self.height },
        };
    }

    /// Render piece `p` into `out` (`size(p)` pixels, row-major).
    pub fn render(self: Plan, p: Piece, out: []u32) void {
        const s = self.size(p);
        const w: usize = s[0];
        for (0..s[1]) |row| {
            for (0..w) |col| out[row * w + col] = switch (p) {
                .drift => self.driftPixel(col, row),
                .band => self.bandPixel(col, row),
                .rim => self.rimPixel(col, row),
            };
        }
    }

    /// The drift's loop: one linear slide of a period over 5 s.
    pub fn driftLoop(self: Plan) [1]Cubic {
        const dur: f64 = @as(f64, @floatFromInt(motion.Drift.duration_ms)) / 1000;
        return .{.{ .begin_s = 0, .c0 = self.drift.from, .c1 = (self.drift.to - self.drift.from) / dur, .c2 = 0, .c3 = 0 }};
    }

    pub const band_segments = comp_overlay.ease_segments + 1;

    /// The band's loop: the eased sweep, then held off the pill until the
    /// period ends.
    pub fn bandLoop(self: Plan) [band_segments]Cubic {
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.height);
        const tr = motion.travel(w, h);
        const sweep_s: f64 = @as(f64, @floatFromInt(motion.sheen_sweep_ms)) / 1000;
        var unit: [comp_overlay.ease_segments]Cubic = undefined;
        comp_overlay.fitCurve(motion.easeInOut, sweep_s, &unit);
        var out: [band_segments]Cubic = undefined;
        const from = tr.from + self.band_skip;
        const span = tr.to - tr.from;
        for (unit, 0..) |c, i| out[i] = .{ .begin_s = c.begin_s, .c0 = from + span * c.c0, .c1 = span * c.c1, .c2 = span * c.c2, .c3 = span * c.c3 };
        out[band_segments - 1] = .{ .begin_s = sweep_s, .c0 = tr.to + self.band_skip, .c1 = 0, .c2 = 0, .c3 = 0 };
        return out;
    }
};

pub const glint_period_s: f64 = @as(f64, @floatFromInt(motion.sheen_period_ms)) / 1000;
pub const drift_period_s: f64 = @as(f64, @floatFromInt(motion.Drift.duration_ms)) / 1000;

/// The value of a loop (`segs` over `period_s`) at `t_s` since its origin.
pub fn loopAt(segs: []const Cubic, period_s: f64, t_s: f64) f64 {
    const t = @mod(t_s, period_s);
    var i: usize = 0;
    for (segs, 0..) |c, j| {
        if (c.begin_s <= t) i = j;
    }
    return segs[i].at(t);
}

/// What a busy fade still has to run, from `now_ms`, for the compositor:
/// the rest of the eased curve and how long it lasts. Null when it is
/// settled (nothing left to declare - the level is just 0 or 1).
pub const FadeRest = struct { curve: []Cubic, duration_s: f64 };

pub fn fadeRest(f: motion.Fade, now_ms: u64, out: *[comp_overlay.ease_segments]Cubic) ?FadeRest {
    if (f.settled(now_ms)) return null;
    const full_s: f64 = @as(f64, @floatFromInt(motion.fade_ms)) / 1000;
    const done_s: f64 = @as(f64, @floatFromInt(now_ms -| f.since_ms)) / 1000;
    var unit: [comp_overlay.ease_segments]Cubic = undefined;
    comp_overlay.fitCurve(motion.easeInOut, full_s, &unit);
    const tail = comp_overlay.tailOf(&unit, done_s, out);
    return .{ .curve = tail, .duration_s = full_s - done_s };
}

// --- tests ------------------------------------------------------------------

fn alphaOf(p: u32) f64 {
    return @as(f64, @floatFromInt(p >> 24)) / 255;
}

fn whiteOf(p: u32) f64 {
    return @as(f64, @floatFromInt(p & 0xff)) / 255;
}

/// The pieces composed at `ms` at pill pixel (`col`, `row`), sampling each
/// strip at the nearest pixel of its offset: what the compositor shows,
/// within its resampling.
fn composed(plan: Plan, ms: u64, col: usize, row: usize) motion.Px {
    const t_s = @as(f64, @floatFromInt(ms)) / 1000;
    const x = @as(f64, @floatFromInt(col)) + 0.5;
    var out: motion.Px = .{};
    const dl = plan.driftLoop();
    const drift_at = loopAt(&dl, drift_period_s, t_s);
    const bl = plan.bandLoop();
    const band_at = loopAt(&bl, glint_period_s, t_s);
    inline for (.{ .{ Plan.Piece.drift, drift_at }, .{ Plan.Piece.band, band_at }, .{ Plan.Piece.rim, @as(f64, 0) } }) |pc| {
        const s = plan.size(pc[0]);
        const bx = @floor(x - pc[1]);
        if (bx >= 0 and bx < @as(f64, @floatFromInt(s[0]))) {
            const p = switch (pc[0]) {
                .drift => plan.driftPixel(@intFromFloat(bx), row),
                .band => plan.bandPixel(@intFromFloat(bx), row),
                .rim => plan.rimPixel(@intFromFloat(bx), row),
            };
            const a = alphaOf(p);
            if (a > 0) out = .{ .white = whiteOf(p) + out.white * (1 - a), .alpha = a + out.alpha * (1 - a) };
        }
    }
    return out;
}

test "T2801: the composed pieces are the stepped paint's sheen, frame for frame" {
    for ([_][2]u32{ .{ 36, 28 }, .{ 240, 28 } }) |wh| {
        for ([_]bool{ true, false }) |dark| {
            const plan = Plan.init(wh[0], wh[1], 4, 0.5, dark);
            for ([_]u64{ 0, 130, 400, 777, 1500, 2350, 4999, 7321 }) |ms| {
                var o = motion.Overlay.init(@floatFromInt(wh[0]), @floatFromInt(wh[1]), 4, 0.5, dark);
                o.busyAt(1, ms);
                var row: usize = 2;
                while (row + 2 < wh[1]) : (row += 3) {
                    var col: usize = 6;
                    while (col + 6 < wh[0]) : (col += 1) {
                        const want = o.pixel(col, row);
                        const got = composed(plan, ms, col, row);
                        // Within the glint's slope over one pixel of
                        // nearest sampling, and 8-bit rounding.
                        try std.testing.expectApproxEqAbs(want.alpha, got.alpha, 0.06);
                        try std.testing.expectApproxEqAbs(want.white, got.white, 0.06);
                    }
                }
            }
        }
    }
}

test "T2801: the band's loop is the stepped sweep, held off the pill after it" {
    const plan = Plan.init(240, 28, 4, 0.5, true);
    const segs = plan.bandLoop();
    var ms: u64 = 0;
    while (ms < 4000) : (ms += 10) {
        const want = motion.bandLeft(ms, 240, 28) + plan.band_skip;
        try std.testing.expectApproxEqAbs(want, loopAt(&segs, glint_period_s, @as(f64, @floatFromInt(ms)) / 1000), 0.5);
    }
}

test "T2801: the drift's loop is the stepped slide, seamless across the wrap" {
    const plan = Plan.init(36, 28, 4, 0.5, false);
    const segs = plan.driftLoop();
    var ms: u64 = 0;
    while (ms < 12000) : (ms += 37) {
        try std.testing.expectApproxEqAbs(plan.drift.left(ms), loopAt(&segs, drift_period_s, @as(f64, @floatFromInt(ms)) / 1000), 1e-6);
    }
}

test "T2801: both loops start from one origin on both clocks" {
    try std.testing.expectEqual(@as(u64, 20_000), originMs(27_345));
    try std.testing.expectEqual(@as(u64, 30_000), originMs(30_000));
    // 7.345 s back at 10 MHz.
    try std.testing.expectEqual(@as(i64, 1_000_000_000 - 73_450_000), originQpc(1_000_000_000, 10_000_000, 27_345));
}

test "T2801: a fade's rest picks up where the stepped fade is" {
    var buf: [comp_overlay.ease_segments]Cubic = undefined;
    const in: motion.Fade = .{ .on = true, .since_ms = 1000 };
    try std.testing.expect(fadeRest(in, 1600, &buf) == null);
    const r = fadeRest(in, 1200, &buf).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), r.duration_s, 1e-9);
    // In 0..1 units of the whole fade: starts at the level reached, lands on 1.
    try std.testing.expectApproxEqAbs(in.level(1200), r.curve[0].c0, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1), loopAt(r.curve, 100, r.duration_s - 1e-9), 1e-4);
}

test "T2801: piece sizes cover the slant and the drift's whole travel" {
    const plan = Plan.init(240, 28, 4, 0.5, true);
    try std.testing.expect(@as(f64, @floatFromInt(plan.drift_w)) >= plan.drift.length + 28);
    try std.testing.expect(@as(f64, @floatFromInt(plan.band_w)) >= 0.2 * 3 * 240 + 28);
    try std.testing.expectEqual([2]u32{ 240, 28 }, plan.size(.rim));
    // The rim is clear in the middle and lit on the edge.
    try std.testing.expectEqual(@as(u32, 0), plan.rimPixel(120, 14));
    try std.testing.expect(alphaOf(plan.rimPixel(120, 0)) > 0);
}
