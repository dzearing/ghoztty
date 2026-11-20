//! Hero carousel preview tiles as small elevated cards (T3279, Mac
//! d40352d30 `CarouselTile`): a soft drop shadow under each tile, a hairline
//! rim, and the selected tile backlit - a blurred ring of white light around
//! the card, masked to OUTSIDE it so the picture is never lightened.
//!
//! Pure pixel math over a top-down 0x00RRGGBB buffer, so it is unit-tested in
//! the `none` lane; `HeroCarousel.paint` hands it the band's DIB section.
//!
//! Mac numbers, per state (`isLight` is the terminal background's lightness):
//!
//!   rim      white 20% / 40% hovered / 60% selected  (dark)
//!            black 14% / 25% hovered / 35% selected  (light)
//!   shadow   black, CALayer radius 6 (sigma 3), 3 down, 32% dark / 14% light
//!   glow     white, CALayer radius 4 (sigma 2), centred, selected only,
//!            55% dark / 90% light
//!   picture  100% selected / 85% hovered / 70% otherwise (the rim never fades)
//!   radius   5 pt (a pane's 11 pt is too round at that size)
const std = @import("std");
const pane_elevation = @import("pane_elevation.zig");

pub const State = enum { normal, hovered, selected };

pub const RADIUS_DIP: f32 = 5;
pub const RIM_DIP: f32 = 1;

/// The card's rect in buffer pixels (right/bottom exclusive).
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

pub const Style = struct {
    radius: f32,
    rim_width: f32,
    /// 0 = black, 255 = white, at `rim_alpha`.
    rim_white: bool,
    rim_alpha: f32,
    shadow: pane_elevation.Shadow,
    glow: pane_elevation.Shadow,
    /// The picture's constant alpha, 0..255.
    picture_alpha: u8,
};

pub fn style(state: State, is_light: bool, scale: f32) Style {
    const rim_alpha: f32 = switch (state) {
        .selected => if (is_light) 0.35 else 0.6,
        .hovered => if (is_light) 0.25 else 0.4,
        .normal => if (is_light) 0.14 else 0.2,
    };
    return .{
        .radius = radiusPx(scale),
        .rim_width = @max(1, @round(RIM_DIP * scale)),
        .rim_white = !is_light,
        .rim_alpha = rim_alpha,
        .shadow = .{ .sigma = 3 * scale, .dy = 3 * scale, .opacity = if (is_light) 0.14 else 0.32 },
        .glow = .{
            .sigma = 2 * scale,
            .dy = 0,
            .opacity = if (state == .selected) (if (is_light) @as(f32, 0.9) else 0.55) else 0,
        },
        .picture_alpha = switch (state) {
            .selected => 255,
            .hovered => 217, // 0.85
            .normal => 179, // 0.70
        },
    };
}

pub fn radiusPx(scale: f32) f32 {
    return @max(2, @round(RADIUS_DIP * scale));
}

/// How far past a card its shadow or glow can still be seen.
pub fn reachPx(scale: f32) i32 {
    // The drop's 3 sigma plus its 3 DIP fall, against the glow's 3 sigma.
    return @intFromFloat(@ceil(@max(3 * 3 * scale + 3 * scale, 3 * 2 * scale)));
}

/// Signed distance from (x, y) to the rounded rect's edge: negative inside.
pub fn distance(x: f32, y: f32, r: Rect, radius: f32) f32 {
    const l: f32 = @floatFromInt(r.left);
    const t: f32 = @floatFromInt(r.top);
    const hw: f32 = @as(f32, @floatFromInt(r.width())) / 2;
    const hh: f32 = @as(f32, @floatFromInt(r.height())) / 2;
    const rad = @min(radius, @min(hw, hh));
    const qx = @abs(x - (l + hw)) - (hw - rad);
    const qy = @abs(y - (t + hh)) - (hh - rad);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - rad;
}

fn lerpPx(dst: u32, src: u32, a: f32) u32 {
    if (a <= 0) return dst;
    if (a >= 1) return src & 0x00FF_FFFF;
    var out: u32 = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const d: f32 = @floatFromInt((dst >> shift) & 0xFF);
        const s: f32 = @floatFromInt((src >> shift) & 0xFF);
        const v: u32 = @intFromFloat(@round(d + (s - d) * a));
        out |= @as(u32, @min(v, 255)) << shift;
        if (shift == 16) break;
    }
    return out;
}

