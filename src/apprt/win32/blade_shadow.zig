//! The shadow a stacked pane's strip casts (T2307; Mac 5a9a2e2a4, afc64dc53
//! `PaneCardView`): strips are blades tucked behind the panes on show, each
//! lying against the next blade out, so each casts a tight, light shadow on
//! that one (30% on dark, 14% on light). It leans AWAY from the run, onto the
//! blade behind it. Along the strip it is cast from a shape pulled in by the
//! corner radius from each end, so it fades out inside the strip's rounded
//! corners - never cut off flat there, nor haloing past them; only the
//! strip's own shape is masked out (T2410; Mac 7e2d0a9da).
//!
//! A card gliding into or out of its strip casts it too, at its collapse
//! (`strip_face.collapseOf`): Mac mixes every parameter from the stacked
//! card's shadow to the blade's by how far into the strip the card is, so the
//! shadow comes on as the card narrows instead of in one step when the glide
//! lands. Here a card's shadow is `pane_elevation`'s own two layers, which the
//! window fades out by the same fraction (`Card.shadow`), so this one's
//! strength is scaled by it as well: nothing snaps at either end.
//!
//! Pure, so the tests need no window: the parameters and the pixels.

const std = @import("std");
const testing = std.testing;
const pane_elevation = @import("pane_elevation.zig");
const desk_palette = @import("desk_palette.zig");
const pane_stack_strip = @import("pane_stack_strip.zig");
const Direction = @import("pane_stack_layout.zig").Direction;

const Rect = pane_stack_strip.Rect;

/// Mac's `shadowRadius` for a stacked card and for a blade, in DIP; a SwiftUI
/// / CALayer blur radius, whose Gaussian has sigma = radius / 2.
pub const card_radius_dip: f32 = 10;
pub const blade_radius_dip: f32 = 5;
/// How far a blade's shadow leans away from the run, in DIP.
pub const lean_dip: f32 = 3;

/// Mac's `shadowOpacity`, stacked card and blade, dark and light.
pub fn cardOpacity(is_light: bool) f32 {
    return if (is_light) 0.16 else 0.4;
}
pub fn bladeOpacity(is_light: bool) f32 {
    return if (is_light) 0.14 else 0.3;
}

/// The shadow at `collapse` (0..1), in pixels.
pub const Params = struct {
    sigma: f32,
    /// After the fade-in: `collapse` of the mixed opacity.
    opacity: f32,
    /// Along the stack, away from the run (unsigned).
    lean: f32,
    /// How far the caster is pulled in from each end of the strip, as a
    /// fraction of the corner radius (Mac `ends`).
    ends: f32,
};

pub fn params(collapse: f32, is_light: bool, scale: f32) Params {
    const t = std.math.clamp(collapse, 0, 1);
    const mix = struct {
        fn f(a: f32, b: f32, k: f32) f32 {
            return a + (b - a) * k;
        }
    }.f;
    return .{
        .sigma = mix(card_radius_dip, blade_radius_dip, t) / 2 * scale,
        .opacity = mix(cardOpacity(is_light), bladeOpacity(is_light), t) * t,
        .lean = lean_dip * t * scale,
        .ends = t,
    };
}

/// Darken `buf` (a `w` x `h` desk composite, 0x00RRGGBB with coverage in the
/// alpha byte) with the shadow of the strip or card at `rect`, whose corners
/// are `radius` pixels, in a stack along `axis` whose run lies after it
/// (`leads`) or before it. Only outside the shape: the band or the pane is
/// laid over the inside. The caster is `rect` pulled in along the strip by
/// the corner radius (at most a quarter of the strip's length), so the
/// shadow fades out inside the rounded ends.
pub fn paint(
    buf: []u32,
    w: usize,
    h: usize,
    rect: Rect,
    axis: Direction,
    leads: bool,
    collapse: f32,
    is_light: bool,
    scale: f32,
    radius: i32,
) void {
    std.debug.assert(buf.len >= w * h);
    if (collapse <= 0 or rect.width() <= 0 or rect.height() <= 0) return;
    const p = params(collapse, is_light, scale);
    if (p.opacity <= 0) return;
    const s: pane_elevation.Shadow = .{ .sigma = p.sigma, .dy = 0, .opacity = p.opacity };
    const card: pane_elevation.Card = .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
    const caster = casterOf(rect, axis, p.ends, radius);
    const rad: f32 = @floatFromInt(radius);
    const out: f32 = if (leads) -1 else 1;
    const dx: f32, const dy: f32 = switch (axis) {
        .horizontal => .{ p.lean * out, 0 },
        .vertical => .{ 0, p.lean * out },
    };
    const reach: i32 = @intFromFloat(@ceil(3 * p.sigma + p.lean) + 1);
    const x0 = rect.left - reach;
    const x1 = rect.right + reach;
    const y0 = rect.top - reach;
    const y1 = rect.bottom + reach;
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);
    const black: desk_palette.Rgbf = .{ .r = 0, .g = 0, .b = 0 };
    var y = @max(y0, 0);
    while (y < @min(y1, hi)) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x = @max(x0, 0);
        while (x < @min(x1, wi)) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            // Outside the shape only (Mac's even-odd mask), antialiased.
            const d0 = pane_elevation.roundRectDistance(px, py, card, rad);
            const outside = std.math.clamp(0.5 + d0, 0, 1);
            if (outside <= 0) continue;
            const a = pane_elevation.shadowAlpha(pane_elevation.roundRectDistance(px - dx, py - dy, caster, rad), s) * outside;
            if (a < 1.0 / 512.0) continue;
            const i: usize = @intCast(y * wi + x);
            const dst = buf[i];
            buf[i] = desk_palette.withCoverage(
                desk_palette.Rgbf.lerp(desk_palette.Rgbf.unpack(dst), black, a).pack(),
                desk_palette.coverOver(desk_palette.coverage(dst), a),
            );
        }
    }
}

