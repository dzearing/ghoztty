//! The pane sidebar's motion (T1843, T2279, T2309), pure so it is testable: a
//! busy pane's row sheens, in two layers, both slanted 45 degrees (an upright
//! band turned clockwise, "/") and both moving right to left, in phase across
//! rows - the GLINT, a faint band of light crossing the pill now and then,
//! starting and ending fully off it, top corner included; and the DRIFT, a
//! wide soft seamless gradient sliding one period every 5s, inside a pane
//! card's hairline rim so a busy pill's silhouette is always on screen. It is
//! the SAME sheen on a full row and on a rail tile, since a tile is its row
//! without the text (Mac 75dc046e3, 2924ea5cc, 919fba868, dcdc59712,
//! 157b08c48: `PaneSidebarTileSheenLayer` / `PaneSidebarSheen`). A rail tile
//! also wears a glassy rim, lit from above (`PaneSidebarRow.tileBorder`).
//! Mac's Core Animation clock is a window timer that repaints the column
//! here, and it stops outright when the user turned off "Animation effects"
//! (SPI_GETCLIENTAREAANIMATION, Mac's Reduce Motion): a busy row then shows no
//! sheen at all, as Mac's does not. The question badge's breathing ring that
//! was the other motion went with the badge (T2280, Mac 2924ea5cc).

const std = @import("std");
const Rect = @import("pane_sidebar.zig").Rect;

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
/// How far right a band's top is from its bottom, per pixel of height: 1 is
/// 45 degrees, an upright band turned clockwise ("/") (Mac
/// `PaneSidebarSheen.slant`, a shear).
pub const slant: f64 = 1;

/// The sheen fades in as work starts and out as it stops, so it never pops
/// on or off (Mac `busyFade`, easeInOut 0.6s).
pub const fade_ms: u64 = 600;

/// The repaint cadence while anything moves: 30 frames a second is smooth
/// for a faint band crossing a row, at half the cost of 60.
pub const frame_ms: u32 = 33;

pub const Travel = struct { from: f64, to: f64 };

/// Where the band layer's left edge (at the pill's bottom) travels for a pill
/// `width` x `height`: from the light just past the pill's right edge to just
/// past its left - its top included, which the slant puts `height` further
/// right - so a sweep starts off the pill, crosses it right to left, and
/// leaves it entirely (Mac `PaneSidebarSheen.travel`; one that stopped short
/// at either end jumped in, or never quite left).
pub fn travel(width: f64, height: f64) Travel {
    const margin = width * travel_margin;
    const light_start = light_lo * band_width_factor * width;
    const light_end = light_hi * band_width_factor * width;
    return .{ .from = width - light_start + margin, .to = -light_end - slant * height - margin };
}

/// Mac's sweep curve, `CAMediaTimingFunction(0.455, 0.03, 0.515, 0.955)`:
/// the classic ease-in-out, which a quadratic tracks to within a pixel on a
/// row.
fn easeInOut(t: f64) f64 {
    const c = std.math.clamp(t, 0, 1);
    return if (c < 0.5) 2 * c * c else 1 - std.math.pow(f64, -2 * c + 2, 2) / 2;
}

/// The band layer's left edge at `ms`, for a pill `width` x `height`. Every
/// busy row shares the one clock, so they all sweep in phase (Mac phases its
/// animation to the reference date for the same reason).
pub fn bandLeft(ms: u64, width: f64, height: f64) f64 {
    const tr = travel(width, height);
    const phase = ms % sheen_period_ms;
    if (phase >= sheen_sweep_ms) return tr.to;
    const t = @as(f64, @floatFromInt(phase)) / @as(f64, @floatFromInt(sheen_sweep_ms));
    return tr.from + (tr.to - tr.from) * easeInOut(t);
}

/// The glint's white at `x` across a pill `width` wide, on the line `rise`
/// above the pill's bottom, with the band layer's bottom-left edge at `left`:
/// a triangle over the light's stretch of the layer, `sheen_peak` at its
/// middle (Mac's three gradient stops), each line shifted right by its rise.
pub fn sheenAlpha(x: f64, rise: f64, left: f64, width: f64) f64 {
    if (width <= 0) return 0;
    const u = (x - slant * rise - left) / (band_width_factor * width);
    if (u <= light_lo or u >= light_hi) return 0;
    const mid = (light_lo + light_hi) / 2;
    const half = (light_hi - light_lo) / 2;
    return sheen_peak * (1 - @abs(u - mid) / half);
}

