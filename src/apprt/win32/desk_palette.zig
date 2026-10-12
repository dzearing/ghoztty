//! The colours of one window's gradient desk in the elevated pane style
//! (T1831 ocean, T1832 per-window variants; Mac `PaneDeskPalette` /
//! `PaneDeskVariant` / `PaneDesk` in `PaneElevation.swift`, main fe3f7c8da,
//! a516200d2, 5ba797c8c, a34653b2a, b4a3216cc).
//!
//! Two looks:
//!
//!   * `pools` - the default "ocean": a blue pool at the top-leading corner and
//!     a teal one at the bottom-trailing corner over a slate base.
//!   * `spotlight` - a window's OWN gradient (`+new-window --color=random`, or
//!     a window opened by hand): one random hue from the whole wheel, lit by a
//!     soft elliptical spotlight from just above the top centre, the base
//!     grading darker toward the bottom-trailing corner on a dark theme
//!     (lighter on a light one), where a dim pool of the COMPLEMENTARY hue
//!     lights it.
//!
//! A variant is a SEED, and its palette is derived per theme, so a window keeps
//! its character across a light/dark switch and across a session restore. The
//! derivation is Mac's, draw for draw, through the same SplitMix64 - so one
//! seed is one gradient on both platforms, and a layout restored across
//! machines keeps its look.
//!
//! Pure maths, no OS imports, so the tests run in every app-runtime lane.

const std = @import("std");
const testing = std.testing;
const color_math = @import("color_math.zig");

pub const Rgbf = struct {
    r: f32,
    g: f32,
    b: f32,

    pub fn fromHsb(hue_deg: f64, s: f64, b: f64) Rgbf {
        const c = color_math.hsbToRgb(.{ .h = hue_deg / 360.0, .s = s, .b = b });
        return .{
            .r = @floatFromInt(c.r),
            .g = @floatFromInt(c.g),
            .b = @floatFromInt(c.b),
        };
    }

    pub fn lerp(a: Rgbf, b: Rgbf, t: f32) Rgbf {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
        };
    }

    pub fn pack(c: Rgbf) u32 {
        return packRgb(chan(c.r), chan(c.g), chan(c.b));
    }

    pub fn unpack(p: u32) Rgbf {
        return .{
            .r = @floatFromInt((p >> 16) & 0xFF),
            .g = @floatFromInt((p >> 8) & 0xFF),
            .b = @floatFromInt(p & 0xFF),
        };
    }
};

