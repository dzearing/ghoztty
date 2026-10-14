//! The pane sidebar's open card as a per-pixel-alpha layer (T1865), pure so
//! it is testable. Mac's hover-open card is glass over the grid: its rounded
//! corners are antialiased and its soft shadow falls on the terminals beside
//! it. A window region can do neither - it is a 1-bit mask, so the corners
//! were hard steps and the shadow stopped dead at the card's edge. The card
//! is now a layered window instead, and this module turns the opaque pixels
//! the sidebar paints into what that layer shows:
//!
//!   - the column strip at the window's left stays opaque (it is the rail's
//!     own column, which the grid never sits under);
//!   - the card is opaque, with an antialiased edge;
//!   - around it, the banner card's drop shadow (`banner_card`'s blur and
//!     offset) is black at partial alpha over whatever is underneath;
//!   - everything else is fully transparent.
//!
//! Clicks follow the card's SHAPE, not its alpha: a shadow pixel is visible
//! but passes the click through to the pane under it (`hits`), which is what
//! the region used to guarantee for the trailing margin.

const std = @import("std");
const banner_card = @import("banner_card.zig");
const color_math = @import("color_math.zig");
const pane_elevation = @import("pane_elevation.zig");

/// What the layer is built from: the column strip's width and the card's
/// metrics (the SAME metrics the card's material was rendered with, so the
/// alpha edge lands on the painted edge).
pub const Geometry = struct {
    column_w: i32,
    card: banner_card.Rect,
    radius: f32,
    shadow_blur: f32,
    shadow_dy: f32,

    pub fn init(column_w: i32, m: banner_card.Metrics) Geometry {
        return .{
            .column_w = column_w,
            .card = m.card(),
            .radius = m.radius,
            .shadow_blur = m.shadow_blur,
            .shadow_dy = m.shadow_dy,
        };
    }

    fn shadowRect(self: Geometry) banner_card.Rect {
        return .{
            .left = self.card.left,
            .top = self.card.top + self.shadow_dy,
            .right = self.card.right,
            .bottom = self.card.bottom + self.shadow_dy,
        };
    }
};

/// One pixel of the layer: `alpha` is what the layer shows, `weight` is how
/// much of the painted colour survives (the card's coverage; the shadow is
/// black and contributes alpha only). Both 0-255.
pub const Cell = struct { alpha: u8, weight: u8 };

pub const opaque_cell = Cell{ .alpha = 255, .weight = 255 };
pub const clear_cell = Cell{ .alpha = 0, .weight = 0 };

fn coverage(sd: f32) f32 {
    return std.math.clamp(0.5 - sd, 0.0, 1.0);
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    if (edge1 <= edge0) return if (x < edge0) 0.0 else 1.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn byte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
}

/// The layer at pixel (`x`, `y`) - the same SDF, coverage and shadow falloff
/// `banner_card.render` paints with, sampled at the pixel's centre.
pub fn cellAt(g: Geometry, x: i32, y: i32) Cell {
    if (x < g.column_w) return opaque_cell;
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    const cov = coverage(banner_card.sdRoundRect(fx, fy, g.card, g.radius));
    if (cov >= 1.0) return opaque_cell;
    const sds = banner_card.sdRoundRect(fx, fy, g.shadowRect(), g.radius);
    const shadow = banner_card.SHADOW_ALPHA * (1.0 - smoothstep(-g.shadow_blur, g.shadow_blur, sds));
    return .{ .alpha = byte(cov + shadow * (1.0 - cov)), .weight = byte(cov) };
}

