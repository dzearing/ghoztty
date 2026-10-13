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

/// The square at each top corner of a band laid at the child's inset (a
/// rearrange header, T1851) that the band's own fill must leave to the card
/// paint: the card's curve runs through it, and only the card paint can
/// antialias that curve in the band's colour.
pub fn bandCornerPx(scale: f32) i32 {
    return radiusPx(scale) - childInsetPx(.elevated, scale);
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
    /// The card's own colour when it is not the terminal's (T1851): a
    /// viewer pane's page. Always solid - a page is opaque, so a glass
    /// sheet's corners would ring it in the desk.
    fill: ?color_math.Rgb = null,
    /// An opaque band across the card's top in another colour (T1851): the
    /// rearrange header, a viewer's nav bar. Rows above `head_bottom` take
    /// it as the card's colour, so the band's top corners are the card's
    /// own antialiased curve rather than a square laid over it.
    head: ?color_math.Rgb = null,
    head_bottom: i32 = 0,

    /// The card's colour on row `y`, or null for the style's (glass-able)
    /// terminal fill.
    pub fn colorAt(self: Card, y: i32) ?color_math.Rgb {
        if (self.head) |h| if (y < self.head_bottom) return h;
        return self.fill;
    }
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
pub fn erfc(x: f32) f32 {
    const z = @abs(x);
    const t = 1 / (1 + 0.3275911 * z);
    const poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))));
    const r = poly * @exp(-z * z);
    return if (x >= 0) r else 2 - r;
}

/// `src` at opacity `a` over `dst`, the coverage in the alpha byte
/// accumulating with it (T1852, `desk_palette.coverage`).
fn blend(dst: u32, src: Rgbf, a: f32) u32 {
    if (a <= 0) return dst;
    if (a >= 1) return src.pack() | 0xFF00_0000;
    return desk_palette.withCoverage(
        Rgbf.lerp(unpack(dst), src, a).pack(),
        desk_palette.coverOver(desk_palette.coverage(dst), a),
    );
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

// ---------------------------------------------------------------------------
// The focused pane's glow (T1834; Mac `PaneFocusGlow`, main 9755dc1f7 /
// 51573daf0 / 7966780ae): among several panes, the focused card is backlit -
// a white stroke along its edge, blurred, masked off the card so the light
// lands only on the desk around it - and its rim is a touch brighter.

/// Mac `.stroke(lineWidth: 4)`: the band is centred on the card's edge.
pub const GLOW_STROKE_DIP: f32 = 4;
/// Mac `.blur(radius: 4)`. SwiftUI's blur radius is read the way `shadows`
/// reads a shadow radius, sigma = radius / 2: with the band's outer half
/// that puts the light's end ~8pt past the edge (2 + 3 sigma), which is
/// exactly what 9755dc1f7 tuned it to - and short of the 10pt gap, so a
/// neighbouring pane is never lit from behind.
pub const GLOW_SIGMA_DIP: f32 = 2;
/// How long the glow takes to move to a newly focused pane (Mac
/// `.animation(.easeOut(duration: 0.25), value: isFocused)`).
pub const GLOW_FADE_MS: i64 = 250;

/// The glow's peak strength: white 24% on a dark theme, 50% on a light one
/// (7966780ae's softer value).
pub fn glowOpacity(is_light: bool) f32 {
    return if (is_light) 0.5 else 0.24;
}

/// How far past the card the glow can still be seen, in physical pixels.
pub fn glowReachPx(scale: f32) i32 {
    return @intFromFloat(@ceil((GLOW_STROKE_DIP / 2 + 3 * GLOW_SIGMA_DIP) * scale));
}

/// The glow's alpha at signed distance `d` from the card's edge (negative
/// inside): the blurred band's profile across a straight edge, times the
/// share of the pixel that lies OUTSIDE the card - nothing lights the pane
/// itself.
pub fn glowAlpha(d: f32, is_light: bool, scale: f32) f32 {
    const outside = std.math.clamp(0.5 + d, 0, 1);
    if (outside <= 0) return 0;
    const hw = GLOW_STROKE_DIP / 2 * scale;
    const k = GLOW_SIGMA_DIP * scale * std.math.sqrt2;
    const band = 0.5 * (erfc((d - hw) / k) - erfc((d + hw) / k));
    return glowOpacity(is_light) * band * outside;
}

/// The glow's strength `elapsed_ms` into a focus change, 0 -> 1 on Mac's
/// `.easeOut` (CSS `ease-out`, cubic-bezier(0, 0, 0.58, 1)). The pane
/// losing focus fades on `1 - fadeLevel`.
pub fn fadeLevel(elapsed_ms: i64) f32 {
    if (elapsed_ms <= 0) return 0;
    if (elapsed_ms >= GLOW_FADE_MS) return 1;
    const x: f32 = @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(GLOW_FADE_MS));
    return cubicBezierY(0, 0.58, x);
}