/// The slow drift under the glint (Mac `PaneSidebarSheen.Drift`): a gradient
/// repeating every `period` pixels, long enough to cover the pill at every
/// height of the slant, sliding left by exactly one period per `duration_ms`,
/// so its last frame is its first and it never jumps.
pub const Drift = struct {
    /// One cycle; the glint is 2s. Slow enough to read as a breath.
    pub const duration_ms: u64 = 5000;
    /// (between, at) the crests: white on a dark pill...
    pub const dark_alpha: [2]f64 = .{ 0.02, 0.08 };
    /// ...black on a light one, where white alone vanishes.
    pub const light_alpha: [2]f64 = .{ 0.015, 0.05 };

    /// Stretched: wider than the pill, so a tile shows one soft crest at a
    /// time, never stripes.
    period: f64,
    /// The layer's length, a whole number of periods.
    length: f64,
    /// Where its bottom-left edge travels: left of the pill by the slant, so
    /// the top-left corner is covered, then one period further left.
    from: f64,
    to: f64,

    pub fn init(width: f64, height: f64) Drift {
        const period = @max(width * 1.5, 60);
        const reach = width + slant * height;
        const periods = @ceil(reach / period) + 1;
        const from = -slant * height;
        return .{ .period = period, .length = period * periods, .from = from, .to = from - period };
    }

    /// The layer's bottom-left edge at `ms`: linear, on the shared clock.
    pub fn left(self: Drift, ms: u64) f64 {
        const t = @as(f64, @floatFromInt(ms % duration_ms)) / @as(f64, @floatFromInt(duration_ms));
        return self.from + (self.to - self.from) * t;
    }

    /// The ink's opacity at `x` on the line `rise` above the bottom, with the
    /// layer at `at`: a trough at every even gradient stop and a crest at
    /// every odd one (two stops a period), linear between them.
    pub fn alpha(self: Drift, x: f64, rise: f64, at: f64, dark: bool) f64 {
        const p = x - slant * rise - at;
        if (p < 0 or p > self.length) return 0;
        const lohi = if (dark) dark_alpha else light_alpha;
        const f = @mod(p, self.period) / self.period;
        const crest = 1 - @abs(2 * f - 1);
        return lohi[0] + (lohi[1] - lohi[0]) * crest;
    }
};

/// The busy pill's hairline rim, so the drift sits in an outline instead of
/// hanging in the list: a pane card's rim at its strength, white on dark,
/// black on light (Mac `Drift.rimAlpha`).
pub const busy_rim_dark: f64 = 0.1;
pub const busy_rim_light: f64 = 0.08;
/// A pane card's hairline, in DIP (Mac `PaneSidebarRow.rimWidth`).
pub const rim_dip: f64 = 0.5;

/// A rail tile's glassy rim (T2309, Mac `PaneSidebarRow.rim`): its alpha
/// along the top edge and along the bottom, lit from above - about twice the
/// pane rim's strength at the top, half of it at the bottom - in white on
/// dark, black on light. Mac's white-on-accent variant has no counterpart:
/// a Windows selection is a neutral pill (T828), which takes this rim.
pub const TileRim = struct { top: f64, bottom: f64 };

pub fn tileRim(dark: bool, hovered: bool) TileRim {
    if (dark) return if (hovered) .{ .top = 0.32, .bottom = 0.1 } else .{ .top = 0.22, .bottom = 0.05 };
    return if (hovered) .{ .top = 0.16, .bottom = 0.08 } else .{ .top = 0.1, .bottom = 0.04 };
}

/// The rim's alpha at `y` (0 = top) of a pill `height` tall.
pub fn tileRimAt(r: TileRim, y: f64, height: f64) f64 {
    if (height <= 0) return r.top;
    const t = std.math.clamp(y / height, 0, 1);
    return r.top + (r.bottom - r.top) * t;
}

/// How much of the pixel centred at (`x`, `y`) in a `w` x `h` pill rounded
/// to `radius` lies inside the pill, 0 to 1, and how much of it is the
/// `rim_w`-wide band along the inside of its edge: an antialiased hairline,
/// the way a pane card's is (`pane_elevation`).
pub const Cover = struct { inside: f64, ring: f64 };