/// Fill `cells` (a top-down `w` x `h` grid) for `g`. Built once per geometry
/// and reused for every repaint: the card's rows change on hover and on the
/// busy shimmer, its shape does not.
pub fn buildMask(cells: []Cell, w: i32, h: i32, g: Geometry) void {
    if (w <= 0 or h <= 0) return;
    const uw: usize = @intCast(w);
    if (cells.len < uw * @as(usize, @intCast(h))) return;
    // Rows and columns this far inside the card are wholly the card.
    const inner = g.radius + 1.0;
    for (0..@intCast(h)) |row| {
        const y: i32 = @intCast(row);
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const y_inside = fy >= g.card.top + inner and fy <= g.card.bottom - inner;
        for (cells[row * uw ..][0..uw], 0..) |*c, col| {
            const x: i32 = @intCast(col);
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            c.* = if (y_inside and fx >= g.card.left + inner and fx <= g.card.right - inner)
                opaque_cell
            else
                cellAt(g, x, y);
        }
    }
}

/// Turn the opaque `0x00RRGGBB` pixels the sidebar painted into the layer's
/// premultiplied `0xAARRGGBB`, through `cells` (same size).
pub fn apply(pixels: []u32, cells: []const Cell) void {
    const n = @min(pixels.len, cells.len);
    for (pixels[0..n], cells[0..n]) |*p, c| {
        if (c.alpha == 0) {
            p.* = 0;
            continue;
        }
        const k: u32 = c.weight;
        const a: u32 = c.alpha;
        // weight <= alpha always (alpha is coverage plus shadow), so the
        // premultiplied channels never exceed the alpha.
        const r = (((p.* >> 16) & 0xFF) * k + 127) / 255;
        const gr = (((p.* >> 8) & 0xFF) * k + 127) / 255;
        const b = ((p.* & 0xFF) * k + 127) / 255;
        p.* = (a << 24) | (r << 16) | (gr << 8) | b;
    }
}

/// What a presented layer holds, for the log (a layered window's pixels
/// cannot be read back off the test desktop, so the card says what it sent).
pub const Stats = struct {
    /// Fully opaque pixels: the column and the card.
    solid: usize = 0,
    /// Partially transparent ones: the card's antialiased edge and its shadow.
    partial: usize = 0,
    /// Distinct colours among the solid pixels, counted up to `distinct_cap`.
    distinct: usize = 0,

    pub const distinct_cap = 16;
};

/// Tally premultiplied `pixels` (after `apply`).
pub fn stats(pixels: []const u32) Stats {
    var s: Stats = .{};
    var seen: [Stats.distinct_cap]u32 = undefined;
    for (pixels) |p| {
        const a = p >> 24;
        if (a == 0) continue;
        if (a < 255) {
            s.partial += 1;
            continue;
        }
        s.solid += 1;
        if (s.distinct == Stats.distinct_cap) continue;
        if (std.mem.indexOfScalar(u32, seen[0..s.distinct], p) == null) {
            seen[s.distinct] = p;
            s.distinct += 1;
        }
    }
    return s;
}

/// Whether a click at (`x`, `y`) is the card's: the column strip, or the
/// card's own shape (at least half covered). The shadow and the trailing
/// margin are not, so the pane beside the card takes those clicks.
pub fn hits(g: Geometry, x: i32, y: i32) bool {
    if (x < 0 or y < 0) return false;
    if (x < g.column_w) return true;
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    return banner_card.sdRoundRect(fx, fy, g.card, g.radius) <= 0.0;
}

// ---------------------------------------------------------------------------
// Glass (T1887; Mac `SidePanelCard(isGlass:)`, main ec71db251 / 733b03e58)
// ---------------------------------------------------------------------------
//
// With glass panes on, Mac's unpinned card - the rail, and the card it opens
// to - is not an opaque slab but a lighter glass sheet: the terminal
// background at `OVERLAY_TINT` (`PaneGlass.overlayTint`) over whatever lies
// beneath, the card's sheen and rim on it, its drop shadow and the sheet's
// own soft one around it, and NO lifting wash (it greys the colour coming
// through). Under it, in the open card's case, are the glass panes; the
// sheet is lighter than a pane's 40% because it stacks on them.
//
// The open card is a layered window, so the sheet really is see-through:
// `buildGlass` lays the glass's own layers down premultiplied, and
// `composeOver` puts the rows on it - painted twice, over black and over
// white, which gives every content pixel its own alpha (text edges
// included) rather than guessing it from a key colour.

