//! The `elevated` pane style (T1831; Mac `PaneElevation.swift`,
//! main 91ba7c08c / fe3f7c8da): every pane is a slightly raised rounded card
//! on a soft "ocean" gradient, separated from its neighbours by a real gap
//! that is still the divider.
//!
//! Pure geometry and rasterisation, no OS imports, so the unit tests run in
//! every app-runtime lane (the split_geometry.zig / dim_math.zig pattern).
//! `Window.zig` owns the HWND half: where the cards are, the cached desk
//! bitmap, the `BitBlt` and the child window regions.
//!
//! How the card is drawn on Windows, since a child HWND cannot cast a shadow
//! or antialias its own corners: the PARENT paints the desk, both shadow
//! layers, the card's fill (the terminal background, antialiased at the
//! corners) and the hairline rim. The pane's child window sits one rim width
//! inside that card and is clipped to a rounded region whose staircase lies
//! wholly INSIDE the parent's antialiased curve - so the edge the eye sees is
//! the parent's smooth one, and the child's jagged one falls on pixels of the
//! same colour. That is the whole trick, and `childRadiusPx` is where it is
//! kept honest.

const std = @import("std");
const testing = std.testing;
const color_math = @import("color_math.zig");
const desk_palette = @import("desk_palette.zig");

/// THE spacing of the elevated layout, in DIP: between the outermost panes
/// and the window's edge (room for their shadows), and between two panes
/// (fe3f7c8da made the gap the same number, so every gutter matches).
pub const MARGIN_DIP: f32 = 10;
pub const GAP_DIP: f32 = MARGIN_DIP;
/// The card's corner radius, in DIP.
pub const CORNER_RADIUS_DIP: f32 = 11;
/// The rim's stroke width, in DIP (Mac `strokeBorder(lineWidth: 0.5)`).
pub const RIM_DIP: f32 = 0.5;

/// Mac's `macos-pane-style`, which this platform reads under the same key
/// (T1831): a config file is shared between a user's machines, and one key
/// meaning one look on both is the parity the setting exists for.
pub const Style = enum { elevated, flat };

fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

/// The margin around the grid, in physical pixels; 0 in the flat style.
pub fn marginPx(style: Style, scale: f32) i32 {
    return if (style == .elevated) @max(px(MARGIN_DIP, scale), 1) else 0;
}

/// The gap between two panes in physical pixels, or null for the flat style
/// (whose band is `split_geometry.bandPx`, unchanged byte for byte).
pub fn gapPx(style: Style, scale: f32) ?i32 {
    return if (style == .elevated) @max(px(GAP_DIP, scale), 2) else null;
}

pub fn radiusPx(scale: f32) i32 {
    return @max(px(CORNER_RADIUS_DIP, scale), 2);
}

/// How far a pane's child window sits inside its card: one rim width,
/// rounded up to a whole pixel, so the rim the parent paints is visible down
/// every straight edge rather than only at the corners. 0 in the flat style.
pub fn childInsetPx(style: Style, scale: f32) i32 {
    if (style != .elevated) return 0;
    return @max(@as(i32, @intFromFloat(@ceil(RIM_DIP * scale))), 1);
}

/// The radius of the child window's rounded region. One pixel larger than
/// the curve the card itself follows at that inset, which keeps every pixel
/// of `CreateRoundRectRgn`'s staircase inside the parent's antialiased edge.
pub fn childRadiusPx(scale: f32) i32 {
    return radiusPx(scale) - childInsetPx(.elevated, scale) + 1;
}

// The desk's colours and gradient live in `desk_palette.zig` (T1832: a
// window may carry its own); the card painter shares its pixel helpers.

const Rgbf = desk_palette.Rgbf;
const unpack = Rgbf.unpack;
pub const packRgb = desk_palette.packRgb;

// ---------------------------------------------------------------------------
// Cards: shadow, fill, rim.

/// One card, in buffer pixels, `right`/`bottom` exclusive.
pub const Card = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Signed distance from (x, y) to a rounded rectangle; negative inside.
pub fn roundRectDistance(x: f32, y: f32, c: Card, radius: f32) f32 {
    const l: f32 = @floatFromInt(c.left);
    const t: f32 = @floatFromInt(c.top);
    const r: f32 = @floatFromInt(c.right);
    const b: f32 = @floatFromInt(c.bottom);
    const cx = (l + r) / 2;
    const cy = (t + b) / 2;
    const hw = (r - l) / 2;
    const hh = (b - t) / 2;
    const rad = @min(radius, @min(hw, hh));
    const qx = @abs(x - cx) - (hw - rad);
    const qy = @abs(y - cy) - (hh - rad);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - rad;
}

