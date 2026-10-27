//! The shadow a stacked pane's strip casts (T2307; Mac 5a9a2e2a4, afc64dc53
//! `PaneCardView`): strips are blades tucked behind the panes on show, each
//! lying against the next blade out, so each casts a tight, strong shadow on
//! that one. It leans AWAY from the run, onto the blade behind it, and stops
//! at the strip's own sides rather than haloing past them.
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
/// Mac `PaneCardView.outset`: the room round a card its shadow may use. The
/// mask across the stack narrows from that to the strip's own sides.
pub const outset_dip: f32 = 32;

/// Mac's `shadowOpacity`, stacked card and blade, dark and light.
pub fn cardOpacity(is_light: bool) f32 {
    return if (is_light) 0.16 else 0.4;
}
pub fn bladeOpacity(is_light: bool) f32 {
    return if (is_light) 0.26 else 0.6;
}

/// The shadow at `collapse` (0..1), in pixels.
pub const Params = struct {
    sigma: f32,
    /// After the fade-in: `collapse` of the mixed opacity.
    opacity: f32,
    /// Along the stack, away from the run (unsigned).
    lean: f32,
    /// How far past the strip's sides it may reach across the stack.
    spill: f32,
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
        .spill = outset_dip * (1 - t) * scale,
    };
}

/// Darken `buf` (a `w` x `h` desk composite, 0x00RRGGBB with coverage in the
/// alpha byte) with the shadow of the strip or card at `rect`, whose corners
/// are `radius` pixels, in a stack along `axis` whose run lies after it
/// (`leads`) or before it. Only outside the shape: the band or the pane is
/// laid over the inside.
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
    const rad: f32 = @floatFromInt(radius);
    const out: f32 = if (leads) -1 else 1;
    const dx: f32, const dy: f32 = switch (axis) {
        .horizontal => .{ p.lean * out, 0 },
        .vertical => .{ 0, p.lean * out },
    };
    const reach: i32 = @intFromFloat(@ceil(3 * p.sigma + p.lean) + 1);
    const spill: i32 = @min(reach, @as(i32, @intFromFloat(@floor(p.spill))));
    const along_pad = reach;
    const x0: i32, const x1: i32, const y0: i32, const y1: i32 = switch (axis) {
        .horizontal => .{ rect.left - along_pad, rect.right + along_pad, rect.top - spill, rect.bottom + spill },
        .vertical => .{ rect.left - spill, rect.right + spill, rect.top - along_pad, rect.bottom + along_pad },
    };
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
            const a = pane_elevation.shadowAlpha(pane_elevation.roundRectDistance(px - dx, py - dy, card, rad), s) * outside;
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

test "params: a card's shadow at 0, a blade's at 1, faded in between (T2307)" {
    const card = params(0, false, 1);
    try testing.expectEqual(@as(f32, 0), card.opacity);
    try testing.expectEqual(@as(f32, 5), card.sigma);
    try testing.expectEqual(@as(f32, 0), card.lean);
    try testing.expectEqual(@as(f32, 32), card.spill);
    const blade = params(1, false, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.6), blade.opacity, 1e-6);
    try testing.expectEqual(@as(f32, 2.5), blade.sigma);
    try testing.expectEqual(@as(f32, 3), blade.lean);
    try testing.expectEqual(@as(f32, 0), blade.spill);
    try testing.expectApproxEqAbs(@as(f32, 0.26), params(1, true, 1).opacity, 1e-6);
    // Half way: half of the half-mixed opacity, and in DIP.
    const half = params(0.5, false, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.25), half.opacity, 1e-6);
    try testing.expectEqual(@as(f32, 7.5), half.sigma);
    try testing.expectEqual(@as(f32, 3), half.lean);
    try testing.expectEqual(@as(f32, 32), half.spill);
    // Clamped.
    try testing.expectEqual(params(1, false, 1), params(3, false, 1));
}

fn grey(buf: []const u32, w: usize, x: usize, y: usize) u32 {
    return buf[y * w + x] & 0xFF;
}

test "paint: a blade darkens the side away from the run, not its own inside, and stops at its sides" {
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
    // Across the stack it stops at the strip's own sides.
    try testing.expectEqual(base, buf[8 * w + 48]);
    try testing.expectEqual(base, buf[52 * w + 48]);
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
    try testing.expectEqual(base, buf[71 * w + 8]);
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
    // Mid-glide the mask has not narrowed all the way: a little spills past
    // the strip's side, which the blade's never does.
    try testing.expect(grey(&half, w, 48, 8) < 200);
    try testing.expectEqual(@as(u32, 200), grey(&full, w, 48, 8));
}

test "paint: clipped to the buffer" {
    const w = 20;
    const h = 20;
    var buf = [_]u32{0} ** (w * h);
    paint(&buf, w, h, .{ .left = -10, .top = -5, .right = 5, .bottom = 30 }, .horizontal, false, 1, false, 1, 4);
    paint(&buf, w, h, .{ .left = 15, .top = 0, .right = 40, .bottom = 20 }, .vertical, true, 1, true, 1.5, 6);
}