/// y at x on a CSS timing curve with control points (x1, 0), (x2, 1): solve
/// x(t) by bisection (monotonic for x1, x2 in [0, 1]), then evaluate y(t).
fn cubicBezierY(x1: f32, x2: f32, x: f32) f32 {
    const bez = struct {
        fn at(a: f32, b: f32, t: f32) f32 {
            const u = 1 - t;
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
        }
    };
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..24) |_| {
        const mid = (lo + hi) / 2;
        if (bez.at(x1, x2, mid) < x) lo = mid else hi = mid;
    }
    return bez.at(0, 1, (lo + hi) / 2);
}

/// One lit card: `card` indexes the `cards` slice, `level` is how far into
/// its fade it is (1 = fully focused).
pub const Glow = struct {
    card: usize,
    level: f32 = 1,
};

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
    /// The focused card (T1834) - two of them mid-fade, one coming up and
    /// one going down. Empty for a lone pane: it has nothing to stand out
    /// from.
    glows: []const Glow = &.{},
};

/// The rim's strength. Mac: white 7% on a dark card, black 6% on a light
/// one; a glass sheet's is brighter (white 10%, black 8%); and the focused
/// card's brighter again (51573daf0) - solid 16% / 10%, glass 20% / 12%.
pub fn rimAlpha(glass: bool, is_light: bool, focus: f32) f32 {
    const rest: f32, const lit: f32 = if (glass)
        (if (is_light) .{ 0.08, 0.12 } else .{ 0.10, 0.20 })
    else if (is_light) .{ 0.06, 0.10 } else .{ 0.07, 0.16 };
    return rest + (lit - rest) * std.math.clamp(focus, 0, 1);
}

/// Light the desk around each glowing card. Runs before any shadow, the way
/// Mac's glow is the card's backmost layer.
fn paintGlows(buf: []u32, wi: i32, hi: i32, cards: []const Card, style: CardStyle) void {
    const radius: f32 = @floatFromInt(radiusPx(style.scale));
    const reach = glowReachPx(style.scale);
    const ri: i32 = radiusPx(style.scale);
    const edge: i32 = @as(i32, @intFromFloat(@ceil(GLOW_STROKE_DIP / 2 * style.scale))) + 1;
    const white: Rgbf = .{ .r = 255, .g = 255, .b = 255 };
    for (style.glows) |g| {
        if (g.card >= cards.len or g.level <= 0) continue;
        const c = cards[g.card];
        const y0: i32 = @max(c.top - reach, 0);
        const y1: i32 = @min(c.bottom + reach, hi);
        const x0: i32 = @max(c.left - reach, 0);
        const x1: i32 = @min(c.right + reach, wi);
        var y = y0;
        while (y < y1) : (y += 1) {
            // The card's interior is never lit; skip it on a straight row.
            const sides = y >= c.top + ri and y < c.bottom - ri;
            var x = x0;
            while (x < x1) : (x += 1) {
                if (sides and x >= c.left + edge and x < c.right - edge) {
                    x = c.right - edge - 1;
                    continue;
                }
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const fy = @as(f32, @floatFromInt(y)) + 0.5;
                const a = glowAlpha(roundRectDistance(fx, fy, c, radius), style.is_light, style.scale);
                if (a <= 0) continue;
                const i: usize = @intCast(y * wi + x);
                buf[i] = blend(buf[i], white, a * std.math.clamp(g.level, 0, 1));
            }
        }
    }
}