/// One SwiftUI `.shadow` layer, in physical pixels. SwiftUI's `radius` is
/// a blur radius; the Gaussian under it has sigma = radius / 2.
pub const Shadow = struct {
    sigma: f32,
    dy: f32,
    opacity: f32,
};

/// Mac `PaneCard`'s two layers: a tight contact shadow and a soft drop.
pub fn shadows(is_light: bool, scale: f32) [2]Shadow {
    return .{
        .{ .sigma = 0.5 * scale, .dy = 1 * scale, .opacity = if (is_light) 0.08 else 0.28 },
        .{ .sigma = 5.5 * scale, .dy = 8 * scale, .opacity = if (is_light) 0.12 else 0.24 },
    };
}

/// Mac `PaneGlass.tint` (0d8de3436): how much of the terminal's background
/// a glass sheet keeps - chosen as 50% in the mock, lowered to 40% after the
/// user lived with it - so the desk's light and shade read through the pane
/// while text keeps its contrast (T1833).
pub const GLASS_TINT: f32 = 0.4;

/// Mac `PaneGlass`'s pre-Liquid-Glass shadow (`radius: 9, y: 6`, black 20%
/// dark / 6% light). SwiftUI casts it from the sheet's own alpha, so it
/// reaches the desk at the tint's strength.
pub fn glassShadow(is_light: bool, scale: f32) Shadow {
    return .{
        .sigma = 4.5 * scale,
        .dy = 6 * scale,
        .opacity = (if (is_light) @as(f32, 0.06) else 0.2) * GLASS_TINT,
    };
}

/// How far past the card a shadow layer can still be seen.
pub fn shadowReachPx(scale: f32) i32 {
    const s = shadows(false, scale)[1];
    return @intFromFloat(@ceil(3 * s.sigma + s.dy));
}

/// The alpha a blurred rounded rectangle casts at signed distance `d`:
/// the Gaussian's tail across an edge, which is exact for a straight edge
/// and a close, cheap stand-in round a corner.
pub fn shadowAlpha(d: f32, s: Shadow) f32 {
    if (s.sigma <= 0) return if (d <= 0) s.opacity else 0;
    return s.opacity * 0.5 * erfc(d / (s.sigma * std.math.sqrt2));
}

/// Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7) - shadows need no better.
fn erfc(x: f32) f32 {
    const z = @abs(x);
    const t = 1 / (1 + 0.3275911 * z);
    const poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))));
    const r = poly * @exp(-z * z);
    return if (x >= 0) r else 2 - r;
}

fn blend(dst: u32, src: Rgbf, a: f32) u32 {
    if (a <= 0) return dst;
    if (a >= 1) return src.pack();
    return Rgbf.lerp(unpack(dst), src, a).pack();
}

const black: Rgbf = .{ .r = 0, .g = 0, .b = 0 };

// sRGB <-> linear light, as tables: the glass mix runs per pixel over every
// card on every paint, a divider drag included.
const srgb_to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]f32 = undefined;
    for (0..256) |i| {
        const c: f32 = @as(f32, @floatFromInt(i)) / 255.0;
        t[i] = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
    break :blk t;
};
const LINEAR_STEPS = 4096;
const linear_to_srgb: [LINEAR_STEPS]u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [LINEAR_STEPS]u8 = undefined;
    for (0..LINEAR_STEPS) |i| {
        const l: f32 = @as(f32, @floatFromInt(i)) / (LINEAR_STEPS - 1);
        const c = if (l <= 0.0031308) l * 12.92 else 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055;
        t[i] = @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255.0));
    }
    break :blk t;
};

fn mixChannel(desk: u32, tint_lin: f32, t: f32) u32 {
    const l = srgb_to_linear[desk] * (1 - t) + tint_lin * t;
    const idx: usize = @intFromFloat(@round(std.math.clamp(l, 0, 1) * (LINEAR_STEPS - 1)));
    return linear_to_srgb[idx];
}