pub fn cover(x: f64, y: f64, w: f64, h: f64, radius: f64, rim_w: f64) Cover {
    const r = std.math.clamp(radius, 0, @min(w, h) / 2);
    // Signed distance from the rounded rectangle's edge, negative inside.
    const qx = @abs(x - w / 2) - (w / 2 - r);
    const qy = @abs(y - h / 2) - (h / 2 - r);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    const d = @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r;
    const outer = std.math.clamp(0.5 - d, 0, 1);
    const inner = std.math.clamp(0.5 - (d + rim_w), 0, 1);
    return .{ .inside = outer, .ring = outer - inner };
}

/// One pixel of a pill's overlay, premultiplied 0..1: how much of it is
/// white, and its alpha (the rest of the alpha is black).
pub const Px = struct {
    white: f64 = 0,
    alpha: f64 = 0,

    /// `ink` (1 white, 0 black) at `a`, over what is already here.
    pub fn over(self: Px, ink: f64, a: f64) Px {
        if (a <= 0) return self;
        return .{ .white = ink * a + self.white * (1 - a), .alpha = a + self.alpha * (1 - a) };
    }

    pub fn scaled(self: Px, k: f64) Px {
        return .{ .white = self.white * k, .alpha = self.alpha * k };
    }
};

/// What a pill shows over its fill, for one frame.
pub const Overlay = struct {
    width: f64,
    height: f64,
    radius: f64,
    /// The hairline's width in pixels.
    rim_w: f64,
    dark: bool,
    /// The busy layer's strength while it fades in or out, 0 to 1; 0 draws
    /// no drift, glint or busy rim.
    busy: f64 = 0,
    /// The glint's and the drift's layer positions this frame.
    band_left: f64 = 0,
    drift: Drift,
    drift_left: f64 = 0,
    /// A rail tile's rim; null on a full row, which has none.
    tile_rim: ?TileRim = null,

    pub fn init(width: f64, height: f64, radius: f64, rim_w: f64, dark: bool) Overlay {
        return .{ .width = width, .height = height, .radius = radius, .rim_w = rim_w, .dark = dark, .drift = Drift.init(width, height) };
    }

    /// Show the busy layer at `level`, positioned for `ms`.
    pub fn busyAt(self: *Overlay, level: f64, ms: u64) void {
        self.busy = std.math.clamp(level, 0, 1);
        self.band_left = bandLeft(ms, self.width, self.height);
        self.drift_left = self.drift.left(ms);
    }

    /// Whether any pixel can be lit at all: a resting full row draws nothing.
    pub fn visible(self: Overlay) bool {
        return self.busy > 0 or self.tile_rim != null;
    }

    /// Pixel (`col`, `row`) of the overlay, `row` 0 at the top. Layered the
    /// way Mac's are: the drift, the glint over it, the busy rim over both,
    /// faded together, and a tile's rim over everything.
    pub fn pixel(self: Overlay, col: usize, row: usize) Px {
        const x = @as(f64, @floatFromInt(col)) + 0.5;
        const y = @as(f64, @floatFromInt(row)) + 0.5;
        const c = cover(x, y, self.width, self.height, self.radius, self.rim_w);
        if (c.inside <= 0) return .{};
        const ink: f64 = if (self.dark) 1 else 0;
        var out: Px = .{};
        if (self.busy > 0) {
            const rise = self.height - y;
            var layer: Px = .{};
            layer = layer.over(ink, self.drift.alpha(x, rise, self.drift_left, self.dark));
            layer = layer.over(1, sheenAlpha(x, rise, self.band_left, self.width));
            layer = layer.over(ink, (if (self.dark) busy_rim_dark else busy_rim_light) * c.ring);
            out = layer.scaled(self.busy * c.inside);
        }
        if (self.tile_rim) |r| out = out.over(ink, tileRimAt(r, y, self.height) * c.ring);
        return out;
    }
};

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

