//! A pane's own progress light (T1899; Mac `SurfaceBusyBorder` and
//! `SurfaceProgressBar`, main a5c0841be / 3ac40dc8b): while a program in the
//! pane reports progress (OSC 9;4) the pane says so itself, not only the
//! taskbar button.
//!
//!   * Busy with no percentage - what Claude Code reports while it works - is
//!     a soft light circling the pane's border: a thin line with a long fading
//!     tail and a bright head, once round every 2.4s, clockwise.
//!   * A percentage is a glowing line across the pane's top edge, as long as
//!     the share that is done. A pause with no percentage is a full line.
//!   * White on a dark pane, charcoal on a light one; an error is red and a
//!     pause orange.
//!
//! How it is drawn on Windows, and the one place it differs from Mac. On Mac
//! the light is a layer inside the pane, clipped to the card, so its glow
//! spills INWARD over the terminal. Here a pane is its own GL child window,
//! and the window that owns the card paints only the card's 1px rim and the
//! desk around it (`pane_elevation.zig`). So the line runs along that rim,
//! where Mac's does, and its glow spills OUTWARD onto the desk instead of
//! over the text. A layered overlay per pane could have put the glow inside,
//! at the price of a full pane-sized bitmap pushed to the compositor every
//! frame per busy pane and another popup to keep in z-order; the light is on
//! screen for as long as an agent works, so it has to cost close to nothing.
//!
//! What keeps it cheap: the ring of pixels a light can touch is fixed by the
//! card's geometry, and so is each pixel's distance from the edge and angle
//! from the centre. `build` computes that once per geometry, `rebase`
//! re-reads the pixels underneath after each full paint, and a frame is just
//! `apply` - a table lookup and three blends per ring pixel - followed by a
//! blit of the four strips the ring lies in.
//!
//! Pure, no OS imports, so the unit tests run in every app-runtime lane.

const std = @import("std");
const testing = std.testing;
const color_math = @import("color_math.zig");
const desk_palette = @import("desk_palette.zig");
const pane_elevation = @import("pane_elevation.zig");

const Rgbf = desk_palette.Rgbf;
const Card = pane_elevation.Card;

/// One revolution of the busy light (Mac `BusyBorderView.period`).
pub const PERIOD_MS: i64 = 2400;
/// A report that is not renewed for this long is dropped (Mac
/// `progressReportTimer`): a program that dies mid-report must not leave a
/// pane looking busy forever.
pub const EXPIRE_MS: i64 = 15_000;
/// The repaint cadence while a light circles: 30 frames a second, the pane
/// sidebar's shimmer cadence.
pub const FRAME_MS: u32 = 33;
/// The cadence when nothing moves (Animation effects off): only the expiry
/// needs a clock then.
pub const IDLE_TICK_MS: u32 = 1000;

/// The OSC 9;4 report, mirrored so this module needs nothing from the core.
pub const State = enum { remove, set, @"error", indeterminate, pause };
pub const Report = struct {
    state: State,
    progress: ?u8 = null,
};

/// What a report draws.
pub const Shape = union(enum) {
    /// The light circling the border.
    ring,
    /// The line across the top, this many percent long.
    bar: u8,
};

/// Mac's split, `SurfaceBusyBorder.usesBar`: a percentage (or a pause, shown
/// as complete) is a bar; everything else that is not `remove` is the ring.
pub fn shapeFor(r: Report) ?Shape {
    if (r.state == .remove) return null;
    if (r.progress) |p| return .{ .bar = @min(p, 100) };
    if (r.state == .pause) return .{ .bar = 100 };
    return .ring;
}

/// The light's colour. Mac `NSColor.progressGlow` (white on dark, 0.2 grey
/// on light) and the system red/orange of each appearance.
pub fn lightColor(state: State, is_light: bool) color_math.Rgb {
    return switch (state) {
        .@"error" => if (is_light) .{ .r = 255, .g = 59, .b = 48 } else .{ .r = 255, .g = 69, .b = 58 },
        .pause => if (is_light) .{ .r = 255, .g = 149, .b = 0 } else .{ .r = 255, .g = 159, .b = 10 },
        else => if (is_light) .{ .r = 51, .g = 51, .b = 51 } else .{ .r = 255, .g = 255, .b = 255 },
    };
}