fn chan(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

/// A 32bpp top-down DIB pixel (`BI_RGB`): 0x00RRGGBB.
pub fn packRgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

pub const Look = union(enum) {
    /// A pool of colour at the top-leading corner and another at the
    /// bottom-trailing one; each reach is a fraction of the window's longer
    /// side. (Ocean.)
    pools: struct { lead: Rgbf, trail: Rgbf, lead_reach: f32, trail_reach: f32 },
    /// A spotlight from just above the top centre, and a dim pool of the
    /// complementary hue lighting the bottom-trailing corner. (A variant.)
    spotlight: struct { light: Rgbf, accent: Rgbf },
};

pub const Palette = struct {
    /// The base the look sits on, from its top-leading end to its far end.
    base_start: Rgbf,
    base_end: Rgbf,
    look: Look,

    /// Mac `PaneDeskPalette.ocean(isLight:)`, value for value.
    pub fn ocean(is_light: bool) Palette {
        if (is_light) return .{
            .base_start = Rgbf.fromHsb(206, 0.04, 0.98),
            .base_end = Rgbf.fromHsb(198, 0.03, 0.96),
            .look = .{ .pools = .{
                .lead = Rgbf.fromHsb(205, 0.16, 0.97),
                .trail = Rgbf.fromHsb(171, 0.14, 0.93),
                .lead_reach = 0.75,
                .trail_reach = 0.65,
            } },
        };
        return .{
            .base_start = Rgbf.fromHsb(213, 0.50, 0.14),
            .base_end = Rgbf.fromHsb(213, 0.39, 0.11),
            .look = .{ .pools = .{
                .lead = Rgbf.fromHsb(205, 0.73, 0.42),
                .trail = Rgbf.fromHsb(177, 0.77, 0.35),
                .lead_reach = 0.75,
                .trail_reach = 0.65,
            } },
        };
    }

    /// The palette a window draws: its own variant's, or the ocean.
    pub fn forWindow(variant: ?Variant, is_light: bool) Palette {
        return if (variant) |v| v.palette(is_light) else ocean(is_light);
    }

    /// The desk's colour at a point of a `w` x `h` window - SwiftUI's stack
    /// for each look. A gradient to `.clear` is a premultiplied fade, which
    /// over an opaque base is a plain mix by the remaining alpha.
    pub fn at(self: Palette, x: f32, y: f32, w: f32, h: f32) Rgbf {
        const reach = @max(w, h);
        switch (self.look) {
            .pools => |p| {
                // A linear base from (0.2w, 0) to (0.8w, h), then the pools.
                var c = Rgbf.lerp(self.base_start, self.base_end, linearT(x, y, 0.2 * w, 0, 0.8 * w, h));
                const lead_r = @max(reach * p.lead_reach, 1);
                c = Rgbf.lerp(c, p.lead, 1 - @min(@sqrt(x * x + y * y) / lead_r, 1));
                const tx = w - x;
                const ty = h - y;
                const trail_r = @max(reach * p.trail_reach, 1);
                return Rgbf.lerp(c, p.trail, 1 - @min(@sqrt(tx * tx + ty * ty) / trail_r, 1));
            },
            .spotlight => |s| {
                // A linear base from the top-leading corner to the far one.
                var c = Rgbf.lerp(self.base_start, self.base_end, linearT(x, y, 0, 0, w, h));
                // `EllipticalGradient(center: (0.5, -0.1), endRadiusFraction:
                // 0.95)`: an ellipse fitted to the window, so the light
                // spreads wide across the top and only part way down.
                const ex = (x - 0.5 * w) / @max(0.5 * w, 1);
                const ey = (y + 0.1 * h) / @max(0.5 * h, 1);
                c = Rgbf.lerp(c, s.light, threeStopAlpha(@sqrt(ex * ex + ey * ey) / 0.95, 0.45));
                // The complementary corner light: `RadialGradient` from the
                // bottom-trailing corner out to 0.6 of the longer side.
                const tx = w - x;
                const ty = h - y;
                const accent_r = @max(reach * 0.6, 1);
                return Rgbf.lerp(c, s.accent, threeStopAlpha(@sqrt(tx * tx + ty * ty) / accent_r, 0.35));
            },
        }
    }
};

/// Where (x, y) projects onto the gradient line from (sx, sy) to (ex, ey),
/// clamped to 0...1.
fn linearT(x: f32, y: f32, sx: f32, sy: f32, ex: f32, ey: f32) f32 {
    const dx = ex - sx;
    const dy = ey - sy;
    const len2 = @max(dx * dx + dy * dy, 1);
    return std.math.clamp(((x - sx) * dx + (y - sy) * dy) / len2, 0, 1);
}

/// The alpha of SwiftUI's `[c, c.opacity(mid), .clear]` at gradient position
/// `t`: three evenly spaced stops, linear between them.
fn threeStopAlpha(t: f32, mid: f32) f32 {
    if (t >= 1) return 0;
    if (t <= 0) return 1;
    if (t < 0.5) return 1 - (1 - mid) * (t / 0.5);
    return mid * (1 - (t - 0.5) / 0.5);
}

/// A window's own gradient, as the seed it is derived from (Mac
/// `PaneDeskVariant`). Zero is not a seed Mac ever draws (`1...UInt64.max`).
pub const Variant = struct {
    seed: u64,

    pub fn random() Variant {
        return .{ .seed = std.crypto.random.intRangeAtMost(u64, 1, std.math.maxInt(u64)) };
    }

    /// Mac `PaneDeskVariant.palette(isLight:)`, draw for draw: the draws are
    /// made in the order Swift evaluates the initializer's arguments, so the
    /// same seed is the same gradient on both platforms.
    pub fn palette(self: Variant, is_light: bool) Palette {
        var rng: SplitMix64 = .{ .state = self.seed };
        // A hue from the whole wheel for everything except the corner light,
        // which takes its complement (a NEIGHBOURING second hue read as
        // duo-toned; the complement, dim and in one corner, reads as light
        // from elsewhere).
        const degrees = rng.pick(0, 360);
        const complement = @mod(degrees + 180, 360);

        if (is_light) {
            // A tinted near-white, brightening toward the top centre and
            // getting LIGHTER toward the bottom-trailing corner, which the
            // complement faintly colours.
            const start = rng.pick(0.93, 0.945);
            const start_sat = rng.pick(0.07, 0.10);
            const end_sat = rng.pick(0.02, 0.04);
            const end_bright = start + rng.pick(0.035, 0.045);
            const light_sat = rng.pick(0.02, 0.04);
            const accent_sat = rng.pick(0.10, 0.15);
            const accent_bright = rng.pick(0.96, 0.99);
            return .{
                .base_start = Rgbf.fromHsb(degrees, start_sat, start),
                .base_end = Rgbf.fromHsb(degrees, end_sat, end_bright),
                .look = .{ .spotlight = .{
                    .light = Rgbf.fromHsb(degrees, light_sat, 1.0),
                    .accent = Rgbf.fromHsb(complement, accent_sat, accent_bright),
                } },
            };
        }
        // A deep slate of the hue, lit from the top centre and getting DARKER
        // toward the bottom-trailing corner, where the complement glows dimly:
        // well under the spotlight, a little over the base.
        const start = rng.pick(0.15, 0.18);
        const start_sat = rng.pick(0.38, 0.50);
        const end_sat = rng.pick(0.35, 0.45);
        const end_bright = start - rng.pick(0.07, 0.09);
        const light_sat = rng.pick(0.30, 0.42);
        const light_bright = rng.pick(0.40, 0.48);
        const accent_sat = rng.pick(0.40, 0.55);
        const accent_bright = rng.pick(0.22, 0.28);
        return .{
            .base_start = Rgbf.fromHsb(degrees, start_sat, start),
            .base_end = Rgbf.fromHsb(degrees, end_sat, end_bright),
            .look = .{ .spotlight = .{
                .light = Rgbf.fromHsb(degrees, light_sat, light_bright),
                .accent = Rgbf.fromHsb(complement, accent_sat, accent_bright),
            } },
        };
    }
};

/// Mac's `SplitMix64`, so a variant's palette is the same every time it is
/// derived, on every machine.
pub const SplitMix64 = struct {
    state: u64,

    pub fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9E37_79B9_7F4A_7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        return z ^ (z >> 31);
    }

    /// A uniform value in 0..<1.
    pub fn nextUnit(self: *SplitMix64) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, 1 << 53);
    }

    fn pick(self: *SplitMix64, lo: f64, hi: f64) f64 {
        return lo + (hi - lo) * self.nextUnit();
    }
};