/// The pills a motion frame has to repaint (T1925): each busy or fading
/// pill where the last paint drew it. Mac 321e61d7c found its sheen re-ran
/// the whole sidebar every frame (86-99% of a core with a dozen busy panes)
/// and moved it onto Core Animation; here a frame invalidates only these, so
/// one busy pane among forty repaints its pill, not the column. More pills
/// than it holds is `full`: the whole column, as before.
pub const Dirty = struct {
    pub const cap = 16;
    rects: [cap]Rect = undefined,
    count: usize = 0,
    full: bool = false,

    pub fn add(self: *Dirty, r: Rect) void {
        if (r.width() <= 0 or r.height() <= 0) return;
        if (self.count == cap) {
            self.full = true;
            return;
        }
        self.rects[self.count] = r;
        self.count += 1;
    }

    pub fn items(self: *const Dirty) []const Rect {
        return self.rects[0..self.count];
    }

    /// Whether a frame can repaint `items` alone: something was noted, and
    /// nothing overflowed.
    pub fn partial(self: Dirty) bool {
        return !self.full and self.count > 0;
    }
};

/// Whether `a` and `b` share a pixel - a row outside a paint's clip box is
/// tallied but not drawn (T1925).
pub fn overlaps(a: Rect, b: Rect) bool {
    return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom;
}

test "T1925: a motion frame repaints the moving pills, or everything once they overflow" {
    var d: Dirty = .{};
    try std.testing.expect(!d.partial()); // nothing noted: the whole column
    d.add(.{ .left = 0, .top = 0, .right = 0, .bottom = 10 }); // empty: ignored
    try std.testing.expect(!d.partial());
    d.add(.{ .left = 4, .top = 40, .right = 200, .bottom = 68 });
    try std.testing.expect(d.partial());
    try std.testing.expectEqual(@as(usize, 1), d.items().len);
    try std.testing.expectEqual(@as(i32, 40), d.items()[0].top);
    for (1..Dirty.cap) |k| d.add(.{ .left = 4, .top = @intCast(k * 32), .right = 200, .bottom = @intCast(k * 32 + 28) });
    try std.testing.expect(d.partial()); // exactly full is still partial
    d.add(.{ .left = 4, .top = 900, .right = 200, .bottom = 928 });
    try std.testing.expect(d.full);
    try std.testing.expect(!d.partial());
}

test "T1925: overlaps is strict at the edges" {
    const a: Rect = .{ .left = 0, .top = 0, .right = 10, .bottom = 10 };
    try std.testing.expect(overlaps(a, .{ .left = 9, .top = 9, .right = 20, .bottom = 20 }));
    try std.testing.expect(!overlaps(a, .{ .left = 10, .top = 0, .right = 20, .bottom = 10 }));
    try std.testing.expect(!overlaps(a, .{ .left = 0, .top = 10, .right = 10, .bottom = 20 }));
    try std.testing.expect(overlaps(a, .{ .left = -5, .top = -5, .right = 30, .bottom = 30 }));
}

test "T2279/T2309: a sweep starts off the pill and leaves it entirely, top corner included" {
    // Mac's PaneSidebarSheenTests sizes: a tile, and two panel widths.
    for ([_]f64{ 36, 240, 380 }) |w| {
        const h: f64 = 28;
        const tr = travel(w, h);
        try std.testing.expect(tr.from > tr.to); // right to left
        // At both ends of its travel no pixel of the pill is lit, on any line.
        var y: f64 = 0;
        while (y < h) : (y += 1) {
            var x: f64 = 0;
            while (x < w) : (x += 1) {
                try std.testing.expectEqual(@as(f64, 0), sheenAlpha(x + 0.5, y + 0.5, tr.from, w));
                try std.testing.expectEqual(@as(f64, 0), sheenAlpha(x + 0.5, y + 0.5, tr.to, w));
            }
        }
    }
    // On a tile, ending where an upright band ended would leave the top-left
    // corner still lit - the overshoot Mac's travel adds the slant for.
    const w: f64 = 36;
    const h: f64 = 28;
    const flat_to = travel(w, h).to + slant * h;
    var lit = false;
    var x: f64 = 0;
    while (x < w) : (x += 1) lit = lit or sheenAlpha(x + 0.5, h - 0.5, flat_to, w) > 0;
    try std.testing.expect(lit);
}