/// Mac `PaneGlass.overlayTint`: how much of the terminal background a glass
/// card floating over glass panes keeps.
pub const OVERLAY_TINT: f32 = 0.3;

pub const Glass = struct {
    /// The terminal background, the sheet's tint.
    tint: color_math.Rgb,
    scale: f32,

    fn isLight(self: Glass) bool {
        return color_math.isLight(self.tint);
    }

    /// Mac `PaneGlass`'s pre-Liquid-Glass shadow (`radius: 9, y: 6`, black
    /// 20% dark / 6% light), cast from a sheet at the overlay tint - so it
    /// reaches the desk at that strength, as the panes' does at theirs.
    fn sheetShadow(self: Glass) pane_elevation.Shadow {
        return .{
            .sigma = 4.5 * self.scale,
            .dy = 6 * self.scale,
            .opacity = (if (self.isLight()) @as(f32, 0.06) else 0.2) * OVERLAY_TINT,
        };
    }
};

/// A premultiplied colour, 0-255 channels and a 0-1 alpha.
pub const Pm = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    /// `c` at `alpha` over this.
    fn over(self: *Pm, c: color_math.Rgb, alpha: f32) void {
        if (alpha <= 0) return;
        const k = 1 - alpha;
        self.r = self.r * k + @as(f32, @floatFromInt(c.r)) * alpha;
        self.g = self.g * k + @as(f32, @floatFromInt(c.g)) * alpha;
        self.b = self.b * k + @as(f32, @floatFromInt(c.b)) * alpha;
        self.a = self.a * k + alpha;
    }

    /// This over the opaque `0x00RRGGBB` pixel `under`, opaque.
    fn onto(self: Pm, under: u32) u32 {
        const k = 1 - self.a;
        const ch = struct {
            fn f(top: f32, u: u32, kk: f32) u32 {
                return @intFromFloat(std.math.clamp(@round(top + @as(f32, @floatFromInt(u & 0xFF)) * kk), 0, 255));
            }
        }.f;
        return 0xFF00_0000 | (ch(self.r, under >> 16, k) << 16) | (ch(self.g, under >> 8, k) << 8) | ch(self.b, under, k);
    }

    /// As a premultiplied `0xAARRGGBB` layer pixel.
    fn pack(self: Pm) u32 {
        const a: u32 = byte(self.a);
        const ch = struct {
            fn f(v: f32, cap: u32) u32 {
                return @min(@as(u32, @intFromFloat(std.math.clamp(@round(v), 0, 255))), cap);
            }
        }.f;
        return (a << 24) | (ch(self.r, a) << 16) | (ch(self.g, a) << 8) | ch(self.b, a);
    }
};

const white: color_math.Rgb = .{ .r = 255, .g = 255, .b = 255 };
const black: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 };

/// The glass card's own layers at pixel (`x`, `y`), back to front: the
/// sheet's shadow and the card's drop shadow on what is around it (kept off
/// the sheet, as Mac masks the card out of its shadow), the tint, the sheen
/// and its grounding shade, and the specular rim on the edge. The column
/// strip plays no part here - `buildGlass` decides what lies under a pixel.
pub fn glassAt(g: Geometry, gl: Glass, x: i32, y: i32) Pm {
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    const sd = banner_card.sdRoundRect(fx, fy, g.card, g.radius);
    const cov = coverage(sd);
    var p: Pm = .{};
    if (cov < 1) {
        const s = gl.sheetShadow();
        const sheet_sd = banner_card.sdRoundRect(fx, fy - s.dy, g.card, g.radius);
        p.over(black, pane_elevation.shadowAlpha(sheet_sd, s) * (1 - cov));
        const sds = banner_card.sdRoundRect(fx, fy, g.shadowRect(), g.radius);
        const drop = banner_card.SHADOW_ALPHA * (1.0 - smoothstep(-g.shadow_blur, g.shadow_blur, sds));
        p.over(black, drop * (1 - cov));
    }
    if (cov > 0) {
        p.over(gl.tint, OVERLAY_TINT * cov);
        p.over(white, banner_card.sheenAlpha(fx, fy, g.card) * cov);
        p.over(black, banner_card.bottomShadeAlpha(fy, g.card) * cov);
        const rim = @max(cov - coverage(sd + 1.0), 0.0);
        if (rim > 0) p.over(white, banner_card.rimAlpha(fx, fy, g.card) * rim);
    }
    return p;
}

