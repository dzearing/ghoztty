//! Each pane's own hue in the pane sidebar, and the tint a pane takes while
//! its sidebar row or tile is under the pointer (T2278; Mac `PaneSidebarHue`,
//! `PaneSidebarHover`, `PaneSidebarHoverTint` - 075d787d1, dc2bbab6b,
//! 75dc046e3).
//!
//! A pane's hue is spaced by the golden ratio along its place in its tab's
//! tree (stashed panes included), so neighbours never come out alike and a
//! reorder of the list changes no pane's colour. Only the sidebar's GLYPH
//! carries it: light and soft on a dark theme, deeper on a light one, a touch
//! quieter when the row is neither the focused one nor hovered. Hovering the
//! row or tile washes the pane itself in that hue (10%) with a 2 DIP rim
//! (45%), faded in over 0.12 s and back out over 0.2 s.
//!
//! No OS imports, so this unit-tests in every app-runtime lane; the window
//! half is `HoverTint.zig`, the paint is `PaneSidebar.zig`.

const std = @import("std");
const color_math = @import("color_math.zig");

const Rgb = color_math.Rgb;

/// The hue, 0..<1, of the pane at `index` of its tab's tree (Mac
/// `PaneSidebarHue.hue(index:)`).
pub fn hue(index: usize) f64 {
    const h = @mod(0.58 + @as(f64, @floatFromInt(index)) * 0.618_033_988_75, 1.0);
    return if (h < 0) h + 1 else h;
}

/// The pane's colour (Mac `PaneSidebarHue.color(index:)`): saturation 0.42 at
/// full brightness on a dark theme - at full saturation the deep hues sank
/// into the sidebar - and 0.7 at 0.62 on a light one, where a pastel would
/// vanish.
pub fn color(index: usize, dark: bool) Rgb {
    return color_math.hsbToRgb(if (dark)
        .{ .h = hue(index), .s = 0.42, .b = 1 }
    else
        .{ .h = hue(index), .s = 0.7, .b = 0.62 });
}

/// How strong an icon's hue is when its row is neither the focused one (in a
/// window that has the focus) nor hovered: Mac's `hue.opacity(0.8)`.
pub const quiet_opacity: f64 = 0.8;

/// The ink of a pane's sidebar glyph over `under` (Mac `iconColor`): the hue
/// itself when the row is strong, else the hue at `quiet_opacity`. Windows
/// has no accent selection pill, so Mac's white-on-accent arm never applies.
pub fn iconInk(c: Rgb, under: Rgb, strong: bool) Rgb {
    return if (strong) c else color_math.mix(under, c, quiet_opacity);
}