test "T2279: one sweep every 2s, taking 0.8s, then resting off the pill" {
    const w: f64 = 36;
    const h: f64 = 28;
    const tr = travel(w, h);
    try std.testing.expectApproxEqAbs(tr.from, bandLeft(0, w, h), 1e-9);
    try std.testing.expectApproxEqAbs((tr.from + tr.to) / 2, bandLeft(400, w, h), 1e-9);
    try std.testing.expectApproxEqAbs(tr.to, bandLeft(800, w, h), 1e-9);
    try std.testing.expectApproxEqAbs(tr.to, bandLeft(1999, w, h), 1e-9);
    try std.testing.expectApproxEqAbs(tr.from, bandLeft(2000, w, h), 1e-9);
    // Monotone right to left over the sweep.
    var prev = std.math.inf(f64);
    var ms: u64 = 0;
    while (ms <= 800) : (ms += 10) {
        const b = bandLeft(ms, w, h);
        try std.testing.expect(b <= prev);
        prev = b;
    }
}

test "T2279: the light is a faint band, at most 25% white, brightest in its middle" {
    const w: f64 = 100;
    // Left edge at -150 on the bottom line: the light spans -150 + [120, 180]
    // = [-30, 30], brightest at x = 0.
    try std.testing.expectApproxEqAbs(sheen_peak, sheenAlpha(0, 0, -150, w), 1e-9);
    try std.testing.expect(sheenAlpha(15, 0, -150, w) < sheen_peak);
    try std.testing.expect(sheenAlpha(15, 0, -150, w) > 0);
    try std.testing.expectEqual(@as(f64, 0), sheenAlpha(31, 0, -150, w));
    var i: usize = 0;
    while (i <= 200) : (i += 1) {
        const a = sheenAlpha(@as(f64, @floatFromInt(i)) - 100, 0, -150, w);
        try std.testing.expect(a >= 0 and a <= sheen_peak + 1e-12);
    }
}

test "T2309: the band leans 45 degrees, like '/': each line up is one pixel further right" {
    const w: f64 = 100;
    // The brightest point on the line `rise` up sits `rise` to the right.
    for ([_]f64{ 0, 5, 12, 27 }) |rise| {
        try std.testing.expectApproxEqAbs(sheen_peak, sheenAlpha(rise, rise, -150, w), 1e-9);
        try std.testing.expect(sheenAlpha(rise - 10, rise, -150, w) < sheenAlpha(rise, rise, -150, w));
    }
    // Higher up is further right: "/" (an upright band turned clockwise).
    try std.testing.expect(sheenAlpha(20, 20, -150, w) > sheenAlpha(20, 0, -150, w));
}

test "T2309: the drift is seamless - one period a cycle, its last frame its first" {
    for ([_]f64{ 36, 240, 380 }) |w| {
        const h: f64 = 28;
        const d = Drift.init(w, h);
        // Wider than the pill, so a tile shows one soft crest, never stripes.
        try std.testing.expect(d.period >= w * 1.5 and d.period >= 60);
        try std.testing.expectApproxEqAbs(d.period, d.from - d.to, 1e-9);
        try std.testing.expectApproxEqAbs(d.from, d.left(0), 1e-9);
        try std.testing.expectApproxEqAbs(d.from, d.left(Drift.duration_ms), 1e-9);
        // Moving right to left, linearly.
        try std.testing.expect(d.left(2500) < d.left(0));
        try std.testing.expectApproxEqAbs((d.from + d.to) / 2, d.left(2500), 1e-9);
        // Every pixel, on every line, is covered by the layer at both ends
        // of its travel, and looks the same at both (no jump at the wrap).
        var y: f64 = 0;
        while (y < h) : (y += 1) {
            var x: f64 = 0;
            while (x < w) : (x += 1) {
                const at_from = d.alpha(x + 0.5, y + 0.5, d.from, true);
                const at_to = d.alpha(x + 0.5, y + 0.5, d.to, true);
                try std.testing.expect(at_from >= Drift.dark_alpha[0] - 1e-12);
                try std.testing.expect(at_to >= Drift.dark_alpha[0] - 1e-12);
                try std.testing.expectApproxEqAbs(at_from, at_to, 1e-9);
            }
        }
    }
}

test "T2309: the drift is 2-8% white on dark, 1.5-5% black on light" {
    const d = Drift.init(100, 28);
    var lo_d: f64 = 1;
    var hi_d: f64 = 0;
    var lo_l: f64 = 1;
    var hi_l: f64 = 0;
    var x: f64 = 0.5;
    while (x < 300) : (x += 1) {
        const a = d.alpha(x, 0, 0, true);
        const b = d.alpha(x, 0, 0, false);
        lo_d = @min(lo_d, a);
        hi_d = @max(hi_d, a);
        lo_l = @min(lo_l, b);
        hi_l = @max(hi_l, b);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), lo_d, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), hi_d, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 0.015), lo_l, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), hi_l, 1e-3);
}

