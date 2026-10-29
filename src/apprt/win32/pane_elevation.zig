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
    /// The head band is a material over the glass sheet rather than an opaque
    /// band (T1884): with glass on, its rows are `head` at `HEAD_MATERIAL`
    /// over the sheet, so the desk reads through it. Mac's rearrange header is
    /// `.regularMaterial` over the pane's card, which on a glass pane is the
    /// sheet. A viewer's nav bar is the same material on glass (T1916; Mac
    /// `ChromeBarBackground`).
    head_glass: bool = false,
    /// This card's glass sheet (T2086): thinner - and for a dimmed terminal,
    /// faded - on an unfocused pane among several. Read only when the style
    /// is glass.
    sheet: Sheet = .{},
    /// How much of its shadow the card casts, 0..1 (T2307): a card gliding
    /// into or out of its strip trades it for the strip's blade shadow
    /// (`blade_shadow`) by how far into the strip it is.
    shadow: f32 = 1,

    /// The card's colour on row `y`, or null for the style's (glass-able)
    /// terminal fill.
    pub fn colorAt(self: Card, y: i32) ?color_math.Rgb {
        if (self.head) |h| if (y < self.head_bottom) return h;
        return self.fill;
    }

    /// Whether row `y` is a glass head row under `glass` (T1884).
    pub fn glassHeadAt(self: Card, y: i32, glass: bool) bool {
        return glass and self.head_glass and self.head != null and y < self.head_bottom;
    }
};

/// Signed distance from (x, y) to a rounded rectangle; negative inside.
pub fn roundRectDistance(x: f32, y: f32, c: Card, radius: f32) f32 {
    const f = Frame.of(c, radius);
    return f.dist(f.qx(x), f.qy(y));
}

/// `roundRectDistance` in its two halves (T1856). The distance is a function
/// of a horizontal term `qx` (x alone) and a vertical one `qy` (y alone), and
/// it couples them only in the four corner squares, where both are positive.
/// Everywhere else it is the distance to ONE straight edge - `dist(m, m)`
/// with `m = max(qx, qy)` - which is what lets `paintCards` pay for a
/// shadow's `erfc` once per column and once per row instead of once per
/// pixel. The same arithmetic `roundRectDistance` runs, so a value read from
/// a table is the value the per-pixel call would have computed, to the bit.
const Frame = struct {
    cx: f32,
    cy: f32,
    ex: f32,
    ey: f32,
    rad: f32,

    fn of(c: Card, radius: f32) Frame {
        const l: f32 = @floatFromInt(c.left);
        const t: f32 = @floatFromInt(c.top);
        const r: f32 = @floatFromInt(c.right);
        const b: f32 = @floatFromInt(c.bottom);
        const hw = (r - l) / 2;
        const hh = (b - t) / 2;
        const rad = @min(radius, @min(hw, hh));
        return .{ .cx = (l + r) / 2, .cy = (t + b) / 2, .ex = hw - rad, .ey = hh - rad, .rad = rad };
    }

    fn qx(f: Frame, x: f32) f32 {
        return @abs(x - f.cx) - f.ex;
    }

    fn qy(f: Frame, y: f32) f32 {
        return @abs(y - f.cy) - f.ey;
    }

    fn dist(f: Frame, qx_: f32, qy_: f32) f32 {
        const ox = @max(qx_, 0);
        const oy = @max(qy_, 0);
        return @sqrt(ox * ox + oy * oy) + @min(@max(qx_, qy_), 0) - f.rad;
    }

    /// The distance where `q` is the larger term and the other is not
    /// positive: off the corners, the only case a table is consulted for.
    fn edge(f: Frame, q: f32) f32 {
        return f.dist(q, @min(q, 0));
    }
};

/// Per-row/per-column tables over one card's reach (T1856): `q[i]` is the
/// axis term at pixel centre `lo + i`, and `a[k][i]` the alpha layer `k`
/// gives a pixel whose distance is `Frame.edge(q[i])`.
const MAX_TABLE_LAYERS = 2;
const AxisTable = struct {
    lo: i32,
    q: []f32,
    a: [MAX_TABLE_LAYERS][]f32,
};

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

/// Where a glass pane sits on its window's desk (T1833): the pane child's
/// rect and the desk's size, in content-area pixels, and the desk's palette.
/// A terminal hands it to its renderer; a viewer paints the sheet itself
/// (T1885).
pub const GlassBackdrop = struct {
    rect: [4]i32,
    full_w: i32,
    full_h: i32,
    palette: desk_palette.Palette,
    /// The pane's sheet (T2086). Every pane's is the same since T2281 (Mac
    /// 9da9618f8): focus changes only a glass pane's rim and glow.
    sheet: Sheet = .{},
};

/// Mac `PaneGlass.tint` (0d8de3436): how much of the terminal's background
/// a glass sheet keeps - chosen as 50% in the mock, lowered to 40% after the
/// user lived with it - so the desk's light and shade read through the pane
/// while text keeps its contrast (T1833).
pub const GLASS_TINT: f32 = 0.4;

/// One pane's glass sheet (T2086): `t` of the terminal's background over the
/// desk, and then `fade` of the desk back over that, mixed in sRGB the way a
/// layered wash over the pane child blends. Nothing varies it per pane since
/// T2281 (Mac 9da9618f8 dropped the unfocused pane's thinner, faded sheet);
/// T2293 collapses it back to `GLASS_TINT`.
pub const Sheet = struct {
    t: f32 = GLASS_TINT,
    fade: f32 = 0,

    /// What the sheet covers of the desk.
    pub fn cover(self: Sheet) f32 {
        return self.t * (1 - self.fade);
    }

    /// This sheet under the pane banner's card (T2255, Mac a81db68f9): thinned
    /// to `BANNER_TINT`, so the card reads as a pane of glass of its own -
    /// and never thicker than the sheet itself, since a sheet already thinner
    /// (Mac's unfocused 15%) is one terminal text is read through.
    pub fn underBanner(self: Sheet) Sheet {
        return .{ .t = @min(self.t, BANNER_TINT), .fade = self.fade };
    }
};

/// Mac `PaneGlass.bannerTint` (a81db68f9): the sheet under the pane banner's
/// card - a bit thinner than the focused pane's `GLASS_TINT`, so the desk
/// reads through the banner more than through the pane.
pub const BANNER_TINT: f32 = 0.25;

/// How much of the header band's colour a glass pane's rearrange header
/// keeps over the sheet (T1884) - the stand-in for Mac's `.regularMaterial`,
/// which is mostly its own colour with the backdrop's light carried through.
/// Strong enough that the chrome ink chosen against the band still reads.
pub const HEAD_MATERIAL: f32 = 0.7;

/// What a glass head row covers of the desk: the sheet, then the material.
pub const HEAD_COVER: f32 = headCover(GLASS_TINT);

/// What a glass head row covers of the desk over a sheet of `t` (T2086).
pub fn headCover(t: f32) f32 {
    return 1 - (1 - t) * (1 - HEAD_MATERIAL);
}

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