const Span = struct { x0: usize, x1: usize, y0: usize, y1: usize };

fn clampSpan(card: Rect, pad: i32, w: usize, h: usize) ?Span {
    const x0 = @max(card.left - pad, 0);
    const y0 = @max(card.top - pad, 0);
    const x1 = @min(card.right + pad, @as(i32, @intCast(w)));
    const y1 = @min(card.bottom + pad, @as(i32, @intCast(h)));
    if (x0 >= x1 or y0 >= y1) return null;
    return .{ .x0 = @intCast(x0), .x1 = @intCast(x1), .y0 = @intCast(y0), .y1 = @intCast(y1) };
}

/// What lies UNDER a card, painted onto the band before its picture: the drop
/// shadow (everywhere it reaches, the card's own footprint included - Mac's
/// picture is translucent over it) and, on the selected tile, the backlight
/// outside the card.
pub fn paintUnder(buf: []u32, w: usize, h: usize, card: Rect, st: Style, scale: f32) void {
    if (card.width() <= 0 or card.height() <= 0) return;
    const span = clampSpan(card, reachPx(scale) + 1, w, h) orelse return;
    var y = span.y0;
    while (y < span.y1) : (y += 1) {
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        const row = buf[y * w ..][0..w];
        var x = span.x0;
        while (x < span.x1) : (x += 1) {
            const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            // The drop: the card's silhouette moved down by `dy`, blurred.
            const ds = distance(fx, fy - st.shadow.dy, card, st.radius);
            const sa = pane_elevation.shadowAlpha(ds, st.shadow);
            var p = row[x];
            if (sa > 0.002) p = lerpPx(p, 0, sa);
            if (st.glow.opacity > 0) {
                const d = distance(fx, fy, card, st.radius);
                if (d > 0) {
                    const ga = pane_elevation.shadowAlpha(d, st.glow);
                    if (ga > 0.002) p = lerpPx(p, 0xFF_FFFF, ga);
                }
            }
            row[x] = p;
        }
    }
}

/// Largest corner the picture's antialiased clip handles; a tile corner is
/// 5 DIP, 20 px at 400%.
pub const MAX_CLIP_PX: usize = 32;

/// The band under a tile's four corner squares, saved before its picture is
/// drawn so the corners can be cut back to the rounded shape antialiased.
pub const Corners = struct {
    n: usize = 0,
    px: [4][MAX_CLIP_PX * MAX_CLIP_PX]u32 = undefined,
};

fn cornerOrigin(card: Rect, n: usize, k: usize) [2]i32 {
    const ni: i32 = @intCast(n);
    return .{
        if (k & 1 == 0) card.left else card.right - ni,
        if (k & 2 == 0) card.top else card.bottom - ni,
    };
}

fn cornerSize(card: Rect, st: Style) usize {
    const r: i32 = @intFromFloat(@ceil(st.radius));
    const n = @min(r + 1, @min(@divTrunc(card.width(), 2), @divTrunc(card.height(), 2)));
    return @intCast(@max(@min(n, @as(i32, MAX_CLIP_PX)), 0));
}

pub fn saveCorners(buf: []const u32, w: usize, h: usize, card: Rect, st: Style, out: *Corners) void {
    out.n = cornerSize(card, st);
    for (0..4) |k| {
        const o = cornerOrigin(card, out.n, k);
        for (0..out.n) |j| for (0..out.n) |i| {
            const x = o[0] + @as(i32, @intCast(i));
            const y = o[1] + @as(i32, @intCast(j));
            out.px[k][j * out.n + i] = if (x >= 0 and y >= 0 and x < w and y < h)
                buf[@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))]
            else
                0;
        };
    }
}