/// The glass layer of a `w` x `h` window into `out`. Pixels left of
/// `opaque_w` are composited over `under` (opaque `0x00RRGGBB`, same size) -
/// the desk the column strip shows, or for the rail the whole desk slice -
/// and come out opaque `0xFFRRGGBB`; the rest are the layers alone,
/// premultiplied, over nothing.
pub fn buildGlass(out: []u32, w: i32, h: i32, g: Geometry, gl: Glass, opaque_w: i32, under: []const u32) void {
    if (w <= 0 or h <= 0) return;
    const uw: usize = @intCast(w);
    const n = uw * @as(usize, @intCast(h));
    if (out.len < n or under.len < n) return;
    // Far from the card nothing reaches: the shadows' reach, generously.
    const reach = g.shadow_blur + g.shadow_dy + 3 * gl.sheetShadow().sigma + gl.sheetShadow().dy + 2;
    // Rows and columns this far inside the card are wholly sheet: no edge,
    // no rim, no shadow (`buildMask`'s fast path).
    const inner = g.radius + 2.0;
    for (0..@intCast(h)) |row| {
        const y: i32 = @intCast(row);
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const y_far = fy < g.card.top - reach or fy > g.card.bottom + reach;
        const y_inside = fy >= g.card.top + inner and fy <= g.card.bottom - inner;
        const shade = banner_card.bottomShadeAlpha(fy, g.card);
        for (0..uw) |col| {
            const x: i32 = @intCast(col);
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const i = row * uw + col;
            const far = y_far or fx < g.card.left - reach or fx > g.card.right + reach;
            const p: Pm = if (far) .{} else if (y_inside and fx >= g.card.left + inner and fx <= g.card.right - inner) blk: {
                var s: Pm = .{};
                s.over(gl.tint, OVERLAY_TINT);
                s.over(white, banner_card.sheenAlpha(fx, fy, g.card));
                s.over(black, shade);
                break :blk s;
            } else glassAt(g, gl, x, y);
            out[i] = if (x < opaque_w) p.onto(under[i]) else p.pack();
        }
    }
}

