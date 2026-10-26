//! What a draggable gutter shows (T2253; Mac `GutterBar`, main a81db68f9 +
//! 5e4f30144): an accent bar down the middle of the gutter, with a soft glow,
//! while the pointer is over it - half strength - and at full strength while
//! it is dragged. One bar at a time: a drag's bar is the only one on show, and
//! a gutter the pointer happens to cross mid-drag does not light. Nothing here
//! stays lit after the drag lets go; the window re-asks which gutter the
//! pointer is over when it does (`Window.endDividerDrag` / `endGripDrag`).
//!
//! The gutter alone gave no sign it could be taken. This is the math and the
//! pixels; the window decides which gutter and paints it into the elevated
//! desk's buffer (`PaneDesk.paint`) or over the flat style's line
//! (`Window.paintDividers`).
//!
//! Mac's layer, carried across: a 4pt bar (`GutterBar.thickness`), corner
//! radius half that, `controlAccentColor` for both the bar and its shadow,
//! `shadowRadius` 5 at `shadowOpacity` 0.9, and the layer's opacity 0.5 on
//! hover and 1 while dragged - the opacity takes the shadow with it.

const std = @import("std");
const color_math = @import("color_math.zig");

const Rgb = color_math.Rgb;

/// The bar's width across the gutter, in DIP (Mac `GutterBar.thickness`).
pub const thickness_dip: f32 = 4;
/// The glow's blur radius, in DIP (Mac `shadowRadius`).
pub const glow_radius_dip: f32 = 5;
/// The glow's strength at the bar (Mac `shadowOpacity`).
pub const glow_opacity: f32 = 0.9;

/// A rectangle in pixels, right/bottom exclusive.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn inflate(self: Rect, by: i32) Rect {
        return .{ .left = self.left - by, .top = self.top - by, .right = self.right + by, .bottom = self.bottom + by };
    }
};

/// Which way the gutter runs. `.across_x`: panes side by side, the gutter is
/// a column and the bar is narrow in x. `.across_y`: panes stacked, the
/// gutter is a row and the bar is narrow in y.
pub const Axis = enum { across_x, across_y };

pub const Strength = enum {
    hover,
    drag,

    /// Half strength on hover; the drag's bar is the full one (Mac `show`).
    pub fn opacity(self: Strength) f32 {
        return switch (self) {
            .hover => 0.5,
            .drag => 1.0,
        };
    }
};

/// A gutter the window can name: a split divider, or a stack grip.
pub const Gutter = union(enum) {
    divider: u16,
    grip: usize,

    pub fn eql(a: Gutter, b: Gutter) bool {
        return std.meta.eql(a, b);
    }
};

pub const Lit = struct { gutter: Gutter, strength: Strength };

/// The one bar on show: the dragged gutter's at full strength while a drag is
/// under way - whatever the pointer is over - else the hovered one's at half.
pub fn lit(hovered: ?Gutter, dragged: ?Gutter) ?Lit {
    if (dragged) |d| return .{ .gutter = d, .strength = .drag };
    if (hovered) |h| return .{ .gutter = h, .strength = .hover };
    return null;
}

/// The bar's core in `gutter`: `thickness_dip` wide, centred across the
/// gutter, along its whole length (Mac `GutterBar.layout`). Never wider than
/// the gutter it is kept in.
pub fn barIn(gutter: Rect, axis: Axis, scale: f32) Rect {
    const s = if (scale > 0) scale else 1;
    const t: i32 = @max(1, @as(i32, @intFromFloat(@round(thickness_dip * s))));
    var r = gutter;
    switch (axis) {
        .across_x => {
            const span = gutter.right - gutter.left;
            const w = @min(t, @max(span, 1));
            r.left = gutter.left + @divFloor(span - w, 2);
            r.right = r.left + w;
        },
        .across_y => {
            const span = gutter.bottom - gutter.top;
            const h = @min(t, @max(span, 1));
            r.top = gutter.top + @divFloor(span - h, 2);
            r.bottom = r.top + h;
        },
    }
    return r;
}