/// A glass sheet over one desk pixel: `t` of the tint over the desk, mixed
/// in linear light - the blend the terminal's renderer makes inside the
/// pane under Windows' default `alpha-blending` (linear-corrected), so the
/// card's rim and corners meet the pane's own pixels without a seam.
pub fn glassMix(desk: u32, tint: color_math.Rgb, t: f32) u32 {
    return (mixChannel((desk >> 16) & 0xFF, srgb_to_linear[tint.r], t) << 16) |
        (mixChannel((desk >> 8) & 0xFF, srgb_to_linear[tint.g], t) << 8) |
        mixChannel(desk & 0xFF, srgb_to_linear[tint.b], t);
}

pub const CardStyle = struct {
    /// The card's fill - the terminal background.
    fill: color_math.Rgb,
    is_light: bool,
    scale: f32,
    /// A glass sheet (`macos-pane-glass`, T1833): the fill is `GLASS_TINT`
    /// of `fill` over the desk rather than `fill` itself, with Mac
    /// `PaneGlass`'s single soft shadow, kept off the sheet, and its
    /// brighter rim.
    glass: bool = false,
};

/// Paint every card's shadows, then every card, over the desk already in
/// `buf` (a `w` x `h` window-content buffer). Shadows go down first for ALL
/// cards so one card's drop shadow never lands on top of its neighbour.
///
/// Only pixels a card can affect are visited: each card's shadow reach,
/// minus the interior a card fill covers anyway.
pub fn paintCards(buf: []u32, w: usize, h: usize, cards: []const Card, style: CardStyle) void {
    std.debug.assert(buf.len >= w * h);
    const radius: f32 = @floatFromInt(radiusPx(style.scale));
    const solid_layers = shadows(style.is_light, style.scale);
    const glass_layer = [1]Shadow{glassShadow(style.is_light, style.scale)};
    const layers: []const Shadow = if (style.glass) &glass_layer else &solid_layers;
    const reach = shadowReachPx(style.scale);
    const ri: i32 = radiusPx(style.scale);
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);

    for (cards) |c| {
        const y0: i32 = @max(c.top - reach, 0);
        const y1: i32 = @min(c.bottom + reach, hi);
        const x0: i32 = @max(c.left - reach, 0);
        const x1: i32 = @min(c.right + reach, wi);
        var y = y0;
        while (y < y1) : (y += 1) {
            // A row through the card's straight sides skips its interior.
            const sides = y >= c.top + ri and y < c.bottom - ri;
            var x = x0;
            while (x < x1) : (x += 1) {
                if (sides and x >= c.left and x < c.right) {
                    x = c.right - 1;
                    continue;
                }
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                const d0 = roundRectDistance(fx, fy, c, radius);
                if (d0 <= -1) continue;
                // A glass sheet shows the desk, so its shadow is kept to
                // the desk around it: under the sheet it would read as a
                // smudge through the glass.
                const outside: f32 = if (style.glass) std.math.clamp(0.5 + d0, 0, 1) else 1;
                if (outside <= 0) continue;
                const i: usize = @intCast(y * wi + x);
                var p = buf[i];
                for (layers) |s| {
                    const d = roundRectDistance(fx, fy - s.dy, c, radius);
                    p = blend(p, black, shadowAlpha(d, s) * outside);
                }
                buf[i] = p;
            }
        }
    }

    const fill: Rgbf = .{
        .r = @floatFromInt(style.fill.r),
        .g = @floatFromInt(style.fill.g),
        .b = @floatFromInt(style.fill.b),
    };
    const fill_px = fill.pack();
    // Mac's rim: white 7% on a dark card, black 6% on a light one; a glass
    // sheet's is brighter (white 10%, black 8%).
    const rim_rgb: Rgbf = if (style.is_light) black else .{ .r = 255, .g = 255, .b = 255 };
    const rim_a: f32 = if (style.glass)
        (if (style.is_light) @as(f32, 0.08) else 0.10)
    else if (style.is_light) @as(f32, 0.06) else 0.07;
    const rim_w = RIM_DIP * style.scale;
    const rim_c = Rgbf.lerp(fill, rim_rgb, rim_a);
    // The inner edge of the band an antialiased rim pixel can sit in.
    const edge: i32 = @as(i32, @intFromFloat(@ceil(rim_w))) + 1;

    for (cards) |c| {
        const y0: i32 = @max(c.top, 0);
        const y1: i32 = @min(c.bottom, hi);
        var y = y0;
        while (y < y1) : (y += 1) {
            const sides = y >= c.top + ri and y < c.bottom - ri and
                y >= c.top + edge and y < c.bottom - edge;
            const x0: i32 = @max(c.left, 0);
            const x1: i32 = @min(c.right, wi);
            var x = x0;
            while (x < x1) : (x += 1) {
                const i: usize = @intCast(y * wi + x);
                if (sides and x >= c.left + edge and x < c.right - edge) {
                    buf[i] = if (style.glass) glassMix(buf[i], style.fill, GLASS_TINT) else fill_px;
                    continue;
                }
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                const d = roundRectDistance(fx, fy, c, radius);
                const outer = std.math.clamp(0.5 - d, 0, 1);
                if (outer <= 0) continue;
                const inner = std.math.clamp(0.5 - (d + rim_w), 0, 1);
                // The pixel is card, of which `outer - inner` is rim.
                const ring = outer - inner;
                // Glass: the sheet's own colour over THIS pixel of desk.
                const base = if (style.glass) unpack(glassMix(buf[i], style.fill, GLASS_TINT)) else fill;
                const rim_px = if (style.glass) Rgbf.lerp(base, rim_rgb, rim_a) else rim_c;
                const col = if (outer > 0)
                    Rgbf.lerp(base, rim_px, ring / outer)
                else
                    base;
                buf[i] = blend(buf[i], col, outer);
            }
        }
    }
}