/// Cut the picture back to the rounded card: each corner pixel is the picture
/// by its coverage and the saved band for the rest.
pub fn clipCorners(buf: []u32, w: usize, h: usize, card: Rect, st: Style, saved: *const Corners) void {
    for (0..4) |k| {
        const o = cornerOrigin(card, saved.n, k);
        for (0..saved.n) |j| for (0..saved.n) |i| {
            const x = o[0] + @as(i32, @intCast(i));
            const y = o[1] + @as(i32, @intCast(j));
            if (x < 0 or y < 0 or x >= w or y >= h) continue;
            const d = distance(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, card, st.radius);
            const cover = std.math.clamp(0.5 - d, 0, 1);
            if (cover >= 1) continue;
            const idx = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
            buf[idx] = lerpPx(saved.px[k][j * saved.n + i], buf[idx], cover);
        };
    }
}

/// The hairline rim, laid just inside the card's edge on top of its picture.
pub fn paintRim(buf: []u32, w: usize, h: usize, card: Rect, st: Style) void {
    if (card.width() <= 0 or card.height() <= 0 or st.rim_alpha <= 0) return;
    const span = clampSpan(card, 1, w, h) orelse return;
    const ink: u32 = if (st.rim_white) 0xFF_FFFF else 0;
    const half = st.rim_width / 2;
    const band: i32 = @intFromFloat(@ceil(st.rim_width + st.radius) + 1);
    var y = span.y0;
    while (y < span.y1) : (y += 1) {
        const yi: i32 = @intCast(y);
        const near_y = yi < card.top + band or yi >= card.bottom - band;
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        const row = buf[y * w ..][0..w];
        var x = span.x0;
        while (x < span.x1) : (x += 1) {
            const xi: i32 = @intCast(x);
            // Away from every edge there is nothing to lay; skip to the far side.
            if (!near_y and xi >= card.left + band and xi < card.right - band) {
                x = @intCast(card.right - band - 1);
                continue;
            }
            const d = distance(@as(f32, @floatFromInt(x)) + 0.5, fy, card, st.radius);
            const cover = std.math.clamp(half + 0.5 - @abs(d + half), 0, 1);
            if (cover > 0) row[x] = lerpPx(row[x], ink, cover * st.rim_alpha);
        }
    }
}

const testing = std.testing;

fn testBuf(comptime w: usize, comptime h: usize, fill: u32) [w * h]u32 {
    return [_]u32{fill} ** (w * h);
}

test "hero_tile_card: Mac's per-state numbers" {
    const dark_sel = style(.selected, false, 1);
    try testing.expect(dark_sel.rim_white);
    try testing.expectApproxEqAbs(@as(f32, 0.6), dark_sel.rim_alpha, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.55), dark_sel.glow.opacity, 1e-6);
    try testing.expectEqual(@as(u8, 255), dark_sel.picture_alpha);
    const dark_hov = style(.hovered, false, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.4), dark_hov.rim_alpha, 1e-6);
    try testing.expectEqual(@as(f32, 0), dark_hov.glow.opacity);
    try testing.expectEqual(@as(u8, 217), dark_hov.picture_alpha);
    const dark = style(.normal, false, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.2), dark.rim_alpha, 1e-6);
    try testing.expectEqual(@as(u8, 179), dark.picture_alpha);
    try testing.expectApproxEqAbs(@as(f32, 0.32), dark.shadow.opacity, 1e-6);
    const light_sel = style(.selected, true, 1);
    try testing.expect(!light_sel.rim_white);
    try testing.expectApproxEqAbs(@as(f32, 0.35), light_sel.rim_alpha, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), light_sel.glow.opacity, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.14), style(.normal, true, 1).rim_alpha, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.14), style(.normal, true, 1).shadow.opacity, 1e-6);
    // 5 DIP corners, scaled.
    try testing.expectEqual(@as(f32, 5), style(.normal, false, 1).radius);
    try testing.expectEqual(@as(f32, 10), style(.normal, false, 2).radius);
}

test "hero_tile_card: distance is negative inside, zero on the edge, rounds the corner" {
    const r: Rect = .{ .left = 10, .top = 10, .right = 50, .bottom = 30 };
    try testing.expect(distance(30, 20, r, 5) < 0);
    try testing.expectApproxEqAbs(@as(f32, 0), distance(10, 20, r, 5), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), distance(30, 32, r, 5), 1e-4);
    // The rect's corner point is outside the rounded corner.
    try testing.expect(distance(10.5, 10.5, r, 5) > 0);
}