/// One glow layer: a CALayer/SwiftUI shadow of the line, sigma = radius / 2
/// (the reading `pane_elevation.shadows` uses).
const Glow = struct { sigma_dip: f32, opacity: f32 };

const Profile = struct {
    line_dip: f32,
    tight: Glow,
    wide: Glow,
};

/// Mac `BusyBorderView`: a 1pt line, shadows radius 2 at 0.5 and 7 at 0.3.
const ring_profile: Profile = .{
    .line_dip = 1,
    .tight = .{ .sigma_dip = 1, .opacity = 0.5 },
    .wide = .{ .sigma_dip = 3.5, .opacity = 0.3 },
};
/// Mac `SurfaceProgressBar`: a 2pt capsule, shadows radius 2 at 0.9 and 6
/// at 0.5.
const bar_profile: Profile = .{
    .line_dip = 2,
    .tight = .{ .sigma_dip = 1, .opacity = 0.9 },
    .wide = .{ .sigma_dip = 3, .opacity = 0.5 },
};

fn profileFor(shape: Shape) Profile {
    return switch (shape) {
        .ring => ring_profile,
        .bar => bar_profile,
    };
}

/// How far past the card's edge the glow is drawn, in physical pixels: the
/// wide glow's 3 sigma, kept one pixel short of the gap so a neighbouring
/// card is never touched.
pub fn reachPx(shape: Shape, scale: f32) i32 {
    const p = profileFor(shape);
    const want: i32 = @intFromFloat(@ceil(3 * p.wide.sigma_dip * scale));
    const gap = pane_elevation.gapPx(.elevated, scale) orelse want + 1;
    return @max(@min(want, gap - 1), 1);
}

/// How far inside the card the line reaches, in physical pixels.
fn depthPx(shape: Shape, scale: f32) i32 {
    return @as(i32, @intFromFloat(@ceil(profileFor(shape).line_dip * scale))) + 1;
}

/// Mac's comet: a tail trailing off over almost half the turn, easing up to
/// a bright head, then ending sharply (`BusyBorderView.applyColors`).
const ramp = [_]struct { loc: f32, alpha: f32 }{
    .{ .loc = 0, .alpha = 0 },
    .{ .loc = 0.55, .alpha = 0 },
    .{ .loc = 0.8, .alpha = 0.07 },
    .{ .loc = 0.92, .alpha = 0.22 },
    .{ .loc = 0.975, .alpha = 0.45 },
    .{ .loc = 0.995, .alpha = 0.6 },
    .{ .loc = 1, .alpha = 0 },
};

/// The comet's strength at `loc` along the gradient (1 = the head's tip).
pub fn rampAlpha(loc: f32) f32 {
    if (loc <= ramp[0].loc) return ramp[0].alpha;
    var i: usize = 1;
    while (i < ramp.len) : (i += 1) {
        const a = ramp[i - 1];
        const b = ramp[i];
        if (loc <= b.loc) {
            const t = (loc - a.loc) / (b.loc - a.loc);
            return a.alpha + (b.alpha - a.alpha) * t;
        }
    }
    return ramp[ramp.len - 1].alpha;
}

/// Where the head is, as a fraction of a turn clockwise from the top,
/// `ms` into the animation. Held at the top when motion is off.
pub fn headAt(ms: i64, motion: bool) f32 {
    if (!motion) return 0;
    const m = @mod(ms, PERIOD_MS);
    return @as(f32, @floatFromInt(m)) / @as(f32, @floatFromInt(PERIOD_MS));
}

/// The comet's strength at a point `pos` of a turn round the card
/// (clockwise from the top) with the head at `head`: full at the head,
/// fading behind it, dark ahead of it.
pub fn ringAlpha(pos: f32, head: f32) f32 {
    var behind = head - pos;
    behind -= @floor(behind);
    return rampAlpha(1 - behind);
}