// ---------------------------------------------------------------------------

test "T1831: one spacing - the gap and the margin are the same number" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        try testing.expectEqual(marginPx(.elevated, s), gapPx(.elevated, s).?);
    }
    try testing.expectEqual(@as(i32, 10), marginPx(.elevated, 1.0));
    try testing.expectEqual(@as(i32, 15), marginPx(.elevated, 1.5));
    try testing.expectEqual(@as(i32, 11), radiusPx(1.0));
}

test "T1831: the flat style is untouched - no margin, no gap, no inset" {
    try testing.expectEqual(@as(i32, 0), marginPx(.flat, 1.5));
    try testing.expectEqual(@as(?i32, null), gapPx(.flat, 1.5));
    try testing.expectEqual(@as(i32, 0), childInsetPx(.flat, 1.5));
}

test "T1831: the child sits inside the rim and its corner never leaves the card" {
    for ([_]f32{ 1.0, 1.25, 1.5, 1.75, 2.0, 3.0 }) |s| {
        const inset = childInsetPx(.elevated, s);
        try testing.expect(inset >= 1);
        try testing.expect(@as(f32, @floatFromInt(inset)) >= RIM_DIP * s);
        // Every pixel centre a CreateRoundRectRgn of the child's radius
        // admits at the child's corner must lie inside the card.
        const card: Card = .{ .left = 0, .top = 0, .right = 400, .bottom = 300 };
        const cr: f32 = @floatFromInt(childRadiusPx(s));
        const r: f32 = @floatFromInt(radiusPx(s));
        const fi: f32 = @floatFromInt(inset);
        var y: f32 = 0;
        while (y < cr) : (y += 1) {
            var x: f32 = 0;
            while (x < cr) : (x += 1) {
                const px_c = fi + x + 0.5;
                const py_c = fi + y + 0.5;
                const child: Card = .{ .left = inset, .top = inset, .right = 400 - inset, .bottom = 300 - inset };
                if (roundRectDistance(px_c, py_c, child, cr) > -0.5) continue; // outside the region
                try testing.expect(roundRectDistance(px_c, py_c, card, r) < 0);
            }
        }
    }
}

test "T1831: roundRectDistance - inside, edge, corner" {
    const c: Card = .{ .left = 0, .top = 0, .right = 100, .bottom = 50 };
    try testing.expect(roundRectDistance(50, 25, c, 10) < 0);
    try testing.expectApproxEqAbs(@as(f32, 0), roundRectDistance(50, 0, c, 10), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5), roundRectDistance(105, 25, c, 10), 1e-4);
    // The square corner is outside a rounded card.
    try testing.expect(roundRectDistance(0.5, 0.5, c, 10) > 0);
}

test "T1831: a shadow is darkest under the card and gone past its reach" {
    const s = shadows(false, 1.0)[1];
    try testing.expect(shadowAlpha(-20, s) > 0.99 * s.opacity);
    try testing.expectApproxEqAbs(s.opacity / 2, shadowAlpha(0, s), 1e-4);
    const reach: f32 = @floatFromInt(shadowReachPx(1.0));
    try testing.expect(shadowAlpha(reach - s.dy, s) < 0.01);
}