/// Put content onto the glass: `on_black` and `on_white` are the same rows
/// painted over black and over white (`0x00RRGGBB`, any alpha byte ignored),
/// and `on_black` becomes the premultiplied layer - the content, with the
/// alpha the two paints imply, over `glass`.
pub fn composeOver(on_black: []u32, on_white: []const u32, glass: []const u32) void {
    const n = @min(on_black.len, @min(on_white.len, glass.len));
    for (on_black[0..n], on_white[0..n], glass[0..n]) |*p, wp, gp| {
        const b = p.* & 0x00FF_FFFF;
        const wt = wp & 0x00FF_FFFF;
        // Nothing painted here: the key shows in both.
        if (b == 0 and wt == 0x00FF_FFFF) {
            p.* = gp;
            continue;
        }
        // Each channel's coverage is 1 - (white - black); the layer has one
        // alpha, so take their mean, and keep the colour within it.
        var sum: u32 = 0;
        const shifts = [_]u5{ 16, 8, 0 };
        for (shifts) |s| {
            const cb = (b >> s) & 0xFF;
            const cw = (wt >> s) & 0xFF;
            sum += 255 - (if (cw > cb) cw - cb else 0);
        }
        const a = (sum + 1) / 3;
        const k = 255 - a;
        var out: u32 = 0;
        var ga = gp >> 24;
        ga = a + (ga * k + 127) / 255;
        for (shifts) |s| {
            const c = @min((b >> s) & 0xFF, a);
            const gc = (gp >> s) & 0xFF;
            out |= @min(c + (gc * k + 127) / 255, ga) << s;
        }
        p.* = (ga << 24) | out;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A flat-style open card at 1x: 68 px column, 264 x 600 window, the card at
/// the 12 px margin all round.
fn testGeometry(scale: f32) struct { g: Geometry, w: i32, h: i32 } {
    const w: i32 = @intFromFloat(@round(264 * scale));
    const h: i32 = @intFromFloat(@round(600 * scale));
    const col: i32 = @intFromFloat(@round(68 * scale));
    return .{ .g = Geometry.init(col, banner_card.Metrics.init(w, h, scale)), .w = w, .h = h };
}

test "pane_sidebar_layer: the column strip and the card's middle are opaque" {
    const t = testGeometry(1.0);
    try testing.expectEqual(opaque_cell, cellAt(t.g, 0, 0));
    try testing.expectEqual(opaque_cell, cellAt(t.g, 34, 2));
    try testing.expectEqual(opaque_cell, cellAt(t.g, 150, 300));
}

test "pane_sidebar_layer: the shadow falls on the grid in the trailing margin and below the card" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        const t = testGeometry(s);
        const card = t.g.card;
        const mid_y: i32 = @divTrunc(t.h, 2);
        // Just right of the card's edge: shadow, not card, not clear.
        const right = cellAt(t.g, @as(i32, @intFromFloat(card.right)) + 1, mid_y);
        try testing.expect(right.alpha > 0);
        try testing.expect(right.alpha < 255);
        try testing.expectEqual(@as(u8, 0), right.weight);
        // Below the card the shadow is deeper than beside it (the 4 DIP drop).
        const below = cellAt(t.g, @as(i32, @intFromFloat((card.left + card.right) / 2)), @as(i32, @intFromFloat(card.bottom)) + 2);
        try testing.expect(below.alpha > right.alpha);
        // Never darker than the shadow's own alpha.
        try testing.expect(@as(f32, @floatFromInt(below.alpha)) <= banner_card.SHADOW_ALPHA * 255.0 + 1.0);
        // The window's far right edge has faded to (nearly) nothing.
        const edge = cellAt(t.g, t.w - 1, mid_y);
        try testing.expect(edge.alpha < right.alpha);
    }
}

test "pane_sidebar_layer: the card's corners are antialiased, not a 1-bit step" {
    const t = testGeometry(1.0);
    var cells: [264 * 600]Cell = undefined;
    buildMask(&cells, t.w, t.h, t.g);
    // Walk outward along a row through the top-right corner's curve: card
    // coverage falls through at least one partial value on its way from
    // full to none (a region stepped straight from 255 to 0).
    const row: i32 = @intFromFloat(t.g.card.top + 2);
    const x0: i32 = @intFromFloat(t.g.card.right - t.g.radius);
    var partial = false;
    var x = x0;
    while (x < t.w) : (x += 1) {
        const c = cells[@intCast(row * t.w + x)];
        if (c.weight > 0 and c.weight < 255) partial = true;
    }
    try testing.expect(partial);
}

test "pane_sidebar_layer: the mask matches the per-pixel answer everywhere" {
    const t = testGeometry(1.5);
    const n: usize = @intCast(t.w * t.h);
    const cells = try testing.allocator.alloc(Cell, n);
    defer testing.allocator.free(cells);
    buildMask(cells, t.w, t.h, t.g);
    var y: i32 = 0;
    while (y < t.h) : (y += 7) {
        var x: i32 = 0;
        while (x < t.w) : (x += 3) {
            try testing.expectEqual(cellAt(t.g, x, y), cells[@intCast(y * t.w + x)]);
        }
    }
}