/// The shape the shadow is cast from: `rect` pulled in from each end of the
/// strip (across the stack) by `ends` of the corner radius, at most a quarter
/// of the strip's length (Mac `caster`).
pub fn casterOf(rect: Rect, axis: Direction, ends: f32, radius: i32) pane_elevation.Card {
    const along: i32 = switch (axis) {
        .horizontal => rect.height(),
        .vertical => rect.width(),
    };
    const want: i32 = @intFromFloat(@round(std.math.clamp(ends, 0, 1) * @as(f32, @floatFromInt(radius))));
    const in = @max(0, @min(want, @divTrunc(along, 4)));
    return switch (axis) {
        .horizontal => .{ .left = rect.left, .top = rect.top + in, .right = rect.right, .bottom = rect.bottom - in },
        .vertical => .{ .left = rect.left + in, .top = rect.top, .right = rect.right - in, .bottom = rect.bottom },
    };
}

test "params: a card's shadow at 0, a blade's at 1, faded in between (T2307)" {
    const card = params(0, false, 1);
    try testing.expectEqual(@as(f32, 0), card.opacity);
    try testing.expectEqual(@as(f32, 5), card.sigma);
    try testing.expectEqual(@as(f32, 0), card.lean);
    try testing.expectEqual(@as(f32, 0), card.ends);
    // A blade's is light (T2410; Mac 7e2d0a9da): 30% dark, 14% light.
    const blade = params(1, false, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.3), blade.opacity, 1e-6);
    try testing.expectEqual(@as(f32, 2.5), blade.sigma);
    try testing.expectEqual(@as(f32, 3), blade.lean);
    try testing.expectEqual(@as(f32, 1), blade.ends);
    try testing.expectApproxEqAbs(@as(f32, 0.14), params(1, true, 1).opacity, 1e-6);
    // Half way: half of the half-mixed opacity, and in DIP.
    const half = params(0.5, false, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.175), half.opacity, 1e-6);
    try testing.expectEqual(@as(f32, 7.5), half.sigma);
    try testing.expectEqual(@as(f32, 3), half.lean);
    try testing.expectEqual(@as(f32, 0.5), half.ends);
    // Clamped.
    try testing.expectEqual(params(1, false, 1), params(3, false, 1));
}

fn grey(buf: []const u32, w: usize, x: usize, y: usize) u32 {
    return buf[y * w + x] & 0xFF;
}

test "casterOf: pulled in along the strip by the radius, at most a quarter of its length (T2410)" {
    const tall: Rect = .{ .left = 50, .top = 10, .right = 70, .bottom = 50 };
    // A horizontal stack's strip runs down y: its ends are top and bottom.
    try testing.expectEqual(pane_elevation.Card{ .left = 50, .top = 14, .right = 70, .bottom = 46 }, casterOf(tall, .horizontal, 1, 4));
    // A vertical stack's runs along x.
    const wide: Rect = .{ .left = 10, .top = 50, .right = 50, .bottom = 70 };
    try testing.expectEqual(pane_elevation.Card{ .left = 14, .top = 50, .right = 46, .bottom = 70 }, casterOf(wide, .vertical, 1, 4));
    // None for a card (ends 0), half way through a glide half of it.
    try testing.expectEqual(pane_elevation.Card{ .left = 50, .top = 10, .right = 70, .bottom = 50 }, casterOf(tall, .horizontal, 0, 4));
    try testing.expectEqual(pane_elevation.Card{ .left = 50, .top = 12, .right = 70, .bottom = 48 }, casterOf(tall, .horizontal, 0.5, 4));
    // A short strip: a quarter of its length, not the whole radius.
    const short: Rect = .{ .left = 0, .top = 0, .right = 20, .bottom = 12 };
    try testing.expectEqual(pane_elevation.Card{ .left = 0, .top = 3, .right = 20, .bottom = 9 }, casterOf(short, .horizontal, 1, 8));
}