test "hero_tile_card: the drop shadow darkens below the card more than above it" {
    const W = 80;
    const H = 60;
    var buf = testBuf(W, H, 0x40_40_40);
    const card: Rect = .{ .left = 20, .top = 20, .right = 60, .bottom = 40 };
    paintUnder(&buf, W, H, card, style(.normal, false, 1), 1);
    const below = buf[42 * W + 40] & 0xFF;
    const above = buf[18 * W + 40] & 0xFF;
    try testing.expect(below < 0x40);
    try testing.expect(below < above);
    // Far away: untouched.
    try testing.expectEqual(@as(u32, 0x40_40_40), buf[2 * W + 2]);
}

test "hero_tile_card: only the selected tile is backlit, and only outside the card" {
    const W = 80;
    const H = 60;
    const card: Rect = .{ .left = 20, .top = 20, .right = 60, .bottom = 40 };
    var sel = testBuf(W, H, 0x20_20_20);
    paintUnder(&sel, W, H, card, style(.selected, false, 1), 1);
    var plain = testBuf(W, H, 0x20_20_20);
    paintUnder(&plain, W, H, card, style(.normal, false, 1), 1);
    // Just above the card's top edge (the drop falls the other way): lit.
    const lit = sel[18 * W + 40] & 0xFF;
    const unlit = plain[18 * W + 40] & 0xFF;
    try testing.expect(lit > 0x20);
    try testing.expect(lit > unlit + 20);
    // Inside the card, the glow adds nothing: same as the unselected tile.
    try testing.expectEqual(plain[30 * W + 40], sel[30 * W + 40]);
}

test "hero_tile_card: the rim is a hairline just inside the edge" {
    const W = 60;
    const H = 40;
    var buf = testBuf(W, H, 0);
    const card: Rect = .{ .left = 10, .top = 10, .right = 50, .bottom = 30 };
    paintRim(&buf, W, H, card, style(.selected, false, 1));
    // The first column inside the left edge carries 60% white.
    const edge = buf[20 * W + 10] & 0xFF;
    try testing.expect(edge >= 150 and edge <= 155);
    // Outside the card and in its middle: nothing.
    try testing.expectEqual(@as(u32, 0), buf[20 * W + 9]);
    try testing.expectEqual(@as(u32, 0), buf[20 * W + 30]);
    try testing.expectEqual(@as(u32, 0), buf[20 * W + 12]);
    // The right edge too (the skip must land before it).
    try testing.expect((buf[20 * W + 49] & 0xFF) >= 150);
    // A light theme lays black.
    var light = testBuf(W, H, 0xFF_FFFF);
    paintRim(&light, W, H, card, style(.normal, true, 1));
    try testing.expect((light[20 * W + 10] & 0xFF) < 0xFF);
}

test "hero_tile_card: corners are cut back to the band, antialiased" {
    const W = 40;
    const H = 40;
    var buf = testBuf(W, H, 0x00_00_00);
    const card: Rect = .{ .left = 5, .top = 5, .right = 35, .bottom = 35 };
    const st = style(.normal, false, 1);
    var saved: Corners = .{};
    saveCorners(&buf, W, H, card, st, &saved);
    // The picture lands square.
    for (5..35) |y| for (5..35) |x| {
        buf[y * W + x] = 0xFF_FFFF;
    };
    clipCorners(&buf, W, H, card, st, &saved);
    // The very corner pixel is band again; the middle is the picture.
    try testing.expectEqual(@as(u32, 0), buf[5 * W + 5]);
    try testing.expectEqual(@as(u32, 0), buf[34 * W + 34]);
    try testing.expectEqual(@as(u32, 0xFF_FFFF), buf[20 * W + 20]);
    try testing.expectEqual(@as(u32, 0xFF_FFFF), buf[5 * W + 20]);
    // Somewhere on the arc is a partial pixel.
    var partial = false;
    for (5..11) |y| for (5..11) |x| {
        const v = buf[y * W + x] & 0xFF;
        if (v > 0 and v < 0xFF) partial = true;
    };
    try testing.expect(partial);
}