test "pane_sidebar_layer: apply premultiplies, keeps the card, blacks the shadow, clears the rest" {
    var px = [_]u32{ 0x00FF8040, 0x00FF8040, 0x00FF8040, 0x00FF8040 };
    const cells = [_]Cell{ opaque_cell, .{ .alpha = 128, .weight = 128 }, .{ .alpha = 40, .weight = 0 }, clear_cell };
    apply(&px, &cells);
    try testing.expectEqual(@as(u32, 0xFFFF8040), px[0]);
    try testing.expectEqual(@as(u32, 0x80804020), px[1]);
    try testing.expectEqual(@as(u32, 0x28000000), px[2]);
    try testing.expectEqual(@as(u32, 0), px[3]);
    // No channel ever exceeds its alpha (a valid premultiplied pixel).
    for (px) |p| {
        const a = p >> 24;
        try testing.expect(((p >> 16) & 0xFF) <= a and ((p >> 8) & 0xFF) <= a and (p & 0xFF) <= a);
    }
}

test "pane_sidebar_layer: stats count solid, partial and distinct pixels" {
    const px = [_]u32{ 0xFF101010, 0xFF101010, 0xFF202020, 0x40000000, 0x80404040, 0 };
    const s = stats(&px);
    try testing.expectEqual(@as(usize, 3), s.solid);
    try testing.expectEqual(@as(usize, 2), s.partial);
    try testing.expectEqual(@as(usize, 2), s.distinct);
}

test "pane_sidebar_layer: clicks take the column and the card, never the shadow or the margin" {
    const t = testGeometry(1.0);
    const mid_y: i32 = @divTrunc(t.h, 2);
    try testing.expect(hits(t.g, 34, 2)); // the column strip, above the card
    try testing.expect(hits(t.g, 150, mid_y)); // the card's middle
    try testing.expect(!hits(t.g, t.w - 6, mid_y)); // the trailing margin
    try testing.expect(!hits(t.g, @as(i32, @intFromFloat(t.g.card.right)) + 1, mid_y)); // the shadow
    try testing.expect(!hits(t.g, t.w - 13, 12)); // the rounded-off top-right corner
    try testing.expect(!hits(t.g, 150, t.h - 3)); // under the card
    try testing.expect(!hits(t.g, -1, 5));
}

const test_glass: Glass = .{ .tint = .{ .r = 0, .g = 0, .b = 0 }, .scale = 1.0 };

test "T1887: the glass card is the tint at 30% over what lies beneath, with no lifting wash" {
    const t = testGeometry(1.0);
    // The card's middle: the sheet alone (the sheen has all but faded by
    // mid-height, and a black tint keeps nothing of white).
    const mid = glassAt(t.g, test_glass, 150, 300);
    try testing.expect(mid.a >= OVERLAY_TINT and mid.a < OVERLAY_TINT + 0.03);
    // Over a mid-grey desk it darkens by the tint, and a wash would have
    // lifted it back: it must stay below 70% of the desk plus the sheen.
    const grey: u32 = 0x00808080;
    const on = mid.onto(grey);
    const r: f32 = @floatFromInt((on >> 16) & 0xFF);
    try testing.expect(r >= 128 * 0.7 - 1 and r < 128 * 0.7 + 4);
    // Two desks give two answers: the sheet is see-through.
    try testing.expect(mid.onto(0x00204080) != mid.onto(0x00804020));
    // A light tint pulls toward itself instead.
    const light = glassAt(t.g, .{ .tint = .{ .r = 255, .g = 255, .b = 255 }, .scale = 1.0 }, 150, 300);
    try testing.expect((light.onto(0x00000000) >> 16) & 0xFF >= 70);
}

test "T1887: the glass card is lighter than a pane's sheet" {
    try testing.expect(OVERLAY_TINT < pane_elevation.GLASS_TINT);
}

test "T1887: shadows fall around the card and never on the sheet" {
    const t = testGeometry(1.0);
    const card = t.g.card;
    const below = glassAt(t.g, test_glass, 150, @as(i32, @intFromFloat(card.bottom)) + 3);
    try testing.expect(below.a > 0.05);
    try testing.expectEqual(@as(f32, 0), below.r);
    // Far away: nothing at all.
    const far = glassAt(t.g, test_glass, t.w - 1, 2);
    try testing.expect(far.a < 0.01);
    // Inside, the sheet's alpha is the tint's, not tint plus shadow.
    const inside = glassAt(t.g, test_glass, 150, @as(i32, @intFromFloat(card.top)) + 40);
    try testing.expect(inside.a < OVERLAY_TINT + 0.11);
}