/// The leaf position of `view` in `tree` (every leaf, stashed included, in
/// the tree's own order - Mac's `surfaceTree.enumerated()`), or 0 when it is
/// not there.
pub fn treeIndex(tree: anytype, view: anytype) usize {
    var it = tree.leafIterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        if (entry.view == view) return i;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// The hover tint
// ---------------------------------------------------------------------------

/// Mac `shape.fill(hover.color.opacity(0.1))`.
pub const wash_alpha: f64 = 0.1;
/// Mac `shape.strokeBorder(hover.color.opacity(0.45), lineWidth: 2)`.
pub const rim_alpha: f64 = 0.45;
pub const rim_dip: f32 = 2;
/// Mac `PaneSidebarHover.fadeIn` / `fadeOut` (`.easeOut`).
pub const fade_in_ms: i64 = 120;
pub const fade_out_ms: i64 = 200;

/// The rim's width in device pixels at `scale`, never thinner than one.
pub fn rimPx(scale: f32) i32 {
    const s = if (std.math.isNan(scale) or scale <= 0) 1.0 else scale;
    return @max(1, @as(i32, @intFromFloat(@round(rim_dip * s))));
}

/// `c` at `alpha` as one premultiplied BGRA pixel (what
/// `UpdateLayeredWindow` takes).
pub fn premultiplied(c: Rgb, alpha: f64) u32 {
    const a: u32 = @intFromFloat(std.math.clamp(@round(alpha * 255), 0, 255));
    const ch = struct {
        fn f(v: u8, a_: u32) u32 {
            return (@as(u32, v) * a_ + 127) / 255;
        }
    }.f;
    return (a << 24) | (ch(c.r, a) << 16) | (ch(c.g, a) << 8) | ch(c.b, a);
}

/// The shape the tint follows: the pane's own - a rounded card in the
/// elevated style (`radius` > 0), square when flat - with its top corners
/// square when a header or banner above it carries the card's top curve.
pub const Shape = struct {
    radius: i32 = 0,
    square_top: bool = false,
};

/// What the tint is at pixel (`x`, `y`) of a `w` x `h` pane: outside the
/// shape (a rounded corner's cut-out), the rim, or the wash inside it.
pub const Zone = enum { outside, rim, wash };

pub fn zoneAt(x: i32, y: i32, w: i32, h: i32, rim: i32, shape: Shape) Zone {
    const fx = @as(f32, @floatFromInt(x)) + 0.5;
    const fy = @as(f32, @floatFromInt(y)) + 0.5;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const r: f32 = @floatFromInt(@max(@min(shape.radius, @divTrunc(@min(w, h), 2)), 0));
    // Distance inward from the shape's edge: the nearest straight edge, or
    // in a rounded corner the radius less the distance to its centre.
    var d = @min(@min(fx, fw - fx), @min(fy, fh - fy));
    if (r > 0) {
        const cx: ?f32 = if (fx < r) r else if (fx > fw - r) fw - r else null;
        const cy: ?f32 = if (fy < r and !shape.square_top) r else if (fy > fh - r) fh - r else null;
        if (cx != null and cy != null) {
            const dx = fx - cx.?;
            const dy = fy - cy.?;
            d = r - @sqrt(dx * dx + dy * dy);
        }
    }
    if (d < 0) return .outside;
    if (d < @as(f32, @floatFromInt(rim))) return .rim;
    return .wash;
}

/// Fill `px` (a top-down `w` x `h` buffer) with the tint in `c`: the wash
/// inside, the rim over the wash along the edge (inset, Mac's
/// `strokeBorder`), nothing outside a rounded corner.
pub fn renderTint(px: []u32, w: i32, h: i32, c: Rgb, rim: i32, shape: Shape) void {
    if (w <= 0 or h <= 0) return;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    std.debug.assert(px.len >= uw * uh);
    const wash = premultiplied(c, wash_alpha);
    // The rim is stroked OVER the wash: one colour, so the two alphas
    // compose as a + w(1 - a).
    const edge = premultiplied(c, rim_alpha + wash_alpha * (1 - rim_alpha));
    // Only the corner squares can hold anything but the straight-edge
    // answer; everything else is a row of rim | wash | rim.
    const r: usize = @intCast(@max(@min(shape.radius, @divTrunc(@min(w, h), 2)), 0));
    const bw: usize = @intCast(@max(rim, 0));
    for (0..uh) |y| {
        const row = px[y * uw ..][0..uw];
        const in_corner_rows = (y < r and !shape.square_top) or y + r >= uh;
        if (!in_corner_rows) {
            if (y < bw or y + bw >= uh) {
                @memset(row, edge);
                continue;
            }
            const side = @min(bw, uw);
            @memset(row, wash);
            @memset(row[0..side], edge);
            @memset(row[uw - side ..], edge);
            continue;
        }
        for (row, 0..) |*p, x| {
            p.* = switch (zoneAt(@intCast(x), @intCast(y), w, h, rim, shape)) {
                .outside => 0,
                .rim => edge,
                .wash => wash,
            };
        }
    }
}

/// SwiftUI's `.easeOut`: the cubic Bezier (0, 0) (0.58, 1), as y for a time
/// fraction `t` in 0..1. x(u) is monotonic, so u is found by bisection.
pub fn easeOut(t: f64) f64 {
    if (!(t > 0)) return 0;
    if (t >= 1) return 1;
    const bez = struct {
        fn at(u: f64, p1: f64, p2: f64) f64 {
            const v = 1 - u;
            return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u;
        }
    };
    var lo: f64 = 0;
    var hi: f64 = 1;
    for (0..40) |_| {
        const mid = (lo + hi) / 2;
        if (bez.at(mid, 0, 0.58) < t) lo = mid else hi = mid;
    }
    return bez.at((lo + hi) / 2, 0, 1);
}

/// How long a fade from `from` toward `to` takes: quick in, a touch slower
/// out, so running the pointer down the list never flickers.
pub fn fadeMs(from: u8, to: u8) i64 {
    return if (to > from) fade_in_ms else fade_out_ms;
}

/// The tint's whole-window opacity (0..255) `elapsed_ms` into a fade from
/// `from` toward `to`. A fade that reverses part-way starts from wherever the
/// last one got to, as SwiftUI retargets a running animation.
pub fn fadeAlpha(from: u8, to: u8, elapsed_ms: i64) u8 {
    const dur = fadeMs(from, to);
    if (elapsed_ms >= dur) return to;
    const t = @as(f64, @floatFromInt(@max(elapsed_ms, 0))) / @as(f64, @floatFromInt(dur));
    const e = easeOut(t);
    const f: f64 = @floatFromInt(from);
    const g: f64 = @floatFromInt(to);
    return @intFromFloat(std.math.clamp(@round(f + (g - f) * e), 0, 255));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "hue: Mac's golden-ratio walk from 0.58, always in 0..<1" {
    try testing.expectApproxEqAbs(@as(f64, 0.58), hue(0), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.19803398875), hue(1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8160679775), hue(2), 1e-9);
    for (0..500) |i| {
        const h = hue(i);
        try testing.expect(h >= 0 and h < 1);
    }
}

test "hue: neighbours in a tree never come out alike" {
    // The golden ratio keeps every pair of adjacent indices at least ~0.38
    // apart around the wheel.
    for (0..64) |i| {
        const d = @abs(hue(i + 1) - hue(i));
        try testing.expect(@min(d, 1 - d) > 0.3);
    }
}

test "color: light and soft on dark, deeper on light" {
    for (0..16) |i| {
        const d = color_math.rgbToHsb(color(i, true));
        const l = color_math.rgbToHsb(color(i, false));
        try testing.expectApproxEqAbs(@as(f64, 1.0), d.b, 0.01);
        try testing.expectApproxEqAbs(@as(f64, 0.42), d.s, 0.02);
        try testing.expectApproxEqAbs(@as(f64, 0.62), l.b, 0.01);
        try testing.expectApproxEqAbs(@as(f64, 0.7), l.s, 0.02);
        // The dark-theme ink is brighter than the light-theme ink.
        try testing.expect(color_math.luminance(color(i, true)) > color_math.luminance(color(i, false)));
    }
    // Index 0 is a blue (hue 0.58): blue leads.
    const c0 = color(0, true);
    try testing.expect(c0.b > c0.r and c0.b > c0.g);
}

test "iconInk: strong is the hue, quiet is the hue at 80% over what it sits on" {
    const c: Rgb = .{ .r = 200, .g = 100, .b = 50 };
    const under: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    try testing.expectEqual(c, iconInk(c, under, true));
    try testing.expectEqual(Rgb{ .r = 160, .g = 80, .b = 40 }, iconInk(c, under, false));
}

test "treeIndex: a leaf's place in tree order, 0 when absent" {
    const Fake = struct {
        const View = u8;
        views: []const *const u8,
        const Entry = struct { view: *const u8 };
        const It = struct {
            v: []const *const u8,
            i: usize = 0,
            fn next(self: *It) ?Entry {
                if (self.i == self.v.len) return null;
                defer self.i += 1;
                return .{ .view = self.v[self.i] };
            }
        };
        fn leafIterator(self: @This()) It {
            return .{ .v = self.views };
        }
    };
    const a: u8 = 1;
    const b: u8 = 2;
    const c: u8 = 3;
    const missing: u8 = 4;
    const tree: Fake = .{ .views = &.{ &a, &b, &c } };
    try testing.expectEqual(@as(usize, 0), treeIndex(tree, &a));
    try testing.expectEqual(@as(usize, 2), treeIndex(tree, &c));
    try testing.expectEqual(@as(usize, 0), treeIndex(tree, &missing));
}

test "premultiplied: alpha in the top byte, each channel scaled by it" {
    const p = premultiplied(.{ .r = 255, .g = 128, .b = 0 }, 0.45);
    try testing.expectEqual(@as(u32, 115), p >> 24);
    try testing.expectEqual(@as(u32, 115), (p >> 16) & 0xFF);
    try testing.expectEqual(@as(u32, 58), (p >> 8) & 0xFF);
    try testing.expectEqual(@as(u32, 0), p & 0xFF);
    try testing.expectEqual(@as(u32, 0), premultiplied(.{ .r = 9, .g = 9, .b = 9 }, 0));
}

test "rimPx: Mac's 2pt scaled, at least one pixel" {
    try testing.expectEqual(@as(i32, 2), rimPx(1.0));
    try testing.expectEqual(@as(i32, 3), rimPx(1.5));
    try testing.expectEqual(@as(i32, 4), rimPx(2.0));
    try testing.expectEqual(@as(i32, 1), rimPx(0.2));
    try testing.expectEqual(@as(i32, 2), rimPx(std.math.nan(f32)));
}

test "renderTint flat: rim of rim px on every side, wash inside" {
    const w = 10;
    const h = 8;
    var px: [w * h]u32 = undefined;
    const c: Rgb = .{ .r = 255, .g = 0, .b = 0 };
    renderTint(&px, w, h, c, 2, .{});
    const wash = premultiplied(c, wash_alpha);
    const edge = premultiplied(c, rim_alpha + wash_alpha * (1 - rim_alpha));
    try testing.expectEqual(edge, px[0]);
    try testing.expectEqual(edge, px[1 * w + 1]);
    try testing.expectEqual(wash, px[2 * w + 2]);
    try testing.expectEqual(wash, px[5 * w + 7]);
    try testing.expectEqual(edge, px[5 * w + 8]);
    try testing.expectEqual(edge, px[7 * w + 5]);
    // The rim is the stronger of the two.
    try testing.expect((edge >> 24) > (wash >> 24));
}

test "renderTint rounded: the corner is cut out and the rim follows the curve" {
    const w = 40;
    const h = 30;
    var px: [w * h]u32 = undefined;
    const c: Rgb = .{ .r = 0, .g = 255, .b = 0 };
    renderTint(&px, w, h, c, 2, .{ .radius = 10 });
    const wash = premultiplied(c, wash_alpha);
    const edge = premultiplied(c, rim_alpha + wash_alpha * (1 - rim_alpha));
    // Every corner pixel lies outside the curve.
    try testing.expectEqual(@as(u32, 0), px[0]);
    try testing.expectEqual(@as(u32, 0), px[w - 1]);
    try testing.expectEqual(@as(u32, 0), px[(h - 1) * w]);
    try testing.expectEqual(@as(u32, 0), px[(h - 1) * w + w - 1]);
    // On the diagonal of the top-left corner: out, then rim, then wash.
    // The curve crosses the diagonal at 10 - 10/sqrt2 ~ 2.93.
    try testing.expectEqual(@as(u32, 0), px[2 * w + 2]);
    try testing.expectEqual(edge, px[3 * w + 3]);
    try testing.expectEqual(wash, px[6 * w + 6]);
    // The straight edges between the corners are plain rim.
    try testing.expectEqual(edge, px[0 * w + 20]);
    try testing.expectEqual(edge, px[15 * w + 0]);
    try testing.expectEqual(wash, px[15 * w + 2]);
}

test "renderTint square_top: the top corners stay square, the bottom ones round" {
    const w = 40;
    const h = 30;
    var px: [w * h]u32 = undefined;
    const c: Rgb = .{ .r = 0, .g = 0, .b = 255 };
    renderTint(&px, w, h, c, 2, .{ .radius = 10, .square_top = true });
    try testing.expect(px[0] != 0);
    try testing.expect(px[w - 1] != 0);
    try testing.expectEqual(@as(u32, 0), px[(h - 1) * w]);
}

test "renderTint: a radius larger than the pane is clamped, nothing panics" {
    var px: [6 * 4]u32 = undefined;
    renderTint(&px, 6, 4, .{ .r = 1, .g = 2, .b = 3 }, 3, .{ .radius = 100 });
    var one: [1]u32 = undefined;
    renderTint(&one, 1, 1, .{ .r = 1, .g = 2, .b = 3 }, 2, .{});
    try testing.expect(one[0] != 0);
}

test "easeOut: SwiftUI's curve, fast first and settling" {
    try testing.expectEqual(@as(f64, 0), easeOut(0));
    try testing.expectEqual(@as(f64, 1), easeOut(1));
    try testing.expectEqual(@as(f64, 0), easeOut(-1));
    try testing.expectEqual(@as(f64, 1), easeOut(2));
    // Ahead of linear the whole way.
    var t: f64 = 0.1;
    while (t < 1) : (t += 0.1) try testing.expect(easeOut(t) > t);
    try testing.expect(easeOut(0.2) < easeOut(0.4));
}

test "fadeAlpha: 0.12 s in, 0.2 s out, retargeting from where it was" {
    try testing.expectEqual(@as(i64, 120), fadeMs(0, 255));
    try testing.expectEqual(@as(i64, 200), fadeMs(255, 0));
    try testing.expectEqual(@as(u8, 0), fadeAlpha(0, 255, 0));
    try testing.expectEqual(@as(u8, 255), fadeAlpha(0, 255, 120));
    try testing.expectEqual(@as(u8, 255), fadeAlpha(0, 255, 500));
    try testing.expect(fadeAlpha(0, 255, 60) > 128);
    // Out is still under way when in would be done.
    try testing.expect(fadeAlpha(255, 0, 120) > 0);
    try testing.expectEqual(@as(u8, 0), fadeAlpha(255, 0, 200));
    // A reversal part-way starts from the alpha it had reached.
    try testing.expectEqual(@as(u8, 140), fadeAlpha(140, 0, 0));
}