/// The angle of (x, y) about the card's centre, as a fraction of a turn
/// clockwise from straight up (screen coordinates, y down). Mac's sweep is a
/// conic gradient about the pane's centre, so on a wide pane the light
/// crosses the long edges faster than the short ones - kept.
pub fn turnOf(x: f32, y: f32, c: Card) f32 {
    const cx = @as(f32, @floatFromInt(c.left + c.right)) / 2;
    const cy = @as(f32, @floatFromInt(c.top + c.bottom)) / 2;
    const a = std.math.atan2(x - cx, cy - y);
    const t = a / (2 * std.math.pi);
    return t - @floor(t);
}

/// The share of the pixel centred at signed distance `d` (negative inside)
/// that the line - the band `[-line, 0]` just inside the edge - covers.
fn lineCoverage(d: f32, line: f32) f32 {
    const lo = @max(d - 0.5, -line);
    const hi = @min(d + 0.5, 0);
    return std.math.clamp(hi - lo, 0, 1);
}

/// A glow layer at signed distance `d`: the line blurred by a Gaussian of
/// `sigma`, its exact profile across a straight edge. Only ever drawn
/// outside the card (see the file comment).
fn glowAt(d: f32, line: f32, g: Glow, scale: f32) f32 {
    if (d <= 0) return 0;
    const k = g.sigma_dip * scale * std.math.sqrt2;
    if (k <= 0) return 0;
    const band = 0.5 * (pane_elevation.erfc(d / k) - pane_elevation.erfc((d + line) / k));
    return g.opacity * band;
}

/// One pixel the light can touch, cached for a geometry.
pub const RingPx = struct {
    /// Into the buffer the ring was built for.
    idx: u32,
    /// The light-free pixel underneath (`rebase`).
    base: u32 = 0,
    /// The line's coverage and the two glows, 0..255.
    line: u8,
    tight: u8,
    wide: u8,
    /// Ring: the pixel's turn about the centre (0..65535). Bar: how much of
    /// the bar's length covers it (0..65535), fixed for a percentage.
    pos: u16,
};

/// The four rectangles, in buffer pixels (`right`/`bottom` exclusive), that
/// hold every pixel `build` can cache for `card`: a top and a bottom band as
/// deep as the corner radius, and the two sides between them. A bar needs
/// only the first. Clipped to the buffer; an empty one has `right <= left`.
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

pub fn strips(card: Card, shape: Shape, scale: f32, w: i32, h: i32) [4]Rect {
    const reach = reachPx(shape, scale);
    const depth = depthPx(shape, scale);
    const r = pane_elevation.radiusPx(scale);
    const corner = @max(r, depth);
    const empty: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const clip = struct {
        fn f(x: Rect, ww: i32, hh: i32) Rect {
            return .{
                .left = @max(x.left, 0),
                .top = @max(x.top, 0),
                .right = @min(x.right, ww),
                .bottom = @min(x.bottom, hh),
            };
        }
    }.f;
    const top = clip(.{
        .left = card.left - reach,
        .top = card.top - reach,
        .right = card.right + reach,
        .bottom = card.top + corner,
    }, w, h);
    if (shape == .bar) return .{ top, empty, empty, empty };
    return .{
        top,
        clip(.{ .left = card.left - reach, .top = card.bottom - corner, .right = card.right + reach, .bottom = card.bottom + reach }, w, h),
        clip(.{ .left = card.left - reach, .top = card.top + corner, .right = card.left + depth, .bottom = card.bottom - corner }, w, h),
        clip(.{ .left = card.right - depth, .top = card.top + corner, .right = card.right + reach, .bottom = card.bottom - corner }, w, h),
    };
}

fn to8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v * 255), 0, 255));
}

fn to16(v: f32) u16 {
    return @intFromFloat(std.math.clamp(@round(v * 65535), 0, 65535));
}