fn focusOf(style: CardStyle, card: usize) f32 {
    var f: f32 = 0;
    for (style.glows) |g| {
        if (g.card == card) f = @max(f, g.level);
    }
    return f;
}

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

    paintGlows(buf, wi, hi, cards, style);

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

    const rim_w = RIM_DIP * style.scale;
    // The inner edge of the band an antialiased rim pixel can sit in.
    const edge: i32 = @as(i32, @intFromFloat(@ceil(rim_w))) + 1;

    for (cards, 0..) |c, ci| {
        const focus = focusOf(style, ci);
        const y0: i32 = @max(c.top, 0);
        const y1: i32 = @min(c.bottom, hi);
        var y = y0;
        while (y < y1) : (y += 1) {
            // This row's card colour (T1851): a header or nav band, a
            // viewer's page, or the terminal - glass only for the last.
            const own = c.colorAt(y);
            const glass = style.glass and own == null;
            const row_rgb = own orelse style.fill;
            const fill: Rgbf = .{
                .r = @floatFromInt(row_rgb.r),
                .g = @floatFromInt(row_rgb.g),
                .b = @floatFromInt(row_rgb.b),
            };
            const fill_px = fill.pack();
            // The rim reads against the colour it edges, so a light page in a
            // dark window is rimmed the way a light card is.
            const light = if (own != null) color_math.isLight(row_rgb) else style.is_light;
            const rim_rgb: Rgbf = if (light) black else .{ .r = 255, .g = 255, .b = 255 };
            const rim_a = rimAlpha(glass, light, focus);
            const rim_c = Rgbf.lerp(fill, rim_rgb, rim_a);
            const sides = y >= c.top + ri and y < c.bottom - ri and
                y >= c.top + edge and y < c.bottom - edge;
            const x0: i32 = @max(c.left, 0);
            const x1: i32 = @min(c.right, wi);
            var x = x0;
            while (x < x1) : (x += 1) {
                const i: usize = @intCast(y * wi + x);
                if (sides and x >= c.left + edge and x < c.right - edge) {
                    // A glass sheet hides the desk only by its tint; a solid
                    // card hides it entirely (T1852).
                    buf[i] = if (glass)
                        desk_palette.withCoverage(
                            glassMix(buf[i], style.fill, GLASS_TINT),
                            desk_palette.coverOver(desk_palette.coverage(buf[i]), GLASS_TINT),
                        )
                    else
                        fill_px | 0xFF00_0000;
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
                const base = if (glass) unpack(glassMix(buf[i], style.fill, GLASS_TINT)) else fill;
                const rim_px = if (glass) Rgbf.lerp(base, rim_rgb, rim_a) else rim_c;
                const col = if (outer > 0)
                    Rgbf.lerp(base, rim_px, ring / outer)
                else
                    base;
                const under = buf[i];
                buf[i] = blend(under, col, outer);
                // `col` already holds the desk a glass sheet shows, so the
                // sheet covers only its tint's worth of it.
                if (glass) buf[i] = desk_palette.withCoverage(
                    buf[i],
                    desk_palette.coverOver(desk_palette.coverage(under), outer * GLASS_TINT),
                );
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

/// A composite pixel's colour, without the coverage its alpha byte carries
/// (T1852).
fn rgbOf(p: u32) u32 {
    return p & 0x00FF_FFFF;
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
    try testing.expectEqual(packRgb(30, 30, 30), rgbOf(buf[45 * w + 60]));
    // Far away: the desk, untouched.
    try testing.expectEqual(desk, buf[2 * w + 2]);
    // Below the card the drop shadow darkens the desk; above it, less so.
    const below = unpack(buf[76 * w + 60]);
    const above = unpack(buf[14 * w + 60]);
    try testing.expect(below.b < 90);
    try testing.expect(below.b < above.b);
    // The square corner pixel is NOT card: the corner is rounded.
    try testing.expect(rgbOf(buf[20 * w + 20]) != packRgb(30, 30, 30));
    // The rim lightens the card's outermost pixel row on a dark theme.
    const rim = unpack(buf[20 * w + 60]);
    try testing.expect(rim.r > 30);

    // Coverage (T1852): the card hides the desk entirely, bare desk not at
    // all, and the shadow part way - more just below the card than far off.
    try testing.expectEqual(@as(u32, 0xFF), buf[45 * w + 60] >> 24);
    try testing.expectEqual(@as(u32, 0), buf[2 * w + 2] >> 24);
    const sh_near = buf[72 * w + 60] >> 24;
    const sh_far = buf[76 * w + 60] >> 24;
    try testing.expect(sh_near > 0 and sh_near < 0xFF);
    try testing.expect(sh_far > 0 and sh_far <= sh_near);
}

test "T1851: a head band takes the card's curve in its own colour, and the rest keeps the fill" {
    const w = 120;
    const h = 100;
    var buf: [w * h]u32 = undefined;
    const desk = packRgb(40, 60, 90);
    @memset(&buf, desk);
    const head: color_math.Rgb = .{ .r = 200, .g = 100, .b = 50 };
    const card: Card = .{ .left = 20, .top = 20, .right = 100, .bottom = 90, .head = head, .head_bottom = 50 };
    const bg: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    paintCards(&buf, w, h, &.{card}, .{ .fill = bg, .is_light = false, .scale = 1.0 });

    // Inside the band: the band's colour, exactly - including the corner
    // zone a band fill leaves to the card paint (just inside the curve).
    try testing.expectEqual(packRgb(200, 100, 50), rgbOf(buf[40 * w + 60]));
    try testing.expectEqual(packRgb(200, 100, 50), rgbOf(buf[28 * w + 28]));
    // Below the band: the terminal fill.
    try testing.expectEqual(packRgb(30, 30, 30), rgbOf(buf[70 * w + 60]));
    // The band's top-left corner is rounded: the square corner is desk-ish,
    // and a pixel on the curve is a blend of band and desk, never the fill.
    try testing.expect(rgbOf(buf[20 * w + 20]) != packRgb(200, 100, 50));
    const on_curve = unpack(buf[22 * w + 23]);
    try testing.expect(on_curve.r > 40 and on_curve.r < 200);
    // The bottom corners keep the terminal's colour.
    try testing.expect(unpack(buf[87 * w + 23]).r < 60);
}

test "T1851: a card's own fill replaces the terminal's and is never glass" {
    const w = 120;
    const h = 100;
    var buf: [w * h]u32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        buf[y * w + x] = packRgb(@intCast(x * 2), 80, @intCast(y * 2));
    };
    const page: color_math.Rgb = .{ .r = 255, .g = 255, .b = 255 };
    const card: Card = .{ .left = 20, .top = 20, .right = 100, .bottom = 90, .fill = page };
    const bg: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    paintCards(&buf, w, h, &.{card}, .{ .fill = bg, .is_light = false, .scale = 1.0, .glass = true });
    try testing.expectEqual(packRgb(255, 255, 255), rgbOf(buf[50 * w + 30]));
    try testing.expectEqual(packRgb(255, 255, 255), rgbOf(buf[50 * w + 90]));
    // The rim of a light page darkens it (black rim), as on a light card.
    try testing.expect(unpack(buf[20 * w + 60]).r < 255);
}

test "T1851: the band corner square holds the whole curve the child inset leaves" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        const k = bandCornerPx(s);
        try testing.expect(k > 0);
        try testing.expectEqual(radiusPx(s), k + childInsetPx(.elevated, s));
    }
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
    try testing.expectEqual(glassMix(desk[a], bg, GLASS_TINT), rgbOf(buf[a]));
    try testing.expectEqual(glassMix(desk[b], bg, GLASS_TINT), rgbOf(buf[b]));
    try testing.expect(buf[a] != buf[b]);
    // A sheet hides the desk by its tint only (T1852).
    try testing.expect(@abs(@as(i32, @intCast(buf[a] >> 24)) - @as(i32, @intFromFloat(@round(GLASS_TINT * 255)))) <= 1);
    // Below the card: still a shadow on the desk.
    const below = 74 * w + 60;
    try testing.expect(unpack(buf[below]).g < unpack(desk[below]).g);
    // Far away: the desk, untouched.
    try testing.expectEqual(desk[5 * w + 5], buf[5 * w + 5]);

    // The solid card, for contrast, is the terminal background exactly.
    @memcpy(&buf, &desk);
    paintCards(&buf, w, h, &.{card}, .{ .fill = bg, .is_light = false, .scale = 1.0 });
    try testing.expectEqual(packRgb(30, 30, 30), rgbOf(buf[a]));
}

/// Mac `PaneFocusGlowTests`, on a 300x240 buffer with a 200x140 card at
/// (50, 50): the light lands OUTSIDE the card, never inside it, and has died
/// out by the 10pt gap to the next pane.
fn renderGlowFixture(buf: []u32, focused: bool, glass: bool) void {
    @memset(buf, packRgb(26, 31, 28)); // Mac's test desk, 0.1/0.12/0.11
    const card: Card = .{ .left = 50, .top = 50, .right = 250, .bottom = 190 };
    const glows = [_]Glow{.{ .card = 0 }};
    paintCards(buf, 300, 240, &.{card}, .{
        .fill = .{ .r = 28, .g = 31, .b = 36 },
        .is_light = false,
        .scale = 1.0,
        .glass = glass,
        .glows = if (focused) &glows else &.{},
    });
}

fn brightness(p: u32) f32 {
    const c = unpack(p);
    return @max(c.r, @max(c.g, c.b)) / 255.0;
}

test "T1834: the focused pane lights the desk around it, never itself, never the next pane" {
    var lit: [300 * 240]u32 = undefined;
    var dark: [300 * 240]u32 = undefined;
    for ([_]bool{ true, false }) |glass| {
        renderGlowFixture(&lit, true, glass);
        renderGlowFixture(&dark, false, glass);
        const row = 120 * 300;
        // 3pt outside the card's right edge (card spans x 50..250).
        try testing.expect(brightness(lit[row + 253]) > brightness(dark[row + 253]) + 0.02);
        // Nothing lights the pane itself: 6pt inside the same edge.
        try testing.expect(@abs(brightness(lit[row + 244]) - brightness(dark[row + 244])) < 0.01);
        // Tight: gone by the 10pt gap, where the next pane would start.
        try testing.expect(@abs(brightness(lit[row + 260]) - brightness(dark[row + 260])) < 0.01);
        // Far from the card, the desk is untouched.
        try testing.expectEqual(dark[row + 296], lit[row + 296]);
        // And the other sides too: above the top edge, left of the left one.
        try testing.expect(brightness(lit[47 * 300 + 150]) > brightness(dark[47 * 300 + 150]) + 0.02);
        try testing.expect(brightness(lit[row + 47]) > brightness(dark[row + 47]) + 0.02);
    }
}

test "T1834: the glow's reach is ~8pt and scales with DPI" {
    try testing.expectEqual(@as(i32, 8), glowReachPx(1.0));
    try testing.expectEqual(@as(i32, 12), glowReachPx(1.5));
    // Within reach of the gap, never past it.
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        try testing.expect(glowReachPx(s) < gapPx(.elevated, s).?);
        const at_gap: f32 = @floatFromInt(gapPx(.elevated, s).?);
        try testing.expect(glowAlpha(at_gap, false, s) < 0.001);
        try testing.expect(glowAlpha(-1, false, s) == 0);
    }
    // A light theme's glow is stronger (white on light needs more to show).
    try testing.expect(glowAlpha(2, true, 1) > glowAlpha(2, false, 1));
}