/// Fill a `w` x `h` buffer with the desk of a `full_w` x `full_h` window,
/// sampled at the centre of each of the buffer's pixels. The caller renders a
/// reduced-size desk and stretches it: the gradient has no detail to lose,
/// and a full-size desk recomputed on every live resize frame is the cost a
/// drag would feel.
pub fn renderDesk(buf: []u32, w: usize, h: usize, full_w: f32, full_h: f32, pal: Palette) void {
    std.debug.assert(buf.len >= w * h);
    if (w == 0 or h == 0) return;
    const fx = full_w / @as(f32, @floatFromInt(w));
    const fy = full_h / @as(f32, @floatFromInt(h));
    for (0..h) |row| {
        const y = (@as(f32, @floatFromInt(row)) + 0.5) * fy;
        for (0..w) |col| {
            const x = (@as(f32, @floatFromInt(col)) + 0.5) * fx;
            buf[row * w + col] = pal.at(x, y, full_w, full_h).pack();
        }
    }
}

// ---------------------------------------------------------------------------

fn sum(c: Rgbf) f32 {
    return c.r + c.g + c.b;
}

test "T1831: the ocean desk is blue at the top-leading corner and teal at the far one" {
    const pal = Palette.ocean(false);
    const tl = pal.at(0, 0, 1000, 600);
    const br = pal.at(1000, 600, 1000, 600);
    // Blue: more blue than green; teal: green and blue close together.
    try testing.expect(tl.b > tl.g and tl.g > tl.r);
    try testing.expect(br.g > br.r and @abs(br.g - br.b) < 20);
    // A dark desk on a dark theme, a near-white one on a light theme.
    const mid = pal.at(500, 300, 1000, 600);
    try testing.expect(mid.r + mid.g + mid.b < 3 * 110);
    const light = Palette.ocean(true).at(500, 300, 1000, 600);
    try testing.expect(light.r + light.g + light.b > 3 * 220);
}

test "T1831: renderDesk samples the full window however small the buffer" {
    var buf: [4 * 3]u32 = undefined;
    const pal = Palette.ocean(false);
    renderDesk(&buf, 4, 3, 1000, 600, pal);
    try testing.expectEqual(pal.at(125, 100, 1000, 600).pack(), buf[0]);
    try testing.expectEqual(pal.at(875, 500, 1000, 600).pack(), buf[11]);
}