test "T1887: the rim lights the card's top edge" {
    const t = testGeometry(1.0);
    const edge = glassAt(t.g, test_glass, 132, @as(i32, @intFromFloat(t.g.card.top)));
    const below = glassAt(t.g, test_glass, 132, @as(i32, @intFromFloat(t.g.card.top)) + 6);
    try testing.expect(edge.r > below.r);
}

test "T1887: buildGlass is opaque over the desk in the column and see-through past it" {
    const w: i32 = 200;
    const h: i32 = 120;
    const g = Geometry.init(40, banner_card.Metrics.init(w, h, 1.0));
    var under: [200 * 120]u32 = undefined;
    @memset(&under, 0x00305070);
    var out: [200 * 120]u32 = undefined;
    buildGlass(&out, w, h, g, test_glass, 40, &under);
    // The column strip on the card: opaque, the sheet over the desk.
    const col = out[60 * 200 + 20];
    try testing.expectEqual(@as(u32, 0xFF), col >> 24);
    try testing.expectEqual(glassAt(g, test_glass, 20, 60).onto(0x00305070), col);
    // Past the column, the card is partial alpha - the panes show through.
    const card = out[60 * 200 + 120];
    try testing.expect(card >> 24 > 60 and card >> 24 < 100);
    // A valid premultiplied pixel everywhere.
    for (out) |p| {
        const a = p >> 24;
        try testing.expect(((p >> 16) & 0xFF) <= a and ((p >> 8) & 0xFF) <= a and (p & 0xFF) <= a);
    }
}

test "T1887: composeOver - glass where nothing was painted, content opaque, edges partial" {
    const glass_px: u32 = 0x4D0A0A0A; // ~30% alpha
    var on_black = [_]u32{ 0x00000000, 0x00C0C0C0, 0x00606060, 0x00FF0000 };
    const on_white = [_]u32{ 0x00FFFFFF, 0x00C0C0C0, 0x00E0E0E0, 0x00FF0000 };
    const glass = [_]u32{ glass_px, glass_px, glass_px, glass_px };
    composeOver(&on_black, &on_white, &glass);
    // Unpainted: the glass, untouched.
    try testing.expectEqual(glass_px, on_black[0]);
    // Opaque content: itself.
    try testing.expectEqual(@as(u32, 0xFFC0C0C0), on_black[1]);
    try testing.expectEqual(@as(u32, 0xFFFF0000), on_black[3]);
    // A text edge at half coverage: more alpha than the glass, less than 1.
    const a = on_black[2] >> 24;
    try testing.expect(a > 0x4D and a < 0xFF);
    for (on_black) |p| {
        const pa = p >> 24;
        try testing.expect(((p >> 16) & 0xFF) <= pa and ((p >> 8) & 0xFF) <= pa and (p & 0xFF) <= pa);
    }
}

test "T1887: buildGlass's interior fast path is the per-pixel answer" {
    const w: i32 = 220;
    const h: i32 = 300;
    const g = Geometry.init(30, banner_card.Metrics.init(w, h, 1.5));
    const n: usize = @intCast(w * h);
    const out = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(out);
    const under = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(under);
    @memset(under, 0x00405060);
    const gl: Glass = .{ .tint = .{ .r = 20, .g = 22, .b = 26 }, .scale = 1.5 };
    buildGlass(out, w, h, g, gl, 30, under);
    var y: i32 = 0;
    while (y < h) : (y += 5) {
        var x: i32 = 0;
        while (x < w) : (x += 3) {
            const p = glassAt(g, gl, x, y);
            const want = if (x < 30) p.onto(0x00405060) else p.pack();
            const got = out[@intCast(y * w + x)];
            // Far pixels skip the (vanishing) shadow tail: allow one level.
            const d = @max(got >> 24, want >> 24) - @min(got >> 24, want >> 24);
            try testing.expect(d <= 1);
        }
    }
}