test "T1831: paintCards - fill inside, desk outside, shadow below, rim on the edge" {
    const w = 120;
    const h = 100;
    var buf: [w * h]u32 = undefined;
    const desk = packRgb(40, 60, 90);
    @memset(&buf, desk);
    const card: Card = .{ .left = 20, .top = 20, .right = 100, .bottom = 70 };
    const bg: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    paintCards(&buf, w, h, &.{card}, .{ .fill = bg, .is_light = false, .scale = 1.0 });

    // Interior: the terminal background, exactly.
    try testing.expectEqual(packRgb(30, 30, 30), buf[45 * w + 60]);
    // Far away: the desk, untouched.
    try testing.expectEqual(desk, buf[2 * w + 2]);
    // Below the card the drop shadow darkens the desk; above it, less so.
    const below = unpack(buf[76 * w + 60]);
    const above = unpack(buf[14 * w + 60]);
    try testing.expect(below.b < 90);
    try testing.expect(below.b < above.b);
    // The square corner pixel is NOT card: the corner is rounded.
    try testing.expect(buf[20 * w + 20] != packRgb(30, 30, 30));
    // The rim lightens the card's outermost pixel row on a dark theme.
    const rim = unpack(buf[20 * w + 60]);
    try testing.expect(rim.r > 30);
}

test "T1831: paintCards leaves the desk alone when there are no cards" {
    var buf: [16]u32 = undefined;
    @memset(&buf, 0x123456);
    paintCards(&buf, 4, 4, &.{}, .{ .fill = .{ .r = 0, .g = 0, .b = 0 }, .is_light = false, .scale = 1 });
    for (buf) |p| try testing.expectEqual(@as(u32, 0x123456), p);
}

test "T1833: glassMix keeps 40% of the tint over the desk, in linear light" {
    const desk = packRgb(200, 100, 50);
    const tint: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    // The ends are exact: nothing of the tint, all of it.
    try testing.expectEqual(desk, glassMix(desk, tint, 0));
    try testing.expectEqual(packRgb(30, 30, 30), glassMix(desk, tint, 1));
    // In between, the mix is in linear light: brighter than the sRGB lerp.
    const m = unpack(glassMix(desk, tint, GLASS_TINT));
    const srgb_r: f32 = 200 * 0.6 + 30 * 0.4;
    try testing.expect(m.r > srgb_r + 10 and m.r < 200);
    // A desk the tint's own colour is unchanged by it.
    try testing.expectEqual(packRgb(30, 30, 30), glassMix(packRgb(30, 30, 30), tint, GLASS_TINT));
}

test "T1833: a glass card shows the desk through its fill and keeps its shadow off the sheet" {
    const w = 120;
    const h = 100;
    var buf: [w * h]u32 = undefined;
    var desk: [w * h]u32 = undefined;
    // A desk with a gradient across it, so "through" is observable.
    for (0..h) |y| for (0..w) |x| {
        desk[y * w + x] = packRgb(@intCast(x * 2), 80, @intCast(y * 2));
    };
    @memcpy(&buf, &desk);
    const bg: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    const card: Card = .{ .left = 20, .top = 20, .right = 100, .bottom = 70 };
    paintCards(&buf, w, h, &.{card}, .{ .fill = bg, .is_light = false, .scale = 1.0, .glass = true });

    // Interior: the glass mix of exactly the desk pixel under it - no
    // shadow darkened it first - and two interior pixels differ, because
    // the desk under them does.
    const a = 45 * w + 30;
    const b = 45 * w + 90;
    try testing.expectEqual(glassMix(desk[a], bg, GLASS_TINT), buf[a]);
    try testing.expectEqual(glassMix(desk[b], bg, GLASS_TINT), buf[b]);
    try testing.expect(buf[a] != buf[b]);
    // Below the card: still a shadow on the desk.
    const below = 74 * w + 60;
    try testing.expect(unpack(buf[below]).g < unpack(desk[below]).g);
    // Far away: the desk, untouched.
    try testing.expectEqual(desk[5 * w + 5], buf[5 * w + 5]);

    // The solid card, for contrast, is the terminal background exactly.
    @memcpy(&buf, &desk);
    paintCards(&buf, w, h, &.{card}, .{ .fill = bg, .is_light = false, .scale = 1.0 });
    try testing.expectEqual(packRgb(30, 30, 30), buf[a]);
}
