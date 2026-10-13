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