/// Cache every pixel of a `w` x `h` buffer that `shape`'s light on `card`
/// can touch. Bases are left 0; `rebase` fills them.
pub fn build(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(RingPx),
    w: i32,
    h: i32,
    card: Card,
    shape: Shape,
    scale: f32,
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();
    const p = profileFor(shape);
    const line = p.line_dip * scale;
    const radius: f32 = @floatFromInt(pane_elevation.radiusPx(scale));
    const reach: f32 = @floatFromInt(reachPx(shape, scale));
    const bar_end: f32 = switch (shape) {
        .bar => |pct| @as(f32, @floatFromInt(card.left)) +
            @as(f32, @floatFromInt(card.right - card.left)) * @as(f32, @floatFromInt(pct)) / 100,
        .ring => 0,
    };
    for (strips(card, shape, scale, w, h)) |s| {
        var y = s.top;
        while (y < s.bottom) : (y += 1) {
            var x = s.left;
            while (x < s.right) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                const d = pane_elevation.roundRectDistance(fx, fy, card, radius);
                if (d > reach or d < -line - 1) continue;
                const pos: f32 = switch (shape) {
                    .ring => turnOf(fx, fy, card),
                    // Along the top edge only - the band above the corners'
                    // centres - and as far as the share that is done, with
                    // an antialiased end.
                    .bar => if (fy > @as(f32, @floatFromInt(card.top)) + radius)
                        0
                    else
                        std.math.clamp(bar_end - fx + 0.5, 0, 1),
                };
                const px: RingPx = .{
                    .idx = @intCast(y * w + x),
                    .line = to8(lineCoverage(d, line)),
                    .tight = to8(glowAt(d, line, p.tight, scale)),
                    .wide = to8(glowAt(d, line, p.wide, scale)),
                    .pos = to16(pos),
                };
                if (px.line == 0 and px.tight == 0 and px.wide == 0) continue;
                if (shape == .bar and px.pos == 0) continue;
                try out.append(alloc, px);
            }
        }
    }
}

/// Re-read the light-free pixels under the ring, after the buffer was
/// repainted without it.
pub fn rebase(buf: []const u32, px: []RingPx) void {
    for (px) |*p| p.base = buf[p.idx];
}

fn blend(dst: Rgbf, src: Rgbf, a: f32) Rgbf {
    if (a <= 0) return dst;
    return Rgbf.lerp(dst, src, @min(a, 1));
}

/// Draw one frame of the light into `buf` over the cached bases: the wide
/// glow, the tight glow, then the line, each weighted by the comet (a ring)
/// or the bar's length.
pub fn apply(buf: []u32, px: []const RingPx, shape: Shape, color: color_math.Rgb, head: f32) void {
    const src: Rgbf = .{
        .r = @floatFromInt(color.r),
        .g = @floatFromInt(color.g),
        .b = @floatFromInt(color.b),
    };
    for (px) |p| {
        const pos = @as(f32, @floatFromInt(p.pos)) / 65535;
        const k = switch (shape) {
            .ring => ringAlpha(pos, head),
            .bar => pos,
        };
        if (k <= 0) {
            buf[p.idx] = p.base;
            continue;
        }
        var c = Rgbf.unpack(p.base);
        // The light covers the desk as much as it shows (T1852).
        var cov = desk_palette.coverage(p.base);
        inline for (.{ p.wide, p.tight, p.line }) |layer| {
            const a = @min(@as(f32, @floatFromInt(layer)) / 255 * k, 1);
            c = blend(c, src, a);
            if (a > 0) cov = desk_palette.coverOver(cov, a);
        }
        buf[p.idx] = desk_palette.withCoverage(c.pack(), cov);
    }
}

// ---------------------------------------------------------------------------

test "T1899: a report with no percentage circles the border, a percentage or a pause is a bar" {
    try testing.expectEqual(@as(?Shape, null), shapeFor(.{ .state = .remove }));
    try testing.expectEqual(@as(?Shape, .ring), shapeFor(.{ .state = .indeterminate }));
    try testing.expectEqual(@as(?Shape, .ring), shapeFor(.{ .state = .@"error" }));
    try testing.expectEqual(@as(?Shape, .{ .bar = 40 }), shapeFor(.{ .state = .set, .progress = 40 }));
    try testing.expectEqual(@as(?Shape, .{ .bar = 70 }), shapeFor(.{ .state = .@"error", .progress = 70 }));
    try testing.expectEqual(@as(?Shape, .{ .bar = 100 }), shapeFor(.{ .state = .pause }));
    try testing.expectEqual(@as(?Shape, .{ .bar = 100 }), shapeFor(.{ .state = .set, .progress = 250 }));
}