test "T2309: a hairline's coverage - inside, its rim band, and nothing outside" {
    const c_mid = cover(20, 10, 40, 20, 4, 0.5);
    try std.testing.expectEqual(@as(f64, 1), c_mid.inside);
    try std.testing.expectEqual(@as(f64, 0), c_mid.ring);
    // An edge pixel (its centre 0.5 in): half of a 1px pixel is a 0.5px rim.
    const edge = cover(20, 0.5, 40, 20, 4, 0.5);
    try std.testing.expectEqual(@as(f64, 1), edge.inside);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), edge.ring, 1e-9);
    // At 2x a 1px rim covers the edge pixel whole.
    try std.testing.expectApproxEqAbs(@as(f64, 1), cover(20, 0.5, 40, 20, 4, 1).ring, 1e-9);
    // Outside the rounded corner: nothing at all.
    try std.testing.expectEqual(@as(f64, 0), cover(0.5, 0.5, 40, 20, 8, 0.5).inside);
}

test "T2309: a rail tile's rim is lit from above, brighter hovered" {
    const dark = tileRim(true, false);
    try std.testing.expectEqual(@as(f64, 0.22), dark.top);
    try std.testing.expectEqual(@as(f64, 0.05), dark.bottom);
    try std.testing.expectEqual(TileRim{ .top = 0.32, .bottom = 0.1 }, tileRim(true, true));
    try std.testing.expectEqual(TileRim{ .top = 0.1, .bottom = 0.04 }, tileRim(false, false));
    try std.testing.expectEqual(TileRim{ .top = 0.16, .bottom = 0.08 }, tileRim(false, true));
    try std.testing.expect(tileRimAt(dark, 0, 30) > tileRimAt(dark, 15, 30));
    try std.testing.expect(tileRimAt(dark, 15, 30) > tileRimAt(dark, 30, 30));
}

test "T2309: an overlay lights only what it should" {
    const w: usize = 52;
    const h: usize = 30;
    // A resting full row: nothing.
    const rest = Overlay.init(w, h, 4, 0.5, true);
    try std.testing.expect(!rest.visible());
    // A resting rail tile: its rim along the edge, never its middle, and
    // brighter at the top than the bottom.
    var tile = Overlay.init(w, h, 4, 0.5, true);
    tile.tile_rim = tileRim(true, false);
    try std.testing.expect(tile.visible());
    try std.testing.expectEqual(@as(f64, 0), tile.pixel(w / 2, h / 2).alpha);
    try std.testing.expect(tile.pixel(w / 2, 0).alpha > tile.pixel(w / 2, h - 1).alpha);
    try std.testing.expectEqual(@as(f64, 0), tile.pixel(0, 0).alpha); // the rounded corner
    // A busy row: the drift lights its middle between glints, white on dark
    // and black on light; and at a level of 0 nothing shows.
    var busy = Overlay.init(240, h, 4, 0.5, true);
    busy.busyAt(1, 1500); // the glint at rest, off the pill
    const mid = busy.pixel(120, h / 2);
    try std.testing.expect(mid.alpha >= Drift.dark_alpha[0] - 1e-9);
    try std.testing.expectApproxEqAbs(mid.alpha, mid.white, 1e-12);
    busy.dark = false;
    try std.testing.expectEqual(@as(f64, 0), busy.pixel(120, h / 2).white);
    try std.testing.expect(busy.pixel(120, h / 2).alpha > 0);
    busy.busyAt(0, 1500);
    try std.testing.expectEqual(@as(f64, 0), busy.pixel(120, h / 2).alpha);
    // Mid-sweep the glint is brighter than any drift.
    var glint = Overlay.init(240, h, 4, 0.5, true);
    glint.busyAt(1, 400);
    var peak: f64 = 0;
    for (0..240) |x| peak = @max(peak, glint.pixel(x, h / 2).alpha);
    try std.testing.expect(peak > Drift.dark_alpha[1] + 0.1);
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