/// How far inside a card's edge anything `paintCards` lays still depends on
/// where that edge is (T2454): the shadow's corner patch reaches furthest in,
/// past the corner radius by the deepest layer's drop. Further in, a card's
/// pixels are the same wherever that edge sits.
pub fn edgeInnerPx(scale: f32) i32 {
    const dy: i32 = @intFromFloat(@ceil(shadows(false, scale)[1].dy));
    return radiusPx(scale) + dy + 3;
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

fn sheetChannel(desk: u32, tint_lin: f32, sheet: Sheet) u32 {
    const m = mixChannel(desk, tint_lin, sheet.t);
    if (sheet.fade <= 0) return m;
    const f = std.math.clamp(sheet.fade, 0, 1);
    const v = @as(f32, @floatFromInt(m)) * (1 - f) + @as(f32, @floatFromInt(desk)) * f;
    return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
}

/// A pane's sheet over one desk pixel (T2086): `glassMix` at the sheet's
/// tint, then its fade back to the desk.
pub fn sheetMix(desk: u32, tint: color_math.Rgb, sheet: Sheet) u32 {
    return (sheetChannel((desk >> 16) & 0xFF, srgb_to_linear[tint.r], sheet) << 16) |
        (sheetChannel((desk >> 8) & 0xFF, srgb_to_linear[tint.g], sheet) << 8) |
        sheetChannel(desk & 0xFF, srgb_to_linear[tint.b], sheet);
}

/// A glass header row's colour over one desk pixel (T1884): the sheet, then
/// the band's material over it.
pub fn glassHeadMix(desk: u32, fill: color_math.Rgb, head: color_math.Rgb) u32 {
    return glassHeadMixAt(desk, fill, head, GLASS_TINT);
}

/// `glassHeadMix` over a sheet of `t` (T2086). A head band is chrome laid on
/// the card, outside the pane child the dim wash covers, so it takes the
/// sheet's tint and never its fade.
pub fn glassHeadMixAt(desk: u32, fill: color_math.Rgb, head: color_math.Rgb, t: f32) u32 {
    return glassMix(glassMix(desk, fill, t), head, HEAD_MATERIAL);
}

/// Fill `out` (`w` x `h`, `0x00RRGGBB`) with the glass sheet over the part of
/// a `full_w` x `full_h` desk whose top-left is at (`rx`, `ry`) - what a
/// glass pane shows at those pixels before anything is drawn on it (T1884).
/// The pane banner is a window of its own over the pane's card, so it lays
/// this down under its floating card; past the desk is the plain tint.
pub fn glassSheetRegion(
    out: []u32,
    w: usize,
    h: usize,
    rx: i32,
    ry: i32,
    full_w: i32,
    full_h: i32,
    pal: desk_palette.Palette,
    tint: color_math.Rgb,
    sheet: Sheet,
) void {
    std.debug.assert(out.len >= w * h);
    const fw: f32 = @floatFromInt(@max(full_w, 1));
    const fh: f32 = @floatFromInt(@max(full_h, 1));
    const lut = GlassLut.initSheet(tint, sheet);
    for (0..h) |row| {
        const y = @as(f32, @floatFromInt(ry + @as(i32, @intCast(row)))) + 0.5;
        for (0..w) |col| {
            const x = @as(f32, @floatFromInt(rx + @as(i32, @intCast(col)))) + 0.5;
            out[row * w + col] = lut.mix(pal.at(
                std.math.clamp(x, 0, fw),
                std.math.clamp(y, 0, fh),
                fw,
                fh,
            ).pack());
        }
    }
}

/// `glassSheetRegion` with a head band's material laid over it: each pixel is
/// `glassHeadMix` of the desk there (T1916). A viewer's nav bar is a window of
/// its own on the pane's sheet, so it paints its band this way itself - the
/// same pixels the card paint gives a glass head's corners round it.
pub fn glassHeadRegion(
    out: []u32,
    w: usize,
    h: usize,
    rx: i32,
    ry: i32,
    full_w: i32,
    full_h: i32,
    pal: desk_palette.Palette,
    fill: color_math.Rgb,
    head: color_math.Rgb,
    sheet: Sheet,
) void {
    // A head band takes the sheet's tint, never its fade (`glassHeadMixAt`).
    glassSheetRegion(out, w, h, rx, ry, full_w, full_h, pal, fill, .{ .t = sheet.t });
    const lut = GlassLut.init(head, HEAD_MATERIAL, headCover(sheet.t));
    for (out[0 .. w * h]) |*p| p.* = lut.mix(p.*);
}

/// `glassMix` at `t` for one tint, and the coverage a sheet leaves, as byte
/// tables (T1856): the sheet covers every pixel of a glass card's interior,
/// and a table lookup per channel is the same answer as the mix.
const GlassLut = struct {
    r: [256]u32,
    g: [256]u32,
    b: [256]u32,
    cover: [256]u32,

    /// `t` is the mix; `cover_t` what the layer covers of the desk's
    /// coverage, which for a head band is the sheet AND the material.
    fn init(tint: color_math.Rgb, t: f32, cover_t: f32) GlassLut {
        return initWith(tint, .{ .t = t }, cover_t);
    }

    /// `sheetMix` at `s` (T2086). The fade is per channel as well, so a
    /// faded sheet costs the paint nothing more than a plain one.
    fn initSheet(tint: color_math.Rgb, s: Sheet) GlassLut {
        return initWith(tint, s, s.cover());
    }

    fn initWith(tint: color_math.Rgb, s: Sheet, cover_t: f32) GlassLut {
        var l: GlassLut = undefined;
        for (0..256) |i| {
            const c: u32 = @intCast(i);
            l.r[i] = sheetChannel(c, srgb_to_linear[tint.r], s) << 16;
            l.g[i] = sheetChannel(c, srgb_to_linear[tint.g], s) << 8;
            l.b[i] = sheetChannel(c, srgb_to_linear[tint.b], s);
            l.cover[i] = desk_palette.withCoverage(0, desk_palette.coverOver(desk_palette.coverage(c << 24), cover_t));
        }
        return l;
    }

    /// `glassMix(p, tint, t)`.
    fn mix(l: *const GlassLut, p: u32) u32 {
        return l.r[(p >> 16) & 0xFF] | l.g[(p >> 8) & 0xFF] | l.b[p & 0xFF];
    }

    /// The sheet over `p`, coverage included.
    fn sheet(l: *const GlassLut, p: u32) u32 {
        return l.mix(p) | l.cover[p >> 24];
    }
};

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

/// How far past the card the glow takes to come up to full strength (T2112).
/// The band is centred on the edge, so unramped its brightest light sat on
/// the first desk pixel and read as a hard line hugging the card ("the inner
/// edge of the glow shouldn't be as bright"). Easing it in over this span
/// moves the peak ~2pt out and leaves everything past it - the outer
/// falloff - exactly as it was.
pub const GLOW_INNER_RAMP_DIP: f32 = 2.5;

/// The glow's alpha at signed distance `d` from the card's edge (negative
/// inside): the blurred band's profile across a straight edge, eased in over
/// `GLOW_INNER_RAMP_DIP`, times the share of the pixel that lies OUTSIDE the
/// card - nothing lights the pane itself.
pub fn glowAlpha(d: f32, is_light: bool, scale: f32) f32 {
    const outside = std.math.clamp(0.5 + d, 0, 1);
    if (outside <= 0) return 0;
    const hw = GLOW_STROKE_DIP / 2 * scale;
    const k = GLOW_SIGMA_DIP * scale * std.math.sqrt2;
    const band = 0.5 * (erfc((d - hw) / k) - erfc((d + hw) / k));
    const r = std.math.clamp(d / (GLOW_INNER_RAMP_DIP * scale), 0, 1);
    const ramp = r * r * (3 - 2 * r);
    return glowOpacity(is_light) * band * ramp * outside;
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
/// card's brighter again (51573daf0) - solid 16% / 10%. On glass the rim and
/// the glow are ALL focus changes (9da9618f8, T2281), so its focused rim is
/// lighter still: white 34%, black 20%.
pub fn rimAlpha(glass: bool, is_light: bool, focus: f32) f32 {
    const rest: f32, const lit: f32 = if (glass)
        (if (is_light) .{ 0.08, 0.20 } else .{ 0.10, 0.34 })
    else if (is_light) .{ 0.06, 0.10 } else .{ 0.07, 0.16 };
    return rest + (lit - rest) * std.math.clamp(focus, 0, 1);
}

/// Light the desk around each glowing card. Runs before any shadow, the way
/// Mac's glow is the card's backmost layer.
fn paintGlows(buf: []u32, wi: i32, hi: i32, cards: []const Card, style: CardStyle, cols: ?[]f32) void {
    const radius: f32 = @floatFromInt(radiusPx(style.scale));
    const reach = glowReachPx(style.scale);
    const ri: i32 = radiusPx(style.scale);
    const edge: i32 = @as(i32, @intFromFloat(@ceil(GLOW_STROKE_DIP / 2 * style.scale))) + 1;
    const white: Rgbf = .{ .r = 255, .g = 255, .b = 255 };
    for (style.glows) |g| {
        if (g.card >= cards.len or g.level <= 0) continue;
        const c = cards[g.card];
        const f = Frame.of(c, radius);
        const y0: i32 = @max(c.top - reach, 0);
        const y1: i32 = @min(c.bottom + reach, hi);
        const x0: i32 = @max(c.left - reach, 0);
        const x1: i32 = @min(c.right + reach, wi);
        if (x1 <= x0) continue;
        // Per column: the horizontal term, and the glow a pixel gets where
        // that term is the distance (T1856).
        const t = columnTable(cols, x0, x1, f);
        if (t) |tab| for (tab.q, 0..) |q, k| {
            tab.a[0][k] = glowAlpha(f.edge(q), style.is_light, style.scale);
        };
        var y = y0;
        while (y < y1) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const qy = f.qy(fy);
            const row_a = glowAlpha(f.edge(qy), style.is_light, style.scale);
            // The card's interior is never lit; skip it on a straight row.
            const sides = y >= c.top + ri and y < c.bottom - ri;
            var x = x0;
            while (x < x1) : (x += 1) {
                if (sides and x >= c.left + edge and x < c.right - edge) {
                    x = c.right - edge - 1;
                    continue;
                }
                const k: usize = @intCast(x - x0);
                const qx = if (t) |tab| tab.q[k] else f.qx(@as(f32, @floatFromInt(x)) + 0.5);
                const a = if (qx > 0 and qy > 0)
                    glowAlpha(f.dist(qx, qy), style.is_light, style.scale)
                else if (qx >= qy)
                    (if (t) |tab| tab.a[0][k] else glowAlpha(f.edge(qx), style.is_light, style.scale))
                else
                    row_a;
                if (a <= 0) continue;
                const i: usize = @intCast(y * wi + x);
                buf[i] = blend(buf[i], white, a * std.math.clamp(g.level, 0, 1));
            }
        }
    }
}

/// The column half of a card's distance over `[x0, x1)`, carved out of
/// `scratch` (null when there is none, and every value is then computed per
/// pixel instead - the same numbers, slower). The alpha rows are left for
/// the caller to fill.
fn columnTable(scratch: ?[]f32, x0: i32, x1: i32, f: Frame) ?AxisTable {
    const s = scratch orelse return null;
    const n: usize = @intCast(x1 - x0);
    const stride = s.len / (1 + MAX_TABLE_LAYERS);
    if (n > stride) return null;
    var t: AxisTable = .{ .lo = x0, .q = s[0..n], .a = undefined };
    for (0..MAX_TABLE_LAYERS) |k| t.a[k] = s[(k + 1) * stride ..][0..n];
    for (t.q, 0..) |*q, k| q.* = f.qx(@as(f32, @floatFromInt(x0 + @as(i32, @intCast(k)))) + 0.5);
    return t;
}

// ---------------------------------------------------------------------------
// Shadows (T2450). The pass that used to run two float blends and, round the
// corners, two `erfc`s on every pixel of every card's shadow ring - about 90%
// of a desk paint, 20 ms of it at 4K, on every frame of a divider glide.
//
// Two facts make it cheap. A shadow ring is the same picture for every card
// of one style, wherever the card is and whatever its size: its straight
// sides are one column profile repeated down the rows, the middle of its top
// and bottom bands is one value a row, and what is left - the corners - is a
// fixed patch measured from the card's edges. So the patch is computed once a
// paint, and a card's ring is table reads. And laying black at `a1` and then
// at `a2` over a pixel leaves `(1 - a1)(1 - a2)` of it, colour and uncovered
// desk alike, so the two layers are one integer multiply a channel.
//
// The price is rounding: one rounding a card where there were two, so a
// shadow pixel can land a level off the two-blend arithmetic, two where two
// cards' shadows overlap (the direct rasteriser test allows exactly that). The glows and the cards are untouched and still
// bit-exact.

/// How much of a pixel a shadow leaves, in 1/65536ths.
const KEEP_ONE: u32 = 1 << 16;

fn keepOf(alphas: [MAX_TABLE_LAYERS]f32, share: f32) u32 {
    var k: f32 = 1;
    for (alphas) |a| k *= 1 - a * share;
    return @intFromFloat(@round(std.math.clamp(k, 0, 1) * @as(f32, KEEP_ONE)));
}

/// `p` under a shadow that keeps `k` of it: each channel and the desk's
/// uncovered share scaled by `k` (the coverage byte, T1852).
fn darken(p: u32, k: u32) u32 {
    const r = (((p >> 16) & 0xFF) * k + 0x8000) >> 16;
    const g = (((p >> 8) & 0xFF) * k + 0x8000) >> 16;
    const b = ((p & 0xFF) * k + 0x8000) >> 16;
    const open = ((255 - (p >> 24)) * k + 0x8000) >> 16;
    return ((255 - open) << 24) | (r << 16) | (g << 8) | b;
}

const LANES = 8;
const Lanes = @Vector(LANES, u32);
const Shift = @Vector(LANES, u5);

fn shr(v: Lanes, comptime n: u5) Lanes {
    return v >> @as(Shift, @splat(n));
}

fn shl(v: Lanes, comptime n: u5) Lanes {
    return v << @as(Shift, @splat(n));
}

/// `darken`, eight pixels at a time.
fn darkenLanes(p: Lanes, k: Lanes) Lanes {
    const ff: Lanes = @splat(0xFF);
    const half: Lanes = @splat(0x8000);
    const r = shr((shr(p, 16) & ff) * k + half, 16);
    const g = shr((shr(p, 8) & ff) * k + half, 16);
    const b = shr((p & ff) * k + half, 16);
    const open = shr((ff - shr(p, 24)) * k + half, 16);
    return shl(ff - open, 24) | shl(r, 16) | shl(g, 8) | b;
}

/// A run of pixels under one shadow value.
fn darkenSpan(span: []u32, k: u32) void {
    if (k >= KEEP_ONE) return;
    var i: usize = 0;
    const kv: Lanes = @splat(k);
    while (i + LANES <= span.len) : (i += LANES) {
        span[i..][0..LANES].* = darkenLanes(span[i..][0..LANES].*, kv);
    }
    while (i < span.len) : (i += 1) span[i] = darken(span[i], k);
}

/// A run of pixels under a shadow value each.
fn darkenEach(span: []u32, ks: []const u32) void {
    std.debug.assert(ks.len >= span.len);
    var i: usize = 0;
    while (i + LANES <= span.len) : (i += LANES) {
        span[i..][0..LANES].* = darkenLanes(span[i..][0..LANES].*, ks[i..][0..LANES].*);
    }
    while (i < span.len) : (i += 1) span[i] = darken(span[i], ks[i]);
}

/// Each layer's alpha at a pixel whose axis terms are `qx`, `qy0` (the card's
/// own) and `qyl` (each layer's, offset by its `dy`) - before the card's
/// `shadow` share - or null where no shadow is painted: deep under the card,
/// or under a glass sheet. The per-pixel arithmetic of the pass before T2450,
/// in one place, so the patch and the fallback compute the same thing.
fn shadowAlphas(f: Frame, layers: []const Shadow, glass: bool, qx: f32, qy0: f32, qyl: [MAX_TABLE_LAYERS]f32) ?[MAX_TABLE_LAYERS]f32 {
    const d0 = if (qx > 0 and qy0 > 0) f.dist(qx, qy0) else if (qx >= qy0) f.edge(qx) else f.edge(qy0);
    if (d0 <= -1) return null;
    // A glass sheet shows the desk, so its shadow is kept to the desk around
    // it: under the sheet it would read as a smudge through the glass.
    const outside: f32 = if (glass) std.math.clamp(0.5 + d0, 0, 1) else 1;
    if (outside <= 0) return null;
    var a: [MAX_TABLE_LAYERS]f32 = @splat(0);
    for (layers, 0..) |s, l| {
        const d = if (qx > 0 and qyl[l] > 0)
            f.dist(qx, qyl[l])
        else if (qx >= qyl[l])
            f.edge(qx)
        else
            f.edge(qyl[l]);
        a[l] = shadowAlpha(d, s) * outside;
    }
    return a;
}

/// One style's shadow ring, measured from a card's edges (T2450). Columns
/// are `u`, the distance out from the card's right edge (`x - right`; the
/// left side is its mirror, `left - 1 - x`); rows are `w = y - top` in the
/// top band and `v = y - bottom` in the bottom one. A row between the bands
/// is the side profile on each side and nothing over the card.
const ShadowPatch = struct {
    /// The patch's columns, `u` in `[u_lo, reach)`: from far enough inside
    /// the card that every pixel nearer its middle takes its row's one value,
    /// out to the end of the shadow.
    u_lo: i32,
    reach: i32,
    /// The top band, `w` in `[-reach, top_hi)`, and the bottom one, `v` in
    /// `[bot_lo, reach)`.
    top_hi: i32,
    bot_lo: i32,
    /// The rows (top band first) times the columns: each layer's alpha, and
    /// what the pixel keeps under a full shadow.
    alphas: [][MAX_TABLE_LAYERS]f32,
    keep: []u32,
    /// A straight side's profile, `u` in `[0, reach)`.
    side_alphas: [][MAX_TABLE_LAYERS]f32,
    side_keep: []u32,
    /// The smallest half-width and half-height a card can have and still be
    /// painted from the patch: its two sides' columns, and its two bands,
    /// must not meet or cross its centre.
    min_hw: f32,
    min_hh: f32,

    fn init(alloc: std.mem.Allocator, rad: f32, ri: i32, reach: i32, layers: []const Shadow, glass: bool) !ShadowPatch {
        var max_dy: f32 = 0;
        for (layers) |s| max_dy = @max(max_dy, s.dy);
        const dyc: i32 = @intFromFloat(@ceil(max_dy));
        const u_lo = -(ri + dyc + 2);
        const top_hi = ri + dyc + 1;
        const bot_lo = -(ri + 1);
        const nu: usize = @intCast(reach - u_lo);
        const rows: usize = @intCast((top_hi + reach) + (reach - bot_lo));
        const alphas = try alloc.alloc([MAX_TABLE_LAYERS]f32, rows * nu);
        const keep = try alloc.alloc(u32, rows * nu);
        const nc: usize = @intCast(reach);
        const side_alphas = try alloc.alloc([MAX_TABLE_LAYERS]f32, nc);
        const side_keep = try alloc.alloc(u32, nc);
        const f: Frame = .{ .cx = 0, .cy = 0, .ex = 0, .ey = 0, .rad = rad };

        var r: usize = 0;
        var w: i32 = -reach;
        while (w < top_hi) : (w += 1) {
            // Above the centre: the terms grow upward from the top edge.
            const qy0 = rad - 0.5 - @as(f32, @floatFromInt(w));
            var qyl: [MAX_TABLE_LAYERS]f32 = @splat(qy0);
            for (layers, 0..) |s, l| qyl[l] = qy0 + s.dy;
            fillRow(alphas[r * nu ..][0..nu], keep[r * nu ..][0..nu], f, layers, glass, u_lo, qy0, qyl);
            r += 1;
        }
        var v: i32 = bot_lo;
        while (v < reach) : (v += 1) {
            // Below the centre: they grow downward from the bottom edge.
            const qy0 = @as(f32, @floatFromInt(v)) + 0.5 + rad;
            var qyl: [MAX_TABLE_LAYERS]f32 = @splat(qy0);
            for (layers, 0..) |s, l| qyl[l] = qy0 - s.dy;
            fillRow(alphas[r * nu ..][0..nu], keep[r * nu ..][0..nu], f, layers, glass, u_lo, qy0, qyl);
            r += 1;
        }
        // A straight side: every vertical term as far inside as it goes.
        const deep = -std.math.inf(f32);
        fillRow(side_alphas, side_keep, f, layers, glass, 0, deep, @splat(deep));

        return .{
            .u_lo = u_lo,
            .reach = reach,
            .top_hi = top_hi,
            .bot_lo = bot_lo,
            .alphas = alphas,
            .keep = keep,
            .side_alphas = side_alphas,
            .side_keep = side_keep,
            .min_hw = @floatFromInt(-u_lo + 1),
            .min_hh = @max(@as(f32, @floatFromInt(top_hi + 1)), @as(f32, @floatFromInt(ri + 2)) + max_dy),
        };
    }

    fn fillRow(
        alphas: [][MAX_TABLE_LAYERS]f32,
        keep: []u32,
        f: Frame,
        layers: []const Shadow,
        glass: bool,
        u_lo: i32,
        qy0: f32,
        qyl: [MAX_TABLE_LAYERS]f32,
    ) void {
        for (alphas, keep, 0..) |*a, *k, i| {
            const u = u_lo + @as(i32, @intCast(i));
            const qx = @as(f32, @floatFromInt(u)) + f.rad + 0.5;
            a.* = shadowAlphas(f, layers, glass, qx, qy0, qyl) orelse @splat(0);
            k.* = keepOf(a.*, 1);
        }
    }

    fn fits(p: ShadowPatch, f: Frame, radius: f32) bool {
        return f.rad == radius and f.ex + f.rad >= p.min_hw and f.ey + f.rad >= p.min_hh;
    }

    /// The patch row for `y` on card `c`, or null for a row between the bands.
    fn rowOf(p: ShadowPatch, c: Card, y: i32) ?usize {
        const w = y - c.top;
        if (w < p.top_hi) return @intCast(w + p.reach);
        const v = y - c.bottom;
        if (v >= p.bot_lo) return @intCast((p.top_hi + p.reach) + (v - p.bot_lo));
        return null;
    }
};

/// Every card's shadow, over the desk and glows already in `buf`, before any
/// card is filled - so no card's shadow lands on its neighbour.
fn paintShadows(
    buf: []u32,
    wi: i32,
    hi: i32,
    cards: []const Card,
    glass: bool,
    layers: []const Shadow,
    radius: f32,
    ri: i32,
    reach: i32,
    scratch: ?[]f32,
    prepared: ?*const Prepared,
) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const patch: ?ShadowPatch = if (prepared) |p|
        p.patch
    else
        ShadowPatch.init(arena, radius, ri, reach, layers, glass) catch null;
    const nc: usize = @intCast(reach);
    // A straight side's values at one card's shadow share, each way round.
    const side_r: ?[]u32 = arena.alloc(u32, nc) catch null;
    const side_l: ?[]u32 = arena.alloc(u32, nc) catch null;
    const w: usize = @intCast(wi);

    for (cards) |c| {
        if (c.shadow <= 0) continue;
        const f = Frame.of(c, radius);
        const y0: i32 = @max(c.top - reach, 0);
        const y1: i32 = @min(c.bottom + reach, hi);
        const x0: i32 = @max(c.left - reach, 0);
        const x1: i32 = @min(c.right + reach, wi);
        if (x1 <= x0 or y1 <= y0) continue;
        const p: ?ShadowPatch = if (patch) |pp|
            (if (pp.fits(f, radius) and side_r != null and side_l != null) pp else null)
        else
            null;
        if (p) |pp| for (0..nc) |u| {
            const k = if (c.shadow >= 1) pp.side_keep[u] else keepOf(pp.side_alphas[u], c.shadow);
            side_r.?[u] = k;
            side_l.?[nc - 1 - u] = k;
        };
        const t = if (p == null) columnTable(scratch, x0, x1, f) else null;
        var y = y0;
        while (y < y1) : (y += 1) {
            const row = buf[@as(usize, @intCast(y)) * w ..][0..w];
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const qy0 = f.qy(fy);
            var qyl: [MAX_TABLE_LAYERS]f32 = @splat(qy0);
            var pure = qy0 <= 0;
            for (layers, 0..) |s, l| {
                qyl[l] = f.qy(fy - s.dy);
                pure = pure and qyl[l] <= 0;
            }
            // A row through the card's straight sides skips its interior.
            const sides = y >= c.top + ri and y < c.bottom - ri;
            if (p) |pp| {
                if (pure and sides) {
                    // Between the bands: the side profile on each side.
                    paintSide(row, c.right, x0, x1, side_r.?);
                    paintSide(row, c.left - reach, x0, x1, side_l.?);
                    continue;
                }
                if (pp.rowOf(c, y)) |r| {
                    paintBandRow(row, pp, r, c, f, layers, glass, sides, qy0, qyl, x0, x1);
                    continue;
                }
            }
            // A card too small for the patch: every pixel worked out.
            var x = x0;
            while (x < x1) : (x += 1) {
                if (sides and x >= c.left and x < c.right) {
                    x = c.right - 1;
                    continue;
                }
                const qx = if (t) |tab| tab.q[@intCast(x - x0)] else f.qx(@as(f32, @floatFromInt(x)) + 0.5);
                const a = shadowAlphas(f, layers, glass, qx, qy0, qyl) orelse continue;
                const i: usize = @intCast(x);
                row[i] = darken(row[i], keepOf(a, c.shadow));
            }
        }
    }
}