test "T1899: the light is white on dark, charcoal on light, red for an error, orange for a pause" {
    try testing.expectEqual(color_math.Rgb{ .r = 255, .g = 255, .b = 255 }, lightColor(.indeterminate, false));
    try testing.expectEqual(color_math.Rgb{ .r = 51, .g = 51, .b = 51 }, lightColor(.set, true));
    try testing.expectEqual(@as(u8, 255), lightColor(.@"error", false).r);
    try testing.expect(lightColor(.@"error", false).g < 100);
    try testing.expect(lightColor(.pause, true).g > 100 and lightColor(.pause, true).b < 20);
}

test "T1899: the comet is bright just behind its head, fades along its tail, and is dark ahead" {
    // Just behind the head: the brightest stop.
    try testing.expectApproxEqAbs(@as(f32, 0.6), ringAlpha(0.5 - 0.005, 0.5), 0.01);
    // The tip itself ends sharply.
    try testing.expectApproxEqAbs(@as(f32, 0), ringAlpha(0.5, 0.5), 0.001);
    // Further back it fades monotonically...
    var last: f32 = 1;
    for ([_]f32{ 0.01, 0.05, 0.1, 0.2, 0.3, 0.44 }) |back| {
        const a = ringAlpha(0.5 - back, 0.5);
        try testing.expect(a < last);
        last = a;
    }
    // ...to nothing past the 45% tail, and nothing ahead of the head.
    try testing.expectEqual(@as(f32, 0), ringAlpha(0.5 - 0.5, 0.5));
    try testing.expectEqual(@as(f32, 0), ringAlpha(0.6, 0.5));
    // Wrapping across the top behaves the same.
    try testing.expectApproxEqAbs(ringAlpha(0.95, 0.05), ringAlpha(0.4, 0.5), 0.0001);
}

test "T1899: the head goes round clockwise once every 2.4s, and holds still without motion" {
    try testing.expectEqual(@as(f32, 0), headAt(0, true));
    try testing.expectApproxEqAbs(@as(f32, 0.25), headAt(600, true), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), headAt(PERIOD_MS + 600, true), 0.0001);
    try testing.expectEqual(@as(f32, 0), headAt(600, false));
    // A quarter turn clockwise from the top is the right-hand side.
    const c: Card = .{ .left = 0, .top = 0, .right = 200, .bottom = 100 };
    try testing.expectApproxEqAbs(@as(f32, 0), turnOf(100, -10, c), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), turnOf(300, 50, c), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), turnOf(100, 200, c), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.75), turnOf(-50, 50, c), 0.001);
}

fn testBuffer(comptime w: usize, comptime h: usize) [w * h]u32 {
    return [_]u32{0x0010_2030} ** (w * h);
}

test "T1899: the ring never paints the pane's interior or past its reach, and lights only behind the head" {
    const alloc = testing.allocator;
    const W = 160;
    const H = 120;
    var buf = testBuffer(W, H);
    const card: Card = .{ .left = 20, .top = 20, .right = 140, .bottom = 100 };
    var ring: std.ArrayListUnmanaged(RingPx) = .empty;
    defer ring.deinit(alloc);
    try build(alloc, &ring, W, H, card, .ring, 1);
    try testing.expect(ring.items.len > 0);
    rebase(&buf, ring.items);
    // Head at the right-hand side: the tail lies across the top edge.
    apply(&buf, ring.items, .ring, lightColor(.indeterminate, false), 0.25);

    const reach = reachPx(.ring, 1);
    var lit: usize = 0;
    for (0..H) |yy| {
        for (0..W) |xx| {
            const i = yy * W + xx;
            if (buf[i] == 0x0010_2030) continue;
            lit += 1;
            const x: i32 = @intCast(xx);
            const y: i32 = @intCast(yy);
            // Never deeper inside the card than the line (and its antialiased
            // pixel)...
            const d = pane_elevation.roundRectDistance(
                @as(f32, @floatFromInt(x)) + 0.5,
                @as(f32, @floatFromInt(y)) + 0.5,
                card,
                @floatFromInt(pane_elevation.radiusPx(1)),
            );
            try testing.expect(d >= -2.5);
            // ...never past the glow's reach.
            try testing.expect(x >= card.left - reach and x < card.right + reach);
            try testing.expect(y >= card.top - reach and y < card.bottom + reach);
        }
    }
    try testing.expect(lit > 0);
    // The top edge just left of the top-right corner is in the tail; the
    // bottom-left, ahead of the head, is dark.
    try testing.expect(buf[@as(usize, @intCast(card.top)) * W + 120] != 0x0010_2030);
    try testing.expectEqual(@as(u32, 0x0010_2030), buf[@as(usize, @intCast(card.bottom - 1)) * W + 30]);
}