test "T1834: the focused rim is brighter, in both styles and both themes" {
    for ([_]bool{ true, false }) |glass| for ([_]bool{ true, false }) |light| {
        try testing.expect(rimAlpha(glass, light, 1) > rimAlpha(glass, light, 0));
    };
    try testing.expectApproxEqAbs(@as(f32, 0.20), rimAlpha(true, false, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.10), rimAlpha(true, false, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.16), rimAlpha(false, false, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.12), rimAlpha(true, true, 1), 1e-6);

    // And painted: the focused card's top rim row is lighter than the
    // unfocused one's.
    var lit: [300 * 240]u32 = undefined;
    var dark: [300 * 240]u32 = undefined;
    renderGlowFixture(&lit, true, false);
    renderGlowFixture(&dark, false, false);
    try testing.expect(unpack(lit[50 * 300 + 150]).r > unpack(dark[50 * 300 + 150]).r);
    // ...while the interior is the terminal background, exactly, either way.
    try testing.expectEqual(dark[120 * 300 + 150], lit[120 * 300 + 150]);
}

test "T1834: fadeLevel eases out over 250ms" {
    try testing.expectEqual(@as(f32, 0), fadeLevel(0));
    try testing.expectEqual(@as(f32, 1), fadeLevel(GLOW_FADE_MS));
    try testing.expectEqual(@as(f32, 1), fadeLevel(10_000));
    // Ease-out: well past halfway by the halfway mark, and monotonic.
    try testing.expect(fadeLevel(125) > 0.6);
    var prev: f32 = 0;
    var t: i64 = 0;
    while (t <= GLOW_FADE_MS) : (t += 10) {
        const v = fadeLevel(t);
        try testing.expect(v >= prev);
        prev = v;
    }
}

test "T1834: a half-faded glow is weaker, and an out-of-range card index is ignored" {
    var full: [300 * 240]u32 = undefined;
    var half: [300 * 240]u32 = undefined;
    const card: Card = .{ .left = 50, .top = 50, .right = 250, .bottom = 190 };
    const base: CardStyle = .{ .fill = .{ .r = 28, .g = 31, .b = 36 }, .is_light = false, .scale = 1 };
    for ([_]*[300 * 240]u32{ &full, &half }) |b| @memset(b, packRgb(26, 31, 28));
    var s = base;
    s.glows = &.{.{ .card = 0, .level = 1 }};
    paintCards(&full, 300, 240, &.{card}, s);
    s.glows = &.{ .{ .card = 0, .level = 0.5 }, .{ .card = 7 } };
    paintCards(&half, 300, 240, &.{card}, s);
    const p = 120 * 300 + 253;
    try testing.expect(brightness(half[p]) < brightness(full[p]));
    try testing.expect(brightness(half[p]) > 26.0 / 255.0 + 0.005);
}