/// `ks` laid along `row` from `x_start`, clipped to `[x0, x1)`.
fn paintSide(row: []u32, x_start: i32, x0: i32, x1: i32, ks: []const u32) void {
    const n: i32 = @intCast(ks.len);
    const a = @max(x_start, x0);
    const b = @min(x_start + n, x1);
    if (b <= a) return;
    darkenEach(row[@intCast(a)..@intCast(b)], ks[@intCast(a - x_start)..]);
}

/// One row of a card's top or bottom band: its one value across the middle,
/// and the patch on each side.
fn paintBandRow(
    row: []u32,
    p: ShadowPatch,
    r: usize,
    c: Card,
    f: Frame,
    layers: []const Shadow,
    glass: bool,
    sides: bool,
    qy0: f32,
    qyl: [MAX_TABLE_LAYERS]f32,
    x0: i32,
    x1: i32,
) void {
    const nu: usize = @intCast(p.reach - p.u_lo);
    const keep = p.keep[r * nu ..][0..nu];
    const alphas = p.alphas[r * nu ..][0..nu];
    // A row through the straight sides (the top of them, still under a
    // lower layer's corner) leaves the card's own span alone; any other row
    // takes its one value there.
    const u_start: i32 = if (sides) 0 else p.u_lo;
    if (!sides) {
        const a = @max(c.left - p.u_lo, x0);
        const b = @min(c.right + p.u_lo, x1);
        if (b > a) {
            if (shadowAlphas(f, layers, glass, -std.math.inf(f32), qy0, qyl)) |al|
                darkenSpan(row[@intCast(a)..@intCast(b)], keepOf(al, c.shadow));
        }
    }
    // Right: x = right + u. Left: x = left - 1 - u.
    var u = @max(u_start, x0 - c.right);
    const rb = @min(p.reach, x1 - c.right);
    while (u < rb) : (u += 1) {
        const i: usize = @intCast(u - p.u_lo);
        const k = if (c.shadow >= 1) keep[i] else keepOf(alphas[i], c.shadow);
        const x: usize = @intCast(c.right + u);
        row[x] = darken(row[x], k);
    }
    u = @max(u_start, c.left - x1);
    const lb = @min(p.reach, c.left - x0);
    while (u < lb) : (u += 1) {
        const i: usize = @intCast(u - p.u_lo);
        const k = if (c.shadow >= 1) keep[i] else keepOf(alphas[i], c.shadow);
        const x: usize = @intCast(c.left - 1 - u);
        row[x] = darken(row[x], k);
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
///
/// This runs on every frame of a divider drag (T1856), so the per-pixel
/// work is kept to table reads: a glow's `erfc` is paid once per column and
/// once per row (`Frame`), except in the corner squares where the distance
/// really is two-dimensional; the shadows are a patch computed once a paint
/// and one integer multiply a channel (`paintShadows`, T2450); a solid
/// card's interior is a row `memset`; and a glass card's interior is four
/// byte lookups a pixel (`GlassLut`). The glows and cards are the pixels the
/// direct per-pixel arithmetic produces, to the bit, and the shadows are
/// within two levels of them - the "matches the direct rasteriser" test holds
/// it to that.
pub fn paintCards(buf: []u32, w: usize, h: usize, cards: []const Card, style: CardStyle) void {
    paintCardsWith(buf, w, h, cards, style, null);
}

/// What `paintCards` works out for a style before it lays any card: the
/// shadow's corner patch, a few thousand `erfc` calls (T2454). A caller that
/// paints one style many times - a partial desk compose paints once per
/// rectangle - builds it once with `prepare` and hands it to
/// `paintCardsWith`, which paints exactly what `paintCards` does.
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    scale: f32,
    is_light: bool,
    glass: bool,
    patch: ?ShadowPatch,

    /// Whether this was prepared for `style`.
    pub fn fits(self: *const Prepared, style: CardStyle) bool {
        return self.scale == style.scale and self.is_light == style.is_light and self.glass == style.glass;
    }

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
    }
};