test "T1832: SplitMix64 is the reference generator, bit for bit" {
    // The published SplitMix64 outputs for seed 0 (Vigna's reference
    // implementation) - the same sequence Mac's `SplitMix64` produces.
    var rng: SplitMix64 = .{ .state = 0 };
    try testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), rng.next());
    try testing.expectEqual(@as(u64, 0x6E789E6AA1B965F4), rng.next());
    try testing.expectEqual(@as(u64, 0x06C45D188009454F), rng.next());
    var u: SplitMix64 = .{ .state = 12345 };
    for (0..1000) |_| {
        const v = u.nextUnit();
        try testing.expect(v >= 0 and v < 1);
    }
}

test "T1832: one seed is one gradient - derived the same way every time" {
    const v: Variant = .{ .seed = 0xDEAD_BEEF_1234_5678 };
    const a = v.palette(false);
    const b = v.palette(false);
    try testing.expectEqual(a.at(300, 200, 1000, 600).pack(), b.at(300, 200, 1000, 600).pack());
    // A different seed is a different window.
    const other = (Variant{ .seed = 42 }).palette(false);
    try testing.expect(a.at(500, 0, 1000, 600).pack() != other.at(500, 0, 1000, 600).pack());
}

test "T1832: random seeds span the whole hue wheel (5ba797c8c - not just blues and teals)" {
    var buckets = [_]bool{false} ** 6;
    var seed: u64 = 1;
    for (0..600) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var rng: SplitMix64 = .{ .state = seed };
        const deg = rng.pick(0, 360);
        buckets[@intFromFloat(@floor(deg / 60))] = true;
    }
    for (buckets) |hit| try testing.expect(hit);
}

test "T1832: a dark variant is lit from the top centre and darkest toward the bottom-trailing corner" {
    var seed: u64 = 1;
    for (0..200) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const pal = (Variant{ .seed = seed }).palette(false);
        try testing.expect(pal.look == .spotlight);
        const w: f32 = 1200;
        const h: f32 = 800;
        const top = pal.at(w / 2, 0, w, h);
        const mid = pal.at(w / 2, h / 2, w, h);
        // The spotlight: brightest at the top centre.
        try testing.expect(sum(top) > sum(mid));
        try testing.expect(sum(top) > sum(pal.at(0, h, w, h)));
        // The base falls away darker toward the far corner on a dark theme.
        try testing.expect(sum(pal.base_end) < sum(pal.base_start));
        // A dark desk for a dark theme, everywhere.
        try testing.expect(sum(mid) < 3 * 128);
    }
}

test "T1832: a light variant is near-white and grows LIGHTER toward the far corner" {
    var seed: u64 = 7;
    for (0..200) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const pal = (Variant{ .seed = seed }).palette(true);
        try testing.expect(sum(pal.base_end) >= sum(pal.base_start));
        try testing.expect(sum(pal.at(600, 400, 1200, 800)) > 3 * 220);
    }
}

test "T1832: the corner light is the COMPLEMENT of the window's hue (b4a3216cc)" {
    var seed: u64 = 99;
    for (0..100) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var rng: SplitMix64 = .{ .state = seed };
        const deg = rng.pick(0, 360);
        const pal = (Variant{ .seed = seed }).palette(false);
        const accent = pal.look.spotlight.accent;
        const want = color_math.hsbToRgb(.{ .h = @mod(deg + 180, 360) / 360.0, .s = 0.5, .b = 0.5 });
        const got = color_math.rgbToHsb(.{ .r = @intFromFloat(accent.r), .g = @intFromFloat(accent.g), .b = @intFromFloat(accent.b) });
        const want_h = color_math.rgbToHsb(want).h;
        var dh = @abs(got.h - want_h);
        if (dh > 0.5) dh = 1 - dh;
        // 8-bit channels at low brightness quantise the hue a little.
        try testing.expect(dh < 0.04);
    }
}

test "T1832: forWindow is the ocean without a variant" {
    const o = Palette.ocean(false);
    const f = Palette.forWindow(null, false);
    try testing.expectEqual(o.at(10, 10, 100, 100).pack(), f.at(10, 10, 100, 100).pack());
    const v = Palette.forWindow(.{ .seed = 5 }, false);
    try testing.expect(v.look == .spotlight);
}

test "T1832: threeStopAlpha matches SwiftUI's even stops" {
    try testing.expectEqual(@as(f32, 1), threeStopAlpha(0, 0.45));
    try testing.expectApproxEqAbs(@as(f32, 0.45), threeStopAlpha(0.5, 0.45), 1e-6);
    try testing.expectEqual(@as(f32, 0), threeStopAlpha(1, 0.45));
    try testing.expectApproxEqAbs(@as(f32, 0.225), threeStopAlpha(0.75, 0.45), 1e-6);
}
