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

// ---------------------------------------------------------------------------
// The desk: Mac `PaneDeskPalette.ocean` (the `pools` look).

pub const Hsb = color_math.Hsb;

pub const Rgbf = struct {
    r: f32,
    g: f32,
    b: f32,

    fn fromHsb(hue_deg: f64, s: f64, b: f64) Rgbf {
        const c = color_math.hsbToRgb(.{ .h = hue_deg / 360.0, .s = s, .b = b });
        return .{
            .r = @floatFromInt(c.r),
            .g = @floatFromInt(c.g),
            .b = @floatFromInt(c.b),
        };
    }

    fn lerp(a: Rgbf, b: Rgbf, t: f32) Rgbf {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
        };
    }

    fn pack(c: Rgbf) u32 {
        return packRgb(chan(c.r), chan(c.g), chan(c.b));
    }
};

fn chan(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

/// A 32bpp top-down DIB pixel (`BI_RGB`): 0x00RRGGBB.
pub fn packRgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

fn unpack(p: u32) Rgbf {
    return .{
        .r = @floatFromInt((p >> 16) & 0xFF),
        .g = @floatFromInt((p >> 8) & 0xFF),
        .b = @floatFromInt(p & 0xFF),
    };
}

pub const Palette = struct {
    base_start: Rgbf,
    base_end: Rgbf,
    lead: Rgbf,
    trail: Rgbf,
    lead_reach: f32,
    trail_reach: f32,

    /// Mac `PaneDeskPalette.ocean(isLight:)`, value for value.
    pub fn ocean(is_light: bool) Palette {
        if (is_light) return .{
            .base_start = Rgbf.fromHsb(206, 0.04, 0.98),
            .base_end = Rgbf.fromHsb(198, 0.03, 0.96),
            .lead = Rgbf.fromHsb(205, 0.16, 0.97),
            .trail = Rgbf.fromHsb(171, 0.14, 0.93),
            .lead_reach = 0.75,
            .trail_reach = 0.65,
        };
        return .{
            .base_start = Rgbf.fromHsb(213, 0.50, 0.14),
            .base_end = Rgbf.fromHsb(213, 0.39, 0.11),
            .lead = Rgbf.fromHsb(205, 0.73, 0.42),
            .trail = Rgbf.fromHsb(177, 0.77, 0.35),
            .lead_reach = 0.75,
            .trail_reach = 0.65,
        };
    }

    /// The desk's colour at a point of a `w` x `h` window. SwiftUI's stack:
    /// a linear base from (0.2w, 0) to (0.8w, h), then a radial pool of
    /// `lead` fading to clear from the top-leading corner, then one of
    /// `trail` from the bottom-trailing one; each reach is a fraction of the
    /// window's longer side. A gradient to `.clear` is a premultiplied fade,
    /// which over an opaque base is a plain mix by the remaining alpha.
    pub fn at(self: Palette, x: f32, y: f32, w: f32, h: f32) Rgbf {
        const sx = 0.2 * w;
        const ex = 0.8 * w;
        const dx = ex - sx;
        const dy = h;
        const len2 = @max(dx * dx + dy * dy, 1);
        const t = std.math.clamp(((x - sx) * dx + y * dy) / len2, 0, 1);
        var c = Rgbf.lerp(self.base_start, self.base_end, t);

        const reach = @max(w, h);
        const lead_r = @max(reach * self.lead_reach, 1);
        const lead_a = 1 - @min(@sqrt(x * x + y * y) / lead_r, 1);
        c = Rgbf.lerp(c, self.lead, lead_a);

        const tx = w - x;
        const ty = h - y;
        const trail_r = @max(reach * self.trail_reach, 1);
        const trail_a = 1 - @min(@sqrt(tx * tx + ty * ty) / trail_r, 1);
        c = Rgbf.lerp(c, self.trail, trail_a);
        return c;
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

pub const CardStyle = struct {
    /// The card's fill - the terminal background.
    fill: color_math.Rgb,
    is_light: bool,
    scale: f32,
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
    const layers = shadows(style.is_light, style.scale);
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
                if (roundRectDistance(fx, fy, c, radius) <= -1) continue;
                const i: usize = @intCast(y * wi + x);
                var p = buf[i];
                for (layers) |s| {
                    const d = roundRectDistance(fx, fy - s.dy, c, radius);
                    p = blend(p, black, shadowAlpha(d, s));
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
    // Mac's rim: white 7% on a dark card, black 6% on a light one.
    const rim_rgb: Rgbf = if (style.is_light) black else .{ .r = 255, .g = 255, .b = 255 };
    const rim_a: f32 = if (style.is_light) 0.06 else 0.07;
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
                    buf[i] = fill_px;
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
                const col = if (outer > 0)
                    Rgbf.lerp(fill, rim_c, ring / outer)
                else
                    fill;
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