pub fn prepare(style: CardStyle) Prepared {
    var p: Prepared = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .scale = style.scale,
        .is_light = style.is_light,
        .glass = style.glass,
        .patch = null,
    };
    const solid_layers = shadows(style.is_light, style.scale);
    const glass_layer = [1]Shadow{glassShadow(style.is_light, style.scale)};
    const layers: []const Shadow = if (style.glass) &glass_layer else &solid_layers;
    p.patch = ShadowPatch.init(p.arena.allocator(), @floatFromInt(radiusPx(style.scale)), radiusPx(style.scale), shadowReachPx(style.scale), layers, style.glass) catch null;
    return p;
}

/// `paintCards` with what `prepare` built for `style`, or without it (null,
/// or prepared for another style) building it here as `paintCards` does.
pub fn paintCardsWith(buf: []u32, w: usize, h: usize, cards: []const Card, style: CardStyle, prepared: ?*const Prepared) void {
    std.debug.assert(buf.len >= w * h);
    const radius: f32 = @floatFromInt(radiusPx(style.scale));
    const solid_layers = shadows(style.is_light, style.scale);
    const glass_layer = [1]Shadow{glassShadow(style.is_light, style.scale)};
    const layers: []const Shadow = if (style.glass) &glass_layer else &solid_layers;
    const reach = shadowReachPx(style.scale);
    const ri: i32 = radiusPx(style.scale);
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);

    const alloc = std.heap.page_allocator;
    const scratch: ?[]f32 = alloc.alloc(f32, (1 + MAX_TABLE_LAYERS) * w) catch null;
    defer if (scratch) |s| alloc.free(s);

    paintGlows(buf, wi, hi, cards, style, scratch);
    const pre: ?*const Prepared = if (prepared) |p| (if (p.fits(style)) p else null) else null;
    paintShadows(buf, wi, hi, cards, style.glass, layers, radius, ri, reach, scratch, pre);

    const rim_w = RIM_DIP * style.scale;
    // The inner edge of the band an antialiased rim pixel can sit in.
    const edge: i32 = @as(i32, @intFromFloat(@ceil(rim_w))) + 1;
    for (cards, 0..) |c, ci| {
        const f = Frame.of(c, radius);
        const focus = focusOf(style, ci);
        // This card's own sheet (T2086); the default one is the common case.
        const lut: ?GlassLut = if (style.glass) GlassLut.initSheet(style.fill, c.sheet) else null;
        const y0: i32 = @max(c.top, 0);
        const y1: i32 = @min(c.bottom, hi);
        const x0: i32 = @max(c.left, 0);
        const x1: i32 = @min(c.right, wi);
        // A card wholly off the buffer, or one with no width - a transient
        // layout mid-split - has nothing to fill, and the interior clamp
        // below needs x0 <= x1 (T1912).
        if (x1 <= x0 or y1 <= y0) continue;
        // A glass head band's material, over the sheet (T1884).
        const head_cover = headCover(c.sheet.t);
        const head_lut: ?GlassLut = if (style.glass and c.head_glass and c.head != null)
            GlassLut.init(c.head.?, HEAD_MATERIAL, head_cover)
        else
            null;
        // The sheet under a head band: the card's tint without its fade
        // (`glassHeadMixAt`), which is `lut` itself unless the card fades.
        const head_base_lut: ?GlassLut = if (head_lut != null and c.sheet.fade > 0)
            GlassLut.init(style.fill, c.sheet.t, c.sheet.t)
        else
            null;
        const head_base: ?*const GlassLut = if (head_base_lut) |*l| l else if (lut) |*l| l else null;
        var y = y0;
        while (y < y1) : (y += 1) {
            // This row's card colour (T1851): a header or nav band, a
            // viewer's page, or the terminal - glass only for the last,
            // and for a header band that is a material over the sheet.
            const own = c.colorAt(y);
            const glass_head = c.glassHeadAt(y, style.glass);
            const glass = (style.glass and own == null) or glass_head;
            const cover_t: f32 = if (glass_head) head_cover else c.sheet.cover();
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
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const qy = f.qy(fy);
            const row: usize = @intCast(y * wi);
            // A straight row's interior, in one go: the solid fill, or the
            // sheet over whatever is under it.
            const in0: i32 = if (sides) std.math.clamp(c.left + edge, x0, x1) else x1;
            const in1: i32 = if (sides) std.math.clamp(c.right - edge, in0, x1) else x1;
            if (in1 > in0) {
                const span = buf[row + @as(usize, @intCast(in0)) .. row + @as(usize, @intCast(in1))];
                if (glass_head) {
                    for (span) |*p| p.* = head_lut.?.mix(head_base.?.mix(p.*)) | head_lut.?.cover[p.* >> 24];
                } else if (glass) {
                    for (span) |*p| p.* = lut.?.sheet(p.*);
                } else @memset(span, fill_px | 0xFF00_0000);
            }
            var x = x0;
            while (x < x1) : (x += 1) {
                if (x == in0 and in1 > in0) {
                    x = in1 - 1;
                    continue;
                }
                const i: usize = row + @as(usize, @intCast(x));
                const d = f.dist(f.qx(@as(f32, @floatFromInt(x)) + 0.5), qy);
                const outer = std.math.clamp(0.5 - d, 0, 1);
                if (outer <= 0) continue;
                const inner = std.math.clamp(0.5 - (d + rim_w), 0, 1);
                // The pixel is card, of which `outer - inner` is rim.
                const ring = outer - inner;
                // Glass: the sheet's own colour over THIS pixel of desk.
                const base = if (glass_head)
                    unpack(head_lut.?.mix(head_base.?.mix(buf[i])))
                else if (glass)
                    unpack(lut.?.mix(buf[i]))
                else
                    fill;
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
                    desk_palette.coverOver(desk_palette.coverage(under), outer * cover_t),
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

test "T2307: a card's shadow strength scales its shadow, and 0 casts none" {
    const w = 120;
    const h = 100;
    const desk = packRgb(40, 60, 90);
    const bg: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    const style: CardStyle = .{ .fill = bg, .is_light = false, .scale = 1.0 };
    var full: [w * h]u32 = undefined;
    var half: [w * h]u32 = undefined;
    var none: [w * h]u32 = undefined;
    for ([_]*[w * h]u32{ &full, &half, &none }, [_]f32{ 1, 0.5, 0 }) |buf, k| {
        @memset(buf, desk);
        paintCards(buf, w, h, &.{.{ .left = 20, .top = 20, .right = 100, .bottom = 70, .shadow = k }}, style);
    }
    const below = 76 * w + 60;
    try testing.expectEqual(desk, none[below]);
    try testing.expect(unpack(full[below]).b < unpack(half[below]).b);
    try testing.expect(unpack(half[below]).b < 90);
    // The card itself is the same however much shadow it casts.
    try testing.expectEqual(full[45 * w + 60], none[45 * w + 60]);
    // And the fast path still matches the reference rasteriser.
    var ref: [w * h]u32 = undefined;
    @memset(&ref, desk);
    refPaintCards(&ref, w, h, &.{.{ .left = 20, .top = 20, .right = 100, .bottom = 70, .shadow = 0.5 }}, style);
    try expectWithinRounding(&ref, &half);
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

test "T1912: paintCards skips a card whose rect misses the buffer instead of asserting" {
    const w = 40;
    const h = 60;
    // Tall cards, so every buffer row is one of a card's straight sides -
    // the rows that clamp the interior span against the clipped rect.
    const cards = [_]Card{
        // Just right of the buffer: its shadow reaches in, its rect does not.
        .{ .left = w + 2, .top = -50, .right = w + 80, .bottom = h + 50 },
        // Just left of it.
        .{ .left = -80, .top = -50, .right = -2, .bottom = h + 50 },
        // No width at all.
        .{ .left = 20, .top = -50, .right = 20, .bottom = h + 50 },
        // Wholly below.
        .{ .left = 0, .top = h + 3, .right = w, .bottom = h + 90 },
    };
    for ([_]bool{ false, true }) |glass| {
        var buf: [w * h]u32 = undefined;
        @memset(&buf, 0x123456);
        paintCards(&buf, w, h, &cards, .{
            .fill = .{ .r = 30, .g = 30, .b = 30 },
            .is_light = false,
            .scale = 1,
            .glass = glass,
        });
    }
    // And a card far off every edge touches nothing, shadow included.
    var buf: [w * h]u32 = undefined;
    @memset(&buf, 0x123456);
    paintCards(&buf, w, h, &.{.{ .left = 500, .top = 500, .right = 600, .bottom = 600 }}, .{
        .fill = .{ .r = 30, .g = 30, .b = 30 },
        .is_light = false,
        .scale = 1,
    });
    for (buf) |p| try testing.expectEqual(@as(u32, 0x123456), p);
}

test "T1884: a glass pane's header band lets the desk through; a solid one and a viewer's bar do not" {
    const w = 100;
    const h = 80;
    const head: color_math.Rgb = .{ .r = 44, .g = 46, .b = 52 };
    const fill: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    const card: Card = .{ .left = 10, .top = 10, .right = 90, .bottom = 70, .head = head, .head_bottom = 30, .head_glass = true };
    // Two desks, so "the desk reads through" is a difference, not a value.
    const desks = [_]u32{ packRgb(20, 60, 120), packRgb(20, 110, 100) };
    var out: [2]u32 = undefined;
    for (desks, 0..) |d, k| {
        var buf: [w * h]u32 = undefined;
        @memset(&buf, d);
        paintCards(&buf, w, h, &.{card}, .{ .fill = fill, .is_light = false, .scale = 1, .glass = true });
        // A pixel inside the band, well clear of the rim.
        out[k] = rgbOf(buf[20 * w + 50]);
        try testing.expectEqual(glassHeadMix(d, fill, head), out[k]);
        // The band is mostly its own colour...
        const m = unpack(out[k]);
        try testing.expect(@abs(m.r - 44) < 20 and @abs(m.g - 46) < 30 and @abs(m.b - 52) < 40);
    }
    // ...and the desk under it still shows.
    try testing.expect(out[0] != out[1]);

    // Without glass, or for a band that is not glass (a viewer's nav bar),
    // the band is the opaque colour it always was.
    for ([_]struct { glass: bool, head_glass: bool }{
        .{ .glass = false, .head_glass = true },
        .{ .glass = true, .head_glass = false },
    }) |case| {
        var buf: [w * h]u32 = undefined;
        @memset(&buf, desks[0]);
        var c = card;
        c.head_glass = case.head_glass;
        paintCards(&buf, w, h, &.{c}, .{ .fill = fill, .is_light = false, .scale = 1, .glass = case.glass });
        try testing.expectEqual(packRgb(44, 46, 52), rgbOf(buf[20 * w + 50]));
    }
}

test "T1884: glassSheetRegion is the sheet over the desk at those pixels" {
    const pal = desk_palette.Palette.ocean(false);
    const tint: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    var out: [6 * 4]u32 = undefined;
    glassSheetRegion(&out, 6, 4, 100, 40, 800, 600, pal, tint, .{});
    for (0..4) |row| for (0..6) |col| {
        const x: f32 = @as(f32, @floatFromInt(100 + col)) + 0.5;
        const y: f32 = @as(f32, @floatFromInt(40 + row)) + 0.5;
        try testing.expectEqual(glassMix(pal.at(x, y, 800, 600).pack(), tint, GLASS_TINT), out[row * 6 + col]);
    };
    // Different places on the desk give different glass.
    var far: [1]u32 = undefined;
    glassSheetRegion(&far, 1, 1, 700, 500, 800, 600, pal, tint, .{});
    try testing.expect(far[0] != out[0]);
}

test "T2255: the sheet under the pane banner thins to 25%, never thicker than the sheet" {
    // The pane's 40% sheet thins to Mac's `PaneGlass.bannerTint`...
    try testing.expectEqual(BANNER_TINT, (Sheet{}).underBanner().t);
    try testing.expectEqual(@as(f32, 0.25), BANNER_TINT);
    // ...a sheet already thinner (Mac's unfocused 15%) stays as it is...
    try testing.expectEqual(@as(f32, 0.15), (Sheet{ .t = 0.15 }).underBanner().t);
    // ...and the fade rides along untouched.
    try testing.expectEqual(@as(f32, 0.3), (Sheet{ .fade = 0.3 }).underBanner().fade);
    // On a dark tint over a light desk, the thinner sheet lets more desk through.
    const pal = desk_palette.Palette.ocean(false);
    const tint: color_math.Rgb = .{ .r = 20, .g = 20, .b = 20 };
    var pane: [1]u32 = undefined;
    var under: [1]u32 = undefined;
    glassSheetRegion(&pane, 1, 1, 400, 300, 800, 600, pal, tint, .{});
    glassSheetRegion(&under, 1, 1, 400, 300, 800, 600, pal, tint, (Sheet{}).underBanner());
    const desk = pal.at(400.5, 300.5, 800, 600).pack();
    try testing.expectEqual(glassMix(desk, tint, BANNER_TINT), under[0]);
    try testing.expect(under[0] != pane[0]);
}

test "T1916: glassHeadRegion is the head material over the sheet at those pixels" {
    const pal = desk_palette.Palette.ocean(false);
    const fill: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    const head: color_math.Rgb = .{ .r = 44, .g = 46, .b = 52 };
    var out: [6 * 4]u32 = undefined;
    glassHeadRegion(&out, 6, 4, 100, 40, 800, 600, pal, fill, head, .{});
    for (0..4) |row| for (0..6) |col| {
        const x: f32 = @as(f32, @floatFromInt(100 + col)) + 0.5;
        const y: f32 = @as(f32, @floatFromInt(40 + row)) + 0.5;
        try testing.expectEqual(glassHeadMix(pal.at(x, y, 800, 600).pack(), fill, head), out[row * 6 + col]);
    };
    // A material, not a band: the desk still moves it, and it is not the
    // plain head colour anywhere.
    var far: [1]u32 = undefined;
    glassHeadRegion(&far, 1, 1, 700, 500, 800, 600, pal, fill, head, .{});
    try testing.expect(far[0] != out[0]);
    try testing.expect(out[0] != packRgb(44, 46, 52));
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

test "T2281: on glass a focused pane's sheet and an unfocused one's are the same; only the rim differs" {
    // Mac 9da9618f8: every glass pane keeps `PaneGlass.tint`, focused or not.
    const w = 120;
    const h = 100;
    var desk: [w * h]u32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        desk[y * w + x] = packRgb(@intCast(x * 2), 200, @intCast(y * 2));
    };
    const bg: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    const card: Card = .{ .left = 20, .top = 20, .right = 100, .bottom = 70 };
    const glows = [_]Glow{.{ .card = 0 }};
    const plain: CardStyle = .{ .fill = bg, .is_light = false, .scale = 1.0, .glass = true };
    var lit_style = plain;
    lit_style.glows = &glows;
    var focused = desk;
    paintCards(&focused, w, h, &.{card}, lit_style);
    var unfocused = desk;
    paintCards(&unfocused, w, h, &.{card}, plain);
    // The sheet: identical inside the card.
    const at = 45 * w + 60;
    try testing.expectEqual(unfocused[at], focused[at]);
    try testing.expectEqual(glassMix(desk[at], bg, GLASS_TINT), rgbOf(focused[at]));
    // The rim: lighter on the focused card.
    try testing.expect(unpack(focused[20 * w + 60]).r > unpack(unfocused[20 * w + 60]).r);
}

test "T2086: a faded sheet fades back to the desk, and a head band never takes the fade" {
    // The mechanism stays until T2293 removes it; nothing sets it per pane.
    const thin: Sheet = .{ .t = 0.15, .fade = 0.3 };
    const desk = packRgb(90, 160, 200);
    const fill: color_math.Rgb = .{ .r = 30, .g = 30, .b = 30 };
    const head: color_math.Rgb = .{ .r = 44, .g = 46, .b = 52 };
    const s = unpack(glassMix(desk, fill, 0.15)).g;
    try testing.expect(@abs(unpack(sheetMix(desk, fill, thin)).g - (s * 0.7 + 160 * 0.3)) <= 0.5);
    const pal = desk_palette.Palette.ocean(false);
    var a: [1]u32 = undefined;
    var b: [1]u32 = undefined;
    glassHeadRegion(&a, 1, 1, 100, 40, 800, 600, pal, fill, head, thin);
    glassHeadRegion(&b, 1, 1, 100, 40, 800, 600, pal, fill, head, .{ .t = 0.15 });
    try testing.expectEqual(a[0], b[0]);
    try testing.expectEqual(HEAD_COVER, headCover(GLASS_TINT));
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

test "T2112: the glow fades in from the card's edge, peaks out on the desk, and keeps its outer falloff" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| for ([_]bool{ true, false }) |light| {
        // The peak, sampled every tenth of a pixel across the reach.
        var peak: f32 = 0;
        var peak_d: f32 = 0;
        var d: f32 = 0;
        while (d < @as(f32, @floatFromInt(glowReachPx(s)))) : (d += 0.1) {
            const a = glowAlpha(d, light, s);
            if (a > peak) {
                peak = a;
                peak_d = d;
            }
        }
        // It sits out on the desk - 1.5 to 3pt past the edge - not on it.
        try testing.expect(peak_d >= 1.5 * s and peak_d <= 3 * s);
        // The pixel touching the card is a fraction of that peak, so no
        // bright line hugs the card.
        try testing.expect(glowAlpha(0.5, light, s) < 0.25 * peak);
        // Ramp fully in: past the ramp the profile is the unramped band.
        const hw = GLOW_STROKE_DIP / 2 * s;
        const k = GLOW_SIGMA_DIP * s * std.math.sqrt2;
        for ([_]f32{ 3, 4, 6 }) |out| {
            const x = out * s;
            const band = 0.5 * (erfc((x - hw) / k) - erfc((x + hw) / k));
            try testing.expectApproxEqAbs(glowOpacity(light) * band, glowAlpha(x, light, s), 1e-6);
        }
    };
}

test "T1834: the focused rim is brighter, in both styles and both themes" {
    for ([_]bool{ true, false }) |glass| for ([_]bool{ true, false }) |light| {
        try testing.expect(rimAlpha(glass, light, 1) > rimAlpha(glass, light, 0));
    };
    // Glass: Mac 9da9618f8's lighter focused rim (T2281) - 34% / 20%.
    try testing.expectApproxEqAbs(@as(f32, 0.34), rimAlpha(true, false, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.10), rimAlpha(true, false, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.16), rimAlpha(false, false, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.20), rimAlpha(true, true, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.08), rimAlpha(true, true, 0), 1e-6);

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

// The rasteriser as it was before T1856 factored the distance into tables:
// every pixel's distance, shadow and glow computed directly. Kept as the
// oracle the fast path is held to, bit for bit.
/// Light the desk around each glowing card. Runs before any shadow, the way
/// Mac's glow is the card's backmost layer.
fn refPaintGlows(buf: []u32, wi: i32, hi: i32, cards: []const Card, style: CardStyle) void {
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


/// Paint every card's shadows, then every card, over the desk already in
/// `buf` (a `w` x `h` window-content buffer). Shadows go down first for ALL
/// cards so one card's drop shadow never lands on top of its neighbour.
///
/// Only pixels a card can affect are visited: each card's shadow reach,
/// minus the interior a card fill covers anyway.
fn refPaintCards(buf: []u32, w: usize, h: usize, cards: []const Card, style: CardStyle) void {
    std.debug.assert(buf.len >= w * h);
    const radius: f32 = @floatFromInt(radiusPx(style.scale));
    const solid_layers = shadows(style.is_light, style.scale);
    const glass_layer = [1]Shadow{glassShadow(style.is_light, style.scale)};
    const layers: []const Shadow = if (style.glass) &glass_layer else &solid_layers;
    const reach = shadowReachPx(style.scale);
    const ri: i32 = radiusPx(style.scale);
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);

    refPaintGlows(buf, wi, hi, cards, style);

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
                    p = blend(p, black, shadowAlpha(d, s) * outside * c.shadow);
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
            const glass_head = c.glassHeadAt(y, style.glass);
            const glass = (style.glass and own == null) or glass_head;
            const cover_t: f32 = if (glass_head) headCover(c.sheet.t) else c.sheet.cover();
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
                    buf[i] = if (glass_head)
                        desk_palette.withCoverage(
                            glassHeadMixAt(buf[i], style.fill, c.head.?, c.sheet.t),
                            desk_palette.coverOver(desk_palette.coverage(buf[i]), headCover(c.sheet.t)),
                        )
                    else if (glass)
                        desk_palette.withCoverage(
                            sheetMix(buf[i], style.fill, c.sheet),
                            desk_palette.coverOver(desk_palette.coverage(buf[i]), c.sheet.cover()),
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
                const base = if (glass_head)
                    unpack(glassHeadMixAt(buf[i], style.fill, c.head.?, c.sheet.t))
                else if (glass)
                    unpack(sheetMix(buf[i], style.fill, c.sheet))
                else
                    fill;
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
                    desk_palette.coverOver(desk_palette.coverage(under), outer * cover_t),
                );
            }
        }
    }
}

/// Whether two composite pixels agree to within `ROUNDING_LEVELS` in every
/// byte - colour and coverage. The shadow pass rounds once a card where the
/// direct rasteriser rounds once a layer (T2450): one level apart under one
/// card's shadow, at most two where two cards' shadows overlap.
const ROUNDING_LEVELS = 2;
fn withinRounding(a: u32, b: u32) bool {
    var k: u5 = 0;
    while (k < 32) : (k += 8) {
        const x: i32 = @intCast((a >> k) & 0xFF);
        const y: i32 = @intCast((b >> k) & 0xFF);
        if (@abs(x - y) > ROUNDING_LEVELS) return false;
        if (k == 24) break;
    }
    return true;
}

fn expectWithinRounding(want: []const u32, got: []const u32) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got, 0..) |a, b, i| {
        if (!withinRounding(a, b)) {
            std.debug.print("pixel {d}: {x} != {x}\n", .{ i, a, b });
            return error.TestUnexpectedResult;
        }
    }
}