/// How far past the core the glow reaches, in pixels: three sigmas, where
/// the blur's sigma is half its radius (the usual reading of a Core
/// Animation `shadowRadius`). What a repaint of the bar has to cover.
pub fn glowReach(scale: f32) i32 {
    const s = if (scale > 0) scale else 1;
    return @as(i32, @intFromFloat(@ceil(3 * sigma(s)))) + 1;
}

fn sigma(scale: f32) f32 {
    return glow_radius_dip * scale / 2;
}

/// Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7): plenty for an 8-bit glow.
fn erf(x: f32) f32 {
    const sign: f32 = if (x < 0) -1 else 1;
    const a = @abs(x);
    const t = 1 / (1 + 0.3275911 * a);
    const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-a * a);
    return sign * y;
}

/// A box [lo, hi) blurred by a gaussian of `s`, read at pixel centre `c`.
fn blurred(c: f32, lo: f32, hi: f32, s: f32) f32 {
    const k = 1 / (s * std.math.sqrt2);
    return 0.5 * (erf((hi - c) * k) - erf((lo - c) * k));
}

/// How much of pixel [p, p+1) the box [lo, hi) covers.
fn covered(p: f32, lo: f32, hi: f32) f32 {
    return std.math.clamp(@min(p + 1, hi) - @max(p, lo), 0, 1);
}

/// The bar's alpha at pixel (x, y): the core over its glow, both at the
/// strength's opacity.
pub fn alphaAt(core: Rect, x: i32, y: i32, scale: f32, strength: Strength) f32 {
    const s = sigma(if (scale > 0) scale else 1);
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const l: f32 = @floatFromInt(core.left);
    const r: f32 = @floatFromInt(core.right);
    const t: f32 = @floatFromInt(core.top);
    const b: f32 = @floatFromInt(core.bottom);
    const body = covered(fx, l, r) * covered(fy, t, b);
    const glow = glow_opacity * blurred(fx + 0.5, l, r, s) * blurred(fy + 0.5, t, b, s);
    return strength.opacity() * (body + (1 - body) * glow);
}

fn lerp8(a: u32, b: u8, t: f32) u32 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return @intFromFloat(@round(fa + (fb - fa) * t));
}

/// Lay the bar over `pixels` (0xAARRGGBB, `w` x `h`, the elevated desk's
/// `comp` contract: the alpha byte is how much of the pixel is not the desk,
/// so a translucent window keeps the bar opaque over a see-through gutter).
/// `core` is in the buffer's pixels; whatever falls outside is skipped.
pub fn paint(pixels: []u32, w: usize, h: usize, core: Rect, color: Rgb, scale: f32, strength: Strength) void {
    const reach = core.inflate(glowReach(scale));
    const x0: usize = @intCast(std.math.clamp(reach.left, 0, @as(i32, @intCast(w))));
    const x1: usize = @intCast(std.math.clamp(reach.right, 0, @as(i32, @intCast(w))));
    const y0: usize = @intCast(std.math.clamp(reach.top, 0, @as(i32, @intCast(h))));
    const y1: usize = @intCast(std.math.clamp(reach.bottom, 0, @as(i32, @intCast(h))));
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const a = alphaAt(core, @intCast(x), @intCast(y), scale, strength);
            if (a <= 0.002) continue;
            const p = &pixels[y * w + x];
            const cov = p.* >> 24;
            const out_cov: u32 = @min(255, lerp8(cov, 255, a));
            const rr = lerp8((p.* >> 16) & 0xFF, color.r, a);
            const gg = lerp8((p.* >> 8) & 0xFF, color.g, a);
            const bb = lerp8(p.* & 0xFF, color.b, a);
            p.* = (out_cov << 24) | (rr << 16) | (gg << 8) | bb;
        }
    }
}

test "lit: one bar at a time, the drag's outranks the hover" {
    const a: Gutter = .{ .divider = 3 };
    const b: Gutter = .{ .grip = 1 };
    try std.testing.expect(lit(null, null) == null);
    const hov = lit(a, null).?;
    try std.testing.expect(hov.gutter.eql(a));
    try std.testing.expectEqual(Strength.hover, hov.strength);
    // Mid-drag the pointer crossing another gutter does not light it.
    const drg = lit(b, a).?;
    try std.testing.expect(drg.gutter.eql(a));
    try std.testing.expectEqual(Strength.drag, drg.strength);
}