test "paint: a blade darkens the side away from the run, not its own inside, and fades out at its ends" {
    const w = 120;
    const h = 60;
    const base: u32 = desk_palette.packRgb(200, 200, 200);
    var buf = [_]u32{base} ** (w * h);
    // A tall strip in a horizontal stack, the run to its right (it leads).
    const strip: Rect = .{ .left = 50, .top = 10, .right = 70, .bottom = 50 };
    paint(&buf, w, h, strip, .horizontal, true, 1, false, 1, 4);
    // Inside: untouched.
    try testing.expectEqual(base, buf[30 * w + 60]);
    // Just outside the leading (outer) side is darker than just outside the
    // trailing side: the shadow leans away from the run.
    const outer = grey(&buf, w, 48, 30);
    const inner = grey(&buf, w, 71, 30);
    try testing.expect(outer < 200);
    try testing.expect(outer < inner);
    // Darkest beside the strip, fading off.
    try testing.expect(grey(&buf, w, 48, 30) < grey(&buf, w, 44, 30));
    try testing.expectEqual(@as(u32, 200), grey(&buf, w, 30, 30));
    // Past the strip's ends it does not halo (T2410)...
    try testing.expect(grey(&buf, w, 48, 7) >= 199);
    try testing.expect(grey(&buf, w, 48, 53) >= 199);
    // ...and it is not cut off flat there either: it fades out inside the
    // rounded ends, lighter just inside an end than along the middle, and
    // darker still a little further in. Before T2410 the row just inside the
    // end was as dark as the middle and the row past it untouched.
    const mid = grey(&buf, w, 48, 30);
    const end = grey(&buf, w, 48, 11);
    try testing.expect(end > mid + 3);
    try testing.expect(grey(&buf, w, 48, 13) < end);
    try testing.expect(grey(&buf, w, 48, 10) < 200);
    // Light: 30% at most, and well under it with the blur.
    try testing.expect(mid >= 140);
    // Coverage rose with the darkening, for a translucent window.
    try testing.expect(desk_palette.coverage(buf[30 * w + 48]) > 0);

    // The other way round: a trailing strip leans right.
    var buf2 = [_]u32{base} ** (w * h);
    paint(&buf2, w, h, strip, .horizontal, false, 1, false, 1, 4);
    try testing.expect(grey(&buf2, w, 71, 30) < grey(&buf2, w, 48, 30));
}

test "paint: a vertical stack leans along y" {
    const w = 60;
    const h = 120;
    const base: u32 = desk_palette.packRgb(200, 200, 200);
    var buf = [_]u32{base} ** (w * h);
    const strip: Rect = .{ .left = 10, .top = 50, .right = 50, .bottom = 70 };
    // Trailing: the run is above, the shadow leans down.
    paint(&buf, w, h, strip, .vertical, false, 1, false, 1, 4);
    try testing.expect(grey(&buf, w, 30, 71) < grey(&buf, w, 30, 48));
    // Its ends are along x: no halo past them, and fading in from them.
    try testing.expect(grey(&buf, w, 7, 71) >= 199);
    try testing.expect(grey(&buf, w, 11, 71) > grey(&buf, w, 30, 71) + 3);
}

test "paint: none at collapse 0, and a mid-glide shadow between none and a blade's" {
    const w = 120;
    const h = 60;
    const base: u32 = desk_palette.packRgb(200, 200, 200);
    const strip: Rect = .{ .left = 50, .top = 10, .right = 70, .bottom = 50 };
    var none = [_]u32{base} ** (w * h);
    paint(&none, w, h, strip, .horizontal, true, 0, false, 1, 4);
    for (none) |p| try testing.expectEqual(base, p);
    var half = [_]u32{base} ** (w * h);
    paint(&half, w, h, strip, .horizontal, true, 0.5, false, 1, 4);
    var full = [_]u32{base} ** (w * h);
    paint(&full, w, h, strip, .horizontal, true, 1, false, 1, 4);
    const g_half = grey(&half, w, 48, 30);
    const g_full = grey(&full, w, 48, 30);
    try testing.expect(g_half < 200);
    try testing.expect(g_full < g_half);
    // Mid-glide the caster is only half pulled in and the blur is wider: a
    // little reaches past the strip's end, which the blade's barely does.
    try testing.expect(grey(&half, w, 48, 8) < grey(&full, w, 48, 8));
}

test "paint: clipped to the buffer" {
    const w = 20;
    const h = 20;
    var buf = [_]u32{0} ** (w * h);
    paint(&buf, w, h, .{ .left = -10, .top = -5, .right = 5, .bottom = 30 }, .horizontal, false, 1, false, 1, 4);
    paint(&buf, w, h, .{ .left = 15, .top = 0, .right = 40, .bottom = 20 }, .vertical, true, 1, true, 1.5, 6);
}