test "T2450: two levels is the tolerance, and three is not" {
    try testing.expect(withinRounding(0xB528_3C37, 0xB728_3C37));
    try testing.expect(withinRounding(0x0002_0203, 0x0100_0101));
    try testing.expect(!withinRounding(0xB528_3C37, 0xB828_3C37));
    try testing.expect(!withinRounding(0x0000_0000, 0x0000_0003));
}

test "T2450: a full shadow over a uniform desk is darken() of it, wherever the card sits" {
    // The same card at two places and two sizes: its ring is one picture
    // measured from its edges, so the pixel the same distance below each
    // card's bottom-right corner is the same value.
    const w = 400;
    const h = 300;
    var buf: [w * h]u32 = undefined;
    const desk = packRgb(40, 60, 90);
    @memset(&buf, desk);
    const style: CardStyle = .{ .fill = .{ .r = 30, .g = 30, .b = 30 }, .is_light = false, .scale = 1.0 };
    const a: Card = .{ .left = 20, .top = 20, .right = 150, .bottom = 120 };
    const b: Card = .{ .left = 200, .top = 150, .right = 380, .bottom = 260 };
    paintCards(&buf, w, h, &.{ a, b }, style);
    for ([_][2]i32{ .{ 3, 5 }, .{ -4, 9 }, .{ 10, 2 }, .{ -40, 6 } }) |o| {
        const pa = buf[@intCast((a.bottom + o[1]) * w + a.right + o[0])];
        const pb = buf[@intCast((b.bottom + o[1]) * w + b.right + o[0])];
        try testing.expectEqual(pa, pb);
        try testing.expect(pa != desk);
    }
    // darken() at full keep is the identity, colour and coverage alike.
    try testing.expectEqual(@as(u32, 0x7F12_3456), darken(0x7F12_3456, KEEP_ONE));
    // And darkenSpan's lanes agree with darken() pixel for pixel.
    var span: [19]u32 = undefined;
    for (&span, 0..) |*q, i| q.* = @as(u32, @intCast(i)) *% 0x0913_5A27;
    var want: [19]u32 = undefined;
    for (span, &want) |q, *o| o.* = darken(q, 41_000);
    darkenSpan(&span, 41_000);
    try testing.expectEqualSlices(u32, &want, &span);
}