test "T1899: moving the head restores the pixels it left" {
    const alloc = testing.allocator;
    const W = 120;
    const H = 90;
    var buf = testBuffer(W, H);
    const card: Card = .{ .left = 15, .top = 15, .right = 105, .bottom = 75 };
    var ring: std.ArrayListUnmanaged(RingPx) = .empty;
    defer ring.deinit(alloc);
    try build(alloc, &ring, W, H, card, .ring, 1);
    rebase(&buf, ring.items);
    apply(&buf, ring.items, .ring, lightColor(.indeterminate, false), 0.25);
    const top_tail = @as(usize, @intCast(card.top)) * W + 90;
    try testing.expect(buf[top_tail] != 0x0010_2030);
    // With the head back near the top that pixel is just ahead of it: dark.
    apply(&buf, ring.items, .ring, lightColor(.indeterminate, false), 0.05);
    try testing.expectEqual(@as(u32, 0x0010_2030), buf[top_tail]);
}

test "T1899: a bar lights the top edge only as far as the share that is done" {
    const alloc = testing.allocator;
    const W = 220;
    const H = 80;
    var buf = testBuffer(W, H);
    const card: Card = .{ .left = 10, .top = 20, .right = 210, .bottom = 70 };
    var bar: std.ArrayListUnmanaged(RingPx) = .empty;
    defer bar.deinit(alloc);
    try build(alloc, &bar, W, H, card, .{ .bar = 50 }, 1);
    rebase(&buf, bar.items);
    apply(&buf, bar.items, .{ .bar = 50 }, lightColor(.set, false), 0);
    const row = @as(usize, @intCast(card.top)) * W;
    // Lit at a quarter of the width, dark at three quarters.
    try testing.expect(buf[row + 60] != 0x0010_2030);
    try testing.expectEqual(@as(u32, 0x0010_2030), buf[row + 160]);
    // Nothing at all along the bottom.
    for (0..W) |x| try testing.expectEqual(@as(u32, 0x0010_2030), buf[@as(usize, @intCast(card.bottom - 1)) * W + x]);
}

test "T1899: the glow stops short of the gap, so a neighbouring card is never lit" {
    for ([_]f32{ 1, 1.25, 1.5, 2, 3 }) |scale| {
        const gap = pane_elevation.gapPx(.elevated, scale).?;
        try testing.expect(reachPx(.ring, scale) < gap);
        try testing.expect(reachPx(.{ .bar = 10 }, scale) < gap);
    }
}

test "T1899: the strips hold every pixel the ring caches" {
    const alloc = testing.allocator;
    const W = 300;
    const H = 200;
    const card: Card = .{ .left = 30, .top = 25, .right = 270, .bottom = 180 };
    var ring: std.ArrayListUnmanaged(RingPx) = .empty;
    defer ring.deinit(alloc);
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        try build(alloc, &ring, W, H, card, .ring, scale);
        const ss = strips(card, .ring, scale, W, H);
        for (ring.items) |p| {
            const x: i32 = @intCast(p.idx % W);
            const y: i32 = @intCast(p.idx / W);
            var held = false;
            for (ss) |s| {
                if (x >= s.left and x < s.right and y >= s.top and y < s.bottom) held = true;
            }
            try testing.expect(held);
        }
    }
}