test "Strength: half on hover, full while dragged" {
    try std.testing.expectEqual(@as(f32, 0.5), Strength.hover.opacity());
    try std.testing.expectEqual(@as(f32, 1.0), Strength.drag.opacity());
}

test "barIn: 4 DIP down the middle of the gutter, its whole length" {
    // A 6 DIP flat gutter at 100%: 4 px, one px either side.
    const g: Rect = .{ .left = 100, .top = 0, .right = 106, .bottom = 400 };
    const b = barIn(g, .across_x, 1);
    try std.testing.expectEqual(Rect{ .left = 101, .top = 0, .right = 105, .bottom = 400 }, b);
    // At 150% the bar is 6 px; in a 12 px gutter it sits 3 px in.
    const g2: Rect = .{ .left = 0, .top = 50, .right = 800, .bottom = 62 };
    const b2 = barIn(g2, .across_y, 1.5);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 53, .right = 800, .bottom = 59 }, b2);
}

test "barIn: kept in a gutter thinner than the bar" {
    const g: Rect = .{ .left = 10, .top = 0, .right = 12, .bottom = 30 };
    const b = barIn(g, .across_x, 2);
    try std.testing.expect(b.left >= g.left and b.right <= g.right);
    try std.testing.expectEqual(@as(i32, 2), b.right - b.left);
}

test "alphaAt: solid in the core, a glow that fades, nothing far off" {
    const core: Rect = .{ .left = 10, .top = 0, .right = 14, .bottom = 100 };
    const mid = alphaAt(core, 11, 50, 1, .drag);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mid, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), alphaAt(core, 11, 50, 1, .hover), 0.001);
    const near = alphaAt(core, 15, 50, 1, .drag);
    const far = alphaAt(core, 18, 50, 1, .drag);
    try std.testing.expect(near > far);
    try std.testing.expect(near > 0.1 and near < 0.9);
    try std.testing.expect(alphaAt(core, 14 + glowReach(1) + 2, 50, 1, .drag) < 0.002);
    // Symmetric across the bar.
    try std.testing.expectApproxEqAbs(alphaAt(core, 8, 50, 1, .drag), alphaAt(core, 15, 50, 1, .drag), 0.001);
}

test "paint: the core takes the accent, the glow tints, coverage only grows" {
    const w = 40;
    const h = 10;
    var px = [_]u32{0x0010_2030} ** (w * h);
    const accent: Rgb = .{ .r = 0, .g = 120, .b = 215 };
    const core: Rect = .{ .left = 18, .top = 0, .right = 22, .bottom = h };
    paint(&px, w, h, core, accent, 1, .drag);
    const c = px[5 * w + 19];
    try std.testing.expectEqual(@as(u32, 0xFF00_78D7), c);
    const g = px[5 * w + 23];
    try std.testing.expect(g >> 24 > 0 and g >> 24 < 255);
    try std.testing.expect((g & 0xFF) > 0x30);
    // Far off: untouched.
    try std.testing.expectEqual(@as(u32, 0x0010_2030), px[5 * w + 0]);
    // Hover: the core is half way to the accent.
    var px2 = [_]u32{0xFF00_0000} ** (w * h);
    paint(&px2, w, h, core, accent, 1, .hover);
    const hc = px2[5 * w + 19];
    try std.testing.expectEqual(@as(u32, 0xFF), hc >> 24);
    try std.testing.expectApproxEqAbs(@as(f32, 108), @as(f32, @floatFromInt(hc & 0xFF)), 1.5);
}

test "paint: a bar off the buffer's edge is clipped, not a crash" {
    var px = [_]u32{0} ** (8 * 8);
    paint(&px, 8, 8, .{ .left = -20, .top = -20, .right = -10, .bottom = 40 }, .{ .r = 255, .g = 0, .b = 0 }, 1, .drag);
    paint(&px, 8, 8, .{ .left = 6, .top = 0, .right = 10, .bottom = 8 }, .{ .r = 255, .g = 0, .b = 0 }, 1, .drag);
    try std.testing.expect(px[7] >> 24 == 0xFF);
}