test "T1856: the table-driven paint matches the direct rasteriser (to two levels in a shadow, T2450)" {
    const w = 260;
    const h = 190;
    var desk: [w * h]u32 = undefined;
    var prng = std.Random.DefaultPrng.init(1856);
    const rnd = prng.random();
    for (&desk) |*p| p.* = rnd.int(u32) & 0x00FF_FFFF;
    var fast: [w * h]u32 = undefined;
    var slow: [w * h]u32 = undefined;
    const layouts = [_][]const Card{
        // Two side by side, a divider between them.
        &.{
            .{ .left = 15, .top = 15, .right = 121, .bottom = 175 },
            .{ .left = 136, .top = 15, .right = 245, .bottom = 175 },
        },
        // A grid with a header band, a viewer page, one card hanging off the
        // buffer's edges, and one smaller than its own corners.
        &.{
            .{ .left = -30, .top = -12, .right = 90, .bottom = 80, .head = .{ .r = 50, .g = 52, .b = 60 }, .head_bottom = 10 },
            .{ .left = 105, .top = 15, .right = 280, .bottom = 90, .fill = .{ .r = 250, .g = 250, .b = 245 }, .head = .{ .r = 230, .g = 230, .b = 235 }, .head_bottom = 40 },
            .{ .left = 15, .top = 105, .right = 33, .bottom = 120 },
            .{ .left = 48, .top = 105, .right = 245, .bottom = 200 },
        },
        // A glass rearrange header over a terminal, and one off the top
        // edge (T1884).
        &.{
            .{ .left = 15, .top = 15, .right = 121, .bottom = 175, .head = .{ .r = 44, .g = 46, .b = 52 }, .head_bottom = 45, .head_glass = true },
            .{ .left = 136, .top = -20, .right = 245, .bottom = 175, .head = .{ .r = 236, .g = 236, .b = 240 }, .head_bottom = 12, .head_glass = true },
        },
        // A thin, faded sheet beside a default one, and a thin sheet under a
        // glass head (T2086's mechanism, kept bit-exact until T2293).
        &.{
            .{ .left = 15, .top = 15, .right = 121, .bottom = 175, .head = .{ .r = 44, .g = 46, .b = 52 }, .head_bottom = 45, .head_glass = true, .sheet = .{ .t = 0.15, .fade = 0.3 } },
            .{ .left = 136, .top = 15, .right = 245, .bottom = 90 },
            .{ .left = 136, .top = 105, .right = 245, .bottom = 175, .sheet = .{ .t = 0.15 } },
        },
    };
    const glows = [_]Glow{ .{ .card = 1, .level = 0.6 }, .{ .card = 0, .level = 0.4 } };
    for ([_]f32{ 1.0, 1.1, 1.25, 1.5, 1.75, 2.0 }) |scale| {
        for ([_]bool{ false, true }) |glass| {
            for ([_]bool{ false, true }) |is_light| {
                for (layouts) |cards| {
                    const style: CardStyle = .{
                        .fill = if (is_light) .{ .r = 247, .g = 246, .b = 240 } else .{ .r = 29, .g = 31, .b = 33 },
                        .is_light = is_light,
                        .scale = scale,
                        .glass = glass,
                        .glows = &glows,
                    };
                    fast = desk;
                    slow = desk;
                    paintCards(&fast, w, h, cards, style);
                    refPaintCards(&slow, w, h, cards, style);
                    for (fast, slow, 0..) |a, b, i| {
                        if (!withinRounding(a, b)) {
                            std.debug.print("scale={d} glass={} light={} pixel ({d},{d}): {x} != {x}\n", .{ scale, glass, is_light, i % w, i / w, a, b });
                            return error.TestUnexpectedResult;
                        }
                    }
                }
            }
        }
    }
}

// T2450: the shadow pass's cost, at the window sizes the task measured.
// Skipped unless GHOZTTY_BENCH is set; run it under ReleaseFast:
//   GHOZTTY_BENCH=1 zig test src/apprt/win32/pane_elevation.zig -OReleaseFast --test-filter T2450
test "T2450: bench - paintCards over six cards" {
    if (!(std.process.hasEnvVar(testing.allocator, "GHOZTTY_BENCH") catch false)) return error.SkipZigTest;
    const sizes = [_]struct { w: usize, h: usize, scale: f32 }{
        .{ .w = 1582, .h = 891, .scale = 1 },
        .{ .w = 3800, .h = 2050, .scale = 2 },
    };
    for (sizes) |sz| {
        const buf = try testing.allocator.alloc(u32, sz.w * sz.h);
        defer testing.allocator.free(buf);
        const m = marginPx(.elevated, sz.scale);
        const g = gapPx(.elevated, sz.scale).?;
        const wi: i32 = @intCast(sz.w);
        const hi: i32 = @intCast(sz.h);
        const cw = @divFloor(wi - 2 * m - 2 * g, 3);
        const ch = @divFloor(hi - 2 * m - g, 2);
        var cards: [6]Card = undefined;
        for (0..6) |i| {
            const col: i32 = @intCast(i % 3);
            const row: i32 = @intCast(i / 3);
            const l = m + col * (cw + g);
            const t = m + row * (ch + g);
            cards[i] = .{ .left = l, .top = t, .right = l + cw, .bottom = t + ch };
        }
        for ([_]bool{ false, true }) |shadows_on| {
            for (&cards) |*c| c.shadow = if (shadows_on) 1 else 0;
            const style: CardStyle = .{ .fill = .{ .r = 29, .g = 31, .b = 33 }, .is_light = false, .scale = sz.scale };
            const runs = 20;
            var best: u64 = std.math.maxInt(u64);
            for (0..runs) |_| {
                @memset(buf, packRgb(40, 60, 90));
                var timer = try std.time.Timer.start();
                paintCards(buf, sz.w, sz.h, &cards, style);
                best = @min(best, timer.read());
            }
            std.debug.print("{d}x{d} @{d}x shadows={}: {d:.2} ms\n", .{ sz.w, sz.h, sz.scale, shadows_on, @as(f64, @floatFromInt(best)) / 1e6 });
        }
    }
}
